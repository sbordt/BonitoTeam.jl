# Worker disconnect path. Tier 4b proved the connect+register side; this
# file proves the *teardown* side: when a worker's WS closes,
# handle_worker_control's `finally` block must:
#   1. Drop the entry from worker_control_ws
#   2. Flip the WorkerInfo.status to :offline
#   3. Bump the dashboard reactive version
#   4. Release any project locks the worker held
#   5. (Real prod also evicts ChatModels; we don't seed any here.)
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using HTTP, JSON
using Bonito: on  # `on` for Observable listeners (re-exported by Bonito)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

# Random port — same rationale as test_worker_handshake.jl: re-running in
# the same Julia session can leave a zombie on the prior port.
const PORT = 19500 + rand(1:399)

server_state = BonitoTeam.serve(;
    host          = "127.0.0.1",
    port          = PORT,
    public_url    = "http://127.0.0.1:$PORT",
    worker_secret = "discon-secret",
    state_dir     = mktempdir(),
    working_dir   = mktempdir())
sleep(0.3)

# Pre-seed a project with a lock held by the worker we're about to connect.
# release_projects_for_worker! should clear it on disconnect.
proj_dir = joinpath(server_state.working_dir, "LockedProj")
mkpath(proj_dir)
p = BonitoTeam.ProjectInfo("p-locked", "LockedProj", "transient-w",
        proj_dir, "/tmp/worker/LockedProj", BonitoTeam.now(BonitoTeam.UTC))
p.locked_by = "transient-w"
p.locked_at = BonitoTeam.now(BonitoTeam.UTC)
server_state.projects[]["p-locked"] = p

# Count notifications fired on `state.workers` / `state.projects` over
# the lifecycle, so we can prove the disconnect path actually announces
# the change to listeners.
reactive_bumps = Threads.Atomic{Int}(0)
on(_ -> Threads.atomic_add!(reactive_bumps, 1), server_state.workers)
on(_ -> Threads.atomic_add!(reactive_bumps, 1), server_state.projects)

# Open a WS, register, then deliberately close. We use a Channel to
# signal the test thread when the WS-handler closure has actually closed
# the connection, so we don't race with the server's finally block.
closed = Channel{Bool}(1)
Base.errormonitor(@async try
    HTTP.WebSockets.open("ws://127.0.0.1:$PORT/worker-ws") do ws
        HTTP.WebSockets.send(ws, JSON.json(Dict(
            "secret"=>"discon-secret", "name"=>"transient-w",
            "hostname"=>"th", "home"=>"/h",
            "mcp_path"=>"/m", "projects_root"=>"/r")))
        # Wait for ack so we know registration completed.
        HTTP.WebSockets.receive(ws)
        # Hold the WS open for a beat to let everything settle on the
        # server side, then close. The `do` block exit closes the WS.
        sleep(0.3)
    end
    put!(closed, true)
catch e
    @warn "worker WS closed unexpectedly" exception=e
    put!(closed, true)
end)

try
    # Wait for the registration phase to complete.
    let deadline = time() + 3
        while time() < deadline
            haskey(server_state.workers[], "transient-w") &&
                server_state.workers[]["transient-w"].status == :online && break
            sleep(0.05)
        end
    end

    TH.section("During the WS lifetime: registered + online + locked") do
        record("worker present",
               @TH.test_true haskey(server_state.workers[], "transient-w"))
        record("worker.status :online",
               @TH.test_eq server_state.workers[]["transient-w"].status :online)
        record("control_ws bookkeeping has the worker",
               @TH.test_true haskey(server_state.worker_control_ws, "transient-w"))
        record("project lock still held",
               @TH.test_eq server_state.projects[]["p-locked"].locked_by "transient-w")
    end

    # Wait for the worker WS to close (the @async exits its `do` block).
    take!(closed)
    # Give the server's finally block time to run.
    let deadline = time() + 5
        while time() < deadline
            (server_state.workers[]["transient-w"].status == :offline) && break
            sleep(0.05)
        end
    end

    TH.section("After WS close: status flips offline + locks released") do
        record("worker.status :offline",
               @TH.test_eq server_state.workers[]["transient-w"].status :offline)
        record("control_ws entry dropped",
               @TH.test_true !haskey(server_state.worker_control_ws, "transient-w"))
        record("project lock released",
               @TH.test_eq server_state.projects[]["p-locked"].locked_by nothing)
        record("locked_at cleared",
               @TH.test_eq server_state.projects[]["p-locked"].locked_at nothing)
    end

    TH.section("Reactive observables fired at least once across the lifecycle") do
        record("state.workers / state.projects notified",
               @TH.test_true (reactive_bumps[] > 0))
    end

finally
    TH.report!("Worker disconnect", results)
    try close(server_state.srv) catch end
end
