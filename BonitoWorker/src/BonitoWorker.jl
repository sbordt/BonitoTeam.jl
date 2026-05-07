module BonitoWorker

# Outbound-only worker: dials the BonitoTeam server, holds a "control" WS open,
# spawns claude-agent-acp + a dedicated per-session WS each time the server
# requests a new session.
#
# Worker has NO inbound listener — no firewall hole on the worker side.
# Single port to open is on the server (8038), already needed for browsers.

using HTTP, HTTP.WebSockets, JSON, RemoteSync

# Lazy: register HTTP.WebSockets with RemoteSync's WebSocketIO on first use.
const REMOTESYNC_HTTP_REGISTERED = Ref(false)
function ensure_remotesync_http!()
    REMOTESYNC_HTTP_REGISTERED[] && return
    RemoteSync.register_http_websockets!(HTTP.WebSockets)
    REMOTESYNC_HTTP_REGISTERED[] = true
    return
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

# Control WS lifecycle
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
            elseif t == "open_transfer"
                @async handle_open_transfer(server_url, secret, cmd)
            elseif t == "list_dir"
                @async handle_list_dir(ws, cmd)
            elseif t == "scan_sessions"
                @async handle_scan_sessions(ws, cmd)
            elseif t == "fetch_blob"
                @async handle_fetch_blob(ws, cmd)
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

# Single-file blob fetch over the control WS. Used by the chat UI's bt_show
# preview renderer to pull `<cwd>/.bonitoTeam/show/<id>.<ext>` from the
# worker on demand. The server requests:
#
#     {"type":"fetch_blob", "request_id", "path": "<abs-or-cwd-relative>"}
#
# Reply over the same WS:
#   Frame 1 (text):   {"type":"fetch_blob_response", "request_id", "size":N}
#                  OR {"type":"fetch_blob_response", "request_id", "error":"..."}
#   Frame 2 (binary): the file's bytes (only if no error)
#
# Cap at 16 MB to keep a runaway request from filling memory.
const FETCH_BLOB_MAX_BYTES = 16 * 1024 * 1024

function handle_fetch_blob(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    path       = String(get(cmd, "path", ""))
    err = if isempty(path)
        "missing path"
    elseif !isfile(path)
        "not a file: $path"
    elseif filesize(path) > FETCH_BLOB_MAX_BYTES
        "file too large ($(filesize(path)) > $FETCH_BLOB_MAX_BYTES)"
    else
        nothing
    end
    if err !== nothing
        try
            WebSockets.send(ws, JSON.json(Dict(
                "type" => "fetch_blob_response",
                "request_id" => request_id,
                "error" => err)))
        catch e
            @warn "fetch_blob error reply failed" exception=e
        end
        return
    end
    bytes = read(path)
    try
        WebSockets.send(ws, JSON.json(Dict(
            "type" => "fetch_blob_response",
            "request_id" => request_id,
            "size" => length(bytes))))
        WebSockets.send(ws, bytes)
    catch e
        @warn "fetch_blob send failed" exception=e
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

    ensure_remotesync_http!()

    transfer_url = ws_url(server_url, "/transfer-ws")
    try
        WebSockets.open(transfer_url) do ws
            WebSockets.send(ws, JSON.json(Dict("secret" => secret, "sync_id" => sync_id)))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            get(ack, "ok", false) ||
                error("server rejected transfer: $(get(ack, "error", "unknown"))")

            wsio = RemoteSync.WebSocketIO(ws)
            if direction == "to_worker"
                # Server is sending; we're the receiver.
                dst = String(cmd["dst_path"])
                mkpath(dst)
                RemoteSync.receive_directory(dst, wsio)
                @info "BonitoWorker: transfer to_worker complete" dst
            elseif direction == "from_worker"
                src = String(cmd["src_path"])
                isdir(src) || error("src_path is not a directory: $src")
                RemoteSync.send_directory(src, wsio)
                @info "BonitoWorker: transfer from_worker complete" src
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

    # Running claude processes via /proc (Linux only)
    if isdir("/proc")
        for pid_s in readdir("/proc"; join=false)
            all(isdigit, pid_s) || continue
            cmdline_path = "/proc/$pid_s/cmdline"
            isfile(cmdline_path) || continue
            cmdline_raw = try read(cmdline_path, String) catch; continue end
            tokens = split(cmdline_raw, '\0'; keepempty=false)
            isempty(tokens) && continue
            basename(tokens[1]) == "claude" || continue
            any(==(("--mcp")), tokens) && continue   # skip MCP subprocesses
            cwd = try readlink("/proc/$pid_s/cwd") catch; continue end
            isdir(cwd) || continue
            push!(active_paths, cwd)
            entry = Dict{String,Any}(
                "path"   => cwd,
                "name"   => basename(cwd),
                "active" => true,
                "pid"    => parse(Int, pid_s),
            )
            haskey(sid_by_cwd, cwd) && (entry["session_id"] = sid_by_cwd[cwd])
            push!(results, entry)
        end
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
