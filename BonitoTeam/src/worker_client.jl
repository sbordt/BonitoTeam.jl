# Server-side handlers for inbound worker connections. Workers dial the
# server; the server tracks each worker's "control" WS and pairs per-session
# ACP WSs with the right project.
#
# Endpoints (registered as Bonito websocket_route!s):
#   /worker-ws    → control channel. Worker sends a hello frame; we register
#                   it in WORKERS, mark online, and keep the WS for sending
#                   commands like "open_session" back to the worker.
#   /worker-acp   → per-session WS. Worker dials this in response to an
#                   "open_session" command and identifies the WS by sid; we
#                   pair it with a Channel that `start_session_on_worker` is
#                   blocked on.

using HTTP, HTTP.WebSockets, JSON, AgentClientProtocol

# name → live control WS (used by the server to push commands to the worker)
const WORKER_CONTROL_WS = Dict{String,Any}()
# sid → Channel{Any} where the matching /worker-acp upgrade hands off the WS
const PENDING_ACP_SESSIONS = Dict{String,Channel{Any}}()
# sync_id → Channel{Any} where /worker-sync upgrade hands off the WS for a
# directional file transfer (server-side counterpart to handle_open_sync on
# the worker)
const PENDING_SYNC_SESSIONS = Dict{String,Channel{Any}}()
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
                if t == "delta"
                    payload = get(cmd, "has_payload", false) ?
                                  WebSockets.receive(ws) : UInt8[]
                    apply_worker_delta!(cmd, payload)
                elseif t == "list_dir_response"
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

# Handler for /worker-sync — one invocation per directional file transfer.
# Worker dials this in response to an `open_sync` command on the control WS.
# Pairs the WS with a Channel that `push_dir_to_worker!` / `pull_dir_from_worker!`
# is blocked on.
function handle_worker_sync(ws, worker_secret::String)
    auth_raw = WebSockets.receive(ws)
    auth = JSON.parse(String(auth_raw))
    if get(auth, "secret", "") != worker_secret
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"unauthorized"))) catch end
        return
    end
    sync_id = String(get(auth, "sync_id", ""))
    if isempty(sync_id) || !haskey(PENDING_SYNC_SESSIONS, sync_id)
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"unknown sync_id"))) catch end
        return
    end
    WebSockets.send(ws, JSON.json(Dict("ok" => true)))

    ch = pop!(PENDING_SYNC_SESSIONS, sync_id)
    put!(ch, ws)

    # Block here so Bonito holds the WS open while the orchestrator drives
    # the transfer via the same `ws` reference.
    while !WebSockets.isclosed(ws)
        sleep(0.5)
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
    if isempty(sid) || !haskey(PENDING_ACP_SESSIONS, sid)
        try WebSockets.send(ws, JSON.json(Dict("ok"=>false, "error"=>"unknown sid"))) catch end
        return
    end
    WebSockets.send(ws, JSON.json(Dict("ok" => true)))

    ch = pop!(PENDING_ACP_SESSIONS, sid)
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
                                  request_handler::Function = AgentClientProtocol.make_request_handler(cwd))

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

    # Wait for the worker's /worker-acp upgrade.
    ws = take!(ch)

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

"""
    push_dir_to_worker!(worker_name, src, dst)

Tar `src` on the server, stream it to the worker over a /worker-sync WS, and
have the worker extract into `dst`.
"""
function push_dir_to_worker!(worker_name::String, src::String, dst::String)
    isdir(src) || error("Source path is not a directory: $src")
    haskey(WORKER_CONTROL_WS, worker_name) ||
        error("Worker '$worker_name' is not connected")

    sync_id = string(uuid4())
    ch = Channel{Any}(1)
    PENDING_SYNC_SESSIONS[sync_id] = ch

    send_command(worker_name, Dict(
        "type"      => "open_sync",
        "sync_id"   => sync_id,
        "direction" => "to_worker",
        "dst_path"  => dst,
    ))

    ws = take!(ch)
    try
        tmp = tempname() * ".tar.gz"
        try
            run(Cmd(`tar -czf $tmp .`; dir = src))
            data = read(tmp)
            WebSockets.send(ws, JSON.json(Dict("type"=>"tar", "size"=>length(data))))
            WebSockets.send(ws, data)
            ack = JSON.parse(String(WebSockets.receive(ws)))
            get(ack, "ok", false) ||
                error("worker rejected sync: $(get(ack, "error", "unknown"))")
        finally
            rm(tmp; force = true)
        end
    finally
        try close(ws) catch end
    end
    return nothing
end

"""
    pull_dir_from_worker!(worker_name, src, dst)

Inverse of `push_dir_to_worker!` — tells the worker to tar `src` (its path)
and stream it back; we extract into `dst` (server path).
"""
function pull_dir_from_worker!(worker_name::String, src::String, dst::String)
    haskey(WORKER_CONTROL_WS, worker_name) ||
        error("Worker '$worker_name' is not connected")
    mkpath(dst)

    sync_id = string(uuid4())
    ch = Channel{Any}(1)
    PENDING_SYNC_SESSIONS[sync_id] = ch

    send_command(worker_name, Dict(
        "type"      => "open_sync",
        "sync_id"   => sync_id,
        "direction" => "from_worker",
        "src_path"  => src,
    ))

    ws = take!(ch)
    try
        header = JSON.parse(String(WebSockets.receive(ws)))
        get(header, "type", "") == "tar" ||
            error("worker sent unexpected sync frame: $(get(header, "type", "?"))")
        data = WebSockets.receive(ws)
        tmp  = tempname() * ".tar.gz"
        try
            write(tmp, data)
            mkpath(dst)
            run(Cmd(`tar -xzf $tmp`; dir = dst))
            WebSockets.send(ws, JSON.json(Dict("ok" => true)))
        finally
            rm(tmp; force = true)
        end
    finally
        try close(ws) catch end
    end
    return nothing
end

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

"""
Apply a delta sent from a worker to the corresponding project's server_path.
The delta envelope identifies the project by id; payload (if any) is a tar.gz
of created+modified files.
"""
function apply_worker_delta!(cmd::AbstractDict, payload::AbstractVector{UInt8})
    project_id = String(get(cmd, "project_id", ""))
    haskey(PROJECTS, project_id) || (@warn "delta for unknown project" project_id; return)
    p = PROJECTS[project_id]

    if !isempty(payload)
        tmp = tempname() * ".tar.gz"
        try
            write(tmp, payload)
            mkpath(p.server_path)
            run(Cmd(`tar -xzf $tmp`; dir = p.server_path))
        finally
            rm(tmp; force = true)
        end
    end

    for rel in get(cmd, "deletes", [])
        full = joinpath(p.server_path, String(rel))
        try
            isfile(full) && rm(full)
        catch e
            @warn "delta delete failed" path=full exception=e
        end
    end

    return nothing
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
