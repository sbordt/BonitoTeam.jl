# Server-side handlers for inbound worker connections. Workers dial the
# server; the server tracks each worker's "control" WS and pairs per-session
# ACP WSs with the right project.
#
# Endpoints (registered as Bonito websocket_route!s):
#   /worker-ws    → control channel. Worker sends a hello frame; we register
#                   it in WORKERS, mark online, and keep the WS for sending
#                   commands like "open_session" / "open_transfer" back.
#   /worker-acp   → per-session WS. Worker dials this in response to an
#                   "open_session" command and identifies the WS by sid; we
#                   pair it with a Channel that `start_session_on_worker` is
#                   blocked on.
#   /transfer-ws  → directional librsync transfer; worker dials this in
#                   response to an "open_transfer" command; pairs the WS
#                   with whichever sync_dir_*_worker! call is waiting.

using HTTP, HTTP.WebSockets, JSON, AgentClientProtocol, RemoteSync

# Lazily register HTTP.WebSockets with RemoteSync's WebSocketIO so it knows
# how to recv_frame/send_frame!/is_closed on a live HTTP.WebSocket. Done on
# first transfer rather than at module load to avoid a circular init.
const REMOTESYNC_HTTP_REGISTERED = Ref(false)
function ensure_remotesync_http!()
    REMOTESYNC_HTTP_REGISTERED[] && return
    RemoteSync.register_http_websockets!(HTTP.WebSockets)
    REMOTESYNC_HTTP_REGISTERED[] = true
    return
end

# name → live control WS (used by the server to push commands to the worker)
const WORKER_CONTROL_WS = Dict{String,Any}()
# sid → Channel{Any} where the matching /worker-acp upgrade hands off the WS
const PENDING_ACP_SESSIONS = Dict{String,Channel{Any}}()
# sync_id → Channel{Any} where the /transfer-ws upgrade hands off the WS for
# a RemoteSync (librsync) directional transfer.
const PENDING_TRANSFERS = Dict{String,Channel{Any}}()
# request_id → Channel{Dict} where worker's list_dir_response is handed back
# to the dashboard task that issued the RPC
const PENDING_LIST_DIR = Dict{String,Channel{Dict}}()
# request_id → Channel where worker's scan_sessions_result is handed back
const PENDING_SCAN_SESSIONS = Dict{String,Channel{Vector{Dict{String,Any}}}}()

# Send a JSON command to a worker over its control WS. Throws if the worker
# isn't currently connected.
function send_command(worker_name::String, payload::AbstractDict)
    haskey(WORKER_CONTROL_WS, worker_name) ||
        error("Worker '$worker_name' is not connected")
    WebSockets.send(WORKER_CONTROL_WS[worker_name], JSON.json(payload))
    return nothing
end

# Take from a pending-handoff channel with a bounded wait. If `timeout` seconds
# elapse without the worker dialing back, we evict the entry from `pending`
# (so the worker gets "unknown id" if it arrives late) and put `nothing` on
# the channel; callers see that and raise `op_name timed out`.
#
# `pending::AbstractDict` and `key::String` are the dict + key that the
# matching handler `pop!`s when the worker arrives. Both sides race-tolerant
# via the haskey guard.
function take_pending!(ch::Channel, pending::AbstractDict, key::String,
                       timeout::Real, op_name::AbstractString)
    Base.errormonitor(@async begin
        sleep(timeout)
        if haskey(pending, key)
            delete!(pending, key)
            try put!(ch, nothing) catch end
        end
    end)
    val = take!(ch)
    val === nothing && error("$op_name timed out after $(timeout)s — worker may be offline or stuck")
    return val
end

# Handler for /worker-ws — runs once per worker, for the worker's lifetime.
function handle_worker_control(ws, worker_secret::String)
    name = "?"
    try
        hello_raw = WebSockets.receive(ws)
        hello = JSON.parse(String(hello_raw))
        if get(hello, "secret", "") != worker_secret
            try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"unauthorized"))) catch end
            return
        end
        name = String(get(hello, "name", get(hello, "hostname", "anon")))

        WebSockets.send(ws, JSON.json(Dict("ok" => true, "registered_as" => name)))

        # Build / refresh the WorkerInfo from the hello frame.
        w = WorkerInfo(
            name,
            "<inbound-ws>",          # we no longer dial the worker; URL is moot
            worker_secret,
            nothing,                 # ssh_target reserved for future rsync-over-ssh
            String(get(hello, "hostname", "")),
            String(get(hello, "home", "")),
            String(get(hello, "mcp_path", "")),
            String(get(hello, "projects_root", "")),
            :online,
            now(UTC),
        )
        WORKERS[name] = w
        WORKER_CONTROL_WS[name] = ws
        save_workers!()
        bump_state!()
        @info "Worker connected" name=name hostname=w.hostname

        # Re-attach any persisted projects on this worker now that it's online.
        for p in values(PROJECTS)
            p.worker_name == name || continue
            try
                ensure_project_session!(p)
            catch e
                @warn "Failed to (re)attach project on connect" project=p.name exception=e
            end
        end

        # Process inbound frames from the worker.
        for frame in ws
            try
                cmd = JSON.parse(String(frame))
                t = get(cmd, "type", "")
                if t == "list_dir_response"
                    rid = String(get(cmd, "request_id", ""))
                    if haskey(PENDING_LIST_DIR, rid)
                        ch = pop!(PENDING_LIST_DIR, rid)
                        put!(ch, Dict{String,Any}(cmd))
                    end
                elseif t == "scan_sessions_result"
                    rid = String(get(cmd, "request_id", ""))
                    if haskey(PENDING_SCAN_SESSIONS, rid)
                        ch = pop!(PENDING_SCAN_SESSIONS, rid)
                        sessions = [Dict{String,Any}(s)
                                    for s in get(cmd, "sessions", Any[])]
                        put!(ch, sessions)
                    end
                end
            catch e
                @warn "Worker control frame error" exception=e
            end
        end
    finally
        delete!(WORKER_CONTROL_WS, name)
        if haskey(WORKERS, name)
            WORKERS[name].status = :offline
            bump_state!()
        end
        # Auto-release any project locks held by this worker — its claude
        # processes are gone, so the locks are stale.
        release_locks_for_worker!(name)
        # Tear down the chat_app's PROJECT_APPS entry so the next reconnect
        # builds a fresh ACP session.
        for p in values(PROJECTS)
            if p.worker_name == name
                delete!(PROJECT_APPS, p.id)
            end
        end
        @info "Worker disconnected" name=name
    end
end

# Handler for /transfer-ws — one invocation per directional RemoteSync transfer.
# Worker (from inside its Malt subprocess) dials this in response to an
# `open_transfer` command on the control WS. We hand the live WS to the
# orchestrator task that called sync_dir_to_worker!/sync_dir_from_worker!.
function handle_transfer_ws(ws, worker_secret::String)
    auth_raw = WebSockets.receive(ws)
    auth = JSON.parse(String(auth_raw))
    if get(auth, "secret", "") != worker_secret
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"unauthorized"))) catch end
        return
    end
    sync_id = String(get(auth, "sync_id", ""))
    if isempty(sync_id)
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"missing sync_id"))) catch end
        return
    end
    ch = nothing
    try
        ch = pop!(PENDING_TRANSFERS, sync_id)
    catch e
        e isa KeyError || rethrow()
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false,
                                                "error"=>"unknown or expired sync_id"))) catch end
        return
    end
    WebSockets.send(ws, JSON.json(Dict("ok" => true)))
    put!(ch, ws)

    # Hold the WS open for the duration of the transfer. The orchestrator
    # task is reading/writing through it on the same process; we just need
    # to keep Bonito from tearing down the underlying connection.
    while !WebSockets.isclosed(ws)
        sleep(1)
    end
end

# Handler for /worker-acp — one invocation per ACP session.
function handle_worker_acp(ws, worker_secret::String)
    auth_raw = WebSockets.receive(ws)
    auth = JSON.parse(String(auth_raw))
    if get(auth, "secret", "") != worker_secret
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"unauthorized"))) catch end
        return
    end
    sid = String(get(auth, "sid", ""))
    if isempty(sid)
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"missing sid"))) catch end
        return
    end
    ch = nothing
    try
        ch = pop!(PENDING_ACP_SESSIONS, sid)
    catch e
        e isa KeyError || rethrow()
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false,
                                                "error"=>"unknown or expired sid"))) catch end
        return
    end
    WebSockets.send(ws, JSON.json(Dict("ok" => true)))
    put!(ch, ws)

    # Block here so Bonito keeps the WS open for the duration of the session.
    while !WebSockets.isclosed(ws)
        sleep(1)
    end
end

# Server-side ACP client over an accepted WS
"""
    start_session_on_worker(worker_name, cwd; on_update, mcp_servers,
                             request_handler) → AgentClientProtocol.Client

Tell the worker to spawn claude-agent-acp for `cwd` and dial back an ACP WS.
Block until the WS arrives, then drive `initialize` + `session/new`. Returns
the live ACP `Client`.
"""
function start_session_on_worker(worker_name::String, cwd::String;
                                  on_update::Function       = identity,
                                  mcp_servers               = [],
                                  request_handler::Function = AgentClientProtocol.make_request_handler(cwd),
                                  timeout::Real             = 30.0)

    haskey(WORKER_CONTROL_WS, worker_name) ||
        error("Worker '$worker_name' is not connected")

    sid = string(uuid4())
    ch  = Channel{Any}(1)
    PENDING_ACP_SESSIONS[sid] = ch

    mcp_list = [Dict("name"    => s.name,
                     "command" => s.command,
                     "args"    => s.args,
                     "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
                for s in mcp_servers]

    # Find the project this session belongs to so the worker can tag its
    # delta frames with project_id (server uses it to apply diffs to the
    # right server_path).
    project_id = ""
    for p in values(PROJECTS)
        p.worker_name == worker_name && p.worker_path == cwd && (project_id = p.id; break)
    end

    send_command(worker_name, Dict(
        "type"       => "open_session",
        "sid"        => sid,
        "project_id" => project_id,
        "cwd"        => cwd,
        "env"        => Dict{String,String}(),
        "mcpServers" => mcp_list,
    ))

    # Wait for the worker's /worker-acp upgrade — bounded so a dead worker
    # doesn't hang the dashboard task that triggered the session.
    ws = take_pending!(ch, PENDING_ACP_SESSIONS, sid, timeout,
                      "open_session on '$worker_name'")

    conn = ws_connection(ws; request_handler, update_handler = on_update)

    AgentClientProtocol.send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict(
            "fs" => Dict("readTextFile" => true, "writeTextFile" => true),
        ),
        "clientInfo" => Dict("name" => "BonitoTeam", "version" => "0.1.0"),
    ))

    result     = AgentClientProtocol.send_request(conn, "session/new",
                     Dict("cwd" => cwd, "mcpServers" => mcp_list))
    session_id = result["sessionId"]

    return AgentClientProtocol.Client(conn, session_id, cwd)
end

# File transport over WS

# RemoteSync transfer (librsync-based, IO-streamed over /transfer-ws).
# Both directions share the same orchestration: we generate a sync_id, tell
# the worker to dial in (the worker side spawns its own Malt subprocess so
# the librsync work doesn't pin the worker's ACP relay loop), wait for the
# WS handoff, then run the matching RemoteSync side here in a Task.
#
# The server side runs in-process (Task) rather than its own subprocess: the
# work is interleaved with WS reads/writes (which yield) and per-file IO
# (which yields), so the main task's heartbeat loop stays responsive even on
# multi-GB transfers.

"""
    sync_dir_to_worker!(worker_name, src, dst; on_progress=nothing)

Send the contents of server-side `src` to worker-side `dst` via librsync.
Resumable: subsequent calls compute deltas against the worker's existing
files, so unchanged content isn't retransmitted.
"""
function sync_dir_to_worker!(worker_name::String, src::String, dst::String;
                              handoff_timeout::Real = 30.0,
                              on_progress = nothing)
    isdir(src) || error("Source path is not a directory: $src")
    haskey(WORKER_CONTROL_WS, worker_name) ||
        error("Worker '$worker_name' is not connected")
    ensure_remotesync_http!()

    sync_id = string(uuid4())
    ch = Channel{Any}(1)
    PENDING_TRANSFERS[sync_id] = ch

    notify_str(on_progress, "Connecting to worker…")
    send_command(worker_name, Dict(
        "type"      => "open_transfer",
        "sync_id"   => sync_id,
        "direction" => "to_worker",
        "dst_path"  => dst,
    ))

    ws = take_pending!(ch, PENDING_TRANSFERS, sync_id, handoff_timeout,
                      "sync to '$worker_name'")
    try
        notify_str(on_progress, "Streaming via librsync…")
        wsio = RemoteSync.WebSocketIO(ws)
        RemoteSync.send_directory(src, wsio;
            on_progress = (stage, info) -> remotesync_progress(on_progress, stage, info))
        notify_str(on_progress, "Done")
    finally
        try close(ws) catch end
    end
    return nothing
end

"""
    sync_dir_from_worker!(worker_name, src, dst; on_progress=nothing)

Inverse: receive worker-side `src` into server-side `dst` via librsync.
Resumable in the same way as `sync_dir_to_worker!`.
"""
function sync_dir_from_worker!(worker_name::String, src::String, dst::String;
                                handoff_timeout::Real = 30.0,
                                on_progress = nothing)
    haskey(WORKER_CONTROL_WS, worker_name) ||
        error("Worker '$worker_name' is not connected")
    ensure_remotesync_http!()
    mkpath(dst)

    sync_id = string(uuid4())
    ch = Channel{Any}(1)
    PENDING_TRANSFERS[sync_id] = ch

    notify_str(on_progress, "Connecting to worker…")
    send_command(worker_name, Dict(
        "type"      => "open_transfer",
        "sync_id"   => sync_id,
        "direction" => "from_worker",
        "src_path"  => src,
    ))

    ws = take_pending!(ch, PENDING_TRANSFERS, sync_id, handoff_timeout,
                      "sync from '$worker_name'")
    try
        notify_str(on_progress, "Streaming via librsync…")
        wsio = RemoteSync.WebSocketIO(ws)
        RemoteSync.receive_directory(dst, wsio;
            on_progress = (stage, info) -> remotesync_progress(on_progress, stage, info))
        notify_str(on_progress, "Done")
    finally
        try close(ws) catch end
    end
    return nothing
end

# Translate RemoteSync's structured progress events into the human-readable
# strings the dashboard busy_msg observable shows.
function remotesync_progress(cb, stage::Symbol, info)
    cb === nothing && return
    msg = if stage === :walk_done
        "Scanning files: $(info.count) found"
    elseif stage === :manifest_received
        "Receiving manifest: $(info.count) files"
    elseif stage === :plan_received
        "Planning: $(info.work) of $(info.planned) need transfer"
    elseif stage === :file_start
        "Sending $(info.idx)/$(info.total): $(info.rel)"
    elseif stage === :apply_start
        "Receiving $(info.idx)/$(info.total): $(info.rel)"
    elseif stage === :transfer_done
        haskey(info, :written) ?
            "Transfer complete: $(info.written) wrote, $(info.deleted) deleted, $(info.skipped) skipped" :
            "Transfer complete: $(info.files) files"
    else
        nothing
    end
    msg === nothing || notify_str(cb, msg)
    return
end

notify_str(::Nothing, _msg::AbstractString) = nothing
notify_str(cb, msg::AbstractString) = (try cb(msg) catch end; nothing)

# Human-readable byte counts used by the progress callbacks above.
function format_bytes(n::Integer)
    n < 1024            && return "$n B"
    n < 1024^2          && return string(round(n / 1024;     digits=1), " KB")
    n < 1024^3          && return string(round(n / 1024^2;   digits=1), " MB")
                           return string(round(n / 1024^3;   digits=2), " GB")
end
format_bytes(n) = format_bytes(Int(n))

"""
    list_worker_dir(worker_name, path; timeout=5.0) → (path, entries) | error

Ask the named worker to readdir() `path` over its control WS. Empty `path`
asks for the worker's \$HOME. Returns a NamedTuple of (path, entries) where
entries is a Vector of NamedTuple (name, dir).
"""
function list_worker_dir(worker_name::String, path::AbstractString;
                          timeout::Real = 5.0)
    haskey(WORKER_CONTROL_WS, worker_name) ||
        error("Worker '$worker_name' is not connected")

    rid = string(uuid4())
    ch = Channel{Dict}(1)
    PENDING_LIST_DIR[rid] = ch

    send_command(worker_name, Dict(
        "type"       => "list_dir",
        "request_id" => rid,
        "path"       => String(path),
    ))

    @async (sleep(timeout); isopen(ch) && put!(ch, Dict("error" => "list_dir timed out")))
    resp = take!(ch)
    haskey(resp, "error") && error("list_dir on '$worker_name': $(resp["error"])")
    return (path = String(resp["path"]),
            entries = [(name = String(e["name"]), dir = Bool(e["dir"]))
                       for e in resp["entries"]])
end

"""
    scan_worker_sessions(worker_name; timeout=15.0) → Vector{Dict{String,Any}}

Ask the named worker to scan for existing Claude Code sessions (running processes
+ ~/.claude/projects/ history) and return the results. Blocks until the worker
replies or `timeout` seconds elapse.
"""
function scan_worker_sessions(worker_name::String; timeout::Real = 15.0)
    haskey(WORKER_CONTROL_WS, worker_name) ||
        error("Worker '$worker_name' is not connected")
    rid = string(uuid4())
    ch  = Channel{Vector{Dict{String,Any}}}(1)
    PENDING_SCAN_SESSIONS[rid] = ch
    send_command(worker_name, Dict("type" => "scan_sessions", "request_id" => rid))
    @async begin
        sleep(timeout)
        if isopen(ch)
            put!(ch, [Dict{String,Any}("error" => "scan_sessions timed out")])
        end
    end
    return take!(ch)
end

# Build an AgentClientProtocol.Connection backed by a WebSocket. Each ACP
# message is one WS frame; the trailing newline is implicit in the framing.
function ws_connection(ws; request_handler, update_handler)
    send_line = line -> WebSockets.send(ws, rstrip(line, '\n'))
    read_line = ()   -> begin
        WebSockets.isclosed(ws) && return ""
        try
            String(WebSockets.receive(ws))
        catch e
            (e isa Base.IOError || e isa WebSockets.WebSocketError) && return ""
            rethrow(e)
        end
    end
    on_close = () -> begin
        try
            close(ws)
        catch e
            (e isa Base.IOError || e isa WebSockets.WebSocketError) && return
            @warn "ws_connection: close failed" exception=e
        end
    end
    return AgentClientProtocol.Connection(send_line, read_line, on_close;
                                          request_handler, update_handler)
end
