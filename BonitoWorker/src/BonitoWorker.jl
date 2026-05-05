module BonitoWorker

# Outbound-only worker: dials the BonitoTeam server, holds a "control" WS open,
# spawns claude-agent-acp + a dedicated per-session WS each time the server
# requests a new session.
#
# Worker has NO inbound listener — no firewall hole on the worker side.
# Single port to open is on the server (8038), already needed for browsers.

using HTTP, HTTP.WebSockets, JSON

# ── Public entry ──────────────────────────────────────────────────────────────

"""
    BonitoWorker.connect_and_serve(; server_url, secret, name, mcp_path,
                                   projects_root, agent_bin, retry_delay = 5.0)

Open a control WS to `server_url/worker-ws`, send the hello frame, then loop
on commands. Reconnects with `retry_delay` between attempts. Blocks forever.
"""
function connect_and_serve(; server_url::String,
                            secret::String,
                            name::String         = gethostname(),
                            mcp_path::String     = "",
                            projects_root::String = joinpath(get(ENV, "HOME", ""), "bonitoteam-projects"),
                            agent_bin::String     = find_agent_bin(),
                            retry_delay::Real     = 5.0)
    while true
        try
            run_control_session(; server_url, secret, name, mcp_path,
                                  projects_root, agent_bin)
        catch e
            e isa InterruptException && rethrow()
            @error "BonitoWorker: control session crashed; reconnecting" exception=(e, catch_backtrace())
        end
        @info "BonitoWorker: reconnecting in $(retry_delay)s"
        sleep(retry_delay)
    end
end

# ── Control WS lifecycle ──────────────────────────────────────────────────────

function run_control_session(; server_url, secret, name, mcp_path,
                               projects_root, agent_bin)
    control_url = ws_url(server_url, "/worker-ws")
    @info "BonitoWorker: connecting to control WS" control_url name
    WebSockets.open(control_url) do ws
        WebSockets.send(ws, JSON.json(Dict(
            "type"          => "hello",
            "secret"        => secret,
            "name"          => name,
            "hostname"      => gethostname(),
            "username"      => get(ENV, "USER", ""),
            "home"          => get(ENV, "HOME", ""),
            "mcp_path"      => mcp_path,
            "projects_root" => projects_root,
        )))

        ack_raw = WebSockets.receive(ws)
        ack = JSON.parse(String(ack_raw))
        if !get(ack, "ok", false)
            error("server rejected hello: $(get(ack, "error", "unknown"))")
        end
        @info "BonitoWorker: registered with server" name=name

        for frame in ws
            cmd = JSON.parse(String(frame))
            t = get(cmd, "type", "")
            if t == "open_session"
                @async handle_open_session(server_url, secret, agent_bin, cmd)
            elseif t == "open_sync"
                @async handle_open_sync(server_url, secret, cmd)
            elseif t == "ping"
                WebSockets.send(ws, JSON.json(Dict("type" => "pong")))
            else
                @warn "BonitoWorker: unknown control frame" type=t
            end
        end
        @info "BonitoWorker: control WS closed by server"
    end
end

# ── Per-session WS handler ────────────────────────────────────────────────────

function handle_open_session(server_url::String, secret::String, agent_bin::String,
                              cmd::AbstractDict)
    sid = String(get(cmd, "sid", ""))
    cwd = String(get(cmd, "cwd", pwd()))
    env_overrides = Dict{String,String}(get(cmd, "env", Dict{String,String}()))
    isempty(sid) && (@error "open_session missing sid"; return)

    isdir(cwd) || try mkpath(cwd) catch end

    env = merge(Dict(string(k) => string(v) for (k, v) in ENV),
                Dict("CLAUDE_PERMISSION_MODE" => "bypassPermissions",
                     "CLAUDE_MAX_TURNS"       => "100"),
                env_overrides)

    proc = try
        open(Cmd(`$agent_bin`; env, dir = cwd), "r+")
    catch e
        @error "BonitoWorker: failed to spawn agent" exception=e cwd
        return
    end
    @info "BonitoWorker: ACP session started" sid cwd pid=getpid()

    acp_url = ws_url(server_url, "/worker-acp")
    try
        WebSockets.open(acp_url) do ws
            # Tell the server which session this WS belongs to.
            WebSockets.send(ws, JSON.json(Dict("secret" => secret, "sid" => sid)))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            get(ack, "ok", false) ||
                error("server rejected ACP session: $(get(ack, "error", "unknown"))")

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
        end
    catch e
        @error "BonitoWorker: ACP session error" sid exception=e
    end
    @info "BonitoWorker: ACP session ended" sid cwd
end

# ── File transport over /worker-sync ──────────────────────────────────────────

function handle_open_sync(server_url::String, secret::String, cmd::AbstractDict)
    sync_id   = String(get(cmd, "sync_id", ""))
    direction = String(get(cmd, "direction", ""))
    isempty(sync_id) && (@error "open_sync missing sync_id"; return)

    sync_url = ws_url(server_url, "/worker-sync")
    try
        WebSockets.open(sync_url) do ws
            WebSockets.send(ws, JSON.json(Dict("secret" => secret, "sync_id" => sync_id)))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            get(ack, "ok", false) ||
                error("server rejected sync: $(get(ack, "error", "unknown"))")

            if direction == "to_worker"
                # Server is sending us a tarball; extract into dst_path.
                dst = String(cmd["dst_path"])
                header = JSON.parse(String(WebSockets.receive(ws)))
                get(header, "type", "") == "tar" ||
                    error("expected tar header, got $(get(header, "type", "?"))")
                data = WebSockets.receive(ws)
                tmp = tempname() * ".tar.gz"
                try
                    write(tmp, data)
                    mkpath(dst)
                    run(Cmd(`tar -xzf $tmp`; dir = dst))
                    WebSockets.send(ws, JSON.json(Dict("ok" => true)))
                finally
                    rm(tmp; force = true)
                end
                @info "BonitoWorker: sync to_worker complete" dst bytes=length(data)

            elseif direction == "from_worker"
                # Server wants us to tar src_path and stream it back.
                src = String(cmd["src_path"])
                isdir(src) || error("src_path is not a directory: $src")
                tmp = tempname() * ".tar.gz"
                try
                    run(Cmd(`tar -czf $tmp .`; dir = src))
                    data = read(tmp)
                    WebSockets.send(ws, JSON.json(Dict("type"=>"tar", "size"=>length(data))))
                    WebSockets.send(ws, data)
                    ack = JSON.parse(String(WebSockets.receive(ws)))
                    get(ack, "ok", false) ||
                        error("server rejected tar: $(get(ack, "error", "unknown"))")
                finally
                    rm(tmp; force = true)
                end
                @info "BonitoWorker: sync from_worker complete" src

            else
                error("unknown sync direction: $direction")
            end
        end
    catch e
        @error "BonitoWorker: sync session error" sync_id direction exception=e
    end
end

# ── Byte-shuttle between WS frame and subprocess stdio ────────────────────────

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
        try close(proc.in) catch e
            e isa Base.IOError || @warn "BonitoWorker: close proc.in failed" exception=e
        end
    end
end

function relay_proc_to_ws(proc, ws)
    try
        while isopen(proc)
            line = readline(proc.out; keep = true)
            isempty(line) && break
            WebSockets.send(ws, line)
        end
    catch e
        e isa EOFError                  && return
        e isa Base.IOError              && return
        WebSockets.isclosed(ws)         && return
        @warn "BonitoWorker proc→ws relay error" exception=e
    end
end

# ── Helpers ───────────────────────────────────────────────────────────────────

function ws_url(http_url::AbstractString, path::AbstractString)
    if startswith(http_url, "http://")
        return "ws://" * replace(http_url, "http://" => ""; count = 1) * path
    elseif startswith(http_url, "https://")
        return "wss://" * replace(http_url, "https://" => ""; count = 1) * path
    else
        return http_url * path
    end
end

function find_agent_bin()
    explicit = get(ENV, "CLAUDE_AGENT_ACP", "")
    !isempty(explicit) && return explicit
    bin = Sys.which("claude-agent-acp")
    bin !== nothing && return bin
    return "claude-agent-acp"
end

end # module BonitoWorker
