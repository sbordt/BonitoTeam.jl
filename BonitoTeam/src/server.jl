# Path to the BonitoTeam package's assets/ (install_template.sh, bonitoteam.js)
const ASSETS_DIR    = normpath(joinpath(@__DIR__, "..", "assets"))
# Monorepo root (sibling of BonitoTeam/) — contains BonitoMCP/, BonitoWorker/, AgentClientProtocol/.
const MONOREPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

const INSTALL_TEMPLATE = read(joinpath(ASSETS_DIR, "install_template.sh"), String)

# Worker bundle: ships the lean BonitoMCP and BonitoWorker packages. The worker
# installs each into its own --project=<dir>. Rebuilt on every request so local
# edits show up without restarting the server.
const WORKER_BUNDLE_PATHS = [
    "BonitoMCP",
    "BonitoWorker",
]

function build_worker_bundle()::Vector{UInt8}
    tmp = tempname() * ".tar.gz"
    run(Cmd(`tar -czf $tmp $(WORKER_BUNDLE_PATHS)`; dir = MONOREPO_ROOT))
    bytes = read(tmp)
    rm(tmp; force=true)
    return bytes
end

"""
    serve(; host, port, public_url, worker_secret, worker_port, state_dir) → Bonito.Server

Start the BonitoTeam dashboard server. Routes:

  /                  — dashboard (workers + projects)
  /p/<project_id>    — chat UI for one project
  /install.sh        — worker installer (curl-pipeable)
  /worker/bundle.tar.gz — package files the installer downloads

`worker_secret` is the shared secret used by every worker spawned via the
install script. `public_url` is the base URL the install script tells workers
to fetch the bundle from; defaults to `http://localhost:<port>`.

`state_dir`   overrides where workers.json / projects.json are persisted
              (default: `~/.local/share/bonitoteam-server`).
`working_dir` overrides where canonical project copies live on the server.
              Each project lives at `<working_dir>/<name>` and is mirrored
              onto the worker at `<worker.projects_root>/<name>`.
              (default: `~/bonitoteam-server`)
"""
function serve(; host::String        = "0.0.0.0",
                 port::Int           = 8038,
                 public_url::Union{String,Nothing}   = nothing,
                 worker_secret::String,
                 worker_port::Int    = 8039,
                 state_dir::Union{String,Nothing}   = nothing,
                 working_dir::Union{String,Nothing} = nothing)

    state_dir   === nothing || (SERVER_STATE_DIR[]   = state_dir)
    working_dir === nothing || (SERVER_WORKING_DIR[] = working_dir)
    mkpath(SERVER_WORKING_DIR[])
    load_workers!()
    load_projects!()

    # The dashboard needs a handle to the live Server to register per-project
    # routes after construction. Create the Ref first; fill it after Server() returns.
    srv_ref = Ref{Bonito.Server}()
    dash = dashboard_app(srv_ref)

    # proxy_url="." → page-relative asset URLs. Bonito's asset route is a
    # regex (`/assets/<40hex>-...`) that matches at any prefix, so requests
    # like /p/<id>/assets/<hex>-foo.js still reach the asset server.
    srv = Bonito.Server(dash, host, port; proxy_url = ".")
    srv_ref[] = srv

    base_url = something(public_url, "http://localhost:$port")
    add_install_routes!(srv, base_url, worker_secret, worker_port)

    # Re-attach previously-saved projects (registers /p/<id> for each)
    for p in values(PROJECTS)
        try
            reattach_project!(srv, p)
        catch e
            @warn "Failed to reattach project" project=p.name exception=e
        end
    end

    start_heartbeat!()

    @info "BonitoTeam dashboard running" url="http://localhost:$port" state=SERVER_STATE_DIR[]
    @info "Worker install endpoint"      url="$base_url/install.sh"
    return srv
end

# ── Worker install routes ──────────────────────────────────────────────────────

function add_install_routes!(srv::Bonito.Server, public_url::String,
                              worker_secret::String, worker_port::Int)
    Bonito.route!(srv, "/install.sh" => function(context)
        script = render_install_script(public_url, worker_secret, worker_port)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body=script)
    end)

    Bonito.route!(srv, "/worker/bundle.tar.gz" => function(context)
        bytes = build_worker_bundle()
        HTTP.Response(200, ["Content-Type" => "application/gzip"], body=bytes)
    end)

    # Self-registration: worker POSTs {secret, host, port, name} on startup.
    # Server probes the worker, stores it in WORKERS, dashboard re-renders.
    Bonito.route!(srv, "/api/workers/register" => function(context)
        local name = "?", url = "?"
        try
            body = JSON.parse(String(context.request.body))
            get(body, "secret", "") == worker_secret ||
                return HTTP.Response(401, JSON.json(Dict("error" => "unauthorized")))
            host = String(get(body, "host", ""))
            isempty(host) && return HTTP.Response(400, JSON.json(Dict("error" => "missing host")))
            port = Int(get(body, "port", worker_port))
            name = String(get(body, "name", host))
            url  = "ws://$host:$port"
            w = register_worker!(name, url, worker_secret)
            @info "Worker registered" name=w.name url=w.url
            HTTP.Response(200, ["Content-Type" => "application/json"],
                          body = JSON.json(Dict("ok"=>true, "name"=>w.name, "url"=>w.url)))
        catch e
            err = sprint(showerror, e)
            @error "Worker registration failed (server can't reach back; firewall?)" name url error=err
            HTTP.Response(500, ["Content-Type" => "application/json"],
                          body = JSON.json(Dict("error" => err)))
        end
    end)
end

function render_install_script(public_url::String, worker_secret::String, worker_port::Int)
    replace(INSTALL_TEMPLATE,
        "{{SERVER_URL}}"     => public_url,
        "{{WORKER_SECRET}}"  => worker_secret,
        "{{WORKER_PORT}}"    => string(worker_port),
    )
end
