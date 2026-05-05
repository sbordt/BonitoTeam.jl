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

        # Block on incoming control frames from the worker (pong, etc.).
        for _ in ws
            # Currently no inbound control frames besides pongs; loop just
            # blocks until the worker disconnects.
        end
    finally
        delete!(WORKER_CONTROL_WS, name)
        if haskey(WORKERS, name)
            WORKERS[name].status = :offline
            bump_state!()
        end
        @info "Worker disconnected" name=name
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

# ── Server-side ACP client over an accepted WS ────────────────────────────────

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

    send_command(worker_name, Dict(
        "type"       => "open_session",
        "sid"        => sid,
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
