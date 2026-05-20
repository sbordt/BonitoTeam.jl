# Path to the BonitoTeam package's assets/ (install.jl, bonitoteam.js)
const ASSETS_DIR    = normpath(joinpath(@__DIR__, "..", "assets"))
# Monorepo root (sibling of BonitoTeam/) — contains BonitoMCP/, BonitoWorker/, AgentClientProtocol/.
const MONOREPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# The worker installer is a cross-platform Julia script (`curl … | julia -`).
# It Pkg.add's BonitoWorker + BonitoMCP from the public GitHub repo into a
# shared `@bonito-team` env — no tar bundle, no per-package source trees, runs
# identically on Linux / macOS / Windows. See assets/install.jl.
const INSTALL_SCRIPT = read(joinpath(ASSETS_DIR, "install.jl"), String)

"""
    serve(; host, port, public_url, worker_secret, state_dir, working_dir) → Bonito.Server

Start the BonitoTeam dashboard server. Workers dial back to this server, so
only port `port` (default 8038) needs to be open in the server's firewall.

Routes:
  /                       — dashboard (workers + projects)
  /p/<project_id>         — chat UI for one project
  /install.jl             — cross-platform worker installer (`curl … | julia -`)
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
    for w in values(state.workers[])
        w.status = :offline
    end

    # Single-page app: sidebar + dashboard/chat swap. No per-project routes.
    srv = Bonito.Server(unified_app(state), host, port; proxy_url = ".")
    state.srv = srv

    # online_url uses the post-start srv.port — handles port=0 → ephemeral
    # AND EADDRINUSE → port+1 retry without us tracking the actual port.
    base_url = something(public_url, Bonito.online_url(srv, ""))
    add_install_routes!(srv, base_url, worker_secret)
    add_worker_ws_routes!(srv, state)

    @info "BonitoTeam dashboard running" url=Bonito.online_url(srv, "") state=sd
    @info "Worker install endpoint"      url="$base_url/install.jl"
    return state
end

# HTTP routes
function add_install_routes!(srv::Bonito.Server, public_url::String, worker_secret::String)
    Bonito.route!(srv, "/install.jl" => function(context)
        script = render_install_script(public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body=script)
    end)
end

# Substitute the server URL + shared secret into the install.jl template. The
# script guards against being run with the `{{ }}` placeholders intact, so a
# raw fetch of assets/install.jl (bypassing this route) fails loudly.
function render_install_script(public_url::String, worker_secret::String)
    replace(INSTALL_SCRIPT,
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
