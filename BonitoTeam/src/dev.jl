# Self-contained dev server + local worker, no systemd / no install steps.
# Used to bring the dashboard up against ephemeral state for development,
# manual UX poking, or one-off scripted demos. Everything lives in
# tempdirs that get rm-rf'd on close.
#
# Usage:
#   handle = BonitoTeam.dev_server()
#   # ... open handle.url in a browser, click around ...
#   close(handle)
#
# Or as a do-block for guaranteed cleanup on Ctrl+C:
#   BonitoTeam.dev_server() do h
#       BonitoTeam.wait!(h)
#   end

using Random

mutable struct DevHandle
    url         :: String
    secret      :: String
    state       :: ServerState
    worker_task :: Task
    state_dir   :: String
    working_dir :: String
    worker_root :: String
    closed      :: Threads.Atomic{Bool}
end

"""
    dev_server(; port=nothing, name="dev", auto_open=false) -> DevHandle

Boot a self-contained BonitoTeam server + a local worker in this
process. All state lives in `mktempdir()`-allocated directories and is
removed when you call `close(handle)` (or when the Julia process exits
— an atexit hook is registered).

The worker is an in-process `BonitoWorker.connect_and_serve` task: it
dials the server's `/worker-ws` over loopback with a freshly-generated
secret. No systemd, no install script.

If `claude-agent-acp` isn't on PATH the dashboard still works (worker
registration, sidebar, project import, file pickers); only opening a
chat session against the worker will fail at the agent spawn step.

```julia
h = BonitoTeam.dev_server(; port = 8138, auto_open = true)
# Click around in the browser...
close(h)
```

Or as a do-block (recommended, cleans up on exception / Ctrl+C):

```julia
BonitoTeam.dev_server() do h
    BonitoTeam.wait!(h)   # blocks until Ctrl+C
end
```
"""
function dev_server(; port::Union{Int,Nothing}             = nothing,
                      name::Union{String,Nothing}          = nothing,
                      auto_open::Bool                      = false,
                      agent_bin::Union{String,Nothing}     = nothing,
                      agent_env::Dict{String,String}       = Dict{String,String}())
    # port=0 lets the kernel pick a free ephemeral port; Bonito.Server
    # writes the real port back to srv.port after start.
    chosen_port = port === nothing ? 0 : port
    secret      = randstring(64)
    state_dir   = mktempdir(; prefix = "bonitoteam-dev-state-")
    working_dir = mktempdir(; prefix = "bonitoteam-dev-work-")
    worker_root = mktempdir(; prefix = "bonitoteam-dev-worker-")
    worker_id   = "dev-" * randstring(8)
    # Route through `default_worker_name` so a machine whose
    # `friendly_hostname()` is empty (no `hostnamectl --pretty` configured,
    # `gethostname()` = "localhost") falls back to `<user>-<4 chars>` —
    # otherwise dev_server registered every worker as "localhost".
    actual_name = name === nothing ? BonitoWorker.default_worker_name(worker_id) : name

    state = serve(; host          = "127.0.0.1",
                    port          = chosen_port,
                    worker_secret = secret,
                    state_dir     = state_dir,
                    working_dir   = working_dir)
    server_url = "http://127.0.0.1:$(state.srv.port)"

    # Spawn the worker control loop in-process. errormonitor surfaces
    # any crash on stderr so dev workflows don't silently lose the
    # worker connection. We use `run_control_session` (one connect
    # attempt) rather than `connect_and_serve` (auto-reconnect loop)
    # because reconnecting against a torn-down server prints a noisy
    # error every retry_delay seconds during shutdown.
    # Spawn the worker control loop in-process. errormonitor surfaces
    # any crash on stderr so dev workflows don't silently lose the
    # worker connection. We use `run_control_session` (one connect
    # attempt) rather than `connect_and_serve` (auto-reconnect loop)
    # because reconnecting against a torn-down server prints a noisy
    # error every retry_delay seconds during shutdown.
    #
    # When the caller wants a deterministic test agent (mock_claude_agent_acp
    # or anything else speaking ACP over stdio), they pass `agent_bin` +
    # `agent_env` and we forward them to the worker so EVERY chat the
    # worker hosts spawns that binary instead of the real claude-agent-acp.
    resolved_agent_bin = agent_bin === nothing ? BonitoWorker.find_agent_bin() :
                          String(agent_bin)
    # Shared shutdown flag — created here so the worker loop can gate on it and
    # `close(handle)` (below) can flip it. A transient control-WS drop or a
    # server restart should auto-recover in dev too (matching a deployed
    # worker's `connect_and_serve`); we only stop reconnecting once the dev
    # server is shutting down, so teardown stays quiet (no retry-spam).
    closed = Threads.Atomic{Bool}(false)
    worker_task = Base.errormonitor(@async begin
        while !closed[]
            try
                BonitoWorker.run_control_session(;
                    server_url    = server_url,
                    secret        = secret,
                    worker_id     = worker_id,
                    name          = actual_name,
                    mcp_command   = BonitoWorker.julia_bin(),
                    mcp_arguments = BonitoWorker.mcp_args(),
                    projects_root = worker_root,
                    agent_bin     = resolved_agent_bin,
                    agent_env     = agent_env)
                # Clean return = server closed the WS. If we're not shutting
                # down, that was a transient drop — loop and redial.
            catch e
                e isa InterruptException && break
                closed[] && break
                msg = sprint(showerror, e)
                if occursin("WebSocketError", msg) || occursin("EOFError", msg) ||
                   occursin("IOError", msg)
                    @debug "dev worker control WS dropped; reconnecting" exception=e
                else
                    @warn "dev worker control session ended; reconnecting" exception=e
                end
            end
            closed[] && break
            sleep(1.0)   # brief backoff before redial
        end
    end)

    handle = DevHandle(server_url, secret, state, worker_task,
                       state_dir, working_dir, worker_root, closed)

    # Best-effort cleanup if the Julia process exits without explicit close.
    Base.atexit(() -> close(handle))

    println()
    @info "BonitoTeam dev server running" url=server_url worker_name=actual_name
    println("  State dirs (auto-cleaned on close):")
    println("    state    $state_dir")
    println("    working  $working_dir")
    println("    worker   $worker_root")
    println()
    println("  Call close(h) to stop, or BonitoTeam.wait!(h) to block " *
            "until Ctrl+C.")
    println()

    auto_open && open_in_browser(server_url)

    return handle
end

# Do-block form: f(handle) is called with a live DevHandle and the
# server is torn down + tempdirs removed even on exception (Ctrl+C
# included, since InterruptException propagates through finally).
function dev_server(f::Function; kwargs...)
    h = dev_server(; kwargs...)
    try
        f(h)
    finally
        close(h)
    end
end

# Idempotent close: stops the server, lets the worker WS drop, removes
# every tempdir we allocated. Safe to call multiple times — only the
# first call does anything.
function Base.close(h::DevHandle)
    # atomic_cas! returns the PRIOR value. We want "exit early iff it
    # was already true", i.e. iff we weren't the first to set it.
    prev = Threads.atomic_cas!(h.closed, false, true)
    prev && return h
    @info "dev_server: shutting down" url=h.url
    # Bonito.Server.close blocks waiting for accept loops + WS handlers
    # to drain, which can take a few seconds when a worker is still
    # connected. Run it in a task so we can move on without it
    # holding cleanup hostage in interactive use. Failures from inside
    # the server's drain (Bonito has a known surface that occasionally
    # throws on background route handlers) are surfaced via
    # `errormonitor` rather than swallowed — they go to stderr, the
    # main cleanup proceeds.
    close_task = Base.errormonitor(@async close(h.state.srv))
    # Give the server a budget to close cleanly; if it doesn't make it,
    # cleanup proceeds anyway. The server's accept-listener is bound to
    # an ephemeral port that the OS reclaims on Julia exit either way.
    for _ in 1:40
        istaskdone(close_task) && break
        sleep(0.05)
    end
    # Worker task should have dropped when its WS got the server's
    # close; brief window so any final writes flush before we rm.
    for _ in 1:20
        istaskdone(h.worker_task) && break
        sleep(0.05)
    end
    # `force = true` already makes "doesn't exist" a no-op, so the only
    # remaining failure modes are permission / filesystem errors — those
    # we DO want surfaced rather than silently dropping the tempdir.
    for d in (h.state_dir, h.working_dir, h.worker_root)
        try
            rm(d; recursive = true, force = true)
        catch e
            @warn "dev_server: cleanup rm failed" path=d exception=e
        end
    end
    return h
end

# Block until Ctrl+C. Useful from scripts and bin wrappers; from the
# REPL just keep the handle and run other code in parallel.
function wait!(h::DevHandle)
    try
        # Long sleep on the main task; Ctrl+C delivers InterruptException
        # which we catch + return cleanly so the caller's finally runs.
        while !h.closed[]
            sleep(1.0)
        end
    catch e
        e isa InterruptException || rethrow()
    end
    return h
end

function open_in_browser(url::AbstractString)
    cmd = if Sys.iswindows()
        `cmd /c start "" $url`
    elseif Sys.isapple()
        `open $url`
    else
        `xdg-open $url`
    end
    # `ignorestatus = true` already swallows non-zero exit codes from
    # the launcher itself; the remaining failure mode is the launcher
    # binary simply not being on PATH (Base.IOError "no such file").
    # That's best-effort by design — the dev_server's banner printed
    # the URL above, the user can still click it. Log at @debug for
    # anyone investigating "why didn't my browser open".
    try
        run(pipeline(Cmd(cmd; ignorestatus = true), stdout = devnull, stderr = devnull))
    catch e
        e isa Base.IOError || rethrow()
        @debug "open_in_browser: launcher not available" url exception=e
    end
end
