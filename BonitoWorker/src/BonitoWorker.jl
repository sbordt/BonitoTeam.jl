module BonitoWorker

# Thin WebSocket → claude-agent-acp relay. Runs on the worker machine.
# Has NO knowledge of the ACP message format — it just shuttles bytes between
# the WS frame and the subprocess stdio, frame-per-line.
#
#   BonitoWorker.serve(; secret) — blocks; accepts WS auth then spawns claude-agent-acp
#
# The server-side counterpart (Worker.connect — needs AgentClientProtocol)
# lives in the BonitoTeam package, not here.

using HTTP, HTTP.WebSockets, JSON

"""
    BonitoWorker.serve(; host, port, secret, agent_bin)

Start the worker WebSocket server. Each incoming connection must authenticate
with the shared secret before an agent subprocess is spawned. Blocks until
the listener is stopped. Use `BonitoWorker.serve!` for the non-blocking variant.
"""
function serve(; host::String  = "0.0.0.0",
                 port::Int     = 8039,
                 secret::String,
                 agent_bin::String = find_agent_bin())
    @info "BonitoWorker listening" host port
    WebSockets.listen(host, port) do ws
        handle_session(ws, secret, agent_bin)
    end
end

serve!(; kw...) = @async serve(; kw...)

# Best-effort error response — WS may already be closed, that's fine.
function try_send_error(ws, msg::String)
    try
        WebSockets.send(ws, JSON.json(Dict("error" => msg)))
    catch e
        e isa WebSockets.WebSocketError && return
        e isa Base.IOError              && return
        @warn "BonitoWorker: failed to send error response" exception=e
    end
end

# Per-connection handler.
function handle_session(ws, secret::String, agent_bin::String)
    # First frame must be our auth+config envelope (not ACP).
    raw = try
        WebSockets.receive(ws)
    catch e
        e isa WebSockets.WebSocketError && return
        e isa Base.IOError              && return
        @warn "BonitoWorker: error receiving auth frame" exception=e
        return
    end

    msg = try
        JSON.parse(String(raw))
    catch e
        @warn "BonitoWorker: invalid auth frame (not valid JSON)" exception=e
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
        @warn "BonitoWorker: failed to send auth ACK" exception=e
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
        @warn "BonitoWorker: failed to spawn agent" exception=e cwd
        try_send_error(ws, "spawn failed: $e")
        return
    end

    @info "BonitoWorker: session started" cwd pid=getpid()

    ws_to_proc = @async relay_ws_to_proc(ws, proc)
    proc_to_ws = @async relay_proc_to_ws(proc, ws)

    try
        wait(ws_to_proc)
    finally
        try
            isopen(proc) && kill(proc)
        catch e
            @warn "BonitoWorker: kill failed" exception=e
        end
        wait(proc_to_ws)
        try
            close(proc)
        catch e
            e isa Base.IOError || @warn "BonitoWorker: close proc failed" exception=e
        end
    end

    @info "BonitoWorker: session ended" cwd
end

function relay_ws_to_proc(ws, proc)
    try
        while !WebSockets.isclosed(ws)
            frame = WebSockets.receive(ws)
            line  = String(frame)
            endswith(line, '\n') || (line *= "\n")
            write(proc.in, line)
            flush(proc.in)
        end
    catch e
        e isa WebSockets.WebSocketError && return
        e isa Base.IOError              && return
        @warn "BonitoWorker ws→proc relay error" exception=e
    finally
        try
            close(proc.in)
        catch e
            e isa Base.IOError || @warn "BonitoWorker: close proc.in failed" exception=e
        end
    end
end

function relay_proc_to_ws(proc, ws)
    try
        while isopen(proc)
            line = readline(proc.out; keep=true)
            isempty(line) && break
            WebSockets.send(ws, line)
        end
    catch e
        e isa EOFError     && return
        e isa Base.IOError && return
        WebSockets.isclosed(ws) && return
        @warn "BonitoWorker proc→ws relay error" exception=e
    end
end

# ── Binary discovery ──────────────────────────────────────────────────────────

function find_agent_bin()
    explicit = get(ENV, "CLAUDE_AGENT_ACP", "")
    !isempty(explicit) && return explicit
    bin = Sys.which("claude-agent-acp")
    bin !== nothing && return bin
    return "claude-agent-acp"
end

end # module BonitoWorker
