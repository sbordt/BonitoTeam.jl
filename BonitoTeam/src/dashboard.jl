# Persistent server state (workers + projects)
const SERVER_STATE_DIR  = Ref(joinpath(homedir(), ".local", "share", "bonitoteam-server"))
# Where canonical project copies live on the SERVER. Each project lives at
# `<SERVER_WORKING_DIR>/<name>` and is mirrored onto the worker at
# `<worker.projects_root>/<name>`.
const SERVER_WORKING_DIR = Ref(joinpath(homedir(), "bonitoteam-server"))

state_dir()         = SERVER_STATE_DIR[]
working_dir()       = SERVER_WORKING_DIR[]
workers_file()      = joinpath(state_dir(), "workers.json")
projects_file()     = joinpath(state_dir(), "projects.json")

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
    worker_name::String                # FK to WORKERS
    server_path::String                # canonical copy on server (= working_dir/name)
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
end

ProjectInfo(id, name, worker_name, server_path, worker_path, created) =
    ProjectInfo(id, name, worker_name, server_path, worker_path, created,
                nothing, nothing)

const WORKERS = Dict{String,WorkerInfo}()
const PROJECTS = Dict{String,ProjectInfo}()

# Per-project runtime — kept out of the persisted state
const PROJECT_APPS = Dict{String,Bonito.App}()

# Observable; bumped whenever WORKERS or PROJECTS changes so the dashboard re-renders.
const STATE_VERSION = Observable(0)
bump_state!() = (STATE_VERSION[] = STATE_VERSION[] + 1)

# Persistence
function save_workers!()
    mkpath(state_dir())
    data = [Dict("name" => w.name, "url" => w.url, "secret" => w.secret,
                 "ssh_target" => w.ssh_target,
                 "hostname" => w.hostname, "home" => w.home,
                 "mcp_path" => w.mcp_path, "projects_root" => w.projects_root)
            for w in values(WORKERS)]
    open(workers_file(), "w") do io
        JSON.print(io, data, 2)
    end
end

function load_workers!()
    isfile(workers_file()) || return
    for d in JSON.parsefile(workers_file())
        w = WorkerInfo(d["name"], d["url"], d["secret"],
                       get(d, "ssh_target", nothing),
                       get(d, "hostname", ""), get(d, "home", ""),
                       get(d, "mcp_path", ""), get(d, "projects_root", ""),
                       :unknown, now(UTC))
        WORKERS[w.name] = w
    end
end

function save_projects!()
    mkpath(state_dir())
    data = [Dict("id" => p.id, "name" => p.name, "worker_name" => p.worker_name,
                 "server_path" => p.server_path, "worker_path" => p.worker_path,
                 "created" => string(p.created))
            for p in values(PROJECTS)]
    open(projects_file(), "w") do io
        JSON.print(io, data, 2)
    end
end

function load_projects!()
    isfile(projects_file()) || return
    for d in JSON.parsefile(projects_file())
        p = ProjectInfo(d["id"], d["name"], d["worker_name"],
                        d["server_path"], d["worker_path"],
                        DateTime(d["created"]))
        PROJECTS[p.id] = p
    end
end

# Worker registration is now handled in worker_client.jl when the worker
# dials the server's /worker-ws endpoint. Liveness comes from the WS itself;
# no periodic probing or heartbeat task.

# Project lock
"""
Mark a project locked by a worker (active ACP session). Errors if the project
is already locked by a different worker.
"""
function acquire_lock!(p::ProjectInfo, worker_name::String)
    if p.locked_by !== nothing && p.locked_by != worker_name
        error("Project '$(p.name)' is locked by worker '$(p.locked_by)'")
    end
    p.locked_by = worker_name
    p.locked_at = now(UTC)
    save_projects!()
    bump_state!()
    return p
end

function release_lock!(p::ProjectInfo)
    p.locked_by = nothing
    p.locked_at = nothing
    save_projects!()
    bump_state!()
    return p
end

# Auto-release every project lock held by `worker_name` (called from
# handle_worker_control's finally branch when the WS drops).
function release_locks_for_worker!(worker_name::String)
    for p in values(PROJECTS)
        p.locked_by == worker_name && release_lock!(p)
    end
end

"""
Create a new project on the named worker. Steps:
1. Seed `<server_working_dir>/<name>` from the picked source folder (if not
   already there).
2. Mirror to `<worker.projects_root>/<name>` (via rsync — local or ssh).
3. Build chat_app whose client_factory asks the worker (over its control WS)
   to spawn an ACP session and dial back; we drive that session from here.
4. Register `/p/<id>` route on the live server.
"""
function create_project!(srv::Bonito.Server, name::String, src_path::String,
                          worker_name::String)
    haskey(WORKERS, worker_name) || error("Unknown worker: $worker_name")
    isempty(name) && error("Project name must not be empty")
    occursin(r"^[a-zA-Z0-9_\-]+$", name) ||
        error("Project name must be alphanumeric/_/- only")
    isempty(src_path) && error("Source path is required (pick a folder).")
    isdir(src_path)   || error("Source path is not a directory: $src_path")

    w = WORKERS[worker_name]
    id          = string(uuid4())[1:8]
    server_path = joinpath(working_dir(), name)
    worker_path = joinpath(w.projects_root, name)

    # 1. Seed the canonical server-side copy from the picked source (local
    # rsync; this is always on the server box, no SSH).
    if abspath(src_path) != abspath(server_path)
        @info "Seeding server-side mirror" src_path server_path
        mkpath(working_dir())
        run(`rsync -az $(rstrip(src_path, '/'))/ $(rstrip(server_path, '/'))/`)
    end

    # 2. Push server → worker over the worker's WS (no SSH, no inbound port).
    @info "Pushing project to worker" worker=worker_name dst=worker_path
    push_dir_to_worker!(worker_name, server_path, worker_path)

    p = ProjectInfo(id, name, worker_name, server_path, worker_path, now(UTC))
    PROJECTS[id] = p
    save_projects!()

    # 3 + 4: build the chat app + register the route.
    ensure_project_session!(p, srv)
    bump_state!()
    return p
end

"""
Create a project rooted at an existing folder ON THE WORKER. The worker's
folder stays in place (becomes `worker_path`); we pull a copy to the server
as the canonical mirror, then start the session like any other project.
"""
function create_project_from_worker!(srv::Bonito.Server, worker_name::String,
                                      worker_path::String;
                                      name::String = basename(rstrip(worker_path, '/')))
    haskey(WORKERS, worker_name) || error("Unknown worker: $worker_name")
    isempty(name) && error("Project name must not be empty (folder has no basename?)")
    occursin(r"^[a-zA-Z0-9_\-]+$", name) ||
        error("Project name must be alphanumeric/_/- only — got '$name'")
    isempty(worker_path) && error("Worker path is required (pick a folder).")

    id = string(uuid4())[1:8]
    server_path = joinpath(working_dir(), name)
    @info "Pulling project from worker" worker=worker_name worker_path server_path
    pull_dir_from_worker!(worker_name, worker_path, server_path)

    p = ProjectInfo(id, name, worker_name, server_path, worker_path, now(UTC))
    PROJECTS[id] = p
    save_projects!()

    ensure_project_session!(p, srv)
    bump_state!()
    return p
end

"""
Build the chat_app + register the /p/<id> route for `p` if not done yet.
Called both from `create_project!` and from `handle_worker_control` (when a
worker reconnects, projects belonging to it become serviceable again).
"""
function ensure_project_session!(p::ProjectInfo, srv::Union{Bonito.Server,Nothing} = nothing)
    haskey(PROJECT_APPS, p.id) && return PROJECT_APPS[p.id]
    haskey(WORKERS, p.worker_name) ||
        error("Worker '$(p.worker_name)' is not connected")
    w = WORKERS[p.worker_name]

    # Acquire the project lock — at most one active session per project.
    # tree_hash(server_path) is captured here so the divergence scanner can
    # detect operator edits during the session.
    acquire_lock!(p, w.name)

    mcp = isempty(w.mcp_path) ? AgentClientProtocol.MCPServer[] :
        [AgentClientProtocol.MCPServer("bonitoteam", w.mcp_path)]

    client_factory = on_update -> start_session_on_worker(w.name, p.worker_path;
                                                           on_update, mcp_servers = mcp)
    app = chat_app(p.server_path; mcp_servers = mcp, client_factory = client_factory)

    PROJECT_APPS[p.id] = app
    if srv !== nothing
        Bonito.route!(srv, "/p/$(p.id)" => app)
    elseif SERVER_REF[] !== nothing
        Bonito.route!(SERVER_REF[], "/p/$(p.id)" => app)
    end
    return app
end

# Module-level handle to the live server, set by serve(). Used so the worker
# control handler (which reconnects asynchronously) can register routes.
const SERVER_REF = Ref{Union{Bonito.Server,Nothing}}(nothing)

# Dashboard styles — modern surface + spacing system, status dots, smooth transitions
const DashboardStyles = Bonito.Styles(
    # ── Tokens ───────────────────────────────────────────────────────────────
    CSS(":root",
        "--bt-bg"            => "#fafaf9",
        "--bt-surface"       => "#ffffff",
        "--bt-surface-2"     => "#f8fafc",
        "--bt-border"        => "rgba(15,23,42,0.08)",
        "--bt-border-strong" => "rgba(15,23,42,0.14)",
        "--bt-text"          => "#0f172a",
        "--bt-text-muted"    => "#64748b",
        "--bt-text-faint"    => "#94a3b8",
        "--bt-accent"        => "#3b82f6",
        "--bt-accent-hover"  => "#2563eb",
        "--bt-success"       => "#10b981",
        "--bt-error"         => "#ef4444",
        "--bt-shadow-sm"     => "0 1px 2px rgba(15,23,42,0.05)",
        "--bt-shadow-md"     => "0 4px 12px rgba(15,23,42,0.08)",
        "--bt-radius"        => "8px",
        "--bt-radius-sm"     => "6px"),

    # ── Shell ────────────────────────────────────────────────────────────────
    CSS(".bt-dash",
        "font-family"  => "'Inter', system-ui, -apple-system, sans-serif",
        "font-size"    => "14px", "line-height" => "1.5",
        "color"        => "var(--bt-text)", "background" => "var(--bt-bg)",
        "min-height"   => "100vh",
        "padding"      => "32px 24px",
        "max-width"    => "960px", "margin" => "0 auto",
        "-webkit-font-smoothing" => "antialiased"),

    # ── Header + tagline ─────────────────────────────────────────────────────
    CSS(".bt-header",
        "display" => "flex", "align-items" => "baseline",
        "justify-content" => "space-between", "gap" => "16px",
        "margin-bottom" => "4px"),
    CSS(".bt-header h1",
        "font-size" => "22px", "font-weight" => "600",
        "letter-spacing" => "-0.01em", "margin" => "0"),
    CSS(".bt-tagline",
        "color" => "var(--bt-text-muted)", "font-size" => "13px"),

    # ── Stats strip ──────────────────────────────────────────────────────────
    CSS(".bt-stats",
        "display" => "flex", "gap" => "20px", "flex-wrap" => "wrap",
        "padding" => "12px 16px", "margin-top" => "16px",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "font-size" => "13px"),
    CSS(".bt-stat",
        "display" => "flex", "align-items" => "center", "gap" => "6px"),
    CSS(".bt-stat-value", "font-weight" => "600"),
    CSS(".bt-stat-label", "color" => "var(--bt-text-muted)"),
    CSS(".bt-stat-sep",   "color" => "var(--bt-text-faint)", "user-select" => "none"),

    # ── Section headings ─────────────────────────────────────────────────────
    CSS(".bt-section",
        "display" => "flex", "align-items" => "baseline",
        "justify-content" => "space-between",
        "margin" => "32px 0 12px"),
    CSS(".bt-section h2",
        "font-size" => "11px", "font-weight" => "600",
        "letter-spacing" => "0.08em", "text-transform" => "uppercase",
        "color" => "var(--bt-text-muted)", "margin" => "0"),

    # ── Card ─────────────────────────────────────────────────────────────────
    CSS(".bt-card",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "14px 16px",
        "margin-bottom" => "8px",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between", "gap" => "16px",
        "transition" => "border-color 120ms ease, box-shadow 120ms ease"),
    CSS(".bt-card:hover",
        "border-color" => "var(--bt-border-strong)",
        "box-shadow" => "var(--bt-shadow-sm)"),
    CSS(".bt-card-body",
        "min-width" => "0", "flex" => "1 1 auto"),
    CSS(".bt-card-title",
        "font-weight" => "600", "font-size" => "14px",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "min-width" => "0"),
    # Name spans inside titles: don't break on hyphens, ellipsis when too long
    CSS(".bt-card-name",
        "min-width" => "0",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis",
        "white-space" => "nowrap",
        "word-break" => "keep-all"),
    CSS(".bt-card-meta",
        "color" => "var(--bt-text-muted)", "font-size" => "12px",
        "margin-top" => "2px",
        "display" => "flex", "align-items" => "center", "gap" => "6px",
        "white-space" => "nowrap", "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    CSS(".bt-card-actions",
        "display" => "flex", "gap" => "6px", "flex-shrink" => "0",
        "align-items" => "center"),
    CSS(".bt-mono",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "11.5px",
        "color" => "var(--bt-text-faint)"),

    # ── Status dot ───────────────────────────────────────────────────────────
    CSS(".bt-dot",
        "display" => "inline-block",
        "width" => "8px", "height" => "8px",
        "border-radius" => "50%", "flex-shrink" => "0"),
    CSS(".bt-dot-online",
        "background" => "var(--bt-success)",
        "box-shadow" => "0 0 0 3px rgba(16,185,129,0.18)"),
    CSS(".bt-dot-offline", "background" => "var(--bt-error)"),
    CSS(".bt-dot-unknown", "background" => "var(--bt-text-faint)"),

    # ── Pill (small text-bearing badge) ──────────────────────────────────────
    CSS(".bt-pill",
        "display" => "inline-flex", "align-items" => "center",
        "padding" => "1px 8px",
        "border-radius" => "999px",
        "font-size" => "11px", "font-weight" => "500",
        "letter-spacing" => "0.02em"),
    CSS(".bt-pill-active",
        "background" => "rgba(16,185,129,0.12)", "color" => "#047857"),
    CSS(".bt-pill-muted",
        "background" => "var(--bt-surface-2)", "color" => "var(--bt-text-muted)"),

    # ── Buttons ──────────────────────────────────────────────────────────────
    CSS(".bt-btn",
        "appearance" => "none", "border" => "none",
        "padding" => "7px 12px",
        "border-radius" => "var(--bt-radius-sm)",
        "background" => "var(--bt-accent)", "color" => "#fff",
        "font-size" => "13px", "font-weight" => "500",
        "cursor" => "pointer",
        "display" => "inline-flex", "align-items" => "center", "gap" => "6px",
        "transition" => "background 120ms ease, transform 80ms ease, opacity 120ms ease, color 120ms"),
    CSS(".bt-btn:hover",  "background" => "var(--bt-accent-hover)"),
    CSS(".bt-btn:active", "transform" => "translateY(1px)"),
    CSS(".bt-btn-secondary",
        "background" => "var(--bt-surface)", "color" => "var(--bt-text)",
        "border" => "1px solid var(--bt-border-strong)"),
    CSS(".bt-btn-secondary:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-btn-ghost",
        "background" => "transparent", "color" => "var(--bt-text-muted)",
        "padding" => "6px 8px"),
    CSS(".bt-btn-ghost:hover",
        "background" => "var(--bt-surface-2)", "color" => "var(--bt-text)"),
    CSS(".bt-btn-loading",
        "opacity" => "0.7", "cursor" => "wait"),

    # ── Forms ────────────────────────────────────────────────────────────────
    CSS(".bt-form",
        "background" => "var(--bt-surface-2)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "16px", "margin-top" => "12px",
        "display" => "grid",
        "grid-template-columns" => "120px 1fr",
        "gap" => "12px 16px", "align-items" => "start"),
    CSS(".bt-form label",
        "color" => "var(--bt-text-muted)", "font-size" => "13px",
        "padding-top" => "8px"),
    CSS(".bt-form input, .bt-form select",
        "padding" => "8px 10px",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "var(--bt-radius-sm)",
        "font-size" => "14px",
        "background" => "var(--bt-surface)",
        "width" => "100%", "box-sizing" => "border-box",
        "outline" => "none",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS(".bt-form input:focus, .bt-form select:focus",
        "border-color" => "var(--bt-accent)",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    CSS(".bt-form-actions",
        "grid-column" => "1 / -1",
        "display" => "flex", "gap" => "8px",
        "justify-content" => "flex-end",
        "padding-top" => "4px"),
    CSS(".bt-form-hint",
        "color" => "#047857", "font-size" => "12px", "margin-top" => "4px"),

    # ── Notices ──────────────────────────────────────────────────────────────
    CSS(".bt-error",
        "background" => "#fef2f2", "color" => "#b91c1c",
        "border" => "1px solid #fee2e2",
        "padding" => "10px 12px",
        "border-radius" => "var(--bt-radius-sm)",
        "font-size" => "13px", "margin-top" => "12px"),
    CSS(".bt-empty",
        "color" => "var(--bt-text-faint)", "font-size" => "13px",
        "padding" => "20px",
        "text-align" => "center",
        "border" => "1px dashed var(--bt-border)",
        "border-radius" => "var(--bt-radius)"),

    # ── Folder picker ────────────────────────────────────────────────────────
    CSS(".bt-picker",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "padding" => "6px",
        "background" => "var(--bt-surface)",
        "max-height" => "260px", "overflow-y" => "auto",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px"),
    CSS(".bt-picker-row",
        "padding" => "5px 8px",
        "border-radius" => "4px", "cursor" => "pointer",
        "transition" => "background 80ms"),
    CSS(".bt-picker-row:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-picker-cur",
        "padding" => "8px 10px",
        "background" => "var(--bt-surface-2)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px",
        "margin-bottom" => "8px",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between", "gap" => "8px"),
    CSS(".bt-picker-loading",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "color" => "var(--bt-text-muted)",
        "padding" => "12px", "font-size" => "12px"),

    # ── Discover panel ───────────────────────────────────────────────────────
    CSS(".bt-discover-panel",
        "background" => "var(--bt-surface-2)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "14px 16px",
        "margin-top" => "-4px", "margin-bottom" => "8px"),
    CSS(".bt-discover-header",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between",
        "margin-bottom" => "10px"),
    CSS(".bt-discover-title",
        "font-weight" => "600", "font-size" => "13px"),
    CSS(".bt-discover-actions",
        "display" => "flex", "gap" => "6px", "align-items" => "center"),

    CSS(".bt-section-label",
        "font-size" => "10.5px", "font-weight" => "600",
        "letter-spacing" => "0.08em", "text-transform" => "uppercase",
        "color" => "var(--bt-text-faint)",
        "margin" => "12px 4px 6px"),
    CSS(".bt-session-row",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between",
        "padding" => "10px 12px",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "margin-bottom" => "6px",
        "transition" => "border-color 120ms"),
    CSS(".bt-session-row:hover",
        "border-color" => "var(--bt-border-strong)"),
    CSS(".bt-session-active",
        "border-left" => "3px solid var(--bt-success)"),
    CSS(".bt-session-name",
        "font-weight" => "600", "font-size" => "13px",
        "display" => "flex", "align-items" => "center", "gap" => "6px"),
    CSS(".bt-session-path",
        "font-family" => "ui-monospace, monospace", "font-size" => "11px",
        "color" => "var(--bt-text-muted)", "margin-top" => "2px",
        "max-width" => "440px", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "white-space" => "nowrap"),
    CSS(".bt-session-meta",
        "font-size" => "11px",
        "color" => "var(--bt-text-faint)", "margin-top" => "2px"),

    # ── Spinner ──────────────────────────────────────────────────────────────
    CSS(".bt-spinner-row",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "color" => "var(--bt-text-muted)", "font-size" => "13px"),
    CSS(".bt-spinner",
        "width" => "14px", "height" => "14px",
        "border-radius" => "50%",
        "border" => "2px solid var(--bt-border)",
        "border-top-color" => "var(--bt-accent)",
        "animation" => "bt-spin 0.7s linear infinite",
        "flex-shrink" => "0"),
    CSS(".bt-spinner-sm",
        "width" => "11px", "height" => "11px", "border-width" => "1.5px"),
    CSS("@keyframes bt-spin", CSS("to", "transform" => "rotate(360deg)")),

    # ── Open chat link ───────────────────────────────────────────────────────
    CSS(".bt-link",
        "color" => "var(--bt-accent)", "text-decoration" => "none",
        "font-size" => "13px", "font-weight" => "500",
        "padding" => "6px 10px",
        "border-radius" => "var(--bt-radius-sm)",
        "display" => "inline-flex", "align-items" => "center", "gap" => "6px",
        "transition" => "background 120ms"),
    CSS(".bt-link:hover",
        "background" => "rgba(59,130,246,0.08)"),
    CSS(".bt-link-loading",
        "color" => "var(--bt-text-muted)", "pointer-events" => "none"),

    # ── Slide-in for forms / panels ──────────────────────────────────────────
    CSS(".bt-slide-in", "animation" => "bt-slide 160ms ease-out"),
    CSS("@keyframes bt-slide",
        CSS("from", "opacity" => "0", "transform" => "translateY(-4px)"),
        CSS("to",   "opacity" => "1", "transform" => "translateY(0)")),

    # ── Install hint (empty-state with copy button) ──────────────────────────
    CSS(".bt-install-block",
        "background" => "var(--bt-surface-2)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "16px 18px"),
    CSS(".bt-install-cmd",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between", "gap" => "8px",
        "background" => "#0f172a", "color" => "#e2e8f0",
        "font-family" => "ui-monospace, monospace", "font-size" => "12.5px",
        "padding" => "10px 12px", "border-radius" => "var(--bt-radius-sm)",
        "margin-top" => "8px"),
    CSS(".bt-install-copy",
        "background" => "rgba(255,255,255,0.06)",
        "color" => "#e2e8f0",
        "border" => "1px solid rgba(255,255,255,0.12)",
        "padding" => "4px 10px", "border-radius" => "4px",
        "font-size" => "12px", "cursor" => "pointer",
        "transition" => "background 120ms"),
    CSS(".bt-install-copy:hover",
        "background" => "rgba(255,255,255,0.12)"),

    # ── Responsive ───────────────────────────────────────────────────────────
    # Header stacks below ~560px so the tagline doesn't squish
    CSS("@media (max-width: 560px)",
        CSS(".bt-header",
            "flex-direction" => "column",
            "align-items" => "flex-start",
            "gap" => "4px"),
        CSS(".bt-tagline", "font-size" => "12px"),
        # form labels above inputs (single column) for touch widths
        CSS(".bt-form",
            "grid-template-columns" => "1fr",
            "gap" => "8px"),
        CSS(".bt-form label",
            "padding-top" => "0", "font-size" => "12px"),
        # cards may need to wrap their action cluster onto a second row
        CSS(".bt-card", "flex-wrap" => "wrap"),
        CSS(".bt-card-actions",
            "margin-left" => "auto", "flex-wrap" => "wrap"),
        # session row max-path doesn't make sense at narrow widths
        CSS(".bt-session-path", "max-width" => "100%"),
        # stats: tighter gap, smaller separators
        CSS(".bt-stats", "gap" => "12px")),
)

# Folder picker component
"""
Slim server-side folder picker. `selected` is an Observable{String} the caller
listens to. Renders as: current path + Browse / Up / Choose buttons + (when
expanded) a flat list of subdirectories.
"""
mutable struct FolderPicker
    cur::Observable{String}        # current directory being browsed
    selected::Observable{String}   # final chosen directory
    expanded::Observable{Bool}
end

FolderPicker(start::String = pwd()) = FolderPicker(
    Observable(abspath(start)), Observable(""), Observable(false))

function folder_picker_render(p::FolderPicker)
    browse_btn = Bonito.Button("Browse"; style=nothing, class = "bt-btn bt-btn-secondary")
    up_btn     = Bonito.Button("↑ Up"; style=nothing, class = "bt-btn bt-btn-secondary")
    choose_btn = Bonito.Button("Choose"; style=nothing, class = "bt-btn")

    on(browse_btn.value) do clicked
        clicked && (p.expanded[] = !p.expanded[])
    end
    on(up_btn.value) do clicked
        clicked || return
        parent = dirname(rstrip(p.cur[], '/'))
        isempty(parent) || (p.cur[] = parent)
    end
    on(choose_btn.value) do clicked
        clicked || return
        p.selected[] = p.cur[]
        p.expanded[] = false
    end

    list = map(p.cur, p.expanded) do path, show
        show || return DOM.div()
        entries = try
            sort!(filter(n -> isdir(joinpath(path, n)) && !startswith(n, "."),
                         readdir(path)))
        catch e
            return DOM.div("error: $e", class = "bt-picker", style = "color:#991b1b")
        end
        rows = isempty(entries) ?
            [DOM.div("(no subfolders)", class = "bt-picker-row", style = "color:#9ca3af")] :
            [DOM.div("📁 $name",
                class = "bt-picker-row",
                onclick = js"event => $(p.cur).notify($(joinpath(path, name))); ")
             for name in entries]
        DOM.div(rows...; class = "bt-picker")
    end

    DOM.div(
        DOM.div(
            DOM.span(p.cur, style = "overflow:hidden;text-overflow:ellipsis;white-space:nowrap"),
            DOM.div(up_btn, browse_btn, choose_btn,
                    style = "display:flex;gap:6px;flex-shrink:0"),
            class = "bt-picker-cur"),
        list)
end

# Remote folder picker — reads the worker's filesystem over its control WS via
# `list_worker_dir`. Async: the WS round-trip would otherwise block Bonito's map
# during render and freeze the UI for hundreds of ms per browse click.
const PickerEntry = NamedTuple{(:name, :dir), Tuple{String, Bool}}

mutable struct RemoteFolderPicker
    worker_name::String
    cur::Observable{String}
    selected::Observable{String}
    expanded::Observable{Bool}
    entries::Observable{Vector{PickerEntry}}
    loading::Observable{Bool}
    err::Observable{String}
    fetch_id::Ref{Int}                 # increments per request; older replies bail
    listeners_set_up::Ref{Bool}        # idempotency for setup_listeners!
end

RemoteFolderPicker(worker_name::String, start::String = "") = RemoteFolderPicker(
    worker_name, Observable(start), Observable(""), Observable(false),
    Observable(PickerEntry[]), Observable(false), Observable(""),
    Ref(0), Ref(false))

# Kick off a WS list_worker_dir for `p.cur[]` and update entries/loading/err.
# Older in-flight responses are discarded via fetch_id.
function fetch_remote_entries!(p::RemoteFolderPicker)
    p.fetch_id[] += 1
    my_id  = p.fetch_id[]
    target = p.cur[]
    p.loading[] = true
    p.err[]     = ""
    @async begin
        try
            resp = list_worker_dir(p.worker_name, target)
            my_id == p.fetch_id[] || return        # stale response, abandon
            if resp.path != target
                # Worker resolved cur="" → its $HOME. Cascading on(cur) will
                # trigger a fresh fetch — leave loading=true so the spinner
                # bridges the gap.
                p.cur[] = resp.path
                return
            end
            p.entries[] = PickerEntry[(name = String(e.name), dir = Bool(e.dir))
                                      for e in resp.entries if e.dir]
            p.loading[] = false
        catch e
            my_id == p.fetch_id[] || return
            p.err[]     = sprint(showerror, e)
            p.loading[] = false
        end
    end
end

function setup_remote_picker_listeners!(p::RemoteFolderPicker)
    p.listeners_set_up[] && return
    p.listeners_set_up[] = true
    on(p.cur)      do _;   p.expanded[] && fetch_remote_entries!(p); end
    on(p.expanded) do exp; exp && fetch_remote_entries!(p); end
    return
end

function remote_folder_picker_render(p::RemoteFolderPicker)
    setup_remote_picker_listeners!(p)

    browse_btn = Bonito.Button("Browse"; style=nothing, class = "bt-btn bt-btn-secondary")
    up_btn     = Bonito.Button("↑ Up";   style=nothing, class = "bt-btn bt-btn-secondary")
    choose_btn = Bonito.Button("Choose"; style=nothing, class = "bt-btn")

    on(browse_btn.value) do clicked
        clicked && (p.expanded[] = !p.expanded[])
    end
    on(up_btn.value) do clicked
        clicked || return
        cur = p.cur[]
        isempty(cur) && return
        parent = dirname(rstrip(cur, '/'))
        !isempty(parent) && parent != cur && (p.cur[] = parent)
    end
    on(choose_btn.value) do clicked
        clicked || return
        p.selected[] = p.cur[]
        p.expanded[] = false
    end

    list = map(p.expanded, p.loading, p.entries, p.err, p.cur) do exp, loading, entries, err, cur
        exp || return DOM.div()
        if loading
            return DOM.div(
                DOM.div(class = "bt-spinner"),
                DOM.span("Listing folder…"),
                class = "bt-picker bt-picker-loading bt-slide-in")
        end
        if !isempty(err)
            return DOM.div("error: $err",
                           class = "bt-picker", style = "color:#b91c1c")
        end
        rows = isempty(entries) ?
            [DOM.div("(no subfolders)",
                class = "bt-picker-row", style = "color:var(--bt-text-faint)")] :
            [DOM.div("📁 $(e.name)",
                class   = "bt-picker-row",
                onclick = js"event => $(p.cur).notify($(joinpath(cur, e.name)));")
             for e in entries]
        DOM.div(rows...; class = "bt-picker bt-slide-in")
    end

    DOM.div(
        DOM.div(
            DOM.span(p.cur, style = "overflow:hidden;text-overflow:ellipsis;white-space:nowrap"),
            DOM.div(up_btn, browse_btn, choose_btn,
                    style = "display:flex;gap:6px;flex-shrink:0"),
            class = "bt-picker-cur"),
        list)
end

# Status indicator helpers
status_dot(s::Symbol) = DOM.span(""; class = "bt-dot bt-dot-$s",
    title = string(s))   # native tooltip

function worker_card(w::WorkerInfo, srv_ref::Ref{Bonito.Server},
                     error_obs::Observable{String}, picker_state::Observable{String},
                     discover_state::Observable{String})
    new_proj_btn  = Bonito.Button("+ Project"; style=nothing, class = "bt-btn bt-btn-secondary")
    discover_btn  = Bonito.Button("Discover";  style=nothing, class = "bt-btn bt-btn-secondary")
    is_online     = w.status == :online

    on(new_proj_btn.value) do clicked
        clicked || return
        picker_state[]   = picker_state[]   == w.name ? "" : w.name
        discover_state[] = ""
        error_obs[]      = ""
    end
    on(discover_btn.value) do clicked
        clicked || return
        discover_state[] = discover_state[] == w.name ? "" : w.name
        picker_state[]   = ""
        error_obs[]      = ""
    end

    DOM.div(
        DOM.div(
            DOM.div(status_dot(w.status),
                    DOM.span(w.name; class = "bt-card-name");
                    class = "bt-card-title"),
            DOM.div(isempty(w.hostname) ? w.url : w.hostname,
                    class = "bt-card-meta");
            class = "bt-card-body"),
        DOM.div(
            is_online ? discover_btn   : DOM.span(),
            is_online ? new_proj_btn   : DOM.span("offline"; class = "bt-pill bt-pill-muted"),
            class = "bt-card-actions"),
        class = "bt-card")
end

# Build a project card. `opening_proj` lets the card show an inline "Opening…"
# spinner when the user clicks "Open chat" — gives feedback that the click
# registered, since the chat page itself can take a few seconds to come up.
function project_card(p::ProjectInfo, error_obs::Observable{String},
                       opening_proj::Observable{String})
    badge = p.locked_by === nothing ? DOM.span() :
        DOM.span("active";
                 class = "bt-pill bt-pill-active",
                 style = "margin-left:6px",
                 title = "active session on $(p.locked_by)")

    open_indicator = map(opening_proj) do oid
        oid == p.id ?
            DOM.span(DOM.div(class = "bt-spinner bt-spinner-sm"), "Opening…";
                     class = "bt-spinner-row",
                     style = "padding-right:8px") :
            DOM.span()
    end

    open_link = DOM.a("Open chat →";
        href    = Bonito.Link("/p/$(p.id)"),
        target  = "_blank",
        class   = "bt-link",
        onclick = js"event => $(opening_proj).notify($(p.id))")

    DOM.div(
        DOM.div(
            DOM.div(DOM.span(p.name; class = "bt-card-name"), badge;
                    class = "bt-card-title"),
            DOM.div(
                DOM.span(p.worker_name),
                DOM.span("·"; class = "bt-stat-sep"),
                DOM.span(p.worker_path; class = "bt-mono",
                         title = "server: $(p.server_path)\nworker: $(p.worker_path)");
                class = "bt-card-meta");
            class = "bt-card-body"),
        DOM.div(open_indicator, open_link;
                class = "bt-card-actions"),
        class = "bt-card")
end

function dashboard_app(srv_ref::Ref{Bonito.Server})
    error_obs = Observable("")

    # Workers self-register over WS — no manual "Add worker" form.

    # ── New Project form ─────────────────────────────────────────────────────
    new_proj_show = Observable(false)
    np_name = Observable("")
    np_picker = FolderPicker(working_dir())
    on(np_picker.selected) do sel
        isempty(strip(np_name[])) || return
        isempty(sel) && return
        np_name[] = basename(rstrip(sel, '/'))
    end
    np_worker = Observable("")
    busy_msg  = Observable("")   # "" = idle; non-empty = operation in progress

    # ── Open-chat click feedback ─────────────────────────────────────────────
    # When the user clicks "Open chat →" on a project card, a new tab opens
    # but the chat app can take a few seconds to come up. We flash an
    # "Opening…" spinner on that card so the click visibly registers.
    opening_proj = Observable("")
    on(opening_proj) do pid
        isempty(pid) && return
        @async begin
            sleep(3)
            opening_proj[] == pid && (opening_proj[] = "")
        end
    end

    np_submit = Bonito.Button("Create"; style=nothing, class = "bt-btn")
    np_cancel = Bonito.Button("Cancel"; style=nothing, class = "bt-btn bt-btn-secondary")

    on(np_submit.value) do clicked
        clicked || return
        isempty(busy_msg[]) || return   # guard: ignore clicks while busy
        busy_msg[] = "Syncing files…"
        @async begin
            try
                create_project!(srv_ref[], String(strip(np_name[])),
                                 String(strip(np_picker.selected[])),
                                 String(strip(np_worker[])))
                error_obs[] = ""
                new_proj_show[] = false
                np_name[] = ""; np_picker.selected[] = ""; np_worker[] = ""
            catch e
                error_obs[] = "Failed to create project: $e"
            finally
                busy_msg[] = ""
            end
        end
    end
    on(np_cancel.value) do clicked
        clicked || return
        isempty(busy_msg[]) || return   # don't cancel mid-create
        new_proj_show[] = false
        error_obs[] = ""
    end

    new_proj_btn = Bonito.Button("+ New project"; style=nothing, class = "bt-btn bt-btn-secondary")
    on(new_proj_btn.value) do clicked
        clicked || return
        if isempty(WORKERS)
            error_obs[] = "Register a worker before creating a project."
            return
        end
        np_worker[] = first(keys(WORKERS))
        new_proj_show[] = true
        error_obs[] = ""
    end

    # Per-worker remote-folder pickers (persistent across re-renders so the
    # current path / expanded state survives bump_state! triggers). The
    # `picker_state` observable holds the name of the worker whose picker
    # form is currently visible (""  → none).
    picker_state = Observable("")
    remote_pickers = Dict{String,RemoteFolderPicker}()

    # Discover panel — scan a worker for existing Claude Code sessions
    discover_state   = Observable("")                       # worker name whose panel is open
    discover_results = Observable(Dict{String,Any}[])
    discover_busy    = Observable(false)
    import_path      = Observable("")                       # JS onclick notifies this

    function trigger_scan!(w_name::String)
        discover_busy[]    = true
        discover_results[] = Dict{String,Any}[]
        @async begin
            try
                discover_results[] = scan_worker_sessions(w_name)
            catch e
                discover_results[] = [Dict{String,Any}("error" => sprint(showerror, e))]
            finally
                discover_busy[] = false
            end
        end
    end

    on(discover_state) do w_name
        isempty(w_name) || trigger_scan!(w_name)
    end

    on(import_path) do path
        isempty(path) && return
        import_path[] = ""          # reset so the same path can be re-imported
        isempty(busy_msg[]) || return
        w_name = discover_state[]
        isempty(w_name) && return
        proj_name = replace(basename(rstrip(path, '/')), r"[^a-zA-Z0-9_\-]" => "_")
        isempty(proj_name) && (proj_name = "project")
        busy_msg[] = "Pulling from worker…"
        @async begin
            try
                create_project_from_worker!(srv_ref[], w_name, path; name=proj_name)
                error_obs[]      = ""
                discover_state[] = ""
            catch e
                error_obs[] = "Failed to import: $(sprint(showerror, e))"
            finally
                busy_msg[] = ""
            end
        end
    end

    function session_row(r::AbstractDict)
        path      = String(get(r, "path", ""))
        isempty(path) && return DOM.div()
        name      = String(get(r, "name", basename(path)))
        is_active = get(r, "active", false) === true
        meta = if is_active
            "PID $(get(r, "pid", "?"))"
        elseif haskey(r, "last_used")
            ts = get(r, "last_used", 0.0)
            dt = Dates.unix2datetime(ts isa Number ? Float64(ts) : 0.0)
            "Last used $(Dates.format(dt, "yyyy-mm-dd HH:MM"))"
        else
            ""
        end
        badge = is_active ?
            DOM.span("active"; class = "bt-pill bt-pill-active") : DOM.span()
        DOM.div(
            DOM.div(
                DOM.div(name, badge; class = "bt-session-name"),
                DOM.div(path; class = "bt-session-path"),
                isempty(meta) ? DOM.span() : DOM.div(meta; class = "bt-session-meta")),
            DOM.div("Import";
                class   = "bt-btn bt-btn-secondary",
                style   = "cursor:pointer;flex-shrink:0",
                onclick = js"event => $(import_path).notify($path);"),
            class = is_active ? "bt-session-row bt-session-active" : "bt-session-row")
    end

    function discover_panel(w_name::String)
        close_btn  = Bonito.Button("✕"; style=nothing, class = "bt-btn bt-btn-ghost")
        rescan_btn = Bonito.Button("↻ Rescan"; style=nothing, class = "bt-btn bt-btn-secondary")
        on(close_btn.value)  do clicked; clicked && (discover_state[] = ""); end
        on(rescan_btn.value) do clicked; clicked && trigger_scan!(w_name); end

        panel_content = map(discover_busy, discover_results) do busy, results
            if busy
                spinner_row("Scanning $w_name for Claude Code sessions…")
            elseif isempty(results)
                DOM.div("No Claude Code sessions found on $w_name."; class = "bt-empty")
            else
                # Surface errors first, then split active vs historical.
                errors = [DOM.div("Error: $(r["error"])"; class = "bt-error")
                          for r in results if haskey(r, "error")]
                clean       = filter(r -> !haskey(r, "error"), results)
                active      = filter(r -> get(r, "active", false) === true, clean)
                historical  = filter(r -> get(r, "active", false) !== true, clean)
                blocks = []
                append!(blocks, errors)
                if !isempty(active)
                    push!(blocks, DOM.div("Active"; class = "bt-section-label"))
                    append!(blocks, [session_row(r) for r in active])
                end
                if !isempty(historical)
                    push!(blocks, DOM.div("Historical"; class = "bt-section-label"))
                    append!(blocks, [session_row(r) for r in historical])
                end
                DOM.div(blocks...; class = "bt-slide-in")
            end
        end

        DOM.div(
            DOM.div(
                DOM.span("Claude Code sessions on $w_name"; class = "bt-discover-title"),
                DOM.div(rescan_btn, close_btn; class = "bt-discover-actions");
                class = "bt-discover-header"),
            panel_content;
            class = "bt-discover-panel bt-slide-in")
    end

    function get_remote_picker(name)
        haskey(remote_pickers, name) || (remote_pickers[name] = RemoteFolderPicker(name))
        remote_pickers[name]
    end

    function submit_remote_pick(w_name::String)
        isempty(busy_msg[]) || return   # guard: ignore if already creating
        rp = get_remote_picker(w_name)
        chosen = String(strip(rp.selected[]))
        if isempty(chosen)
            error_obs[] = "Pick a folder on the worker first (Browse → Choose)."
            return
        end
        busy_msg[] = "Pulling project from worker…"
        @async begin
            try
                create_project_from_worker!(srv_ref[], w_name, chosen)
                error_obs[] = ""
                picker_state[] = ""
                rp.selected[] = ""
            catch e
                error_obs[] = "Failed to create project from worker: $e"
            finally
                busy_msg[] = ""
            end
        end
    end

    text_input(obs::Observable, ph::String) = DOM.input(
        type = "text", placeholder = ph,
        value = obs,    # Julia → JS: pushed back when obs changes (e.g. auto-fill)
        oninput = js"event => $(obs).notify(event.target.value)")

    spinner_row(msg) = DOM.div(
        DOM.div(class = "bt-spinner"),
        DOM.span(msg),
        class = "bt-spinner-row")

    new_proj_form() = DOM.div(
        DOM.label("Name"),   text_input(np_name, "e.g. my-project"),
        DOM.label("Source"), DOM.div(
            folder_picker_render(np_picker),
            map(np_picker.selected) do sel
                isempty(sel) ? DOM.div() :
                    DOM.div("✓ selected: $sel",
                            style = "color:#065f46;font-size:12px;margin-top:4px")
            end),
        DOM.label("Worker"),
        DOM.select(
            (DOM.option(name; value=name) for name in keys(WORKERS))...;
            onchange = js"event => $(np_worker).notify(event.target.value)"),
        map(busy_msg) do msg
            isempty(msg) ?
                DOM.div(np_cancel, np_submit, class = "bt-form-actions") :
                DOM.div(spinner_row(msg), class = "bt-form-actions")
        end,
        class = "bt-form")

    function remote_picker_form(w_name::String)
        rp = get_remote_picker(w_name)
        create_btn = Bonito.Button("Create"; style=nothing, class = "bt-btn")
        cancel_btn = Bonito.Button("Cancel"; style=nothing, class = "bt-btn bt-btn-secondary")
        on(create_btn.value) do clicked
            clicked && submit_remote_pick(w_name)
        end
        on(cancel_btn.value) do clicked
            clicked || return
            isempty(busy_msg[]) || return   # don't cancel mid-create
            picker_state[] = ""; error_obs[] = ""
        end
        DOM.div(
            DOM.label("Folder on $(w_name)"),
            DOM.div(remote_folder_picker_render(rp),
                    map(rp.selected) do sel
                        isempty(sel) ? DOM.div() :
                            DOM.div("✓ selected: $sel",
                                    style = "color:#065f46;font-size:12px;margin-top:4px")
                    end),
            map(busy_msg) do msg
                isempty(msg) ?
                    DOM.div(cancel_btn, create_btn, class = "bt-form-actions") :
                    DOM.div(spinner_row(msg), class = "bt-form-actions")
            end,
            class = "bt-form")
    end

    # ── Stats strip ──────────────────────────────────────────────────────────
    stats_strip = map(STATE_VERSION) do _
        online   = count(w -> w.status == :online, values(WORKERS))
        total    = length(WORKERS)
        n_proj   = length(PROJECTS)
        n_active = count(p -> p.locked_by !== nothing, values(PROJECTS))
        sep()    = DOM.span("·"; class = "bt-stat-sep")
        DOM.div(
            DOM.div(
                status_dot(online > 0 ? :online : (total == 0 ? :unknown : :offline)),
                DOM.span("$online"; class = "bt-stat-value"),
                DOM.span("/$total workers online"; class = "bt-stat-label"),
                class = "bt-stat"),
            sep(),
            DOM.div(
                DOM.span("$n_proj"; class = "bt-stat-value"),
                DOM.span(n_proj == 1 ? "project" : "projects"; class = "bt-stat-label"),
                class = "bt-stat"),
            sep(),
            DOM.div(
                DOM.span("$n_active"; class = "bt-stat-value"),
                DOM.span("active"; class = "bt-stat-label"),
                class = "bt-stat"),
            class = "bt-stats")
    end

    # ── Worker / project lists ───────────────────────────────────────────────
    worker_list = map(STATE_VERSION, picker_state, discover_state) do _, picked, discovered
        if isempty(WORKERS)
            install_url = "$(public_url_or_default())/install.sh"
            install_cmd = "curl -fsSL $install_url | sh"
            return DOM.div(
                DOM.div("No workers connected yet.";
                        style = "color:var(--bt-text-muted);font-size:13px"),
                DOM.div("Run on each agent machine:";
                        style = "color:var(--bt-text-faint);font-size:12px;margin-top:8px"),
                DOM.div(
                    DOM.span(install_cmd),
                    DOM.span("Copy";
                        class   = "bt-install-copy",
                        onclick = js"""event => {
                            navigator.clipboard.writeText($install_cmd);
                            event.target.textContent = 'Copied';
                            setTimeout(() => event.target.textContent = 'Copy', 1200);
                        }"""),
                    class = "bt-install-cmd");
                class = "bt-install-block")
        end
        rows = []
        for w in values(WORKERS)
            push!(rows, worker_card(w, srv_ref, error_obs, picker_state, discover_state))
            picked     == w.name && push!(rows, remote_picker_form(w.name))
            discovered == w.name && push!(rows, discover_panel(w.name))
        end
        DOM.div(rows...)
    end

    project_list = map(STATE_VERSION) do _
        isempty(PROJECTS) ?
            DOM.div("No projects yet — pick a worker above and click + Project, or import an existing Claude session via Discover.";
                    class = "bt-empty") :
            DOM.div((project_card(p, error_obs, opening_proj) for p in values(PROJECTS))...)
    end

    proj_form_block = map(new_proj_show) do show
        show ? DOM.div(new_proj_form(); class = "bt-slide-in") : DOM.div()
    end
    error_block = map(error_obs) do msg
        isempty(msg) ? DOM.div() : DOM.div(msg; class = "bt-error")
    end

    # Layout
    App() do session
        DOM.div(
            DashboardStyles,
            DOM.div(
                DOM.h1("BonitoTeam"),
                DOM.div("Multi-host orchestrator for agentic coding sessions";
                        class = "bt-tagline");
                class = "bt-header"),
            stats_strip,
            error_block,

            DOM.div(DOM.h2("Workers"); class = "bt-section"),
            worker_list,

            DOM.div(
                DOM.h2("Projects"),
                new_proj_btn;
                class = "bt-section"),
            project_list,
            proj_form_block;

            class = "bt-dash")
    end
end

# Best-effort lookup of the public URL for the install one-liner shown in the
# empty state. Reads the same env BONITOTEAM_PUBLIC_URL that the service uses.
function public_url_or_default()
    url = get(ENV, "BONITOTEAM_PUBLIC_URL", "")
    isempty(url) ? "http://<your-server>:8038" : rstrip(url, '/')
end
