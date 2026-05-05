module BonitoWorker

# Outbound-only worker: dials the BonitoTeam server, holds a "control" WS open,
# spawns claude-agent-acp + a dedicated per-session WS each time the server
# requests a new session.
#
# Worker has NO inbound listener — no firewall hole on the worker side.
# Single port to open is on the server (8038), already needed for browsers.

using HTTP, HTTP.WebSockets, JSON, SHA

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
                @async handle_open_session(server_url, secret, agent_bin, cmd, ws)
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
                              cmd::AbstractDict, control_ws)
    sid        = String(get(cmd, "sid", ""))
    project_id = String(get(cmd, "project_id", ""))
    cwd        = String(get(cmd, "cwd", pwd()))
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

            # Live worker→server file sync. Each tick computes a snapshot of
            # `cwd`, diffs against the previous one, and pushes any changes
            # over the control WS as a {type: "delta"} envelope + tarball.
            stop_polling = Ref(false)
            polling_task = isempty(project_id) ? nothing :
                @async poll_and_push(control_ws, project_id, cwd, stop_polling)

            ws_to_proc = @async relay_ws_to_proc(ws, proc)
            proc_to_ws = @async relay_proc_to_ws(proc, ws)
            try
                wait(ws_to_proc)
            finally
                stop_polling[] = true
                polling_task !== nothing && (try wait(polling_task) catch end)
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

# ── Live polling task ─────────────────────────────────────────────────────────

"""
    poll_and_push(control_ws, project_id, cwd, stop_ref; interval=0.5)

Tick every `interval` seconds. Compute a snapshot of `cwd`, diff against the
last one, and if anything changed, send a delta envelope over `control_ws`:

    Frame 1 (text):   {"type":"delta","project_id":...,"deletes":[...],"has_payload":bool}
    Frame 2 (binary): tar.gz of created+modified files (only if has_payload=true)
"""
function poll_and_push(control_ws, project_id::String, cwd::String,
                       stop_ref::Ref{Bool}; interval::Real = 0.5)
    prev = compute_snapshot(cwd)   # baseline; don't ship the initial state
    while !stop_ref[]
        sleep(interval)
        stop_ref[] && break
        local cur
        try
            cur = compute_snapshot(cwd; prev = prev)
        catch e
            @warn "BonitoWorker: snapshot scan failed" cwd exception=e
            continue
        end
        d = diff_snapshots(prev, cur)
        if isempty(d.created) && isempty(d.modified) && isempty(d.deleted)
            prev = cur
            continue
        end
        try
            send_delta(control_ws, project_id, cwd, d)
        catch e
            @warn "BonitoWorker: failed to push delta" exception=e
            # Don't bail — try again next tick.
        end
        prev = cur
    end
end

function send_delta(control_ws, project_id::String, cwd::String,
                    d::NamedTuple)
    changed = vcat(d.created, d.modified)
    has_payload = !isempty(changed)
    header = Dict(
        "type"        => "delta",
        "project_id"  => project_id,
        "deletes"     => d.deleted,
        "has_payload" => has_payload,
    )
    WebSockets.send(control_ws, JSON.json(header))
    if has_payload
        tmp = tempname() * ".tar.gz"
        try
            run(Cmd(`tar -czf $tmp $changed`; dir = cwd))
            WebSockets.send(control_ws, read(tmp))
        finally
            rm(tmp; force = true)
        end
    end
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

# ── Snapshot + diff (used by both worker poller and server divergence scanner) ─

# Snapshot entry: (size, mtime_ns, content_hash). Used as the value of the
# Dict returned by `compute_snapshot`.
const FileEntry = Tuple{Int,Float64,Vector{UInt8}}

const SNAPSHOT_IGNORE_DIRS = (".git", ".bonitoTeam")

"""
    compute_snapshot(root; prev=nothing) → Dict{String,FileEntry}

Walk `root` (skipping .git/ + .bonitoTeam/) and produce {relpath → (size, mtime, sha256)}.

If `prev` is given, files whose `(size, mtime)` are unchanged inherit the old
content_hash without re-reading the file — keeps the cost of a no-change scan
to ~one stat() per file.
"""
function compute_snapshot(root::AbstractString;
                          prev::Union{Nothing,Dict{String,FileEntry}} = nothing)
    files = Dict{String,FileEntry}()
    isdir(root) || return files
    for (dir, dirs, fnames) in walkdir(root; topdown = true)
        filter!(d -> !(d in SNAPSHOT_IGNORE_DIRS), dirs)
        for fname in fnames
            full = joinpath(dir, fname)
            isfile(full) || continue
            rel = relpath(full, root)
            st = stat(full)
            size = Int(st.size)
            mtime = st.mtime
            if prev !== nothing && haskey(prev, rel)
                old_size, old_mtime, old_hash = prev[rel]
                if old_size == size && old_mtime == mtime
                    files[rel] = (size, mtime, old_hash)
                    continue
                end
            end
            files[rel] = (size, mtime, open(SHA.sha256, full))
        end
    end
    return files
end

"""
    tree_hash(root) → Vector{UInt8}

Single sha256 over the snapshot — used by the divergence scanner.
"""
function tree_hash(root::AbstractString)
    snap = compute_snapshot(root)
    h = SHA.SHA256_CTX()
    for rel in sort!(collect(keys(snap)))
        size, mtime, content_hash = snap[rel]
        SHA.update!(h, codeunits(string(rel, "\0", size, "\0", mtime, "\0",
                                        bytes2hex(content_hash))))
    end
    return SHA.digest!(h)
end

"""
    diff_snapshots(prev, current) → (created, modified, deleted)

Each return field is a `Vector{String}` of relpaths.
"""
function diff_snapshots(prev::Dict{String,FileEntry},
                        current::Dict{String,FileEntry})
    created  = String[]
    modified = String[]
    deleted  = String[]
    for (rel, (sz, mt, h)) in current
        if haskey(prev, rel)
            _, _, prev_h = prev[rel]
            prev_h != h && push!(modified, rel)
        else
            push!(created, rel)
        end
    end
    for rel in keys(prev)
        haskey(current, rel) || push!(deleted, rel)
    end
    return (created = created, modified = modified, deleted = deleted)
end

function find_agent_bin()
    explicit = get(ENV, "CLAUDE_AGENT_ACP", "")
    !isempty(explicit) && return explicit
    bin = Sys.which("claude-agent-acp")
    bin !== nothing && return bin
    return "claude-agent-acp"
end

end # module BonitoWorker
