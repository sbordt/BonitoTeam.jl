# Server-side handlers for inbound worker connections. Workers dial the
# server; the server tracks each worker's "control" WS and pairs per-session
# ACP WSs with the right project.
#
# Endpoints (registered as Bonito websocket_route!s):
#   /worker-ws    → control channel. Worker sends a hello frame; we register
#                   it in state.workers, mark online, and keep the WS for
#                   sending commands like "open_session" / "open_transfer".
#   /worker-acp   → per-session WS. Worker dials this in response to an
#                   "open_session" command and identifies the WS by sid; we
#                   pair it with a Channel that `start_session_on_worker` is
#                   blocked on.
#   /transfer-ws  → directional librsync transfer; worker dials this in
#                   response to an "open_transfer" command; pairs the WS
#                   with whichever sync_dir_*_worker! call is waiting.

using HTTP, HTTP.WebSockets, JSON, AgentClientProtocol, RemoteSync

# All worker-related state lives on `state::ServerState`:
#   state.worker_control_ws — name → live HTTP.WebSocket
#   state.pending_rpcs      — request_id/sync_id/sid → Channel{Any}
#                              one dict for every RPC type (list_dir, scan_sessions,
#                              clone_repo, /transfer-ws handoff, /worker-acp handoff).
#                              The keys are uuids so collisions across types can't
#                              happen, and the unified shape is simpler than the
#                              previous five typed dicts.

# Send a JSON command to a worker over its control WS. Throws if the worker
# isn't currently connected.
function send_command(state::ServerState, worker_name::String, payload::AbstractDict)
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")
    WebSockets.send(state.worker_control_ws[worker_name], JSON.json(payload))
    return nothing
end

# Register a pending RPC: returns (request_id, channel). Caller sends the
# command (with `request_id`/`sync_id`/`sid` set to the returned id) and waits
# on the channel via `take_pending!`. The matching control-frame handler /
# WS upgrade pops the id out of `pending_rpcs` and puts the response on the
# channel.
function register_rpc!(state::ServerState)
    rid = string(uuid4())
    ch  = Channel{Any}(1)
    state.pending_rpcs[rid] = ch
    return (rid, ch)
end

# Take from a pending-RPC channel with a bounded wait. If `timeout` seconds
# elapse without the worker replying, evict the entry (so a late reply gets
# "unknown id") and surface a clear error to the caller.
function take_pending!(state::ServerState, ch::Channel, key::String,
                       timeout::Real, op_name::AbstractString)
    Base.errormonitor(@async begin
        sleep(timeout)
        if haskey(state.pending_rpcs, key)
            delete!(state.pending_rpcs, key)
            try put!(ch, nothing) catch end
        end
    end)
    val = take!(ch)
    val === nothing && error("$op_name timed out after $(timeout)s — worker may be offline or stuck")
    return val
end

# Try to deliver a worker-pushed RPC reply by request_id. No-op if the id is
# unknown (caller already timed out, or the response races a re-registration).
function deliver_rpc_response!(state::ServerState, rid::AbstractString, value)
    haskey(state.pending_rpcs, rid) || return
    ch = pop!(state.pending_rpcs, rid)
    try put!(ch, value) catch end
    return
end

# Handler for /worker-ws — runs once per worker, for the worker's lifetime.
function handle_worker_control(state::ServerState, ws)
    name = "?"
    try
        hello_raw = WebSockets.receive(ws)
        hello = JSON.parse(String(hello_raw))
        if get(hello, "secret", "") != state.worker_secret
            try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"unauthorized"))) catch end
            return
        end
        name = String(get(hello, "name", get(hello, "hostname", "anon")))

        WebSockets.send(ws, JSON.json(Dict("ok" => true, "registered_as" => name)))

        # Build / refresh the WorkerInfo from the hello frame.
        w = WorkerInfo(
            name,
            "<inbound-ws>",          # we no longer dial the worker; URL is moot
            state.worker_secret,
            nothing,                 # ssh_target reserved for future rsync-over-ssh
            String(get(hello, "hostname", "")),
            String(get(hello, "home", "")),
            String(get(hello, "mcp_path", "")),
            String(get(hello, "projects_root", "")),
            :online,
            now(UTC),
        )
        state.workers[name] = w
        state.worker_control_ws[name] = ws
        save_workers!(state)
        bump_state!(state)
        @info "Worker connected" name=name hostname=w.hostname

        # Re-attach any persisted projects on this worker now that it's online.
        for p in values(state.projects)
            p.worker_name == name || continue
            try
                ensure_project_session!(state, p)
            catch e
                @warn "Failed to (re)attach project on connect" project=p.name exception=e
            end
        end

        # Process inbound frames from the worker. Every typed reply maps
        # back to a pending RPC by request_id; deliver_rpc_response! is a
        # no-op if the id is unknown (caller already timed out).
        for frame in ws
            try
                cmd = JSON.parse(String(frame))
                t   = get(cmd, "type", "")
                rid = String(get(cmd, "request_id", ""))
                if t == "list_dir_response"
                    deliver_rpc_response!(state, rid, Dict{String,Any}(cmd))
                elseif t == "scan_sessions_result"
                    sessions = [Dict{String,Any}(s)
                                for s in get(cmd, "sessions", Any[])]
                    deliver_rpc_response!(state, rid, sessions)
                elseif t == "clone_repo_response"
                    deliver_rpc_response!(state, rid, Dict{String,Any}(cmd))
                end
            catch e
                @warn "Worker control frame error" exception=e
            end
        end
    finally
        delete!(state.worker_control_ws, name)
        if haskey(state.workers, name)
            state.workers[name].status = :offline
            bump_state!(state)
        end
        # Auto-release any project locks held by this worker — its claude
        # processes are gone, so the locks are stale.
        release_locks_for_worker!(state, name)
        # Tear down the chat_app's project_apps entry so the next reconnect
        # builds a fresh ACP session.
        for p in values(state.projects)
            if p.worker_name == name
                delete!(state.project_apps, p.id)
            end
        end
        @info "Worker disconnected" name=name
    end
end

# Handler for /transfer-ws — one invocation per directional RemoteSync transfer.
# Worker (from inside its Malt subprocess) dials this in response to an
# `open_transfer` command on the control WS. We hand the live WS to the
# orchestrator task that called sync_dir_to_worker!/sync_dir_from_worker!.
function handle_transfer_ws(state::ServerState, ws)
    handle_handoff_ws(state, ws, "sync_id"; close_on_exit = false)
end

# Handler for /worker-acp — one invocation per ACP session.
function handle_worker_acp(state::ServerState, ws)
    handle_handoff_ws(state, ws, "sid"; close_on_exit = false)
end

# Shared handoff: auth on the first frame (`{secret, <id_field>}`), look up
# the matching pending RPC channel by the id, ack with `{ok:true}`, hand the
# live WS to the waiting orchestrator task, then block until close so Bonito
# doesn't tear the connection down underneath us.
function handle_handoff_ws(state::ServerState, ws, id_field::AbstractString;
                            close_on_exit::Bool = false)
    auth_raw = WebSockets.receive(ws)
    auth = JSON.parse(String(auth_raw))
    if get(auth, "secret", "") != state.worker_secret
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"unauthorized"))) catch end
        return
    end
    id = String(get(auth, id_field, ""))
    if isempty(id)
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false,
                                                "error"=>"missing $id_field"))) catch end
        return
    end
    haskey(state.pending_rpcs, id) || begin
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false,
                                                "error"=>"unknown or expired $id_field"))) catch end
        return
    end
    ch = pop!(state.pending_rpcs, id)
    WebSockets.send(ws, JSON.json(Dict("ok" => true)))
    put!(ch, ws)

    while !WebSockets.isclosed(ws)
        sleep(1)
    end
    close_on_exit && try close(ws) catch end
end

# Server-side ACP client over an accepted WS
"""
    start_session_on_worker(worker_name, cwd; on_update, mcp_servers,
                             request_handler, resume_session_id=nothing)
        → AgentClientProtocol.Client

Tell the worker to spawn claude-agent-acp for `cwd` and dial back an ACP WS.
Block until the WS arrives, then drive `initialize`, then either
`session/load` (when `resume_session_id` is set) or `session/new`. Returns
the live ACP `Client`.

When resuming, claude-agent-acp replays the prior conversation as a stream
of `session/update` notifications — our `update_handler` receives them just
like live events, so the chat UI fills in automatically.
"""
function start_session_on_worker(state::ServerState, worker_name::String, cwd::String;
                                  on_update::Function       = identity,
                                  mcp_servers               = [],
                                  request_handler::Function = AgentClientProtocol.make_request_handler(cwd),
                                  resume_session_id::Union{String,Nothing} = nothing,
                                  timeout::Real             = 30.0)

    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")

    sid, ch = register_rpc!(state)

    mcp_list = [Dict("name"    => s.name,
                     "command" => s.command,
                     "args"    => s.args,
                     "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
                for s in mcp_servers]

    # Find the project this session belongs to (purely for the worker-side
    # log line; we don't ship project_id over the wire anymore).
    project_id = ""
    for p in values(state.projects)
        p.worker_name == worker_name && p.worker_path == cwd && (project_id = p.id; break)
    end

    send_command(state, worker_name, Dict(
        "type"       => "open_session",
        "sid"        => sid,
        "project_id" => project_id,
        "cwd"        => cwd,
        "env"        => Dict{String,String}(),
        "mcpServers" => mcp_list,
    ))

    # Wait for the worker's /worker-acp upgrade — bounded so a dead worker
    # doesn't hang the dashboard task that triggered the session.
    ws = take_pending!(state, ch, sid, timeout,
                      "open_session on '$worker_name'")

    conn = ws_connection(ws; request_handler, update_handler = on_update)

    AgentClientProtocol.send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict(
            "fs" => Dict("readTextFile" => true, "writeTextFile" => true),
        ),
        "clientInfo" => Dict("name" => "BonitoTeam", "version" => "0.1.0"),
    ))

    session_id = if resume_session_id !== nothing
        @info "ACP: resuming session" cwd resume_session_id
        # `session/load` returns no useful body — the agent's reply is the
        # stream of session/update notifications that our update_handler
        # picks up. The session ID we use afterwards is the one we asked
        # for (claude-agent-acp keeps it stable across load).
        AgentClientProtocol.send_request(conn, "session/load", Dict(
            "sessionId"  => resume_session_id,
            "cwd"        => cwd,
            "mcpServers" => mcp_list,
        ))
        resume_session_id
    else
        result = AgentClientProtocol.send_request(conn, "session/new",
                     Dict("cwd" => cwd, "mcpServers" => mcp_list))
        result["sessionId"]
    end

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
function sync_dir_to_worker!(state::ServerState, worker_name::String,
                              src::String, dst::String;
                              handoff_timeout::Real = 30.0,
                              on_progress = nothing)
    isdir(src) || error("Source path is not a directory: $src")
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")

    sync_id, ch = register_rpc!(state)

    notify_str(on_progress, "Connecting to worker…")
    send_command(state, worker_name, Dict(
        "type"      => "open_transfer",
        "sync_id"   => sync_id,
        "direction" => "to_worker",
        "dst_path"  => dst,
    ))

    ws = take_pending!(state, ch, sync_id, handoff_timeout,
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
function sync_dir_from_worker!(state::ServerState, worker_name::String,
                                src::String, dst::String;
                                handoff_timeout::Real = 30.0,
                                on_progress = nothing)
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")
    mkpath(dst)

    sync_id, ch = register_rpc!(state)

    notify_str(on_progress, "Connecting to worker…")
    send_command(state, worker_name, Dict(
        "type"      => "open_transfer",
        "sync_id"   => sync_id,
        "direction" => "from_worker",
        "src_path"  => src,
    ))

    ws = take_pending!(state, ch, sync_id, handoff_timeout,
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
function list_worker_dir(state::ServerState, worker_name::String, path::AbstractString;
                          timeout::Real = 5.0)
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")

    rid, ch = register_rpc!(state)
    send_command(state, worker_name, Dict(
        "type"       => "list_dir",
        "request_id" => rid,
        "path"       => String(path),
    ))

    resp = take_pending!(state, ch, rid, timeout, "list_dir on '$worker_name'")
    resp isa AbstractDict || error("list_dir on '$worker_name': unexpected response shape")
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
function scan_worker_sessions(state::ServerState, worker_name::String;
                                timeout::Real = 15.0)
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")
    rid, ch = register_rpc!(state)
    send_command(state, worker_name, Dict("type" => "scan_sessions", "request_id" => rid))
    resp = take_pending!(state, ch, rid, timeout, "scan_sessions on '$worker_name'")
    return resp isa AbstractVector ? resp : Dict{String,Any}[]
end

"""
    clone_repo_on_worker(worker_name, url, dst_path;
                          pr_number = nothing, timeout = 120.0)

Ask the named worker to `git clone <url>` into `dst_path` (a path on the
worker, must not exist yet). For PRs, also fetches `pull/<n>/head` and
checks it out as `pr-<n>`. Throws on timeout or worker-reported errors.
"""
function clone_repo_on_worker(state::ServerState, worker_name::String,
                                url::AbstractString, dst_path::AbstractString;
                                pr_number::Union{Integer,Nothing} = nothing,
                                timeout::Real = 120.0)
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")
    rid, ch = register_rpc!(state)

    payload = Dict{String,Any}(
        "type"       => "clone_repo",
        "request_id" => rid,
        "url"        => String(url),
        "dst_path"   => String(dst_path),
    )
    pr_number === nothing || (payload["pr_number"] = Int(pr_number))
    send_command(state, worker_name, payload)

    resp = take_pending!(state, ch, rid, timeout, "clone_repo on '$worker_name'")
    resp isa AbstractDict || error("clone_repo '$url' on '$worker_name': unexpected response")
    haskey(resp, "error") &&
        error("clone_repo '$url' on '$worker_name': $(resp["error"])")
    return String(resp["dst_path"])
end

"""
    fetch_file_from_worker(worker_name, src_path, dst_path;
                            handoff_timeout = 15.0, on_progress = nothing)

Stream a single file from the named worker into `dst_path` on the server.
Reuses the `/transfer-ws` handoff already used by directory sync, but with
direction `"file_from_worker"` and `RemoteSync.send_file`/`receive_file` for
chunked, memory-bounded transfer. No size cap.

Used by the chat UI's bt_show preview renderer when the file isn't in
`<server_path>/<relpath>` yet (e.g. unsynced project, or a fresh tool
result before the file gets RemoteSync'd as part of a project sync).
"""
function fetch_file_from_worker(state::ServerState, worker_name::String,
                                  src_path::AbstractString,
                                  dst_path::AbstractString;
                                  handoff_timeout::Real = 15.0,
                                  on_progress = nothing)
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")

    sync_id, ch = register_rpc!(state)

    send_command(state, worker_name, Dict(
        "type"      => "open_transfer",
        "sync_id"   => sync_id,
        "direction" => "file_from_worker",
        "src_path"  => String(src_path),
    ))

    ws = take_pending!(state, ch, sync_id, handoff_timeout,
                      "fetch_file from '$worker_name'")
    try
        wsio = RemoteSync.WebSocketIO(ws)
        RemoteSync.receive_file(String(dst_path), wsio; on_progress)
    finally
        try close(ws) catch end
    end
    return String(dst_path)
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
