module Worker

# BonitoTeam.Worker — two roles in one module.
#
# NOTE: this file is NOT included from BonitoTeam.jl (which is a lean package).
# Load it from the root project (which has HTTP + AgentClientProtocol) via:
#   include("<repo>/dev/BonitoTeam/src/Worker/Worker.jl")
#
#   Worker.serve(...)   — run on the worker PC; accepts WS connections from the server,
#                         authenticates, spawns claude-agent-acp, and relays ACP JSON-RPC
#                         bidirectionally between the WebSocket and the subprocess.
#
#   Worker.connect(...) — run on the server; opens a WS to a remote worker and returns
#                         a ready AgentClientProtocol.Client (same interface as local).

using HTTP, HTTP.WebSockets, JSON, AgentClientProtocol

# ── Server-side: run on the worker machine ────────────────────────────────────

"""
    Worker.serve(; host, port, secret, agent_bin)

Start the worker WebSocket server.  Each incoming connection must authenticate
with the shared secret before an agent subprocess is spawned.

Blocks until the server is stopped.  Call `Worker.serve!(...)` for the non-blocking variant.
"""
function serve(; host::String  = "0.0.0.0",
                 port::Int     = 8039,
                 secret::String,
                 agent_bin::String = find_agent_bin())
    @info "BonitoTeam worker listening" host port
    WebSockets.listen(host, port) do ws
        handle_session(ws, secret, agent_bin)
    end
end

"""
    Worker.serve!(; host, port, secret, agent_bin) → Task

Non-blocking variant of `serve`.
"""
function serve!(; kw...)
    @async serve(; kw...)
end

# Best-effort error response — WS may already be closed, that's fine.
function try_send_error(ws, msg::String)
    try
        WebSockets.send(ws, JSON.json(Dict("error" => msg)))
    catch e
        e isa WebSockets.WebSocketError && return
        e isa Base.IOError              && return
        @warn "Worker: failed to send error response" exception=e
    end
end

# Per-connection handler on the worker.
function handle_session(ws, secret::String, agent_bin::String)
    # First frame must be our auth+config envelope (not ACP).
    raw = try
        WebSockets.receive(ws)
    catch e
        e isa WebSockets.WebSocketError && return
        e isa Base.IOError              && return
        @warn "Worker: error receiving auth frame" exception=e
        return
    end

    msg = try
        JSON.parse(String(raw))
    catch e
        @warn "Worker: invalid auth frame (not valid JSON)" exception=e
        try_send_error(ws, "invalid auth frame")
        return
    end

    if get(msg, "auth", "") != secret
        try_send_error(ws, "unauthorized")
        return
    end

    # ACK before spawning so the client's WS open() returns cleanly.
    # Report worker capabilities so the server can pass MCP config, display
    # the worker by hostname, and rsync into a known projects-root path.
    ack = Dict{String,Any}(
        "ok"            => true,
        "hostname"      => gethostname(),
        "username"      => get(ENV, "USER", ""),
        "home"          => get(ENV, "HOME", ""),
        "mcp_path"      => get(ENV, "BONITOTEAM_MCP_BIN",
                               joinpath(get(ENV, "HOME", ""), ".local", "bin", "bonitoteam-mcp")),
        "projects_root" => get(ENV, "BONITOTEAM_PROJECTS_ROOT",
                               joinpath(get(ENV, "HOME", ""), "bonitoteam-projects")),
    )
    try
        WebSockets.send(ws, JSON.json(ack))
    catch e
        @warn "Worker: failed to send auth ACK" exception=e
        return
    end

    # Probe-only handshake: dashboard registration / health check, no agent spawn.
    get(msg, "probe", false) === true && return

    cwd           = get(msg, "cwd", pwd())
    env_overrides = Dict{String,String}(get(msg, "env", Dict{String,String}()))

    env = merge(Dict(string(k) => string(v) for (k,v) in ENV),
                Dict("CLAUDE_PERMISSION_MODE" => "bypassPermissions",
                     "CLAUDE_MAX_TURNS"       => "100"),
                env_overrides)

    proc = try
        open(Cmd(`$agent_bin`; env, dir=cwd), "r+")
    catch e
        @warn "Worker: failed to spawn agent" exception=e cwd
        try_send_error(ws, "spawn failed: $e")
        return
    end

    @info "Worker: session started" cwd pid=getpid()

    ws_to_proc = @async relay_ws_to_proc(ws, proc)
    proc_to_ws = @async relay_proc_to_ws(proc, ws)

    try
        wait(ws_to_proc)
    finally
        try
            isopen(proc) && kill(proc)
        catch e
            @warn "Worker: kill failed" exception=e
        end
        wait(proc_to_ws)
        try
            close(proc)
        catch e
            e isa Base.IOError || @warn "Worker: close proc failed" exception=e
        end
    end

    @info "Worker: session ended" cwd
end

function relay_ws_to_proc(ws, proc)
    try
        while !WebSockets.isclosed(ws)
            frame = WebSockets.receive(ws)
            line  = String(frame)
            # Ensure newline terminator for the subprocess.
            endswith(line, '\n') || (line *= "\n")
            write(proc.in, line)
            flush(proc.in)
        end
    catch e
        # Normal close paths.
        e isa WebSockets.WebSocketError && return
        e isa Base.IOError              && return
        @warn "Worker ws→proc relay error" exception=e
    finally
        try close(proc.in) catch end
    end
end

function relay_proc_to_ws(proc, ws)
    try
        while isopen(proc)
            line = readline(proc.out; keep=true)   # keep \n as frame delimiter
            isempty(line) && break
            WebSockets.send(ws, line)
        end
    catch e
        e isa EOFError     && return
        e isa Base.IOError && return
        WebSockets.isclosed(ws) && return
        @warn "Worker proc→ws relay error" exception=e
    end
end

# ── Client-side: run on the server to connect to a remote worker ──────────────

"""
    Worker.probe(url, secret; timeout=5.0) → Dict{String,Any}

Open a WS, authenticate, read the capability ACK, close. Used by the dashboard
to register a worker and learn its hostname / mcp_path / projects_root before
starting an ACP session. Throws on connection / auth failure.
"""
function probe(url::String, secret::String; timeout::Float64 = 5.0)
    result = Channel{Union{Dict{String,Any},Exception}}(1)

    @async WebSockets.open(url) do ws
        try
            WebSockets.send(ws, JSON.json(Dict("auth" => secret, "probe" => true)))
            ack_raw = WebSockets.receive(ws)
            ack     = JSON.parse(String(ack_raw))
            if haskey(ack, "error")
                put!(result, ErrorException("Worker probe failed: $(ack["error"])"))
            else
                put!(result, Dict{String,Any}(ack))
            end
        catch e
            isopen(result) && put!(result, e)
        finally
            try
                close(ws)
            catch e
                e isa Base.IOError || e isa WebSockets.WebSocketError ||
                    @warn "Worker.probe: close failed" exception=e
            end
        end
    end

    # Bounded wait: take! blocks; race against a timeout task.
    @async (sleep(timeout); isopen(result) && put!(result, ErrorException("probe timed out after $(timeout)s")))
    out = take!(result)
    close(result)   # let the timer task die quietly if it was still asleep
    out isa Exception && throw(out)
    return out
end

"""
    Worker.connect(url, secret, cwd; on_update, mcp_servers, request_handler, agent_env) → AgentClientProtocol.Client

Open a WebSocket to a remote worker, authenticate, then establish an ACP session.
Returns a `Client` with the same interface as a local `AgentClientProtocol.Client`.

`url` should be a `ws://` or `wss://` URL, e.g. `"ws://192.168.1.42:8039"`.
"""
function connect(url::String, secret::String, cwd::String;
                 on_update::Function       = identity,
                 mcp_servers               = [],
                 request_handler::Function = AgentClientProtocol.make_request_handler(cwd),
                 agent_env::Dict{String,String} = Dict{String,String}())

    # WebSockets.open blocks for the lifetime of the connection; run on a task.
    ready = Channel{Union{AgentClientProtocol.Client, Exception}}(1)

    @async WebSockets.open(url) do ws
        try
            # Auth + config handshake.
            WebSockets.send(ws, JSON.json(Dict(
                "auth" => secret,
                "cwd"  => cwd,
                "env"  => agent_env,
            )))

            ack_raw = WebSockets.receive(ws)
            ack     = JSON.parse(String(ack_raw))
            if haskey(ack, "error")
                put!(ready, ErrorException("Worker auth failed: $(ack["error"])"))
                return
            end

            # Build a Connection over the WebSocket and initialize ACP.
            conn = ws_connection(ws; request_handler, update_handler=on_update)

            AgentClientProtocol.send_request(conn, "initialize", Dict(
                "protocolVersion"    => 1,
                "clientCapabilities" => Dict(
                    "fs" => Dict("readTextFile" => true, "writeTextFile" => true)
                ),
                "clientInfo" => Dict("name" => "BonitoTeam.Worker.Client", "version" => "0.1.0")
            ))

            mcp_list = [Dict("name"    => s.name,
                             "command" => s.command,
                             "args"    => s.args,
                             "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
                        for s in mcp_servers]

            result     = AgentClientProtocol.send_request(conn, "session/new",
                             Dict("cwd" => cwd, "mcpServers" => mcp_list))
            session_id = result["sessionId"]

            client = AgentClientProtocol.Client(conn, session_id, cwd)
            put!(ready, client)

            # Keep the WS alive until the connection closes from outside.
            while !WebSockets.isclosed(ws)
                sleep(1)
            end
        catch e
            isopen(ready) && put!(ready, e)
        end
    end

    result = take!(ready)
    result isa Exception && throw(result)
    return result
end

# ── Transport helpers ─────────────────────────────────────────────────────────

# Build an AgentClientProtocol.Connection backed by a WebSocket.
# Each ACP message is one WS frame (frame boundary replaces the newline delimiter).
function ws_connection(ws; request_handler, update_handler)
    send_line = line -> WebSockets.send(ws, rstrip(line, '\n'))
    read_line = ()   -> begin
        WebSockets.isclosed(ws) && return ""
        try
            String(WebSockets.receive(ws))
        catch
            ""
        end
    end
    on_close = () -> (try close(ws) catch end)

    return AgentClientProtocol.Connection(send_line, read_line, on_close;
                                          request_handler, update_handler)
end

# ── Binary discovery ──────────────────────────────────────────────────────────

function find_agent_bin()
    explicit = get(ENV, "CLAUDE_AGENT_ACP", "")
    !isempty(explicit) && return explicit
    bin = Sys.which("claude-agent-acp")
    bin !== nothing && return bin
    return "claude-agent-acp"
end

end # module Worker
