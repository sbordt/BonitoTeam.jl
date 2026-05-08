# Path to the BonitoTeam package's assets/ (install_template.sh, bonitoteam.js)
const ASSETS_DIR    = normpath(joinpath(@__DIR__, "..", "assets"))
# Monorepo root (sibling of BonitoTeam/) — contains BonitoMCP/, BonitoWorker/, AgentClientProtocol/.
const MONOREPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

const INSTALL_TEMPLATE = read(joinpath(ASSETS_DIR, "install_template.sh"), String)

# Worker bundle: ships the lean packages a worker needs (BonitoMCP +
# BonitoWorker + their RemoteSync dep). The installer extracts these alongside
# a generated worker_project.toml at $INSTALL_ROOT and uses that as the SINGLE
# operational env — never per-package Project.tomls. Rebuilt on every request
# so local edits show up without restarting the server.
const WORKER_BUNDLE_PATHS = ["BonitoMCP", "BonitoWorker", "RemoteSync"]

function build_worker_bundle()::Vector{UInt8}
    tmp = tempname() * ".tar.gz"
    run(Cmd(`tar -czf $tmp $(WORKER_BUNDLE_PATHS)`; dir = MONOREPO_ROOT))
    bytes = read(tmp)
    rm(tmp; force=true)
    return bytes
end

"""
    serve(; host, port, public_url, worker_secret, state_dir, working_dir) → Bonito.Server

Start the BonitoTeam dashboard server. Workers dial back to this server, so
only port `port` (default 8038) needs to be open in the server's firewall.

Routes:
  /                       — dashboard (workers + projects)
  /p/<project_id>         — chat UI for one project
  /install.sh             — worker installer (curl-pipeable)
  /worker/bundle.tar.gz   — package files the installer downloads
  /worker-ws    (WS)      — control channel each worker holds open after install
  /worker-acp   (WS)      — per-session ACP relay; one connection per project session
  /transfer-ws  (WS)      — librsync directional transfer; dialed on demand by a
                            worker in response to an `open_transfer` command

`worker_secret` is the shared secret used by every worker. `public_url` is the
base URL workers see (and what the install script tells them to dial back).

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
                 state_dir::Union{String,Nothing}   = nothing,
                 working_dir::Union{String,Nothing} = nothing)
    # `nothing` OR `""` (env-var roundtrip) → use the platform default. Anything
    # else is taken as an absolute override.
    isvalid(s) = s !== nothing && !isempty(String(s))
    sd = isvalid(state_dir)   ? String(state_dir)   :
         joinpath(homedir(), ".local", "share", "bonitoteam-server")
    wd = isvalid(working_dir) ? String(working_dir) :
         joinpath(homedir(), "bonitoteam-server")

    state = ServerState(; state_dir = sd, working_dir = wd, worker_secret = worker_secret)

    # Mark all loaded workers offline; they'll flip online when they re-dial.
    for w in values(state.workers)
        w.status = :offline
    end

    # Single-page app: sidebar + dashboard/chat swap. No per-project routes.
    srv = Bonito.Server(unified_app(state), host, port; proxy_url = ".")
    state.srv = srv

    base_url = something(public_url, "http://localhost:$port")
    add_install_routes!(srv, base_url, worker_secret)
    add_worker_ws_routes!(srv, state)

    @info "BonitoTeam dashboard running" url="http://localhost:$port" state=sd
    @info "Worker install endpoint"      url="$base_url/install.sh"
    return state
end

# HTTP routes
function add_install_routes!(srv::Bonito.Server, public_url::String, worker_secret::String)
    Bonito.route!(srv, "/install.sh" => function(context)
        script = render_install_script(public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body=script)
    end)
    Bonito.route!(srv, "/worker/bundle.tar.gz" => function(context)
        bytes = build_worker_bundle()
        HTTP.Response(200, ["Content-Type" => "application/gzip"], body=bytes)
    end)
end

function render_install_script(public_url::String, worker_secret::String)
    replace(INSTALL_TEMPLATE,
        "{{SERVER_URL}}"    => public_url,
        "{{WORKER_SECRET}}" => worker_secret,
    )
end

# WebSocket routes (worker-side connection terminus). Each closure captures
# `state` so the route handler picks up the same instance the dashboard reads
# from / the chat writes into.
function add_worker_ws_routes!(srv::Bonito.Server, state::ServerState)
    Bonito.HTTPServer.websocket_route!(srv, "/worker-ws"   => (_ctx, ws) ->
        handle_worker_control(state, ws))
    Bonito.HTTPServer.websocket_route!(srv, "/worker-acp"  => (_ctx, ws) ->
        handle_worker_acp(state, ws))
    Bonito.HTTPServer.websocket_route!(srv, "/transfer-ws" => (_ctx, ws) ->
        handle_transfer_ws(state, ws))
end
