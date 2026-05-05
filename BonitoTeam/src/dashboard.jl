using Bonito, AgentClientProtocol, JSON, UUIDs, Dates

# ── Persistent server state (workers + projects) ──────────────────────────────

const SERVER_STATE_DIR = Ref(joinpath(homedir(), ".local", "share", "bonitoteam-server"))
state_dir() = SERVER_STATE_DIR[]
workers_file()  = joinpath(state_dir(), "workers.json")
projects_file() = joinpath(state_dir(), "projects.json")

mutable struct WorkerInfo
    name::String                       # display name (unique key)
    url::String                        # ws://host:port
    secret::String
    ssh_target::Union{String,Nothing}  # for rsync: "user@host", nothing → no rsync
    # discovered via Worker.probe
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
    name::String                       # display + dst dir name
    worker_name::String                # FK to WORKERS
    src_path::String                   # absolute path on server (rsync source)
    dst_path::String                   # absolute path on worker (rsync dest)
    created::DateTime
end

const WORKERS = Dict{String,WorkerInfo}()
const PROJECTS = Dict{String,ProjectInfo}()

# Per-project runtime — kept out of the persisted state
const PROJECT_APPS = Dict{String,Bonito.App}()

# Observable; bumped whenever WORKERS or PROJECTS changes so the dashboard re-renders.
const STATE_VERSION = Observable(0)
bump_state!() = (STATE_VERSION[] = STATE_VERSION[] + 1)

# ── Persistence ───────────────────────────────────────────────────────────────

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
                 "src_path" => p.src_path, "dst_path" => p.dst_path,
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
                        d["src_path"], d["dst_path"],
                        DateTime(d["created"]))
        PROJECTS[p.id] = p
    end
end

# ── Worker registration / probe ───────────────────────────────────────────────

"""
Register or update a worker; probes it to learn hostname / mcp_path / projects_root.
Throws on probe failure.
"""
function register_worker!(name::String, url::String, secret::String;
                          ssh_target::Union{String,Nothing} = nothing)
    caps = Worker.probe(url, secret)
    w = WorkerInfo(name, url, secret, ssh_target,
                   String(get(caps, "hostname", "")),
                   String(get(caps, "home", "")),
                   String(get(caps, "mcp_path", "")),
                   String(get(caps, "projects_root", "")),
                   :online, now(UTC))
    WORKERS[name] = w
    save_workers!()
    bump_state!()
    return w
end

"""
Health-check an existing worker. Updates `status` and `last_check` in-place.
"""
function check_worker!(w::WorkerInfo)
    w.last_check = now(UTC)
    new_status = try
        Worker.probe(w.url, w.secret; timeout = 3.0)
        :online
    catch
        :offline
    end
    if new_status != w.status
        w.status = new_status
        bump_state!()
    end
    return w
end

# Periodic heartbeat: probes every registered worker every `interval` seconds.
# Started by `serve()`; stopped by setting HEARTBEAT_RUNNING[] = false.
const HEARTBEAT_RUNNING = Ref(false)

function start_heartbeat!(interval::Real = 10.0)
    HEARTBEAT_RUNNING[] && return   # already running
    HEARTBEAT_RUNNING[] = true
    @async while HEARTBEAT_RUNNING[]
        for w in collect(values(WORKERS))   # collect → safe over concurrent register
            HEARTBEAT_RUNNING[] || break
            try
                check_worker!(w)
            catch e
                @warn "heartbeat error" worker=w.name exception=e
            end
        end
        # Sleep in small slices so shutdown is responsive
        for _ in 1:Int(interval * 4)
            HEARTBEAT_RUNNING[] || break
            sleep(0.25)
        end
    end
end

stop_heartbeat!() = (HEARTBEAT_RUNNING[] = false)

# ── Rsync orchestration ───────────────────────────────────────────────────────

"""
Push `src` → `ssh_target:dst` via rsync. Creates dst's parent dir on the
worker first. Source ends in `/` so contents are placed *into* dst.
"""
function rsync_to_worker(src::String, ssh_target::String, dst::String)
    isdir(src) || error("Source path is not a directory: $src")
    parent = dirname(rstrip(dst, '/'))
    run(`ssh $ssh_target mkdir -p $parent`)
    src_with_slash = endswith(src, '/') ? src : src * "/"
    @info "rsync" src_with_slash ssh_target dst
    run(`rsync -az --delete $src_with_slash $ssh_target:$dst/`)
    return nothing
end

# ── Project lifecycle ─────────────────────────────────────────────────────────

"""
Create a new project on the named worker. Steps:
1. Validate worker + paths
2. rsync src_path → worker:projects_root/name (only if worker has ssh_target)
3. Build chat_app wired to ACP session on the worker (with bonitoteam MCP)
4. Register `/p/<id>` route on the live server
"""
function create_project!(srv::Bonito.Server, name::String, src_path::String,
                          worker_name::String)
    haskey(WORKERS, worker_name) || error("Unknown worker: $worker_name")
    isempty(name) && error("Project name must not be empty")
    occursin(r"^[a-zA-Z0-9_\-]+$", name) ||
        error("Project name must be alphanumeric/_/- only")

    w = WORKERS[worker_name]
    id = string(uuid4())[1:8]
    dst_path = joinpath(w.projects_root, name)

    # 1. Push source files to the worker
    if w.ssh_target !== nothing && !isempty(src_path)
        rsync_to_worker(src_path, w.ssh_target, dst_path)
    else
        @warn "Worker has no ssh_target — skipping rsync. Files must already exist on the worker." worker=worker_name dst_path
    end

    # 2. Build the chat app (one ACP session per project, started lazily inside
    #    chat_app via client_factory)
    mcp = isempty(w.mcp_path) ? AgentClientProtocol.MCPServer[] :
        [AgentClientProtocol.MCPServer("bonitoteam", w.mcp_path)]
    client_factory = on_update -> Worker.connect(w.url, w.secret, dst_path;
                                                  on_update, mcp_servers = mcp)
    app = chat_app(dst_path; mcp_servers = mcp, client_factory = client_factory)

    PROJECT_APPS[id] = app
    PROJECTS[id] = ProjectInfo(id, name, worker_name, src_path, dst_path, now(UTC))
    save_projects!()

    # 3. Register the route so /p/<id> serves this project's chat
    Bonito.route!(srv, "/p/$id" => app)
    bump_state!()
    return PROJECTS[id]
end

"""
Re-attach an already-loaded project (called at server startup for each entry
in projects.json). Does NOT rsync; assumes files are already on the worker.
"""
function reattach_project!(srv::Bonito.Server, p::ProjectInfo)
    haskey(WORKERS, p.worker_name) || (@warn "Project worker missing" project=p.name worker=p.worker_name; return)
    w = WORKERS[p.worker_name]
    mcp = isempty(w.mcp_path) ? AgentClientProtocol.MCPServer[] :
        [AgentClientProtocol.MCPServer("bonitoteam", w.mcp_path)]
    client_factory = on_update -> Worker.connect(w.url, w.secret, p.dst_path;
                                                  on_update, mcp_servers = mcp)
    app = chat_app(p.dst_path; mcp_servers = mcp, client_factory = client_factory)
    PROJECT_APPS[p.id] = app
    Bonito.route!(srv, "/p/$(p.id)" => app)
    return nothing
end

# ── Dashboard styles ──────────────────────────────────────────────────────────

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

# ── Folder picker component ───────────────────────────────────────────────────

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

# ── Dashboard app ─────────────────────────────────────────────────────────────

status_pill(s::Symbol) = DOM.span(string(s);
    class = "bt-pill bt-pill-$s")

function worker_card(w::WorkerInfo)
    DOM.div(
        DOM.div(
            DOM.div(w.name, " ", status_pill(w.status), class = "bt-card-title"),
            DOM.div(w.url, " · ",
                isempty(w.hostname) ? "?" : w.hostname,
                w.ssh_target === nothing ? "" : " · ssh: $(w.ssh_target)",
                class = "bt-card-meta")),
        class = "bt-card")
end

function project_card(p::ProjectInfo)
    DOM.div(
        DOM.div(
            DOM.div(p.name, class = "bt-card-title"),
            DOM.div(p.worker_name, " · ", p.dst_path, class = "bt-card-meta")),
        DOM.a("Open chat →", href = "/p/$(p.id)", target = "_blank"),
        class = "bt-card")
end

function dashboard_app(srv_ref::Ref{Bonito.Server})
    error_obs = Observable("")

    # ── Add Worker form ───────────────────────────────────────────────────────
    add_worker_show = Observable(false)
    aw_name = Observable("")
    aw_url = Observable("")
    aw_secret = Observable("")
    aw_ssh = Observable("")
    aw_submit = Bonito.Button("Register"; class = "bt-btn")
    aw_cancel = Bonito.Button("Cancel"; class = "bt-btn bt-btn-secondary")

    on(aw_submit.value) do clicked
        clicked || return
        try
            ssh = isempty(strip(aw_ssh[])) ? nothing : String(strip(aw_ssh[]))
            register_worker!(String(strip(aw_name[])),
                              String(strip(aw_url[])),
                              String(strip(aw_secret[]));
                              ssh_target = ssh)
            error_obs[] = ""
            add_worker_show[] = false
            aw_name[] = ""; aw_url[] = ""; aw_secret[] = ""; aw_ssh[] = ""
        catch e
            error_obs[] = "Failed to register worker: $e"
        end
    end
    on(aw_cancel.value) do clicked
        clicked || return
        add_worker_show[] = false
        error_obs[] = ""
    end

    # ── New Project form ──────────────────────────────────────────────────────
    new_proj_show = Observable(false)
    np_name = Observable("")
    np_picker = FolderPicker()           # `np_picker.selected[]` is the chosen folder
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

    add_worker_btn = Bonito.Button("+ Add worker"; class = "bt-btn bt-btn-secondary")
    on(add_worker_btn.value) do clicked
        clicked || return
        add_worker_show[] = true
        error_obs[] = ""
    end

    new_proj_btn = Bonito.Button("+ New project"; class = "bt-btn bt-btn-secondary")
    on(new_proj_btn.value) do clicked
        clicked || return
        if isempty(WORKERS)
            error_obs[] = "Register a worker before creating a project."
            return
        end
        np_worker[] = first(keys(WORKERS))   # default selection
        new_proj_show[] = true
        error_obs[] = ""
    end

    text_input(obs::Observable, ph::String) = DOM.input(
        type = "text", placeholder = ph,
        oninput = js"event => $(obs).notify(event.target.value)")

    add_worker_form() = DOM.div(
        DOM.label("Name"),     text_input(aw_name, "e.g. desktop-tower"),
        DOM.label("WS URL"),   text_input(aw_url, "ws://host:8039"),
        DOM.label("Secret"),   text_input(aw_secret, "shared secret"),
        DOM.label("SSH target"), text_input(aw_ssh, "user@host (optional, for rsync)"),
        DOM.div(aw_cancel, aw_submit, class = "bt-form-actions"),
        class = "bt-form")

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

    # ── Layout ────────────────────────────────────────────────────────────────
    App() do session
        # Re-render lists whenever STATE_VERSION bumps
        worker_list = map(STATE_VERSION) do _
            isempty(WORKERS) ?
                DOM.div("No workers registered. Run the install script on a worker, then click + Add worker.",
                        class = "bt-empty") :
                DOM.div((worker_card(w) for w in values(WORKERS))...)
        end

        project_list = map(STATE_VERSION) do _
            isempty(PROJECTS) ?
                DOM.div("No projects yet.", class = "bt-empty") :
                DOM.div((project_card(p) for p in values(PROJECTS))...)
        end

        worker_form_block = map(add_worker_show) do show
            show ? add_worker_form() : DOM.div()
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
            DOM.div(add_worker_btn, style = "margin-top: 8px"),
            worker_form_block,

            DOM.h2("Projects"),
            project_list,
            DOM.div(new_proj_btn, style = "margin-top: 8px"),
            proj_form_block,

            class = "bt-dash")
    end
end
