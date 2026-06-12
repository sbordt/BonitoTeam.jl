# BonitoAgents desktop app: one process that boots the BonitoAgents server on
# loopback, registers this machine as a local worker, and shows the dashboard
# in an ElectronCall window. Closing the window shuts everything down.
#
# This is the entry point AppBundler packages into the distributable bundles
# (`julia -m BonitoAgentsApp`, or the bundled launcher binary).
module BonitoAgentsApp

import Bonito
using BonitoAgents
using BonitoWorker
using ElectronCall
using HTTP
using URIs: URI
using Random: randstring
using PrecompileTools: @setup_workload, @compile_workload

export desktop
# AppBundler's launcher starts the app as `julia --eval="using BonitoAgentsApp" -- args…`:
# Julia invokes `Main.main` after the eval, and `main` only ends up bound in
# Main if we export it.
export main

# Platform-conventional persistent data root for the desktop app. Unlike
# `BonitoAgents.dev_server` (ephemeral tempdirs), the desktop app keeps its
# state across launches: projects, chats and the worker identity survive.
#
# USER_DATA is the AppBundler/AppEnv convention for the user data directory;
# the bundled launcher sets it to the same platform path so app state and the
# Julia depot cache live under the same root. Honour it here so --data-dir
# (which sets USER_DATA at runtime) moves all state consistently.
function data_root()
    haskey(ENV, "USER_DATA") && return ENV["USER_DATA"]
    base = if Sys.iswindows()
        get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
    elseif Sys.isapple()
        joinpath(homedir(), "Library", "Application Support")
    else
        get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share"))
    end
    return joinpath(base, "BonitoAgents")
end

mutable struct AppHandle
    url           :: String
    state         :: BonitoAgents.ServerState
    worker_id     :: String
    worker_task   :: Task
    closed        :: Threads.Atomic{Bool}
end

# Server-side disconnect of a worker's control WS. The in-process worker task
# is parked in the WS receive loop; closing the socket from the server side is
# the only clean way to end it (there is no out-of-band stop flag). Crucially
# this must happen BEFORE `close(state.srv)`: the server's close drains live
# WS handlers, and a still-connected worker would deadlock that drain (the
# worker only disconnects when the server goes away — a circular wait).
function close_worker_ws(state::BonitoAgents.ServerState, worker_id::String)
    ws = lock(state.lock) do
        get(state.worker_control_ws, worker_id, nothing)
    end
    ws === nothing && return
    close(ws)
    return
end

"""
    start_app(; port = nothing) -> AppHandle

Start the BonitoAgents server on loopback and register an in-process local
worker against it. State persists under [`data_root`](@ref) across launches:

  - `state/`         workers.json / projects.json + chat persistence
  - `working/`       canonical project copies (server side)
  - `projects/`      worker-side project checkouts
  - `worker-config/` stable worker identity (`worker_id`)

`port = nothing` picks a free ephemeral port. Returns an [`AppHandle`](@ref);
`close(handle)` stops the server (the worker task ends with the process).
"""
# In an AppBundler bundle, AppEnv configures the package environment by
# mutating THIS process's LOAD_PATH/DEPOT_PATH arrays only. Child julia
# processes (the BonitoMCP session the worker spawns per chat) run with
# --startup-file=no and would start with default paths — unable to find any
# bundled package. Exporting the resolved paths makes children inherit them;
# in a plain dev run this is a no-op-ish reaffirmation of the same paths.
function export_julia_env!()
    sep = Sys.iswindows() ? ';' : ':'
    ENV["JULIA_LOAD_PATH"]  = join(LOAD_PATH, sep)
    ENV["JULIA_DEPOT_PATH"] = join(DEPOT_PATH, sep)
    return
end

function start_app(; port::Union{Int,Nothing} = nothing)
    export_julia_env!()
    root        = data_root()
    state_dir   = mkpath(joinpath(root, "state"))
    working_dir = mkpath(joinpath(root, "working"))
    worker_cfg  = mkpath(joinpath(root, "worker-config"))
    projects    = mkpath(joinpath(root, "projects"))

    # Fresh secret per run: server and worker live in the same process, nobody
    # else ever needs to know it.
    secret = randstring(64)
    state  = BonitoAgents.serve(; host = "127.0.0.1",
                                  port = something(port, 0),
                                  worker_secret = secret,
                                  state_dir     = state_dir,
                                  working_dir   = working_dir)
    url = "http://127.0.0.1:$(state.srv.port)"

    # Persist the worker identity in our data root (instead of a scratchspace)
    # so the dashboard recognises this machine across launches.
    ENV["BONITOAGENTS_CONFIG_DIR"] = worker_cfg
    worker_id = BonitoWorker.load_or_generate_worker_id()
    worker_task = Base.errormonitor(@async BonitoWorker.connect_and_serve(;
        server_url    = url,
        secret        = secret,
        worker_id     = worker_id,
        projects_root = projects))

    return AppHandle(url, state, worker_id, worker_task, Threads.Atomic{Bool}(false))
end

# Idempotent: first close stops the Bonito server (bounded drain, mirroring
# dev_server's close); the in-process worker task ends when the process exits.
function Base.close(h::AppHandle)
    prev = Threads.atomic_cas!(h.closed, false, true)
    prev && return h
    @info "BonitoAgents app: shutting down" url = h.url
    # Disconnect the local worker FIRST (see close_worker_ws) so the server
    # close below can drain its WS handlers. The worker task's reconnect loop
    # keeps retrying against the closing server; it dies with the process.
    close_worker_ws(h.state, h.worker_id)
    close_task = Base.errormonitor(@async close(h.state.srv))
    for _ in 1:200
        istaskdone(close_task) && break
        sleep(0.05)
    end
    istaskdone(close_task) ||
        @warn "BonitoAgents app: server close did not finish in time"
    delete!(ENV, "BONITOAGENTS_CONFIG_DIR")
    return h
end

# Block until close(h) from elsewhere or Ctrl+C (used by --no-window mode).
function BonitoAgents.wait!(h::AppHandle)
    try
        while !h.closed[]
            sleep(1.0)
        end
    catch e
        e isa InterruptException || rethrow()
    end
    return h
end

# Open the dashboard in an ElectronCall window and block until the user closes
# it (or the Electron process dies, or Ctrl+C).
function run_window(url::String)
    app = ElectronCall.Application(; name = "BonitoAgents")
    win = ElectronCall.Window(app, URI(url);
                              width = 1600, height = 1000,
                              title = "BonitoAgents")
    try
        while isopen(win) && app.exists
            sleep(0.25)
        end
    catch e
        e isa InterruptException || rethrow()
    finally
        # `close(app)` errors on an already-closed app, and the loop above can
        # end exactly because the Electron process went away.
        app.exists && close(app)
    end
    return
end

"""
    desktop(; port = nothing, window = true)

Run the BonitoAgents desktop app: server + local worker + dashboard window.
Blocks until the window is closed (or Ctrl+C with `window = false`), then
shuts the server down. This is what `julia -m BonitoAgentsApp` runs.
"""
function desktop(; port::Union{Int,Nothing} = nothing, window::Bool = true)
    h = start_app(; port)
    try
        if window
            run_window(h.url)
        else
            println("BonitoAgents running at $(h.url) — Ctrl+C to stop.")
            BonitoAgents.wait!(h)
        end
    finally
        close(h)
    end
    return
end

const USAGE = """
BonitoAgents — one bundle, three roles.

Usage: bonitoagents [MODE] [options]

Modes (default: desktop):
  desktop                 server + local worker + dashboard window
  server                  headless dashboard server (workers dial back to it)
  worker                  connect this machine to a remote server as a worker

Desktop options:
  --port=N                bind the dashboard to a fixed port (default: ephemeral)
  --no-window             run server + local worker only; print the URL
  --data-dir=PATH         store all app state under PATH

Server options:
  --port=N                listen port (default: 8038)
  --host=HOST             bind host (default: 0.0.0.0)
  --public-url=URL        base URL workers dial back to (default: auto)
  --secret=HEX            shared worker secret (default: persisted/generated)
  --state-dir=PATH        workers.json / projects.json / chats
  --working-dir=PATH      canonical project copies
  --data-dir=PATH         store all server state under PATH

Worker options:
  --server-url=URL        dashboard server to connect to (required)
  --secret=HEX            shared worker secret (required)
  --worker-id=ID          stable worker id (default: persisted/generated)
  --projects-root=PATH    where project checkouts live
  --data-dir=PATH         store all worker state under PATH

Default data dir: ~/.local/share/BonitoAgents (Linux),
~/Library/Application Support/BonitoAgents (macOS),
%LOCALAPPDATA%\\BonitoAgents (Windows).
"""

# --key=value → opts["key"]="value"; bare --flag → opts["flag"]="". Errors on
# anything not starting with `--`, so a typo fails loudly instead of being
# silently ignored.
function parse_opts(args)
    opts = Dict{String,String}()
    for a in args
        startswith(a, "--") || error("unexpected argument `$a` (use --key=value)")
        body = a[3:end]
        if occursin('=', body)
            k, v = split(body, '='; limit = 2)
            opts[String(k)] = String(v)
        else
            opts[body] = ""
        end
    end
    return opts
end

# `desktop`: the original behaviour — server + local worker + Electron window.
function run_desktop(args)
    port = nothing
    window = true
    for arg in args
        if arg == "--no-window"
            window = false
        elseif startswith(arg, "--port=")
            port = parse(Int, split(arg, '='; limit = 2)[2])
        elseif startswith(arg, "--data-dir=")
            ENV["USER_DATA"] = split(arg, '='; limit = 2)[2]
        else
            println(stderr, "Unknown desktop argument: $arg\n")
            print(stderr, USAGE)
            return 1
        end
    end
    desktop(; port, window)
    return 0
end

# `server`: headless dashboard, mirroring `BonitoAgents`'s own entry point but
# rooting its state under our shared data dir by default.
function run_server(args)
    opts = parse_opts(args)
    haskey(opts, "data-dir") && (ENV["USER_DATA"] = opts["data-dir"])
    root        = data_root()
    state_dir   = get(opts, "state-dir",   mkpath(joinpath(root, "state")))
    working_dir = get(opts, "working-dir", mkpath(joinpath(root, "working")))
    secret = get(opts, "secret", "")
    isempty(secret) && (secret = BonitoAgents.persisted_worker_secret(state_dir))
    export_julia_env!()
    BonitoAgents.serve(;
        host          = get(opts, "host", "0.0.0.0"),
        port          = parse(Int, get(opts, "port", "8038")),
        public_url    = get(opts, "public-url", ""),
        worker_secret = secret,
        state_dir     = state_dir,
        working_dir   = working_dir)
    block_until_interrupt()
    return 0
end

# `worker`: dial back to a remote server. connect_and_serve loops internally
# (reconnect-forever), so it blocks until interrupted.
function run_worker(args)
    opts = parse_opts(args)
    haskey(opts, "data-dir") && (ENV["USER_DATA"] = opts["data-dir"])
    for req in ("server-url", "secret")
        haskey(opts, req) && !isempty(opts[req]) && continue
        println(stderr, "worker: --$req is required\n")
        print(stderr, USAGE)
        return 1
    end
    root     = data_root()
    projects = get(opts, "projects-root", mkpath(joinpath(root, "projects")))
    ENV["BONITOAGENTS_CONFIG_DIR"] = mkpath(joinpath(root, "worker-config"))
    worker_id = get(opts, "worker-id", "")
    isempty(worker_id) && (worker_id = BonitoWorker.load_or_generate_worker_id())
    export_julia_env!()
    BonitoWorker.connect_and_serve(;
        server_url    = opts["server-url"],
        secret        = opts["secret"],
        worker_id     = worker_id,
        projects_root = projects)
    return 0
end

function block_until_interrupt()
    try
        while true
            sleep(3600)
        end
    catch e
        e isa InterruptException || rethrow()
    end
    return
end

function (@main)(args)
    args = collect(String, args)
    # Help is matched before mode-defaulting so `--help`/`-h` (which start with
    # `-`, and would otherwise fall through to desktop) print usage.
    if !isempty(args) && first(args) in ("-h", "--help", "help")
        print(USAGE)
        return 0
    end
    # First non-flag token selects the mode; default is `desktop`.
    mode = (!isempty(args) && !startswith(first(args), "-")) ? popfirst!(args) : "desktop"
    if mode == "desktop"
        return run_desktop(args)
    elseif mode == "server"
        return run_server(args)
    elseif mode == "worker"
        return run_worker(args)
    else
        println(stderr, "Unknown mode: $mode\n")
        print(stderr, USAGE)
        return 1
    end
end

@setup_workload begin
    @compile_workload begin
        mktempdir() do dir
            state = BonitoAgents.serve(;
                host          = "127.0.0.1",
                port          = 0,
                worker_secret = "precompile-secret",
                state_dir     = mkpath(joinpath(dir, "state")),
                working_dir   = mkpath(joinpath(dir, "working")))
            url = "http://127.0.0.1:$(state.srv.port)"
            # Connection:close avoids a lingering keep-alive reader task that
            # would stall the precompile serializer.
            HTTP.get(url, ["Connection" => "close"])
            # Close sessions the GET created — compiles the teardown paths too.
            for (_, v) in state.srv.routes.table
                v isa Bonito.App && !isnothing(v.session[]) && close(v.session[])
            end
            close(state.srv)
        end
        # Signal Bonito's per-server cleanup tasks to stop and clear globals.
        Bonito.cleanup_globals()
        yield()
    end
end

end # module BonitoAgentsApp
