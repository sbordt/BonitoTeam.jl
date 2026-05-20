module BonitoWorker

# Outbound-only worker: dials the BonitoTeam server, holds a "control" WS open,
# spawns claude-agent-acp + a dedicated per-session WS each time the server
# requests a new session.
#
# Worker has NO inbound listener — no firewall hole on the worker side.
# Single port to open is on the server (8038), already needed for browsers.

using HTTP, HTTP.WebSockets, JSON, RemoteSync

# Stable per-install identity for this worker. Generated once and persisted to
# `~/.local/share/bonitoteam-worker/worker_id` so the server can recognise the
# same physical install across hostname/IP changes (DHCP renew, VPN flip,
# laptop carried between Wi-Fi networks). The display name is just a label —
# this id is the dict key on the server.
function worker_id_path()
    base = get(ENV, "XDG_DATA_HOME", joinpath(get(ENV, "HOME", ""), ".local", "share"))
    return joinpath(base, "bonitoteam-worker", "worker_id")
end

# UUIDv4-shaped identifier built from `hash(time_ns(), gethostname(), pid())`.
# We deliberately avoid pulling in the Random or UUIDs stdlibs here — adding
# a new dep to BonitoWorker forces the user's runtime Manifest.toml to be
# re-resolved (Pkg.resolve), which is friction we don't need for a one-shot
# id generation. The id is persisted on first run, so collision risk is
# limited to two installs that happen in the same nanosecond from the same
# pid on the same host (i.e. effectively zero).
function generate_worker_id()
    seed = "$(time_ns())-$(getpid())-$(gethostname())-$(rand(UInt64))"
    h1 = string(hash(seed),                     base = 16, pad = 16)
    h2 = string(hash(string(h1, time_ns())),    base = 16, pad = 16)
    bytes = h1 * h2  # 32 hex chars
    return string(bytes[1:8],   "-",
                  bytes[9:12],  "-",
                  bytes[13:16], "-",
                  bytes[17:20], "-",
                  bytes[21:32])
end

function load_or_generate_worker_id()
    path = worker_id_path()
    if isfile(path)
        id = strip(read(path, String))
        !isempty(id) && return String(id)
    end
    id = generate_worker_id()
    mkpath(dirname(path))
    write(path, id)
    @info "BonitoWorker: generated stable worker_id" path id
    return id
end

# Default display name. Falls back through hostname → username → "worker".
# When hostname is "localhost"/empty (common on freshly-installed Linux
# distros) we splice in a 4-char chunk of the worker_id so two laptops with
# the same `gethostname()=="localhost"` still get distinct *display* names —
# the dict key is the full UUID either way, but the user sees something
# friendlier than "localhost" twice.
function default_worker_name(worker_id::String)
    h = gethostname()
    if !isempty(h) && lowercase(h) != "localhost"
        return h
    end
    user = get(ENV, "USER", get(ENV, "USERNAME", "worker"))
    return "$(user)-$(first(worker_id, 4))"
end

# Public entry
"""
    BonitoWorker.connect_and_serve(; server_url, secret, name, mcp_path,
                                   projects_root, agent_bin, retry_delay = 5.0)

Open a control WS to `server_url/worker-ws`, send the hello frame, then loop
on commands. Reconnects with `retry_delay` between attempts. Blocks forever.
"""
function connect_and_serve(; server_url::String,
                            secret::String,
                            worker_id::String     = load_or_generate_worker_id(),
                            name::String         = default_worker_name(worker_id),
                            mcp_path::String     = "",
                            projects_root::String = joinpath(get(ENV, "HOME", ""), "bonitoteam-projects"),
                            agent_bin::String     = find_agent_bin(),
                            retry_delay::Real     = 5.0)
    while true
        try
            run_control_session(; server_url, secret, worker_id, name, mcp_path,
                                  projects_root, agent_bin)
        catch e
            e isa InterruptException && rethrow()
            @error "BonitoWorker: control session crashed; reconnecting" exception=(e, catch_backtrace())
        end
        @info "BonitoWorker: reconnecting in $(retry_delay)s"
        sleep(retry_delay)
    end
end

# Control WS lifecycle
function run_control_session(; server_url, secret, worker_id, name, mcp_path,
                               projects_root, agent_bin)
    control_url = ws_url(server_url, "/worker-ws")
    @info "BonitoWorker: connecting to control WS" control_url worker_id name
    WebSockets.open(control_url) do ws
        WebSockets.send(ws, JSON.json(Dict(
            "type"          => "hello",
            "secret"        => secret,
            "worker_id"     => worker_id,
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
            elseif t == "open_transfer"
                @async handle_open_transfer(server_url, secret, cmd)
            elseif t == "list_dir"
                @async handle_list_dir(ws, cmd)
            elseif t == "inspect_path"
                @async handle_inspect_path(ws, cmd)
            elseif t == "scan_sessions"
                @async handle_scan_sessions(ws, cmd)
            elseif t == "clone_repo"
                @async handle_clone_repo(ws, cmd)
            elseif t == "ping"
                WebSockets.send(ws, JSON.json(Dict("type" => "pong")))
            else
                @warn "BonitoWorker: unknown control frame" type=t
            end
        end
        @info "BonitoWorker: control WS closed by server"
    end
end

# Per-session WS handler
function handle_open_session(server_url::String, secret::String, agent_bin::String,
                              cmd::AbstractDict)
    sid           = String(get(cmd, "sid", ""))
    cwd           = String(get(cmd, "cwd", pwd()))
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

# Filesystem listing RPC
"""
Respond to `{type:"list_dir", request_id, path}` — used by the dashboard's
remote folder picker. Empty/missing path defaults to the worker's \$HOME.
Reply over the same control WS:

    {type: "list_dir_response", request_id, path, entries: [{name, dir}, …]}

Entries are sorted; dotfiles, .git/, .bonitoTeam/ skipped to keep noise down.
On error, returns `{type: "list_dir_response", request_id, error: "..."}`.
"""
function handle_list_dir(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    raw_path   = String(get(cmd, "path", ""))
    path       = isempty(raw_path) ? get(ENV, "HOME", "/") : raw_path

    response = try
        isdir(path) || error("not a directory: $path")
        entries = []
        for name in sort!(readdir(path))
            startswith(name, ".") && continue
            full = joinpath(path, name)
            push!(entries, Dict("name" => name, "dir" => isdir(full)))
        end
        Dict("type"       => "list_dir_response",
             "request_id" => request_id,
             "path"       => abspath(path),
             "entries"    => entries)
    catch e
        Dict("type"       => "list_dir_response",
             "request_id" => request_id,
             "error"      => sprint(showerror, e))
    end
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "list_dir response failed" exception=e
    end
end

# Inspect a path for "which side is fresher" comparison on project-name
# collision. Cheap walk: file count + total bytes + latest mtime + top-N
# most-recently-modified files, plus per-subrepo git summary (HEAD, dirty
# count, last commit time). Excludes the contents of .git/ from the file
# walk so commit churn doesn't drown out source-edit recency; the git
# summary block reports commit activity separately so nothing is lost.
const INSPECT_RECENT_LIMIT = 10

function handle_inspect_path(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    raw_path   = String(get(cmd, "path", ""))

    response = try
        isempty(raw_path) && error("path is empty")
        isdir(raw_path)   || error("not a directory: $raw_path")
        Dict("type"       => "inspect_path_response",
             "request_id" => request_id,
             "path"       => abspath(raw_path),
             "summary"    => inspect_path_summary(raw_path))
    catch e
        Dict("type"       => "inspect_path_response",
             "request_id" => request_id,
             "error"      => sprint(showerror, e))
    end
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "inspect_path response failed" exception=e
    end
end

function inspect_path_summary(root::AbstractString)
    total_files  = 0
    total_bytes  = 0
    latest_mtime = 0.0
    # Collect (rel, size, mtime) so we can sort for the recent-files list.
    files = NamedTuple{(:rel, :size, :mtime), Tuple{String, Int, Float64}}[]
    git_dirs = String[]   # abs paths of directories that contain a .git entry
    for (dir, dirs, names) in walkdir(String(root); topdown = true,
                                       follow_symlinks = false)
        if ".git" in dirs || ".git" in names
            push!(git_dirs, dir)
            # Don't recurse into .git/: counts huge object trees as "files
            # the user edited", which would mask actual source-edit recency.
            filter!(d -> d != ".git", dirs)
        end
        for n in names
            full = joinpath(dir, n)
            islink(full) && continue
            st = try stat(full) catch; continue end
            sz = Int(st.size)
            mt = Float64(st.mtime)
            total_files += 1
            total_bytes += sz
            mt > latest_mtime && (latest_mtime = mt)
            push!(files, (rel = relpath(full, String(root)),
                          size = sz, mtime = mt))
        end
    end
    sort!(files; by = f -> f.mtime, rev = true)
    n_recent = min(INSPECT_RECENT_LIMIT, length(files))
    recent = [Dict("path"  => f.rel,
                   "size"  => f.size,
                   "mtime" => f.mtime) for f in files[1:n_recent]]
    return Dict(
        "total_files"  => total_files,
        "total_bytes"  => total_bytes,
        "latest_mtime" => latest_mtime,
        "recent_files" => recent,
        "git_subrepos" => [inspect_git_subrepo(d, String(root)) for d in git_dirs],
    )
end

function inspect_git_subrepo(abs_dir::AbstractString, root::AbstractString)
    rel        = relpath(String(abs_dir), String(root))
    head_sha   = ""
    head_time  = 0.0
    dirty_count = 0
    branch     = ""
    try
        head_sha = strip(read(Cmd(`git rev-parse HEAD`; dir = abs_dir), String))
    catch end
    try
        # %ct is committer Unix time. Falls back to 0.0 if HEAD is unborn.
        out = read(Cmd(`git log -1 --format=%ct HEAD`; dir = abs_dir), String)
        head_time = parse(Float64, strip(out))
    catch end
    try
        # `--porcelain` is line-per-change; count non-empty lines.
        out = read(Cmd(`git status --porcelain`; dir = abs_dir), String)
        dirty_count = count(!isempty, split(out, '\n'))
    catch end
    try
        branch = strip(read(Cmd(`git rev-parse --abbrev-ref HEAD`; dir = abs_dir), String))
    catch end
    return Dict(
        "path"        => rel,
        "head_sha"    => head_sha,
        "head_time"   => head_time,
        "dirty_count" => dirty_count,
        "branch"      => branch,
    )
end

# Clone a GitHub repo into `dst_path` (must not exist yet). For PRs we then
# fetch the PR head ref and check it out as a local branch `pr-<n>` so the
# checkout uses a normal branch name. The server pre-derives `dst_path` so
# we don't have to repeat the projects_root logic on the worker.
function handle_clone_repo(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    url        = String(get(cmd, "url", ""))
    dst_path   = String(get(cmd, "dst_path", ""))
    pr_raw     = get(cmd, "pr_number", nothing)
    pr_number  = pr_raw === nothing ? nothing :
                 (pr_raw isa Integer ? Int(pr_raw) : parse(Int, String(pr_raw)))

    response = try
        isempty(url)      && error("missing url")
        isempty(dst_path) && error("missing dst_path")
        ispath(dst_path)  && error("dst_path already exists: $dst_path")
        mkpath(dirname(dst_path))

        run(`git clone --depth 50 $url $dst_path`)
        if pr_number !== nothing
            ref   = "pull/$(pr_number)/head"
            local_branch = "pr-$(pr_number)"
            run(setenv(`git -C $dst_path fetch origin $ref:$local_branch`))
            run(setenv(`git -C $dst_path checkout $local_branch`))
        end
        Dict("type"       => "clone_repo_response",
             "request_id" => request_id,
             "dst_path"   => dst_path)
    catch e
        # If clone partially populated the dir, clean up so a retry can start
        # fresh — leaving a half-cloned tree blocks the "already exists" check.
        try
            isdir(dst_path) && rm(dst_path; recursive = true, force = true)
        catch
        end
        Dict("type"       => "clone_repo_response",
             "request_id" => request_id,
             "error"      => sprint(showerror, e))
    end
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "clone_repo response failed" exception=e
    end
end


# RemoteSync (librsync) transfer over /transfer-ws.
#
# Server sends `{type:"open_transfer", sync_id, direction, src_path or dst_path}`.
# We dial /transfer-ws on the server, authenticate, and run the matching
# RemoteSync side. The transfer happens in the @async task spawned by the
# control loop, so the control WS read-loop continues servicing pings while
# librsync chews through bytes.
function handle_open_transfer(server_url::String, secret::String,
                                cmd::AbstractDict)
    sync_id   = String(get(cmd, "sync_id", ""))
    direction = String(get(cmd, "direction", ""))
    isempty(sync_id) && (@error "open_transfer missing sync_id"; return)

    transfer_url = ws_url(server_url, "/transfer-ws")
    try
        WebSockets.open(transfer_url) do ws
            WebSockets.send(ws, JSON.json(Dict("secret" => secret, "sync_id" => sync_id)))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            get(ack, "ok", false) ||
                error("server rejected transfer: $(get(ack, "error", "unknown"))")

            wsio = RemoteSync.WebSocketIO(ws)
            if direction == "to_worker"
                # Server is sending; we're the receiver. Directory transfer.
                dst = String(cmd["dst_path"])
                mkpath(dst)
                RemoteSync.receive_directory(dst, wsio)
                @info "BonitoWorker: transfer to_worker complete" dst
            elseif direction == "from_worker"
                # Worker is sending; server is the receiver. Directory transfer.
                src = String(cmd["src_path"])
                isdir(src) || error("src_path is not a directory: $src")
                RemoteSync.send_directory(src, wsio)
                @info "BonitoWorker: transfer from_worker complete" src
            elseif direction == "file_from_worker"
                # Single-file streaming. Worker reads the file and ships chunks
                # to the server. No size cap — receiver writes straight to disk.
                src = String(cmd["src_path"])
                isfile(src) || error("src_path is not a file: $src")
                RemoteSync.send_file(src, wsio)
                @info "BonitoWorker: file transfer complete" src
            elseif direction == "file_to_worker"
                # Server pushes a single file. We receive into `dst_path`,
                # creating parent dirs as needed. Used for things that
                # don't justify a full directory sync: pasted screenshots,
                # tool-call captures, ad-hoc Julia eval outputs the server
                # wants to land on the worker without re-walking the
                # whole project tree.
                dst = String(cmd["dst_path"])
                mkpath(dirname(dst))
                RemoteSync.receive_file(dst, wsio)
                @info "BonitoWorker: file received" dst
            else
                error("unknown transfer direction: $direction")
            end
        end
    catch e
        @error "BonitoWorker: transfer error" sync_id direction exception=e
    end
end

# Byte-shuttle between WS frame and subprocess stdio
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
        e isa EOFError                  && return
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

# Helpers
function ws_url(http_url::AbstractString, path::AbstractString)
    if startswith(http_url, "http://")
        return "ws://" * replace(http_url, "http://" => ""; count = 1) * path
    elseif startswith(http_url, "https://")
        return "wss://" * replace(http_url, "https://" => ""; count = 1) * path
    else
        return http_url * path
    end
end

# ── Claude session scanner ─────────────────────────────────────────────────────

"""
    enumerate_claude_processes() → Vector{Tuple{Int,String}}

Walk `/proc` and return `(pid, cwd)` for every running user-facing `claude`
process. Skips MCP subprocesses (those invoked with `--mcp`) since they're
internal to a parent claude. Linux-only — empty vector elsewhere.
"""
function enumerate_claude_processes()
    out = Tuple{Int,String}[]
    isdir("/proc") || return out
    for pid_s in readdir("/proc"; join=false)
        all(isdigit, pid_s) || continue
        cmdline_path = "/proc/$pid_s/cmdline"
        isfile(cmdline_path) || continue
        cmdline_raw = try read(cmdline_path, String) catch; continue end
        tokens = split(cmdline_raw, '\0'; keepempty=false)
        isempty(tokens) && continue
        basename(tokens[1]) == "claude" || continue
        any(==(("--mcp")), tokens) && continue
        cwd = try readlink("/proc/$pid_s/cwd") catch; continue end
        isdir(cwd) || continue
        push!(out, (parse(Int, pid_s), cwd))
    end
    return out
end

"""
    collapse_processes_by_cwd(proc_entries, sid_by_cwd) → Vector{Dict{String,Any}}

Collapse `(pid, cwd)` tuples into one Dict per unique cwd. Multiple concurrent
claude processes for the same cwd are common — a claude-agent-acp child + a
VS Code Claude Code extension + a different tool's claude can all share a
directory without any being parent/child of the others — so we fold them into
one row per project. `pid` is the lowest PID (typically the oldest); when
N > 1, `process_count = N` is added so the UI can surface "PID X (N processes)".
"""
function collapse_processes_by_cwd(proc_entries::AbstractVector,
                                     sid_by_cwd::AbstractDict{<:AbstractString,<:AbstractString})
    by_cwd_pids = Dict{String,Vector{Int}}()
    for (pid, cwd) in proc_entries
        push!(get!(by_cwd_pids, String(cwd), Int[]), Int(pid))
    end
    out = Dict{String,Any}[]
    for (cwd, pids) in by_cwd_pids
        sort!(pids)
        entry = Dict{String,Any}(
            "path"   => cwd,
            "name"   => basename(cwd),
            "active" => true,
            "pid"    => pids[1],
        )
        length(pids) > 1 && (entry["process_count"] = length(pids))
        haskey(sid_by_cwd, cwd) && (entry["session_id"] = sid_by_cwd[cwd])
        push!(out, entry)
    end
    return out
end

"""
    scan_claude_sessions(; home) → Vector{Dict{String,Any}}

Scan the worker machine for existing Claude Code usage:
- Running `claude` processes (via /proc/PID/cwd) — exact cwd, marked active
- Historical projects in ~/.claude/projects/ — decoded via filesystem DFS

Returns sorted: active first, then by last-used time descending. Each entry has:
- `path`, `name`, `active` (always)
- `pid` (active only)
- `last_used` (Unix timestamp, historical only)
- `session_id` (jsonl basename, used by the import flow's `session/load` —
  most-recently-modified jsonl wins for projects with multiple sessions; for
  active sessions we look up the in-flight jsonl by its mtime too)
"""
function scan_claude_sessions(; home::String = get(ENV, "HOME", ""))
    results  = Dict{String,Any}[]
    active_paths = Set{String}()

    # Pre-build cwd → latest_session_id map by walking ~/.claude/projects/
    # once, so both active and historical entries can pick up an ID.
    sid_by_cwd = Dict{String,String}()
    projects_dir = joinpath(home, ".claude", "projects")
    if isdir(projects_dir)
        for encoded in readdir(projects_dir)
            proj_dir = joinpath(projects_dir, encoded)
            isdir(proj_dir) || continue
            jsonl_files = filter(f -> endswith(f, ".jsonl"),
                                 readdir(proj_dir; join=true))
            isempty(jsonl_files) && continue
            decoded = decode_project_path(encoded)
            decoded === nothing && continue
            # Latest jsonl by mtime.
            latest = jsonl_files[argmax(stat(f).mtime for f in jsonl_files)]
            sid_by_cwd[decoded] = first(splitext(basename(latest)))
        end
    end

    # Running claude processes via /proc (Linux only).
    proc_entries = isdir("/proc") ? enumerate_claude_processes() : Tuple{Int,String}[]
    for entry in collapse_processes_by_cwd(proc_entries, sid_by_cwd)
        push!(active_paths, entry["path"])
        push!(results, entry)
    end

    # Historical projects from ~/.claude/projects/
    if isdir(projects_dir)
        for encoded in sort!(readdir(projects_dir))
            proj_dir = joinpath(projects_dir, encoded)
            isdir(proj_dir) || continue
            jsonl_files = filter(f -> endswith(f, ".jsonl"),
                                 readdir(proj_dir; join=true))
            isempty(jsonl_files) && continue
            last_used = maximum(stat(f).mtime for f in jsonl_files)
            decoded = decode_project_path(encoded)
            decoded === nothing && continue
            decoded in active_paths && continue
            entry = Dict{String,Any}(
                "path"      => decoded,
                "name"      => basename(decoded),
                "active"    => false,
                "last_used" => last_used,
            )
            haskey(sid_by_cwd, decoded) && (entry["session_id"] = sid_by_cwd[decoded])
            push!(results, entry)
        end
    end

    sort!(results; by = r -> begin
        is_active = get(r, "active", false) === true
        last      = get(r, "last_used", 0.0)
        last_f    = last isa Number ? -Float64(last) : 0.0
        (is_active ? 0 : 1, last_f)
    end)
    return results
end

# Decode ~/.claude/projects/<encoded> back to an absolute path.
# Encoding: every '/' in the abs path is replaced by '-' (leading '/' → '-').
# This is ambiguous when directory names contain '-'; we resolve by DFS against
# the actual filesystem — only paths whose components physically exist are returned.
function decode_project_path(encoded::String)
    startswith(encoded, "-") || return nothing
    candidates = reconstruct_path("/", encoded[2:end])
    for c in candidates
        isdir(c) && return c
    end
    return nothing
end

function reconstruct_path(current::String, remaining::String)
    isempty(remaining) && return [current]
    results = String[]
    parts   = split(remaining, '-'; keepempty=false)
    for i in 1:length(parts)
        segment   = join(parts[1:i], '-')
        candidate = joinpath(current, segment)
        isdir(candidate) || continue
        rest = i < length(parts) ? join(parts[i+1:end], '-') : ""
        if isempty(rest)
            push!(results, candidate)
        else
            append!(results, reconstruct_path(candidate, rest))
        end
    end
    return results
end

function handle_scan_sessions(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    sessions = try
        scan_claude_sessions()
    catch e
        @warn "BonitoWorker: scan_claude_sessions failed" exception=e
        Dict{String,Any}[]
    end
    try
        WebSockets.send(ws, JSON.json(Dict(
            "type"       => "scan_sessions_result",
            "request_id" => request_id,
            "sessions"   => sessions,
        )))
    catch e
        @warn "BonitoWorker: scan_sessions response failed" exception=e
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
