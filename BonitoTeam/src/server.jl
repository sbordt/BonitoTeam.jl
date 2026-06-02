# Path to the BonitoTeam package's assets/ (install.jl, bonitoteam.js)
const ASSETS_DIR    = normpath(joinpath(@__DIR__, "..", "assets"))
# Monorepo root (sibling of BonitoTeam/) — contains BonitoMCP/, BonitoWorker/, AgentClientProtocol/.
const MONOREPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# The worker installer is a cross-platform Julia script (`curl … | julia -`).
# It Pkg.add's BonitoWorker + BonitoMCP from the public GitHub repo into a
# shared `@bonito-team` env — no tar bundle, no per-package source trees, runs
# identically on Linux / macOS / Windows. See assets/install.jl.
#
# Around it sit two tiny per-shell bootstraps so the install one-liner mirrors
# the familiar `curl URL | sh` shape on each OS. They only check that `julia`
# is on PATH and then hand off to install.jl — they do NOT install juliaup
# (Julia is a prerequisite the user installs separately).
const INSTALL_SCRIPT = read(joinpath(ASSETS_DIR, "install.jl"), String)
const INSTALL_SH     = read(joinpath(ASSETS_DIR, "install.sh"),  String)
const INSTALL_PS1    = read(joinpath(ASSETS_DIR, "install.ps1"), String)

"""
    serve(; host, port, public_url, worker_secret, state_dir, working_dir) → Bonito.Server

Start the BonitoTeam dashboard server. Workers dial back to this server, so
only port `port` (default 8038) needs to be open in the server's firewall.

Routes:
  /                       — dashboard (workers + projects)
  /p/<project_id>         — chat UI for one project
  /install                — OS-sniffing bootstrap (`curl … | sh` / `irm … | iex`)
  /install.sh             — bash wrapper (Linux / macOS)
  /install.ps1            — PowerShell wrapper (Windows)
  /install.jl             — cross-platform worker installer (used by the wrappers)
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

    # Survive long browser disconnects (phone goes into pocket, laptop sleeps,
    # network blip) by keeping SOFT_CLOSED sessions alive for an hour, so the
    # browser can reconnect to the SAME session with all of its Observable
    # state — current view, popup geometry, chat consumer task — intact.
    # The new-tab case still falls back to the localStorage last-route memory
    # wired in the sidebar onload.
    Bonito.set_cleanup_time!(1.0)   # hours

    # Single-page app: sidebar + dashboard/chat swap. No per-project routes.
    srv = Bonito.Server(unified_app(state), host, port; proxy_url = ".")
    state.srv = srv

    # online_url uses the post-start srv.port — handles port=0 → ephemeral
    # AND EADDRINUSE → port+1 retry without us tracking the actual port.
    base_url = something(public_url, Bonito.online_url(srv, ""))
    add_install_routes!(srv, base_url, worker_secret)
    add_worker_ws_routes!(srv, state)

    @info "BonitoTeam dashboard running" url=Bonito.online_url(srv, "") state=sd
    @info "Worker install — run on each agent machine" *
          "\n    Linux / macOS  : curl -fsSL $base_url/install | sh" *
          "\n    Windows (PS)   : irm $base_url/install | iex"
    return state
end

# HTTP routes
#
# /install        — sniffs `User-Agent` and serves either the bash or PS1
#                   wrapper. PowerShell's Invoke-RestMethod sets a UA that
#                   contains the literal "PowerShell"; curl/wget/everything
#                   else falls through to the bash wrapper.
# /install.sh     — always bash wrapper. Useful when /install's sniff guesses
#                   wrong, or when fetched from a browser to inspect.
# /install.ps1    — always PowerShell wrapper. Same.
# /install.jl     — the cross-platform Julia installer the wrappers fetch.
function add_install_routes!(srv::Bonito.Server, public_url::String, worker_secret::String)
    Bonito.route!(srv, "/install.jl" => function(context)
        script = render_install_script(INSTALL_SCRIPT, public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body=script)
    end)
    Bonito.route!(srv, "/install.sh" => function(context)
        body = render_install_script(INSTALL_SH, public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/x-shellscript; charset=utf-8"], body=body)
    end)
    Bonito.route!(srv, "/install.ps1" => function(context)
        body = render_install_script(INSTALL_PS1, public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body=body)
    end)
    Bonito.route!(srv, "/install" => function(context)
        ua   = String(HTTP.header(context.request, "User-Agent", ""))
        is_ps = occursin("PowerShell", ua)
        body = render_install_script(is_ps ? INSTALL_PS1 : INSTALL_SH,
                                     public_url, worker_secret)
        ctype = is_ps ? "text/plain; charset=utf-8" :
                        "text/x-shellscript; charset=utf-8"
        HTTP.Response(200, ["Content-Type" => ctype], body=body)
    end)
end

# Substitute the server URL + shared secret into a templated install script.
# install.jl guards against being run with the `{{ }}` placeholders intact, so
# a raw fetch of any asset (bypassing these routes) fails loudly.
function render_install_script(template::AbstractString,
                                 public_url::String, worker_secret::String)
    replace(template,
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
    # Eval workers (BonitoMCP) dial here to be driven for interactive app proxying.
    Bonito.HTTPServer.websocket_route!(srv, "/eval-ws" => (_ctx, ws) ->
        handle_eval_ws(state, ws))
end
