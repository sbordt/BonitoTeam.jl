# Single source of truth for server-side state. Replaces 14 module-level
# globals (WORKERS, PROJECTS, PENDING_*, STATE_VERSION, etc.) with one
# `ServerState` struct constructed in `serve()` and threaded through every
# route handler / dashboard / chat closure.
#
# Why one struct: each `serve()` call is one server. Module globals made
# multi-instance testing impossible and let stale observables from a
# re-rendered form leak into a new render through the shared dict.

mutable struct WorkerInfo
    name::String                       # display name (unique key)
    url::String                        # ws://host:port
    secret::String
    ssh_target::Union{String,Nothing}  # for ssh-based rsync: "user@host". nothing → local rsync
    # discovered via probe
    hostname::String
    home::String
    mcp_path::String                   # path on worker, used for MCPServer config
    projects_root::String              # rsync destination root on worker
    # runtime
    status::Symbol                     # :unknown, :online, :offline
    last_check::DateTime
end

mutable struct ProjectInfo
    id::String                         # short uuid
    name::String                       # display name + dir name (server + worker)
    worker_name::String                # FK to ServerState.workers
    server_path::String                # canonical copy on server (= state.working_dir/name)
    worker_path::String                # mirrored copy on worker (= worker.projects_root/name)
    created::DateTime
    # At most one active ACP session per project. Acquired when
    # ensure_project_session! brings up the chat_app; released automatically
    # when the bound worker's control WS drops (the claude process is gone
    # with it). Worker-only-write model means there's no checksum/divergence
    # state — anything claude writes on the worker auto-flows back to the
    # server, the operator never edits server_path.
    locked_by::Union{String,Nothing}      # worker_name when active, else nothing
    locked_at::Union{DateTime,Nothing}
    # :unsynced (default for worker-imported projects) — server has no copy.
    # :syncing — a librsync transfer is in progress.
    # :synced — last librsync transfer completed successfully; server has a copy.
    # :stale — was synced once but content has likely diverged since.
    # Persistence: only :unsynced vs :synced is durable; :syncing always resets
    # to :stale on restart so a crash mid-sync doesn't leave a wrong "synced".
    backup_status::Symbol
    last_sync_at::Union{DateTime,Nothing}
    # Set when the project was imported from an existing claude-agent-acp
    # session — the .jsonl basename in ~/.claude/projects/<encoded>/ on the
    # worker. start_session_on_worker uses session/load with this ID to bring
    # the conversation history back to where claude left off; nothing → fresh
    # session/new. Persisted so server restarts still resume.
    resume_session_id::Union{String,Nothing}
    # If set, the chat fires this prompt as the first user message the next
    # time it brings up an ACP session — used by the "From GitHub" template
    # to seed "fix this issue" / "review this PR" without the operator having
    # to retype it. Cleared (and persisted as nothing) once the prompt has
    # been delivered, so a session restart doesn't re-fire.
    auto_prompt::Union{String,Nothing}
end

ProjectInfo(id, name, worker_name, server_path, worker_path, created) =
    ProjectInfo(id, name, worker_name, server_path, worker_path, created,
                nothing, nothing, :unsynced, nothing, nothing, nothing)

"""
    ServerState

Everything one running BonitoTeam server needs. Constructed in `serve()`
and captured by route closures, dashboard / chat apps, and worker control
handlers. Five things deserve a paragraph each:

- `pending_rpcs` collapses what used to be five separate dicts (one per
  RPC type). The keys are uuids, so cross-RPC-type collisions can't happen,
  and the unified shape removes a lot of duplicated bookkeeping.
- `version` drives reactive re-renders. Bumped via `bump_state!` whenever
  workers/projects mutates.
- `worker_control_ws` keys workers by name (the same key as `workers`).
- `srv` is filled in after `Bonito.Server` is constructed (chicken-and-egg:
  the dashboard app captures the state, but the server constructor takes
  the dashboard).
- `worker_secret` is the auth token every worker presents on its hello
  frame; same secret across all workers, baked into the install script.
"""
mutable struct ServerState
    # Disk paths (immutable after construction)
    state_dir   :: String
    working_dir :: String
    # Auth
    worker_secret :: String
    # Live Bonito server (set by serve() after construction)
    srv :: Union{Bonito.Server,Nothing}

    # Persisted state (mutated at runtime, written to disk via save_workers!/save_projects!)
    workers  :: Dict{String,WorkerInfo}
    projects :: Dict{String,Any}        # id → ProjectInfo. Any: see comment in old dashboard

    # Runtime caches (not persisted)
    project_apps :: Dict{String,Bonito.App}
    chat_clients :: Dict{String,Any}   # id → Ref{AgentClientProtocol.Client}

    # Live worker connections (name → HTTP.WebSocket)
    worker_control_ws :: Dict{String,Any}

    # Pending request_id → channel handoffs for every RPC type. Channel{Any}
    # because the answer shape varies (WS for handoff, Dict for rpc result).
    pending_rpcs :: Dict{String,Channel{Any}}

    # Reactive re-render trigger
    version :: Observable{Int}
end

"""
    ServerState(; state_dir, working_dir, worker_secret) → ServerState

Construct a fresh state, loading workers + projects from `state_dir`
(`workers.json`, `projects.json`). `working_dir` is created if missing.
"""
function ServerState(; state_dir::String,
                       working_dir::String,
                       worker_secret::String)
    mkpath(working_dir)
    s = ServerState(
        state_dir, working_dir, worker_secret,
        nothing,
        Dict{String,WorkerInfo}(),
        Dict{String,Any}(),
        Dict{String,Bonito.App}(),
        Dict{String,Any}(),
        Dict{String,Any}(),
        Dict{String,Channel{Any}}(),
        Observable(0),
    )
    load_workers!(s)
    load_projects!(s)
    return s
end

workers_file(s::ServerState)  = joinpath(s.state_dir, "workers.json")
projects_file(s::ServerState) = joinpath(s.state_dir, "projects.json")

# Setting an Observable propagates to the browser via Bonito's WebSocket;
# if a session is broken (e.g. a stale tab whose hashed asset URLs went 404
# after a redeploy), Bonito surfaces that as a JSException from the
# observable update. We don't want a stale UI tab to break server-side
# operations, so this swallows + logs the error rather than propagating it.
function bump_state!(s::ServerState)
    safe_set!(s.version, s.version[] + 1)
    return nothing
end

# Same shape, for any observable update we want to be best-effort.
function safe_set!(obs::Observable, val)
    try
        obs[] = val
    catch e
        @debug "safe_set!: observable propagation failed (likely stale browser session)" exception=e
    end
    return nothing
end

# ── Persistence ───────────────────────────────────────────────────────────
# Atomic JSON write: serialise to a sibling .tmp first, then rename into place.
# `rename(2)` on the same filesystem is atomic, so a crash mid-save can leave
# only the old file or only the new — never a half-written file.
function atomic_write_json(path::String, data)
    mkpath(dirname(path))
    tmp = path * ".tmp"
    open(tmp, "w") do io
        JSON.print(io, data, 2)
    end
    mv(tmp, path; force = true)
end

# Read JSON with corruption tolerance: if the file is truncated/garbled (e.g.
# from a crash before atomic_write_json existed, or a manual edit gone wrong),
# log a warning, move it aside as `<file>.bad`, and continue with empty state.
# We'd rather lose worker/project metadata than refuse to start the server.
function load_json_tolerant(path::String, label::String)
    isfile(path) || return nothing
    try
        return JSON.parsefile(path)
    catch e
        bad = path * ".bad-" * Dates.format(now(UTC), "yyyymmddTHHMMSS")
        try mv(path, bad; force = true) catch end
        @warn "$label: failed to parse — moved aside, starting empty" path bad exception=e
        return nothing
    end
end

function save_workers!(s::ServerState)
    data = [Dict("name" => w.name, "url" => w.url, "secret" => w.secret,
                 "ssh_target" => w.ssh_target,
                 "hostname" => w.hostname, "home" => w.home,
                 "mcp_path" => w.mcp_path, "projects_root" => w.projects_root)
            for w in values(s.workers)]
    atomic_write_json(workers_file(s), data)
end

function load_workers!(s::ServerState)
    raw = load_json_tolerant(workers_file(s), "workers.json")
    raw === nothing && return
    for d in raw
        try
            w = WorkerInfo(d["name"], d["url"], d["secret"],
                           get(d, "ssh_target", nothing),
                           get(d, "hostname", ""), get(d, "home", ""),
                           get(d, "mcp_path", ""), get(d, "projects_root", ""),
                           :unknown, now(UTC))
            s.workers[w.name] = w
        catch e
            @warn "skipping malformed worker entry" entry=d exception=e
        end
    end
end

function save_projects!(s::ServerState)
    data = [Dict("id" => p.id, "name" => p.name, "worker_name" => p.worker_name,
                 "server_path" => p.server_path, "worker_path" => p.worker_path,
                 "created" => string(p.created),
                 # `:syncing` is a runtime state — persist as `:stale` so a
                 # crash mid-sync doesn't leave the next start-up reporting
                 # "synced" for a half-transferred mirror.
                 "backup_status" => string(p.backup_status === :syncing ? :stale : p.backup_status),
                 "last_sync_at"  => p.last_sync_at === nothing ? nothing : string(p.last_sync_at),
                 "resume_session_id" => p.resume_session_id,
                 "auto_prompt"   => p.auto_prompt)
            for p in values(s.projects)]
    atomic_write_json(projects_file(s), data)
end

function load_projects!(s::ServerState)
    raw = load_json_tolerant(projects_file(s), "projects.json")
    raw === nothing && return
    for d in raw
        try
            p = ProjectInfo(d["id"], d["name"], d["worker_name"],
                            d["server_path"], d["worker_path"],
                            DateTime(d["created"]))
            status_str = String(get(d, "backup_status", "unsynced"))
            p.backup_status = Symbol(status_str)
            last = get(d, "last_sync_at", nothing)
            p.last_sync_at = last === nothing ? nothing : DateTime(String(last))
            sid = get(d, "resume_session_id", nothing)
            p.resume_session_id = (sid === nothing || isempty(String(sid))) ?
                                       nothing : String(sid)
            ap = get(d, "auto_prompt", nothing)
            p.auto_prompt = (ap === nothing || isempty(String(ap))) ?
                                       nothing : String(ap)
            s.projects[p.id] = p
        catch e
            @warn "skipping malformed project entry" entry=d exception=e
        end
    end
end
