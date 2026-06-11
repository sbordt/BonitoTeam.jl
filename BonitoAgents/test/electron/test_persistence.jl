# Persistence round-trip: save_workers! + save_projects! write atomic JSON
# files into state_dir; constructing a fresh ServerState pointed at the same
# state_dir reads them back via load_workers! / load_projects! during init.
#
# We touch every persisted field (and a few that should NOT be persisted —
# locks reset, syncing rolls back to stale, etc.) so future schema changes
# get caught here. No Electron in this one — pure Julia state-shape test.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))
using Dates

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

state_dir   = mktempdir()
working_dir = mktempdir()

# --- Round 1: build, mutate, save ---------------------------------------------
let s = BonitoAgents.ServerState(;
        state_dir     = state_dir,
        working_dir   = working_dir,
        worker_secret = "rt-secret")

    # Two workers in distinct states. WorkerInfo: (worker_id, name, url,
    # secret, ssh_target, hostname, home, mcp_path, mcp_args, projects_root,
    # status, last_check) — worker_id is the stable UUID, name is the label.
    s.workers[]["alpha"] = BonitoAgents.WorkerInfo(
        "alpha", "alpha", "ws://a.example", "rt-secret", nothing,
        "alpha-host", "/home/agent", "/usr/local/bin/julia",
        ["--project=@bonito-agents", "-e", "using BonitoMCP"],
        "/var/projects", :online, now(UTC))
    s.workers[]["beta"] = BonitoAgents.WorkerInfo(
        "beta", "beta", "ws://b.example", "rt-secret", "agent@b.host",
        "beta-host", "/home/sim",   "/opt/bin/julia", String[],
        "/srv/projects",            :offline, now(UTC))

    # Three projects covering the persisted backup_status variants. Locks
    # are runtime-only — set one and verify it's NOT persisted.
    s.projects[]["pa"] = BonitoAgents.ProjectInfo(
        "pa", "ProjAlpha", "alpha",
        joinpath(working_dir, "ProjAlpha"), "/var/projects/ProjAlpha", now(UTC))
    s.projects[]["pa"].backup_status = :synced
    s.projects[]["pa"].last_sync_at  = DateTime(2026, 5, 1, 12, 0, 0)
    s.projects[]["pa"].locked_by     = "alpha"            # should NOT survive
    s.projects[]["pa"].locked_at     = now(UTC)            # should NOT survive

    s.projects[]["pb"] = BonitoAgents.ProjectInfo(
        "pb", "ProjBeta", "beta",
        joinpath(working_dir, "ProjBeta"), "/srv/projects/ProjBeta", now(UTC))
    s.projects[]["pb"].backup_status = :syncing            # should fall back to :stale
    s.projects[]["pb"].auto_prompt   = "fix issue #42"     # should survive

    s.projects[]["pc"] = BonitoAgents.ProjectInfo(
        "pc", "ProjCharlie", "alpha",
        joinpath(working_dir, "ProjCharlie"), "/var/projects/ProjCharlie", now(UTC))
    s.projects[]["pc"].resume_session_id = "abc-123"

    BonitoAgents.save_workers!(s)
    BonitoAgents.save_projects!(s)
end

TH.section("Files written") do
    record("workers.json exists", @TH.test_true isfile(joinpath(state_dir, "workers.json")))
    record("projects.json exists", @TH.test_true isfile(joinpath(state_dir, "projects.json")))
end

# --- Round 2: fresh ServerState reads the same dir ----------------------------
s2 = BonitoAgents.ServerState(;
    state_dir     = state_dir,
    working_dir   = working_dir,
    worker_secret = "rt-secret")

TH.section("Workers round-tripped") do
    record("alpha + beta both restored", @TH.test_eq length(s2.workers[]) 2)
    if haskey(s2.workers[], "alpha")
        a = s2.workers[]["alpha"]
        record("alpha hostname",      @TH.test_eq a.hostname      "alpha-host")
        record("alpha home",          @TH.test_eq a.home          "/home/agent")
        record("alpha mcp_path",      @TH.test_eq a.mcp_path      "/usr/local/bin/julia")
        record("alpha mcp_args",      @TH.test_eq a.mcp_args ["--project=@bonito-agents", "-e", "using BonitoMCP"])
        record("alpha projects_root", @TH.test_eq a.projects_root "/var/projects")
        # status is runtime-only → load resets to :unknown.
        record("alpha status reset to :unknown on load",
               @TH.test_eq a.status :unknown)
    end
    if haskey(s2.workers[], "beta")
        b = s2.workers[]["beta"]
        record("beta ssh_target round-tripped", @TH.test_eq b.ssh_target "agent@b.host")
    end
end

TH.section("Projects round-tripped") do
    record("3 projects restored", @TH.test_eq length(s2.projects[]) 3)
    if haskey(s2.projects[], "pa")
        pa = s2.projects[]["pa"]
        record("pa name",          @TH.test_eq pa.name          "ProjAlpha")
        record("pa worker_id",     @TH.test_eq pa.worker_id     "alpha")
        record("pa server_path",   @TH.test_eq pa.server_path   joinpath(working_dir, "ProjAlpha"))
        record("pa worker_path",   @TH.test_eq pa.worker_path   "/var/projects/ProjAlpha")
        record("pa backup_status", @TH.test_eq pa.backup_status :synced)
        record("pa last_sync_at",
               @TH.test_eq pa.last_sync_at DateTime(2026, 5, 1, 12, 0, 0))
        # Locks are runtime-only.
        record("pa locked_by NOT persisted", @TH.test_eq pa.locked_by nothing)
        record("pa locked_at NOT persisted", @TH.test_eq pa.locked_at nothing)
    end
    if haskey(s2.projects[], "pb")
        pb = s2.projects[]["pb"]
        # :syncing → :stale on reload (a half-completed sync isn't really synced).
        record("pb backup_status :syncing → :stale on reload",
               @TH.test_eq pb.backup_status :stale)
        record("pb auto_prompt persisted", @TH.test_eq pb.auto_prompt "fix issue #42")
    end
    if haskey(s2.projects[], "pc")
        pc = s2.projects[]["pc"]
        record("pc resume_session_id persisted",
               @TH.test_eq pc.resume_session_id "abc-123")
    end
end

# --- Round 3: missing files don't crash the constructor -----------------------
TH.section("Empty state_dir is handled gracefully") do
    empty_dir = mktempdir()
    s_empty = BonitoAgents.ServerState(;
        state_dir     = empty_dir,
        working_dir   = mktempdir(),
        worker_secret = "x")
    record("zero workers when files absent",  @TH.test_eq length(s_empty.workers[])  0)
    record("zero projects when files absent", @TH.test_eq length(s_empty.projects[]) 0)
end

# --- Round 4: malformed JSON doesn't bring the server down --------------------
TH.section("Malformed workers.json is tolerated (logs + zero workers)") do
    bad_dir = mktempdir()
    write(joinpath(bad_dir, "workers.json"), "{this is not json")
    s_bad = BonitoAgents.ServerState(;
        state_dir     = bad_dir,
        working_dir   = mktempdir(),
        worker_secret = "x")
    record("malformed JSON yields empty workers, no crash",
           @TH.test_eq length(s_bad.workers[]) 0)
end

TH.report!("Persistence round-trip", results)
