# Tier 4b — worker control WebSocket handshake.
#
# Brings up a real BonitoAgents server, opens an outbound WS to /worker-ws,
# sends a hello frame, and verifies the server registers the worker as
# online and that disconnecting flips it to offline.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using HTTP, JSON

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

# Randomized so re-running the test in the same Julia session (Bonito.Server
# auto-bumps to the next free port if PORT is taken) doesn't leave us
# pointing our WS client at a zombie server from a previous invocation.
const PORT = 18000 + rand(1:999)
state = TH.make_state()  # no seeded workers — we want the registration path

server_state = nothing
server       = nothing

try
    # Bring up the real server. `serve()` returns a ServerState whose `srv`
    # field holds the live Bonito.Server. We manually pass the desired port
    # and worker_secret so we know what to dial / authenticate as.
    server_state = BonitoAgents.serve(;
        host          = "127.0.0.1",
        port          = PORT,
        public_url    = "http://127.0.0.1:$PORT",
        worker_secret = "test-secret",
        state_dir     = mktempdir(),
        working_dir   = mktempdir())
    server = server_state.srv
    sleep(0.3)  # let HTTPServer start accepting

    record("server has zero workers initially",
           @TH.test_eq length(server_state.workers[]) 0)

    TH.section("Connect + hello → worker registers as online") do
        # Dial the control WS, send a well-formed hello frame, read the ack,
        # then keep the WS open in a task so the handle_worker_control loop
        # stays running and the worker stays :online.
        worker_done = Channel{Any}(1)
        Base.errormonitor(@async try
            HTTP.WebSockets.open("ws://127.0.0.1:$PORT/worker-ws") do ws
                hello = Dict(
                    "secret"        => "test-secret",
                    "name"          => "fake-worker-1",
                    "hostname"      => "test-host",
                    "home"          => "/home/agent",
                    "mcp_path"      => "/usr/local/bin/bonitoagents-mcp",
                    "projects_root" => "/tmp/projects")
                HTTP.WebSockets.send(ws, JSON.json(hello))
                ack_raw = HTTP.WebSockets.receive(ws)
                put!(worker_done, (:ack, JSON.parse(String(ack_raw))))
                # Stay open until the test signals close
                for frame in ws
                    # eat frames quietly
                end
            end
        catch e
            put!(worker_done, (:err, e))
        end)

        # Wait for the ack.
        ack = nothing
        let deadline = time() + 3
            while time() < deadline
                isready(worker_done) && (ack = take!(worker_done); break)
                sleep(0.05)
            end
        end
        record("server acknowledged hello",
               @TH.test_true (ack !== nothing && ack[1] === :ack))
        if ack !== nothing && ack[1] === :ack
            record("ack ok=true",
                   @TH.test_eq get(ack[2], "ok", false) true)
            record("ack registered_as=fake-worker-1",
                   @TH.test_eq get(ack[2], "registered_as", "") "fake-worker-1")
        end

        # Server-side state should now have the worker registered + online.
        # Poll generously: handle_worker_control runs the registration in a
        # separate WS-handler task and under load (e.g. when this file runs
        # at the end of the suite, alongside leftover Electron sessions and
        # GC pressure from the chat tests) it can take several seconds to
        # be scheduled.
        let deadline = time() + 10
            while time() < deadline
                haskey(server_state.workers[], "fake-worker-1") && break
                sleep(0.1)
            end
        end
        record("worker present in state.workers",
               @TH.test_true haskey(server_state.workers[], "fake-worker-1"))
        if haskey(server_state.workers[], "fake-worker-1")
            w = server_state.workers[]["fake-worker-1"]
            record("worker.status == :online",
                   @TH.test_eq w.status :online)
            record("worker.hostname round-tripped",
                   @TH.test_eq w.hostname "test-host")
            record("worker.projects_root round-tripped",
                   @TH.test_eq w.projects_root "/tmp/projects")
            record("worker_control_ws holds the WS",
                   @TH.test_true haskey(server_state.worker_control_ws, "fake-worker-1"))
        end
    end

    TH.section("Wrong secret is rejected") do
        rej_done = Channel{Any}(1)
        Base.errormonitor(@async try
            HTTP.WebSockets.open("ws://127.0.0.1:$PORT/worker-ws") do ws
                HTTP.WebSockets.send(ws, JSON.json(Dict(
                    "secret" => "WRONG", "name" => "rogue-worker")))
                ack_raw = try HTTP.WebSockets.receive(ws) catch _; nothing end
                put!(rej_done, ack_raw === nothing ? (:closed,) :
                                (:ack, JSON.parse(String(ack_raw))))
            end
        catch e
            put!(rej_done, (:err, e))
        end)
        result = nothing
        let deadline = time() + 3
            while time() < deadline
                isready(rej_done) && (result = take!(rej_done); break)
                sleep(0.05)
            end
        end
        if result !== nothing && result[1] === :ack
            record("rejection ack ok=false",
                   @TH.test_eq get(result[2], "ok", true) false)
        else
            # The server may close the WS without sending an ack on bad creds
            # — also a valid rejection.
            record("connection closed without registering",
                   @TH.test_true (result !== nothing && result[1] !== :ack))
        end
        record("rogue-worker NOT in state",
               @TH.test_true !haskey(server_state.workers[], "rogue-worker"))
    end

finally
    TH.report!("Tier 4b — worker handshake", results)
    try close(server) catch end
end
