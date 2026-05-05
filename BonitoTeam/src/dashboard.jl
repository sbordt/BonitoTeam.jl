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

# Dashboard styles
const DashboardStyles = Bonito.Styles(
    CSS(".bt-dash",
        "font-family"  => "system-ui, -apple-system, sans-serif",
        "max-width"    => "920px", "margin" => "0 auto", "padding" => "32px 24px",
        "color"        => "#1f2937"),
    CSS(".bt-dash h1", "font-size" => "24px", "margin-bottom" => "8px"),
    CSS(".bt-dash h2", "font-size" => "16px", "margin-top" => "32px",
        "margin-bottom" => "12px", "color" => "#374151",
        "border-bottom" => "1px solid #e5e7eb", "padding-bottom" => "6px"),
    CSS(".bt-dash .bt-sub", "color" => "#6b7280", "font-size" => "13px",
        "margin-bottom" => "24px"),
    CSS(".bt-card",
        "border" => "1px solid #e5e7eb", "border-radius" => "6px",
        "padding" => "12px 16px", "margin-bottom" => "8px",
        "display" => "flex", "justify-content" => "space-between",
        "align-items" => "center", "background" => "#fff"),
    CSS(".bt-card .bt-card-title", "font-weight" => "600"),
    CSS(".bt-card .bt-card-meta", "color" => "#6b7280", "font-size" => "12px"),
    CSS(".bt-card a", "color" => "#2563eb", "text-decoration" => "none",
        "font-size" => "13px"),
    CSS(".bt-pill",
        "display" => "inline-block", "padding" => "2px 8px",
        "border-radius" => "999px", "font-size" => "11px", "font-weight" => "500"),
    CSS(".bt-pill-online",  "background" => "#d1fae5", "color" => "#065f46"),
    CSS(".bt-pill-offline", "background" => "#fee2e2", "color" => "#991b1b"),
    CSS(".bt-pill-unknown", "background" => "#f3f4f6", "color" => "#6b7280"),
    CSS(".bt-form",
        "background" => "#f9fafb", "border" => "1px solid #e5e7eb",
        "border-radius" => "6px", "padding" => "16px", "margin-top" => "12px",
        "display" => "grid", "grid-template-columns" => "120px 1fr",
        "gap" => "8px 12px", "align-items" => "center"),
    CSS(".bt-form input",
        "padding" => "6px 10px", "border" => "1px solid #d1d5db",
        "border-radius" => "4px", "font-size" => "13px", "width" => "100%",
        "box-sizing" => "border-box"),
    CSS(".bt-form select",
        "padding" => "6px 10px", "border" => "1px solid #d1d5db",
        "border-radius" => "4px", "font-size" => "13px"),
    CSS(".bt-form .bt-form-actions",
        "grid-column" => "1 / -1", "display" => "flex", "gap" => "8px",
        "justify-content" => "flex-end", "margin-top" => "8px"),
    CSS(".bt-btn",
        "padding" => "6px 16px", "border" => "none", "border-radius" => "4px",
        "background" => "#2563eb", "color" => "#fff", "font-weight" => "500",
        "cursor" => "pointer", "font-size" => "13px"),
    CSS(".bt-btn-secondary",
        "background" => "#e5e7eb", "color" => "#374151"),
    CSS(".bt-error",
        "background" => "#fee2e2", "color" => "#991b1b",
        "padding" => "8px 12px", "border-radius" => "4px", "font-size" => "13px",
        "margin-top" => "8px"),
    CSS(".bt-empty",
        "color" => "#9ca3af", "font-style" => "italic", "padding" => "8px 0"),
    # Folder picker
    CSS(".bt-picker",
        "border" => "1px solid #d1d5db", "border-radius" => "4px",
        "padding" => "8px", "background" => "#fff",
        "max-height" => "260px", "overflow-y" => "auto",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px"),
    CSS(".bt-picker-row",
        "padding" => "4px 6px", "cursor" => "pointer",
        "border-radius" => "3px"),
    CSS(".bt-picker-row:hover", "background" => "#eef2ff"),
    CSS(".bt-picker-cur",
        "padding" => "6px 10px", "background" => "#f9fafb",
        "border" => "1px solid #e5e7eb", "border-radius" => "4px",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px",
        "margin-bottom" => "6px",
        "display" => "flex", "justify-content" => "space-between",
        "align-items" => "center", "gap" => "8px"),
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
    browse_btn = Bonito.Button("Browse"; class = "bt-btn bt-btn-secondary")
    up_btn     = Bonito.Button("↑ Up"; class = "bt-btn bt-btn-secondary")
    choose_btn = Bonito.Button("Choose"; class = "bt-btn")

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

# Remote folder picker — same shape as FolderPicker but reads the worker's
# filesystem over its control WS via `list_worker_dir`. Used by the per-worker
# "new project" flow.
mutable struct RemoteFolderPicker
    worker_name::String
    cur::Observable{String}
    selected::Observable{String}
    expanded::Observable{Bool}
end

RemoteFolderPicker(worker_name::String, start::String = "") = RemoteFolderPicker(
    worker_name, Observable(start), Observable(""), Observable(false))

function remote_folder_picker_render(p::RemoteFolderPicker)
    browse_btn = Bonito.Button("Browse"; class = "bt-btn bt-btn-secondary")
    up_btn     = Bonito.Button("↑ Up"; class = "bt-btn bt-btn-secondary")
    choose_btn = Bonito.Button("Choose"; class = "bt-btn")

    # On first browse, request the worker's $HOME (cur="" means "default").
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

    # Resolves cur="" → worker's $HOME on first expand by querying the worker.
    list = map(p.cur, p.expanded) do path, show
        show || return DOM.div()
        local resp
        try
            resp = list_worker_dir(p.worker_name, path)
        catch e
            return DOM.div("error: $e", class = "bt-picker", style = "color:#991b1b")
        end
        # Update the path display once we know it (e.g. resolved $HOME)
        resp.path != path && (p.cur[] = resp.path)
        dirs = filter(e -> e.dir, resp.entries)
        rows = isempty(dirs) ?
            [DOM.div("(no subfolders)", class = "bt-picker-row", style = "color:#9ca3af")] :
            [DOM.div("📁 $(e.name)",
                class = "bt-picker-row",
                onclick = js"event => $(p.cur).notify($(joinpath(resp.path, e.name)));")
             for e in dirs]
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

# Dashboard app
status_pill(s::Symbol) = DOM.span(string(s);
    class = "bt-pill bt-pill-$s")

function worker_card(w::WorkerInfo, srv_ref::Ref{Bonito.Server},
                     error_obs::Observable{String}, picker_state::Observable{String})
    new_proj_btn = Bonito.Button("+ Project"; class = "bt-btn bt-btn-secondary")
    on(new_proj_btn.value) do clicked
        clicked || return
        # Toggle the per-worker picker; only one worker's picker open at a time.
        picker_state[] = picker_state[] == w.name ? "" : w.name
        error_obs[] = ""
    end
    DOM.div(
        DOM.div(
            DOM.div(w.name, " ", status_pill(w.status), class = "bt-card-title"),
            DOM.div(w.url, " · ",
                isempty(w.hostname) ? "?" : w.hostname,
                class = "bt-card-meta")),
        DOM.div(new_proj_btn, style = "display:flex;gap:8px"),
        class = "bt-card")
end

function project_card(p::ProjectInfo, error_obs::Observable{String})
    badge = p.locked_by === nothing ? DOM.span() :
        DOM.span("🔒 active on $(p.locked_by)";
                 class = "bt-pill bt-pill-online",
                 style = "margin-left:8px")

    DOM.div(
        DOM.div(
            DOM.div(p.name, badge, class = "bt-card-title"),
            DOM.div(p.worker_name, " · server: ", p.server_path,
                    " · worker: ", p.worker_path, class = "bt-card-meta")),
        DOM.div(DOM.a("Open chat →", href = Bonito.Link("/p/$(p.id)"), target = "_blank"),
                style = "display:flex;gap:12px;align-items:center"),
        class = "bt-card")
end

function dashboard_app(srv_ref::Ref{Bonito.Server})
    error_obs = Observable("")

    # Workers self-register over WS when they dial /worker-ws — no manual
    # "Add worker" form needed. The dashboard just lists them as they connect.

    # New Project form
    new_proj_show = Observable(false)
    np_name = Observable("")
    np_picker = FolderPicker(working_dir())   # default to server's project working dir
    # Auto-fill the project name from the picked folder's basename when the
    # user hasn't typed anything yet. Their typing always wins.
    on(np_picker.selected) do sel
        isempty(strip(np_name[])) || return
        isempty(sel) && return
        np_name[] = basename(rstrip(sel, '/'))
    end
    np_worker = Observable("")
    np_submit = Bonito.Button("Create"; class = "bt-btn")
    np_cancel = Bonito.Button("Cancel"; class = "bt-btn bt-btn-secondary")

    on(np_submit.value) do clicked
        clicked || return
        try
            create_project!(srv_ref[], String(strip(np_name[])),
                             String(strip(np_picker.selected[])),
                             String(strip(np_worker[])))
            error_obs[] = ""
            new_proj_show[] = false
            np_name[] = ""; np_picker.selected[] = ""; np_worker[] = ""
        catch e
            error_obs[] = "Failed to create project: $e"
        end
    end
    on(np_cancel.value) do clicked
        clicked || return
        new_proj_show[] = false
        error_obs[] = ""
    end

    new_proj_btn = Bonito.Button("+ New project"; class = "bt-btn bt-btn-secondary")
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

    function get_remote_picker(name)
        haskey(remote_pickers, name) || (remote_pickers[name] = RemoteFolderPicker(name))
        remote_pickers[name]
    end

    function submit_remote_pick(w_name::String)
        rp = get_remote_picker(w_name)
        chosen = String(strip(rp.selected[]))
        if isempty(chosen)
            error_obs[] = "Pick a folder on the worker first (Browse → Choose)."
            return
        end
        try
            create_project_from_worker!(srv_ref[], w_name, chosen)
            error_obs[] = ""
            picker_state[] = ""
            rp.selected[] = ""
        catch e
            error_obs[] = "Failed to create project from worker: $e"
        end
    end

    text_input(obs::Observable, ph::String) = DOM.input(
        type = "text", placeholder = ph,
        value = obs,    # Julia → JS: pushed back when obs changes (e.g. auto-fill)
        oninput = js"event => $(obs).notify(event.target.value)")

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
        DOM.div(np_cancel, np_submit, class = "bt-form-actions"),
        class = "bt-form")

    function remote_picker_form(w_name::String)
        rp = get_remote_picker(w_name)
        create_btn = Bonito.Button("Create"; class = "bt-btn")
        cancel_btn = Bonito.Button("Cancel"; class = "bt-btn bt-btn-secondary")
        on(create_btn.value) do clicked
            clicked && submit_remote_pick(w_name)
        end
        on(cancel_btn.value) do clicked
            clicked && (picker_state[] = ""; error_obs[] = "")
        end
        DOM.div(
            DOM.label("Folder on $(w_name)"),
            DOM.div(remote_folder_picker_render(rp),
                    map(rp.selected) do sel
                        isempty(sel) ? DOM.div() :
                            DOM.div("✓ selected: $sel",
                                    style = "color:#065f46;font-size:12px;margin-top:4px")
                    end),
            DOM.div(cancel_btn, create_btn, class = "bt-form-actions"),
            class = "bt-form")
    end

    # Layout
    App() do session
        # Re-render lists whenever STATE_VERSION bumps OR picker_state changes
        worker_list = map(STATE_VERSION, picker_state) do _, picked_worker
            isempty(WORKERS) && return DOM.div(
                "No workers registered yet. Run the install script on a worker.",
                class = "bt-empty")
            rows = []
            for w in values(WORKERS)
                push!(rows, worker_card(w, srv_ref, error_obs, picker_state))
                picked_worker == w.name && push!(rows, remote_picker_form(w.name))
            end
            DOM.div(rows...)
        end

        project_list = map(STATE_VERSION) do _
            isempty(PROJECTS) ?
                DOM.div("No projects yet.", class = "bt-empty") :
                DOM.div((project_card(p, error_obs) for p in values(PROJECTS))...)
        end

        proj_form_block = map(new_proj_show) do show
            show ? new_proj_form() : DOM.div()
        end
        error_block = map(error_obs) do msg
            isempty(msg) ? DOM.div() : DOM.div(msg, class = "bt-error")
        end

        DOM.div(
            DashboardStyles,
            DOM.h1("BonitoTeam"),
            DOM.div("Multi-host orchestrator for agentic coding sessions.", class = "bt-sub"),
            error_block,

            DOM.h2("Workers"),
            worker_list,

            DOM.h2("Projects"),
            project_list,
            DOM.div(new_proj_btn, style = "margin-top: 8px"),
            proj_form_block,

            class = "bt-dash")
    end
end
