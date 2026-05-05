#!/usr/bin/env julia
# BonitoTeam standalone worker server.
# Only deps: HTTP, JSON  — no local packages required.
# Serve the worker by running:
#   BONITOTEAM_WORKER_SECRET=<secret> julia --project=/path/to/env worker_standalone.jl
using HTTP, HTTP.WebSockets, JSON

function find_agent_bin()
    explicit = get(ENV, "CLAUDE_AGENT_ACP", "")
    !isempty(explicit) && return explicit
    bin = Sys.which("claude-agent-acp")
    bin !== nothing && return bin
    return "claude-agent-acp"
end

function serve(; host::String = "0.0.0.0",
                 port::Int    = 8039,
                 secret::String,
                 agent_bin::String = find_agent_bin())
    @info "BonitoTeam worker listening" host port
    WebSockets.listen(host, port) do ws
        handle_session(ws, secret, agent_bin)
    end
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

function handle_session(ws, secret::String, agent_bin::String)
    raw = try
        WebSockets.receive(ws)
    catch e
        # Normal client disconnect paths.
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

    # Auth ACK: report worker capabilities so the server can pass MCP config,
    # display the worker by hostname, and rsync to a known projects-root path.
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

    env = merge(
        Dict(string(k) => string(v) for (k, v) in ENV),
        Dict("CLAUDE_PERMISSION_MODE" => "bypassPermissions",
             "CLAUDE_MAX_TURNS"       => "100"),
        env_overrides,
    )

    proc = try
        open(Cmd(`$agent_bin`; env, dir=cwd), "r+")
    catch e
        @warn "Worker: failed to spawn agent" exception=e cwd
        try_send_error(ws, "spawn failed: $e")
        return
    end

    @info "Worker: session started" cwd

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
            endswith(line, '\n') || (line *= "\n")
            write(proc.in, line)
            flush(proc.in)
        end
    catch e
        e isa WebSockets.WebSocketError && return
        e isa Base.IOError              && return
        @warn "Worker ws→proc relay error" exception=e
    finally
        try
            close(proc.in)
        catch e
            e isa Base.IOError || @warn "Worker: close proc.in failed" exception=e
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
        @warn "Worker proc→ws relay error" exception=e
    end
end

# Self-register with the server. Best-effort: if the server is down, log + carry
# on listening — the operator can register manually via the dashboard.
function self_register!(server_url::String, secret::String, port::Int)
    register_host = get(ENV, "BONITOTEAM_REGISTER_HOST", gethostname())
    register_name = get(ENV, "BONITOTEAM_WORKER_NAME", register_host)
    body = JSON.json(Dict(
        "secret" => secret,
        "host"   => register_host,
        "port"   => port,
        "name"   => register_name,
    ))
    @info "Worker: registering with server" server_url register_host port register_name
    try
        r = HTTP.request("POST", "$server_url/api/workers/register",
                         ["Content-Type" => "application/json"], body;
                         readtimeout = 10, retry = false, status_exception = false)
        if r.status == 200
            @info "Worker: registered" response=String(r.body)
        else
            @warn "Worker: registration failed" status=r.status body=String(r.body)
        end
    catch e
        @warn "Worker: registration POST failed (server unreachable?)" exception=e
    end
end

# ── Entry point ───────────────────────────────────────────────────────────────

const secret     = get(ENV, "BONITOTEAM_WORKER_SECRET", "")
const port       = parse(Int, get(ENV, "BONITOTEAM_WORKER_PORT", "8039"))
const host       = get(ENV, "BONITOTEAM_WORKER_HOST", "0.0.0.0")
const server_url = get(ENV, "BONITOTEAM_SERVER_URL", "")
const agent_bin  = find_agent_bin()

isempty(secret) && error("BONITOTEAM_WORKER_SECRET must be set")

# Register in the background; serve() blocks immediately so we can't await it
# before the listener is up. The server retries are handled by the user — if
# it fails they can re-trigger by restarting the worker.
isempty(server_url) ?
    @warn("BONITOTEAM_SERVER_URL not set; skipping self-registration. " *
          "Add the worker manually via the dashboard.") :
    @async (sleep(1); self_register!(server_url, secret, port))

serve(; host, port, secret, agent_bin)
