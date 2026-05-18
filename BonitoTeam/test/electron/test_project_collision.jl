# Tier 4d — project-name collision on import.
#
# Scenario the user actually hits: "I imported myproject from PC, now I
# want to import the same folder name from laptop." Server detects the
# name collision and raises `ProjectCollisionError` carrying both sides'
# summaries (file count, latest mtime, recent files, per-subrepo git
# state) so the UI can show a side-by-side comparison and let the user
# pick which side to keep.
#
# Mock workers handle:
#   - `inspect_path`  → real `BonitoWorker.inspect_path_summary` over the
#                       mock root, so the comparison numbers are real
#   - `open_session`  → silently ignored (we don't start an ACP session
#                       in this test)
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using HTTP, JSON, Dates
using BonitoTeam, BonitoWorker
const WebSockets = HTTP.WebSockets

const PORT   = 19101
const SECRET = "test-secret"

mutable struct MockWorker
    name :: String
    root :: String
    ws   :: Union{Nothing, HTTP.WebSockets.WebSocket}
    task :: Union{Nothing, Task}
end

function start_mock_worker!(name; server_url, root = mktempdir())
    mw    = MockWorker(name, root, nothing, nothing)
    ready = Channel{Bool}(1)
    mw.task = Base.errormonitor(@async try
        ws_url = replace(server_url, "http://" => "ws://") * "/worker-ws"
        WebSockets.open(ws_url) do ws
            mw.ws = ws
            WebSockets.send(ws, JSON.json(Dict(
                "secret"        => SECRET,
                "name"          => name,
                "hostname"      => "mock-$name",
                "home"          => "/home/agent",
                "mcp_path"      => "",
                "projects_root" => root,
            )))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            put!(ready, get(ack, "ok", false) == true)
            for frame in ws
                cmd = try JSON.parse(String(frame)) catch _; nothing end
                cmd === nothing && continue
                t = String(get(cmd, "type", ""))
                if t == "inspect_path"
                    Base.errormonitor(@async handle_mock_inspect(mw, cmd))
                end
            end
        end
    catch e
        @warn "mock worker connection ended" name exception=e
        try put!(ready, false) catch end
    end)
    take!(ready) || error("mock worker '$name' failed to connect")
    return mw
end

function handle_mock_inspect(mw::MockWorker, cmd::AbstractDict)
    rid  = String(get(cmd, "request_id", ""))
    path = String(get(cmd, "path", ""))
    resp = try
        Dict("type"       => "inspect_path_response",
             "request_id" => rid,
             "path"       => abspath(path),
             "summary"    => BonitoWorker.inspect_path_summary(path))
    catch e
        Dict("type"       => "inspect_path_response",
             "request_id" => rid,
             "error"      => sprint(showerror, e))
    end
    try WebSockets.send(mw.ws, JSON.json(resp)) catch end
end

stop_mock_worker!(mw::MockWorker) = (try mw.ws !== nothing && close(mw.ws) catch end)

function wait_for_worker(state, name; timeout = 5.0)
    deadline = time() + timeout
    while time() < deadline
        if haskey(state.workers[], name) &&
           state.workers[][name].status === :online
            return state.workers[][name]
        end
        sleep(0.05)
    end
    error("worker '$name' never came online")
end

server_state = nothing
worker_a     = nothing
worker_b     = nothing
results      = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    server_state = BonitoTeam.serve(;
        host          = "127.0.0.1",
        port          = PORT,
        public_url    = "http://127.0.0.1:$PORT",
        worker_secret = SECRET,
        state_dir     = mktempdir(),
        working_dir   = mktempdir())
    sleep(0.3)

    worker_a = start_mock_worker!("worker-a"; server_url = "http://127.0.0.1:$PORT")
    worker_b = start_mock_worker!("worker-b"; server_url = "http://127.0.0.1:$PORT")
    wait_for_worker(server_state, "worker-a")
    wait_for_worker(server_state, "worker-b")

    # Seed both mock workers with a `myproject` folder, deliberately
    # different state — worker A is older + clean, worker B is newer
    # + has uncommitted changes.
    proj_a = joinpath(worker_a.root, "myproject")
    proj_b = joinpath(worker_b.root, "myproject")
    mkpath(joinpath(proj_a, "src"))
    mkpath(joinpath(proj_b, "src"))

    # Worker A's content (older).
    write(joinpath(proj_a, "src", "main.jl"), "function f(); 1; end\n")
    write(joinpath(proj_a, "README.md"),      "# my project\nv1\n")

    # Touch A's files to a known old timestamp so the "latest mtime"
    # signal is unambiguous.
    old_t = time() - 3600 * 24 * 7   # one week ago
    for f in [joinpath(proj_a, "src", "main.jl"), joinpath(proj_a, "README.md")]
        ccall(:utimes, Cint, (Cstring, Ptr{Int64}),
              f, Ref((Int64(floor(old_t)), Int64(0), Int64(floor(old_t)), Int64(0))))
    end

    # Worker B's content (newer, slightly different).
    write(joinpath(proj_b, "src", "main.jl"), "function f(); 2; end  # tweaked\n")
    write(joinpath(proj_b, "README.md"),      "# my project\nv2\n")
    write(joinpath(proj_b, "extra.jl"),       "println(\"added on laptop\")\n")
    # B's files keep their fresh mtime (now).

    # ── 1. Import from worker-a — no collision ────────────────────────────
    TH.section("First import (no collision)") do
        p = BonitoTeam.create_project_from_worker!(server_state, "worker-a", proj_a;
                                                    on_collision = :detect,
                                                    start_session = false)
        record("returned ProjectInfo",       @TH.test_true (p isa BonitoTeam.ProjectInfo))
        record("name is 'myproject'",        @TH.test_eq p.name "myproject")
        record("bound to worker-a",          @TH.test_eq p.worker_id "worker-a")
        record("registered in state.projects",
               @TH.test_true any(x -> x.name == "myproject", values(server_state.projects[])))
    end

    # ── 2. Import same name from worker-b with :detect — collision raised
    TH.section("Same name from worker-b raises ProjectCollisionError") do
        err = try
            BonitoTeam.create_project_from_worker!(server_state, "worker-b", proj_b;
                                                    on_collision = :detect,
                                                    start_session = false)
            nothing
        catch e
            e
        end
        record("raised ProjectCollisionError",
               @TH.test_true (err isa BonitoTeam.ProjectCollisionError))
        if err isa BonitoTeam.ProjectCollisionError
            cmp = err.comparison
            record("existing side has summary",
                   @TH.test_true (haskey(cmp.existing, "total_files") &&
                                   cmp.existing["total_files"] >= 2))
            record("candidate side has summary",
                   @TH.test_true (haskey(cmp.candidate, "total_files") &&
                                   cmp.candidate["total_files"] >= 3))   # extra.jl
            record("existing source is :worker (live)",
                   @TH.test_eq cmp.existing_source :worker)
            record("candidate latest_mtime > existing latest_mtime (B fresher)",
                   @TH.test_true (cmp.candidate["latest_mtime"] >
                                   cmp.existing["latest_mtime"] + 60))
            record("recent_files non-empty on both sides",
                   @TH.test_true (!isempty(cmp.existing["recent_files"]) &&
                                   !isempty(cmp.candidate["recent_files"])))
            record("project NOT reassigned (still on worker-a)",
                   @TH.test_eq err.existing.worker_id "worker-a")
        end
    end

    # ── 3. :keep_existing returns existing project unchanged ──────────────
    TH.section(":keep_existing returns existing project unchanged") do
        BonitoTeam.create_project_from_worker!(server_state, "worker-b", proj_b;
                                                on_collision = :keep_existing,
                                                start_session = false)
        proj = BonitoTeam.find_project_by_name(server_state, "myproject")
        record("project still bound to worker-a",
               @TH.test_eq proj.worker_id "worker-a")
        record("project name unchanged",
               @TH.test_eq proj.name "myproject")
    end

    # ── 4. :take_candidate reassigns to the new worker ────────────────────
    TH.section(":take_candidate reassigns project to candidate worker") do
        BonitoTeam.create_project_from_worker!(server_state, "worker-b", proj_b;
                                                on_collision = :take_candidate,
                                                start_session = false)
        proj = BonitoTeam.find_project_by_name(server_state, "myproject")
        record("project now bound to worker-b",
               @TH.test_eq proj.worker_id "worker-b")
        record("worker_path updated to proj_b",
               @TH.test_eq proj.worker_path proj_b)
        record("backup_status marked :stale (mirror not yet re-pulled)",
               @TH.test_eq proj.backup_status :stale)
    end

    # ── 5. Different name → no collision, normal import ───────────────────
    TH.section("Different name from worker-a → normal import path") do
        other = joinpath(worker_a.root, "otherproject")
        mkpath(other)
        write(joinpath(other, "foo.jl"), "1\n")
        BonitoTeam.create_project_from_worker!(server_state, "worker-a", other;
                                                start_session = false)
        proj = BonitoTeam.find_project_by_name(server_state, "otherproject")
        record("new project registered",
               @TH.test_true (proj !== nothing))
        record("bound to worker-a",
               @TH.test_eq proj.worker_id "worker-a")
    end

finally
    TH.report!("Tier 4d — project collision", results)
    worker_a !== nothing && stop_mock_worker!(worker_a)
    worker_b !== nothing && stop_mock_worker!(worker_b)
    server_state !== nothing && try close(server_state.srv) catch end
end
