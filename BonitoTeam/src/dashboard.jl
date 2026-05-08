# Project lock + chat / dashboard orchestration. State (workers, projects,
# pending RPCs, etc.) lives in `state.jl::ServerState`; every public function
# in this file takes a `state::ServerState` argument as its first parameter.
# Worker registration is handled in worker_client.jl when the worker dials
# the server's /worker-ws endpoint. Liveness comes from the WS itself; no
# periodic probing or heartbeat task.

# Project lock
"""
Mark a project locked by a worker (active ACP session). Errors if the project
is already locked by a different worker.
"""
function acquire_lock!(state::ServerState, p::ProjectInfo, worker_name::String)
    if p.locked_by !== nothing && p.locked_by != worker_name
        error("Project '$(p.name)' is locked by worker '$(p.locked_by)'")
    end
    p.locked_by = worker_name
    p.locked_at = now(UTC)
    save_projects!(state)
    bump_state!(state)
    return p
end

function release_lock!(state::ServerState, p::ProjectInfo)
    p.locked_by = nothing
    p.locked_at = nothing
    save_projects!(state)
    bump_state!(state)
    return p
end

# Auto-release every project lock held by `worker_name` (called from
# handle_worker_control's finally branch when the WS drops).
function release_locks_for_worker!(state::ServerState, worker_name::String)
    for p in values(state.projects)
        p.locked_by == worker_name && release_lock!(state, p)
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
function create_project!(state::ServerState, name::String, src_path::String,
                          worker_name::String;
                          progress = nothing)
    haskey(state.workers, worker_name) || error("Unknown worker: $worker_name")
    isempty(name) && error("Project name must not be empty")
    occursin(r"^[a-zA-Z0-9_\-]+$", name) ||
        error("Project name must be alphanumeric/_/- only")
    isempty(src_path) && error("Source path is required (pick a folder).")
    isdir(src_path)   || error("Source path is not a directory: $src_path")

    w = state.workers[worker_name]
    id          = string(uuid4())[1:8]
    server_path = joinpath(state.working_dir, name)
    worker_path = joinpath(w.projects_root, name)

    # 1. Seed the canonical server-side copy from the picked source (local
    # rsync; this is always on the server box, no SSH).
    if abspath(src_path) != abspath(server_path)
        progress === nothing || progress("Seeding server-side mirror…")
        @info "Seeding server-side mirror" src_path server_path
        mkpath(state.working_dir)
        run(`rsync -az $(rstrip(src_path, '/'))/ $(rstrip(server_path, '/'))/`)
    end

    # 2. Push server → worker over the worker's WS (no SSH, no inbound port).
    @info "Pushing project to worker" worker=worker_name dst=worker_path
    sync_dir_to_worker!(state, worker_name, server_path, worker_path; on_progress = progress)

    p = ProjectInfo(id, name, worker_name, server_path, worker_path, now(UTC))
    state.projects[id] = p
    save_projects!(state)

    # 3 + 4: build the chat app + register the route.
    progress === nothing || progress("Starting chat session…")
    ensure_project_session!(state, p)
    bump_state!(state)
    return p
end

"""
    create_project_from_worker!(srv, worker_name, worker_path;
                                 name, sync=false, resume_session_id=nothing, progress)

Register a project rooted at an existing folder ON THE WORKER. By default
NO bytes are pulled to the server — the project is immediately usable for
chat (which only needs `worker_path`), and the operator can later trigger an
async sync via `sync_project_to_server!` (e.g. the "Sync to server" button on
the project card or in the chat header menu). Pass `sync=true` to force a
synchronous pull at create time.

If `resume_session_id` is set to a claude-agent-acp session ID (the .jsonl
basename in `~/.claude/projects/<encoded>/`), the chat will use ACP's
`session/load` to resume that conversation — its history replays into the
chat UI and the agent regains full context. The ID persists across server
restarts.
"""
function create_project_from_worker!(state::ServerState, worker_name::String,
                                      worker_path::String;
                                      name::String = basename(rstrip(worker_path, '/')),
                                      sync::Bool = false,
                                      resume_session_id::Union{String,Nothing} = nothing,
                                      progress = nothing)
    haskey(state.workers, worker_name) || error("Unknown worker: $worker_name")
    isempty(name) && error("Project name must not be empty (folder has no basename?)")
    occursin(r"^[a-zA-Z0-9_\-]+$", name) ||
        error("Project name must be alphanumeric/_/- only — got '$name'")
    isempty(worker_path) && error("Worker path is required (pick a folder).")

    id = string(uuid4())[1:8]
    server_path = joinpath(state.working_dir, name)

    p = ProjectInfo(id, name, worker_name, server_path, worker_path, now(UTC))
    p.resume_session_id = resume_session_id
    state.projects[id] = p

    if sync
        @info "Pulling project from worker" worker=worker_name worker_path server_path
        p.backup_status = :syncing
        try
            sync_dir_from_worker!(state, worker_name, worker_path, server_path; on_progress = progress)
            p.backup_status = :synced
            p.last_sync_at  = now(UTC)
        catch e
            p.backup_status = :unsynced
            rethrow(e)
        end
    else
        @info "Registering project from worker (no sync)" worker=worker_name worker_path
    end

    save_projects!(state)

    progress === nothing || progress("Starting chat session…")
    ensure_project_session!(state, p)
    bump_state!(state)
    return p
end

# Triggered by the chat header's "Sync to server" menu item. Looks up the
# project, runs sync_project_to_server! in a Task, pushes status updates
# back to the chat's sync_status observable so the menu shows progress
# without redirecting to the dashboard.
function handle_chat_sync_click(state::ServerState, project_id::AbstractString,
                                 sync_status::Observable{String})
    haskey(state.projects, project_id) || (safe_set!(sync_status, "unknown project"); return)
    p = state.projects[project_id]
    p.backup_status === :syncing && (safe_set!(sync_status, "already syncing…"); return)
    safe_set!(sync_status, "starting…")
    @async begin
        try
            sync_project_to_server!(state, p;
                on_progress = msg -> safe_set!(sync_status, msg))
            safe_set!(sync_status,
                "✓ synced $(Dates.format(p.last_sync_at, "HH:MM:SS")) UTC")
        catch e
            bt = catch_backtrace()
            @warn "handle_chat_sync_click failed" project=p.name exception=(e, bt)
            safe_set!(sync_status, "failed: $(sprint(showerror, e))")
        end
    end
    return
end

"""
    sync_project_to_server!(state, p::ProjectInfo; on_progress=nothing)

Pull the worker's current `worker_path` into the project's server-side
mirror via librsync. Resumable — only changed bytes go over the wire.
Updates `p.backup_status` to `:syncing` for the duration, then `:synced`
on success or `:stale` on failure.
"""
function sync_project_to_server!(state::ServerState, p::ProjectInfo; on_progress = nothing)
    haskey(state.workers, p.worker_name) ||
        error("Worker '$(p.worker_name)' is not connected")
    p.backup_status === :syncing &&
        error("Project '$(p.name)' is already syncing")
    p.backup_status = :syncing
    bump_state!(state)
    try
        sync_dir_from_worker!(state, p.worker_name, p.worker_path, p.server_path;
                              on_progress = on_progress)
        p.backup_status = :synced
        p.last_sync_at  = now(UTC)
        save_projects!(state)
        bump_state!(state)
    catch e
        p.backup_status = :stale
        bump_state!(state)
        rethrow(e)
    end
    return p
end

"""
Build the chat ChatModel for `p` if not done yet, cache it in
state.chat_models, and start its ACP client. Idempotent: subsequent calls
return the cached model. Called from project creation flows + on worker
reconnect (projects belonging to that worker become serviceable again).

The unified app's main panel pulls the cached model out of state.chat_models
when the user selects this project in the sidebar.
"""
function ensure_project_session!(state::ServerState, p::ProjectInfo)
    haskey(state.chat_models, p.id) && return state.chat_models[p.id]
    haskey(state.workers, p.worker_name) ||
        error("Worker '$(p.worker_name)' is not connected")
    w = state.workers[p.worker_name]

    acquire_lock!(state, p, w.name)

    mcp = isempty(w.mcp_path) ? AgentClientProtocol.MCPServer[] :
        [AgentClientProtocol.MCPServer("bonitoteam", w.mcp_path)]

    # If the project was imported with a claude session ID, the factory asks
    # the worker to do session/load (resume) instead of session/new.
    client_factory = on_update -> start_session_on_worker(state, w.name, p.worker_path;
                                                           on_update,
                                                           mcp_servers = mcp,
                                                           resume_session_id = p.resume_session_id)
    # Ensure server_path exists so BonitoBook (which reads files from cwd to
    # render the chat notebook + tools) doesn't crash on a never-synced
    # project. Empty dir is fine; project files live on the worker and only
    # get pulled here if the user clicks "Sync to server".
    mkpath(p.server_path)

    model = ChatModel(state, p.server_path;
                       project_id     = p.id,
                       mcp_servers    = mcp,
                       client_factory = client_factory)
    start_chat_client!(model)        # also caches into state.chat_models
    fire_auto_prompt!(model)
    return model
end

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
    CSS(".bt-pill-online",
        "background" => "rgba(16,185,129,0.12)", "color" => "#047857"),
    CSS(".bt-pill-muted",
        "background" => "var(--bt-surface-2)", "color" => "var(--bt-text-muted)"),
    CSS(".bt-pill-warn",
        "background" => "rgba(234,179,8,0.15)", "color" => "#a16207"),
    CSS(".bt-pill-syncing",
        "background" => "rgba(59,130,246,0.12)", "color" => "#1d4ed8",
        "gap" => "6px"),

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
    CSS(".bt-btn-sm",
        "padding" => "3px 9px", "font-size" => "12px"),

    # ── Forms ────────────────────────────────────────────────────────────────
    CSS(".bt-form",
        "background" => "var(--bt-surface-2)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "16px", "margin-top" => "12px",
        "display" => "grid",
        # minmax(0, 1fr) lets the column shrink below content min-width so the
        # picker's address bar can scroll horizontally without expanding the form
        "grid-template-columns" => "120px minmax(0, 1fr)",
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
        "display" => "flex", "align-items" => "center",
        "gap" => "8px", "margin-bottom" => "8px",
        "flex-wrap" => "wrap",
        "min-width" => "0"),
    # ── Windows-style address bar ────────────────────────────────────────────
    CSS(".bt-addr-bar",
        "flex" => "1 1 0",   "min-width" => "0",
        "display" => "flex", "align-items" => "center",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "var(--bt-radius-sm)",
        "padding" => "2px 4px",
        "min-height" => "32px",
        "cursor" => "text",
        "overflow-x" => "auto",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS(".bt-addr-bar:hover",
        "border-color" => "var(--bt-accent)"),
    CSS(".bt-addr-seg",
        "padding" => "4px 6px",
        "border-radius" => "4px",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "12px",
        "color" => "var(--bt-text)",
        "white-space" => "nowrap",
        "cursor" => "pointer",
        "transition" => "background 80ms, color 80ms"),
    CSS(".bt-addr-seg:hover",
        "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-accent)"),
    CSS(".bt-addr-seg-root",
        "padding" => "4px 4px"),
    CSS(".bt-addr-chevron",
        "color" => "var(--bt-text-faint)",
        "user-select" => "none",
        "padding" => "0 1px",
        "font-size" => "11px",
        "flex-shrink" => "0"),
    # Empty area to the right of the segments — clicking it enters edit mode
    CSS(".bt-addr-filler",
        "flex" => "1 1 auto", "min-width" => "8px",
        "align-self" => "stretch",
        "cursor" => "text"),
    CSS(".bt-addr-input",
        "flex" => "1 1 auto", "min-width" => "0",
        "padding" => "6px 10px",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-accent)",
        "border-radius" => "var(--bt-radius-sm)",
        "min-height" => "32px",
        "box-sizing" => "border-box",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "12px",
        "color" => "var(--bt-text)",
        "outline" => "none",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    CSS(".bt-addr-icon-btn",
        "background" => "transparent", "border" => "none",
        "color" => "var(--bt-text-faint)", "cursor" => "pointer",
        "padding" => "4px 6px", "border-radius" => "4px",
        "font-size" => "13px",
        "transition" => "background 80ms, color 80ms",
        "flex-shrink" => "0"),
    CSS(".bt-addr-icon-btn:hover",
        "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-accent)"),
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
    # Pure UI feedback for the "Open chat →" link. JS just adds the
    # `.bt-link-clicked` class on click; the CSS animation flashes the link
    # and self-clears via `animation-fill-mode: forwards`. No server-side
    # observable, no @async timer — the new tab loading IS the feedback.
    CSS(".bt-link-clicked",
        "background" => "rgba(59,130,246,0.18)",
        "color" => "var(--bt-text-muted)",
        "pointer-events" => "none",
        "animation" => "bt-link-flash 1.6s ease-out forwards"),
    CSS("@keyframes bt-link-flash",
        CSS("0%",   "background" => "rgba(59,130,246,0.32)"),
        CSS("60%",  "background" => "rgba(59,130,246,0.18)"),
        CSS("100%", "background" => "transparent",
                    "color"      => "var(--bt-accent)")),

    # ── Global busy toast ────────────────────────────────────────────────────
    # Fixed top-right (left of the connection LED). Shown whenever any
    # handler has set busy_msg, regardless of which form is open. Live
    # progress messages from push/pull file transfers flow in here.
    CSS(".bt-busy-toast",
        "position" => "fixed",
        "top" => "10px", "right" => "44px",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-accent)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "10px 14px",
        "box-shadow" => "var(--bt-shadow-md)",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "z-index" => "9998",
        "font-size" => "13px",
        "color" => "var(--bt-text)",
        "max-width" => "min(80vw, 480px)"),

    # ── Inline "loading" state for click-fired DOM buttons ───────────────────
    # Used by the Discover Import button — JS flips this class on click for
    # instant visual feedback (the WS round-trip to set busy_msg can take
    # tens of ms; the click should respond immediately).
    CSS(".bt-btn.bt-clicked",
        "opacity" => "0.55", "cursor" => "wait",
        "pointer-events" => "none"),

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
            "grid-template-columns" => "minmax(0, 1fr)",
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

# Windows-style address bar: clickable breadcrumb segments by default;
# clicking the empty area or the ✎ button switches to a text input where the
# user can type/paste a path. Enter commits, Esc cancels.
"""
    address_bar(cur, editing) → Bonito DOM node

`cur::Observable{String}` is the path being browsed; `editing::Observable{Bool}`
toggles between breadcrumb mode and text-input mode. Both are mutated in
response to user clicks/keystrokes.
"""
function address_bar(cur::Observable{String}, editing::Observable{Bool})
    map(cur, editing) do path, edit
        if edit
            DOM.input(
                type    = "text",
                value   = path,
                class   = "bt-addr-input",
                autofocus = true,
                onfocus = js"event => event.target.select()",
                onkeydown = js"""event => {
                    if (event.key === 'Enter') {
                        $(cur).notify(event.target.value);
                        $(editing).notify(false);
                    } else if (event.key === 'Escape') {
                        $(editing).notify(false);
                    }
                }""")
        else
            paths = breadcrumb_paths(String(path))
            nodes = []
            for (i, full) in enumerate(paths)
                label = i == 1 ? "/" : basename(full)
                push!(nodes, DOM.span(label;
                    class   = i == 1 ? "bt-addr-seg bt-addr-seg-root" : "bt-addr-seg",
                    onclick = js"event => { event.stopPropagation(); $(cur).notify($full); }",
                    title   = full))
                if i < length(paths)
                    push!(nodes, DOM.span("›"; class = "bt-addr-chevron"))
                end
            end
            # Filler at the end takes remaining width — clicking it enters edit mode.
            push!(nodes, DOM.div("";
                class = "bt-addr-filler",
                onclick = js"event => $(editing).notify(true)"))
            push!(nodes, DOM.button("✎";
                class    = "bt-addr-icon-btn",
                title    = "Edit path",
                onclick  = js"event => $(editing).notify(true)"))
            DOM.div(nodes...;
                class   = "bt-addr-bar",
                onclick = js"""event => {
                    if (event.target === event.currentTarget) $(editing).notify(true);
                }""")
        end
    end
end

# Build cumulative paths for breadcrumb rendering:
# "/home/server/BonitoTeam" → ["/", "/home", "/home/server", "/home/server/BonitoTeam"]
function breadcrumb_paths(cur::String)::Vector{String}
    isempty(cur) && return ["/"]
    cur = startswith(cur, "/") ? cur : "/" * cur
    parts = split(cur, '/'; keepempty = false)
    paths = String["/"]
    acc = ""
    for p in parts
        acc *= "/" * String(p)
        push!(paths, acc)
    end
    return paths
end

# Folder picker component
"""
Slim server-side folder picker. `selected` is an Observable{String} the caller
listens to. Renders as: address bar + Up / Choose buttons + a flat list of
subdirectories below the bar.
"""
mutable struct FolderPicker
    cur::Observable{String}        # current directory being browsed
    selected::Observable{String}   # final chosen directory
    expanded::Observable{Bool}
    editing::Observable{Bool}      # address bar in text-edit mode
end

FolderPicker(start::String = pwd()) = FolderPicker(
    Observable(abspath(start)), Observable(""), Observable(false), Observable(false))

function folder_picker_render(p::FolderPicker)
    up_btn     = Bonito.Button("↑"; style=nothing, class = "bt-btn bt-btn-secondary",
                               title = "Up one level")
    choose_btn = Bonito.Button("Choose"; style=nothing, class = "bt-btn")

    on(up_btn.value) do clicked
        clicked || return
        parent = dirname(rstrip(p.cur[], '/'))
        isempty(parent) || (p.cur[] = parent)
    end
    on(choose_btn.value) do clicked
        clicked || return
        p.selected[] = p.cur[]
    end

    # Always show the listing — drop the explicit Browse-to-expand mode.
    p.expanded[] = true

    list = map(p.cur) do path
        entries = try
            sort!(filter(n -> isdir(joinpath(path, n)) && !startswith(n, "."),
                         readdir(path)))
        catch e
            return DOM.div("error: $e", class = "bt-picker", style = "color:#b91c1c")
        end
        rows = isempty(entries) ?
            [DOM.div("(no subfolders)";
                class = "bt-picker-row", style = "color:var(--bt-text-faint)")] :
            [DOM.div("📁 $name";
                class   = "bt-picker-row",
                onclick = js"event => $(p.cur).notify($(joinpath(path, name)));")
             for name in entries]
        DOM.div(rows...; class = "bt-picker")
    end

    DOM.div(
        DOM.div(
            address_bar(p.cur, p.editing),
            up_btn, choose_btn;
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
    editing::Observable{Bool}          # address bar in text-edit mode
    entries::Observable{Vector{PickerEntry}}
    loading::Observable{Bool}
    err::Observable{String}
    fetch_id::Ref{Int}                 # increments per request; older replies bail
    listeners_set_up::Ref{Bool}        # idempotency for setup_listeners!
end

RemoteFolderPicker(worker_name::String, start::String = "") = RemoteFolderPicker(
    worker_name, Observable(start), Observable(""), Observable(false),
    Observable(false),
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

    up_btn     = Bonito.Button("↑"; style=nothing, class = "bt-btn bt-btn-secondary",
                               title = "Up one level")
    choose_btn = Bonito.Button("Choose"; style=nothing, class = "bt-btn")

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
    end

    # Picker is always visible — kick off the initial fetch on first render.
    p.expanded[] = true

    list = map(p.loading, p.entries, p.err, p.cur) do loading, entries, err, cur
        if loading
            return DOM.div(
                DOM.div(class = "bt-spinner"),
                DOM.span("Listing folder…");
                class = "bt-picker bt-picker-loading bt-slide-in")
        end
        if !isempty(err)
            return DOM.div("error: $err";
                           class = "bt-picker", style = "color:#b91c1c")
        end
        rows = isempty(entries) ?
            [DOM.div("(no subfolders)";
                class = "bt-picker-row", style = "color:var(--bt-text-faint)")] :
            [DOM.div("📁 $(e.name)";
                class   = "bt-picker-row",
                onclick = js"event => $(p.cur).notify($(joinpath(cur, e.name)));")
             for e in entries]
        DOM.div(rows...; class = "bt-picker bt-slide-in")
    end

    DOM.div(
        DOM.div(
            address_bar(p.cur, p.editing),
            up_btn, choose_btn;
            class = "bt-picker-cur"),
        list)
end

# Status indicator helpers
status_dot(s::Symbol) = DOM.span(""; class = "bt-dot bt-dot-$s",
    title = string(s))   # native tooltip

# Pull a likely username out of $HOME (e.g. "/home/simon" → "simon"). Returns
# "" if we can't find one.
function _user_from_home(home::AbstractString)
    isempty(home) && return ""
    parts = split(home, '/'; keepempty=false)
    isempty(parts) && return ""
    return String(last(parts))
end

# Compose a human-readable worker subtitle. Skips "localhost" since
# gethostname() returns it on some setups and it's useless metadata.
# Order: user@host  ·  projects-root.
function worker_subtitle(w::WorkerInfo)
    parts = String[]
    user  = _user_from_home(w.home)
    host  = (w.hostname == "localhost" || isempty(w.hostname)) ? "" : w.hostname
    if !isempty(user) && !isempty(host)
        push!(parts, "$user@$host")
    elseif !isempty(host)
        push!(parts, host)
    elseif !isempty(user)
        push!(parts, user)
    end
    isempty(w.projects_root) || push!(parts, w.projects_root)
    return isempty(parts) ? "(no metadata)" : join(parts, " · ")
end

function worker_card(state::ServerState, w::WorkerInfo,
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
            DOM.div(worker_subtitle(w); class = "bt-card-meta",
                    title = "$(w.hostname) · home: $(w.home)"),
            class = "bt-card-body"),
        DOM.div(
            is_online ? discover_btn   : DOM.span(),
            is_online ? new_proj_btn   : DOM.span("offline"; class = "bt-pill bt-pill-muted"),
            class = "bt-card-actions"),
        class = "bt-card")
end

# Render a small pill describing the project's backup status. Read at card-
# render time; the dashboard re-renders on bump_state! whenever sync state
# changes.
function backup_pill(p::ProjectInfo)
    if p.backup_status === :syncing
        DOM.span(DOM.div(class = "bt-spinner bt-spinner-sm"),
                 DOM.span("Backing up…");
                 class = "bt-pill bt-pill-syncing bt-spinner-row",
                 style = "margin-left:6px",
                 title = "Project is syncing to server")
    elseif p.backup_status === :synced
        last = p.last_sync_at === nothing ? "" :
               " (last: $(Dates.format(p.last_sync_at, "yyyy-mm-dd HH:MM")) UTC)"
        DOM.span("backed up"; class = "bt-pill bt-pill-online",
                 style = "margin-left:6px",
                 title = "Server has a copy of this project's files$(last)")
    elseif p.backup_status === :stale
        DOM.span("stale backup"; class = "bt-pill bt-pill-warn",
                 style = "margin-left:6px",
                 title = "Server copy may be out of date — re-sync to refresh")
    else
        DOM.span("not backed up"; class = "bt-pill bt-pill-muted",
                 style = "margin-left:6px",
                 title = "Server has no copy — chat works directly against the worker")
    end
end

# Build a project card. "Open chat" notifies the unified app's current_view
# observable to swap the main panel to this project's chat — no navigation,
# no new tab. Falls back to a no-op if no current_view was provided (e.g.
# when project_card is rendered standalone in tests).
# `sync_request` is notified with the project id when the user clicks
# "Sync to server"; the dashboard handler runs the actual transfer.
function project_card(p::ProjectInfo, error_obs::Observable{String},
                       sync_request::Observable{String},
                       current_view::Union{Observable{String},Nothing} = nothing)
    badge = p.locked_by === nothing ? DOM.span() :
        DOM.span("active";
                 class = "bt-pill bt-pill-active",
                 style = "margin-left:6px",
                 title = "active session on $(p.locked_by)")

    open_link = if current_view === nothing
        DOM.span("(no chat available)";
            class = "bt-link", style = "color:var(--bt-text-muted)")
    else
        DOM.span("Open chat →";
            class   = "bt-link",
            style   = "cursor:pointer",
            onclick = js"event => $(current_view).notify($(p.id))")
    end

    sync_btn = if p.backup_status === :syncing
        DOM.span()   # already syncing — pill shows the spinner
    else
        label = p.backup_status === :synced ? "Re-sync" : "Sync to server"
        DOM.span(label;
            class   = "bt-btn bt-btn-secondary bt-btn-sm",
            style   = "cursor:pointer;margin-right:8px",
            # Instant feedback before the WS round-trip lands.
            onclick = js"""event => {
                const btn = event.currentTarget;
                btn.classList.add('bt-clicked');
                btn.textContent = 'Syncing…';
                $(sync_request).notify($(p.id));
            }""")
    end

    DOM.div(
        DOM.div(
            DOM.div(DOM.span(p.name; class = "bt-card-name"),
                    badge, backup_pill(p);
                    class = "bt-card-title"),
            DOM.div(
                DOM.span(p.worker_name),
                DOM.span("·"; class = "bt-stat-sep"),
                DOM.span(p.worker_path; class = "bt-mono",
                         title = "server: $(p.server_path)\nworker: $(p.worker_path)");
                class = "bt-card-meta");
            class = "bt-card-body"),
        DOM.div(sync_btn, open_link;
                class = "bt-card-actions"),
        class = "bt-card")
end

"""
    dashboard_dom(state; current_view = nothing) → DOM

Build the dashboard's DOM block. When `current_view` is provided (the
unified app's view-selector observable), the project-creation flows
auto-navigate to the new project's chat by setting it; otherwise creation
just leaves the user on the dashboard.
"""
function dashboard_dom(state::ServerState;
                        current_view::Union{Observable{String},Nothing} = nothing)
    error_obs = Observable("")

    # Workers self-register over WS — no manual "Add worker" form.

    # `which_form` is the single source of truth for which slide-in panel is
    # open. `:none` (closed), `:new_project`, or `:github`. The two forms are
    # mutually exclusive; one enum is clearer than two booleans that always
    # have to be kept opposite.
    which_form = Observable(:none)
    busy_msg   = Observable("")        # "" = idle; non-empty = operation in progress

    # Form fields
    np_name   = Observable("")
    np_picker = FolderPicker(state.working_dir)
    on(np_picker.selected) do sel
        isempty(strip(np_name[])) || return
        isempty(sel) && return
        np_name[] = basename(rstrip(sel, '/'))
    end
    np_worker = Observable("")
    gh_url    = Observable("")
    gh_worker = Observable("")

    # ── Sync-to-server click handler ─────────────────────────────────────────
    # Fired by the project card's "Sync to server" / "Re-sync" button. The
    # actual transfer runs in the background; we update busy_msg + bump_state!
    # so the UI shows the syncing state on the card.
    sync_request = Observable("")
    on(sync_request) do pid
        isempty(pid) && return
        sync_request[] = ""           # reset so the same card can re-fire
        haskey(state.projects, pid) || return
        p = state.projects[pid]
        p.backup_status === :syncing && return    # already in flight
        @async begin
            try
                # safe_set! on busy_msg: a JS hiccup updating the toast must
                # not abort the in-flight transfer.
                sync_project_to_server!(state, p;
                    on_progress = msg -> safe_set!(busy_msg, "Syncing $(p.name): $(msg)"))
                safe_set!(error_obs, "")
            catch e
                bt = catch_backtrace()
                @warn "sync_project_to_server! failed" project=p.name exception=(e, bt)
                safe_set!(error_obs,
                    "Failed to sync $(p.name): $(sprint(showerror, e))")
            finally
                safe_set!(busy_msg, "")
            end
        end
    end

    np_submit = Bonito.Button("Create"; style=nothing, class = "bt-btn")
    np_cancel = Bonito.Button("Cancel"; style=nothing, class = "bt-btn bt-btn-secondary")

    on(np_submit.value) do clicked
        clicked || return
        isempty(busy_msg[]) || return   # guard: ignore clicks while busy
        nm = String(strip(np_name[]))
        busy_msg[] = "Creating $(nm)…"
        @async begin
            try
                p = create_project!(state, nm,
                                 String(strip(np_picker.selected[])),
                                 String(strip(np_worker[]));
                                 progress = msg -> (busy_msg[] = "Creating $(nm): $(msg)"))
                error_obs[] = ""
                which_form[] = :none
                np_name[] = ""; np_picker.selected[] = ""; np_worker[] = ""
                current_view !== nothing && (current_view[] = p.id)
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
        which_form[] = :none
        error_obs[] = ""
    end

    new_proj_btn = Bonito.Button("+ New project"; style=nothing, class = "bt-btn bt-btn-secondary")
    on(new_proj_btn.value) do clicked
        clicked || return
        if isempty(state.workers)
            error_obs[] = "Register a worker before creating a project."
            return
        end
        np_worker[]  = first(keys(state.workers))
        which_form[] = :new_project
        error_obs[]  = ""
    end

    gh_submit = Bonito.Button("Open"; style=nothing, class = "bt-btn")
    gh_cancel = Bonito.Button("Cancel"; style=nothing, class = "bt-btn bt-btn-secondary")

    on(gh_submit.value) do clicked
        clicked || return
        isempty(busy_msg[]) || return
        url = String(strip(gh_url[]))
        worker_name = String(strip(gh_worker[]))
        isempty(url) && (error_obs[] = "GitHub URL required."; return)
        isempty(worker_name) && (error_obs[] = "Pick a worker."; return)
        busy_msg[] = "Opening from GitHub…"
        @async begin
            try
                p = create_project_from_github!(state, url;
                    worker_name = worker_name,
                    progress    = msg -> (busy_msg[] = "From GitHub: $(msg)"))
                error_obs[]  = ""
                which_form[] = :none
                gh_url[]     = ""
                current_view !== nothing && (current_view[] = p.id)
            catch e
                error_obs[] = "Failed to open from GitHub: $(sprint(showerror, e))"
            finally
                busy_msg[] = ""
            end
        end
    end
    on(gh_cancel.value) do clicked
        clicked || return
        isempty(busy_msg[]) || return
        which_form[] = :none
        error_obs[]  = ""
    end

    gh_btn = Bonito.Button("+ From GitHub"; style=nothing, class = "bt-btn bt-btn-secondary")
    on(gh_btn.value) do clicked
        clicked || return
        if isempty(state.workers)
            error_obs[] = "Register a worker before opening a GitHub project."
            return
        end
        gh_worker[]  = first(keys(state.workers))
        which_form[] = :github
        error_obs[]  = ""
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
    # JS onclick notifies a {path, session_id} dict so the import handler can
    # tell the worker to claude-agent-acp's session/load instead of /new.
    import_path      = Observable(Dict{String,Any}())

    function trigger_scan!(w_name::String)
        discover_busy[]    = true
        discover_results[] = Dict{String,Any}[]
        @async begin
            try
                discover_results[] = scan_worker_sessions(state, w_name)
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

    on(import_path) do payload
        isempty(payload) && return
        path = String(get(payload, "path", ""))
        isempty(path) && return
        sid_raw = get(payload, "session_id", nothing)
        resume_session_id = (sid_raw === nothing || isempty(String(sid_raw))) ?
                                nothing : String(sid_raw)
        import_path[] = Dict{String,Any}()    # reset so the same path can re-fire
        isempty(busy_msg[]) || return
        w_name = discover_state[]
        isempty(w_name) && return
        proj_name = replace(basename(rstrip(path, '/')), r"[^a-zA-Z0-9_\-]" => "_")
        isempty(proj_name) && (proj_name = "project")
        busy_msg[] = resume_session_id === nothing ?
            "Importing $(proj_name)…" :
            "Resuming $(proj_name) (session $(resume_session_id[1:8])…)"
        @async begin
            try
                p = create_project_from_worker!(state, w_name, path;
                                             name = proj_name,
                                             resume_session_id = resume_session_id,
                                             progress = msg -> (busy_msg[] = "Importing $(proj_name): $(msg)"))
                error_obs[]      = ""
                discover_state[] = ""
                current_view !== nothing && (current_view[] = p.id)
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
        # session_id is the .jsonl basename of the most-recent claude session
        # at this cwd. When set, the import flow uses ACP's session/load to
        # resume that conversation instead of starting fresh.
        sid_raw   = get(r, "session_id", nothing)
        session_id = sid_raw === nothing ? "" : String(sid_raw)
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
        # Show whether resume is available, so the user knows what they're
        # getting. Plain "Import" looks the same as before for sessions we
        # didn't find a jsonl for.
        btn_label = isempty(session_id) ? "Import" : "Resume"
        DOM.div(
            DOM.div(
                DOM.div(name, badge; class = "bt-session-name"),
                DOM.div(path; class = "bt-session-path"),
                isempty(meta) ? DOM.span() : DOM.div(meta; class = "bt-session-meta")),
            DOM.div(btn_label;
                class   = "bt-btn bt-btn-secondary",
                style   = "cursor:pointer;flex-shrink:0",
                # Instant visual feedback: flip the button to a loading
                # state synchronously on click, before the WS round-trip
                # that sets busy_msg server-side has a chance to land.
                onclick = js"""event => {
                    const btn = event.currentTarget;
                    btn.classList.add('bt-clicked');
                    btn.textContent = $(btn_label) === 'Resume' ? 'Resuming…' : 'Importing…';
                    $(import_path).notify({path: $path, session_id: $session_id});
                }"""),
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
        nm = basename(rstrip(chosen, '/'))
        busy_msg[] = "Importing $(nm)…"
        @async begin
            try
                p = create_project_from_worker!(state, w_name, chosen;
                    progress = msg -> (busy_msg[] = "Importing $(nm): $(msg)"))
                error_obs[] = ""
                picker_state[] = ""
                rp.selected[] = ""
                current_view !== nothing && (current_view[] = p.id)
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
            (DOM.option(name; value=name) for name in keys(state.workers))...;
            onchange = js"event => $(np_worker).notify(event.target.value)"),
        map(busy_msg) do msg
            isempty(msg) ?
                DOM.div(np_cancel, np_submit, class = "bt-form-actions") :
                DOM.div(spinner_row(msg), class = "bt-form-actions")
        end,
        class = "bt-form")

    gh_form() = DOM.div(
        DOM.label("GitHub URL"),
        text_input(gh_url,
            "https://github.com/<owner>/<repo>  ·  /issues/<n>  ·  /pull/<n>"),
        DOM.div("Repo → just clone. Issue/PR → clone + auto-prompt 'fix this'.";
                style = "font-size:11px;color:var(--bt-text-muted);margin-top:-4px"),
        DOM.label("Worker"),
        DOM.select(
            (DOM.option(name; value=name) for name in keys(state.workers))...;
            onchange = js"event => $(gh_worker).notify(event.target.value)"),
        map(busy_msg) do msg
            isempty(msg) ?
                DOM.div(gh_cancel, gh_submit, class = "bt-form-actions") :
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
    stats_strip = map(state.version) do _
        online   = count(w -> w.status == :online, values(state.workers))
        total    = length(state.workers)
        n_proj   = length(state.projects)
        n_active = count(p -> p.locked_by !== nothing, values(state.projects))
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
    worker_list = map(state.version, picker_state, discover_state) do _, picked, discovered
        if isempty(state.workers)
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
        for w in values(state.workers)
            push!(rows, worker_card(state, w, error_obs, picker_state, discover_state))
            picked     == w.name && push!(rows, remote_picker_form(w.name))
            discovered == w.name && push!(rows, discover_panel(w.name))
        end
        DOM.div(rows...)
    end

    project_list = map(state.version) do _
        isempty(state.projects) ?
            DOM.div("No projects yet — pick a worker above and click + Project, or import an existing Claude session via Discover.";
                    class = "bt-empty") :
            DOM.div((project_card(p, error_obs, sync_request, current_view)
                     for p in values(state.projects))...)
    end

    # Two slide-in forms, one source of truth: which one is open right now.
    form_block = map(which_form) do which
        if which === :new_project
            DOM.div(new_proj_form(); class = "bt-slide-in")
        elseif which === :github
            DOM.div(gh_form(); class = "bt-slide-in")
        else
            DOM.div()
        end
    end
    error_block = map(error_obs) do msg
        isempty(msg) ? DOM.div() : DOM.div(msg; class = "bt-error")
    end

    # Global busy toast — fixed top-right, shown whenever any handler has set
    # busy_msg. Used by Import (discover panel), Create project (form), and
    # Create from worker (per-worker picker form). Stage updates from
    # push_dir_to_worker! / pull_dir_from_worker! flow into busy_msg via the
    # progress callback so the toast updates live during transfers.
    busy_toast = map(busy_msg) do msg
        isempty(msg) ? DOM.div() :
            DOM.div(
                DOM.div(class = "bt-spinner"),
                DOM.span(msg),
                class = "bt-busy-toast bt-slide-in")
    end

    # Layout — DOM only; the App() wrapper + global assets (DashboardStyles,
    # ConnectionIndicator) live in the caller (unified_app or dashboard_app).
    DOM.div(
        busy_toast,
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
            new_proj_btn,
            gh_btn;
            class = "bt-section"),
        project_list,
        form_block;

        class = "bt-dash")
end

# Thin shim for callers that want a standalone dashboard App (tests, the
# pre-unified-app routes). The unified app instead embeds dashboard_dom
# directly into its main panel.
function dashboard_app(state::ServerState)
    App() do session
        DOM.div(
            DashboardStyles,
            Bonito.ConnectionIndicator(),
            dashboard_dom(state))
    end
end

# Best-effort lookup of the public URL for the install one-liner shown in the
# empty state. Reads the same env BONITOTEAM_PUBLIC_URL that the service uses.
function public_url_or_default()
    url = get(ENV, "BONITOTEAM_PUBLIC_URL", "")
    isempty(url) ? "http://<your-server>:8038" : rstrip(url, '/')
end
