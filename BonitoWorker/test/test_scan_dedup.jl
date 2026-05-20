# Unit tests for the claude-process dedup logic. Multiple concurrent
# `claude` processes for the same cwd (e.g. claude-agent-acp child +
# VS Code Claude Code extension + another tool's claude) used to surface
# as multiple rows in the Discover panel. `collapse_processes_by_cwd`
# now folds them into one entry per cwd with `process_count` set.

using Test
using BonitoWorker

@testset "collapse_processes_by_cwd" begin
    @testset "empty input" begin
        out = BonitoWorker.collapse_processes_by_cwd(
            Tuple{Int,String}[], Dict{String,String}())
        @test isempty(out)
    end

    @testset "single process" begin
        out = BonitoWorker.collapse_processes_by_cwd(
            [(100, "/a")], Dict{String,String}())
        @test length(out) == 1
        @test out[1]["pid"] == 100
        @test out[1]["path"] == "/a"
        @test out[1]["name"] == "a"
        @test out[1]["active"] === true
        @test !haskey(out[1], "process_count")
    end

    @testset "multiple processes same cwd → one entry, lowest pid" begin
        out = BonitoWorker.collapse_processes_by_cwd(
            [(500, "/a"), (100, "/a"), (300, "/a")], Dict{String,String}())
        @test length(out) == 1
        @test out[1]["pid"] == 100
        @test out[1]["process_count"] == 3
    end

    @testset "different cwds stay separate" begin
        out = BonitoWorker.collapse_processes_by_cwd(
            [(100, "/a"), (200, "/b"), (300, "/c"), (400, "/a")],
            Dict{String,String}())
        @test length(out) == 3
        @test sort([r["path"] for r in out]) == ["/a", "/b", "/c"]
        a = first(r for r in out if r["path"] == "/a")
        @test a["pid"] == 100
        @test a["process_count"] == 2
        b = first(r for r in out if r["path"] == "/b")
        @test b["pid"] == 200
        @test !haskey(b, "process_count")
    end

    @testset "session_id pulled from sid_by_cwd" begin
        out = BonitoWorker.collapse_processes_by_cwd(
            [(100, "/a"), (200, "/a"), (300, "/b")],
            Dict("/a" => "sess-abc"))
        a = first(r for r in out if r["path"] == "/a")
        b = first(r for r in out if r["path"] == "/b")
        @test a["session_id"] == "sess-abc"
        @test !haskey(b, "session_id")
    end
end

@testset "scan_claude_sessions invariant" begin
    # Whatever processes happen to be running on this machine, every
    # unique cwd should appear at most once in the active results.
    results = BonitoWorker.scan_claude_sessions()
    active  = filter(r -> get(r, "active", false) === true, results)
    cwds    = [String(r["path"]) for r in active]
    @test length(cwds) == length(unique(cwds))
end
