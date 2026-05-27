# Cross-platform regression suite for BonitoWorker. Focus on the surfaces we
# burned ourselves on: Windows `.cmd` shims, scan_claude_sessions invariants
# (cwd from jsonl content, not folder name), and worker_id / worker_name
# derivation.

using Test
using BonitoWorker
const BW = BonitoWorker

@testset "BonitoWorker" begin

# ── which_executable ──────────────────────────────────────────────────────────
# Tests the contract directly via a planted file on a temp PATH dir — avoids
# depending on real-world PATH layout (Pkg.test sandboxes PATH; CI machines
# may or may not have `npm` etc.).
@testset "which_executable" begin
    mktempdir() do dir
        old_path = get(ENV, "PATH", "")
        sep = Sys.iswindows() ? ';' : ':'
        ENV["PATH"] = dir * sep * old_path
        try
            @test BW.which_executable("definitely-not-a-real-bin-xyz-9999") === nothing

            if Sys.iswindows()
                # The whole reason which_executable exists: Sys.which on
                # Windows doesn't walk PATHEXT for .cmd/.bat shims, so
                # plain `Sys.which("foo")` returns nothing for a .cmd file
                # but `which_executable("foo")` must find it.
                cmd_file = joinpath(dir, "fake_helper_xyz.cmd")
                write(cmd_file, "@echo off\r\necho ok\r\n")
                @test Sys.which("fake_helper_xyz") === nothing            # contract baseline
                hit = BW.which_executable("fake_helper_xyz")
                @test hit !== nothing
                @test endswith(lowercase(String(hit)), ".cmd")
                # Also: .bat variant resolves.
                bat_file = joinpath(dir, "another_helper_xyz.bat")
                write(bat_file, "@echo off\r\necho ok\r\n")
                @test endswith(lowercase(String(BW.which_executable("another_helper_xyz"))), ".bat")
            else
                # On Unix `Sys.which` already walks PATH correctly; the
                # wrapper just delegates. Plant an executable and verify
                # the wrapper returns the same path.
                bin = joinpath(dir, "fake_helper_xyz")
                write(bin, "#!/bin/sh\necho ok\n")
                chmod(bin, 0o755)
                @test BW.which_executable("fake_helper_xyz") == Sys.which("fake_helper_xyz")
            end
        finally
            ENV["PATH"] = old_path
        end
    end
end

# ── scan_claude_sessions ──────────────────────────────────────────────────────
@testset "scan_claude_sessions" begin
    # Empty home → empty results, no error (don't crash on a fresh machine).
    mktempdir() do home
        @test BW.scan_claude_sessions(home = home) == Dict{String,Any}[]
    end

    # Build a fake ~/.claude/projects/ with two subprojects and verify the
    # dict shape + descending sort by last_used. The encoded folder name is
    # NOT parsed by the new scanner — we read `cwd` directly from the jsonl
    # content. So the folder name is arbitrary; the jsonl payload is what
    # matters.
    mktempdir() do home
        proj_a = joinpath(home, "proj-a")
        proj_b = joinpath(home, "proj-b")
        mkpath(proj_a); mkpath(proj_b)

        claude_root = joinpath(home, ".claude", "projects")
        # Arbitrary folder names; deliberately NOT a valid encoding of the
        # cwd — this proves we don't rely on folder-name decoding anymore.
        mkpath(joinpath(claude_root, "enc-a"))
        mkpath(joinpath(claude_root, "enc-b"))

        # Two jsonls. First line carries the cwd field; that's all the
        # scanner needs. Touch B's after A so B sorts first by mtime.
        a_jsonl = joinpath(claude_root, "enc-a", "11111111-1111-1111-1111-111111111111.jsonl")
        b_jsonl = joinpath(claude_root, "enc-b", "22222222-2222-2222-2222-222222222222.jsonl")
        write(a_jsonl, """{"cwd":"$(escape_string(proj_a))"}\n""")
        sleep(0.05)
        write(b_jsonl, """{"cwd":"$(escape_string(proj_b))"}\n""")

        results = BW.scan_claude_sessions(home = home)

        # Both projects discovered, sorted newest-first.
        @test length(results) == 2
        @test results[1]["name"] == "proj-b"
        @test results[2]["name"] == "proj-a"
        @test results[1]["path"] == proj_b
        @test results[2]["path"] == proj_a

        # Required keys present + types right.
        for r in results
            @test haskey(r, "path") && r["path"] isa AbstractString
            @test haskey(r, "name") && !isempty(r["name"])
            @test haskey(r, "session_id") && length(r["session_id"]) == 36  # uuid-ish
            @test haskey(r, "last_used") && r["last_used"] isa Number
        end

        # New optional fields are present with their default values: no
        # sessions/<pid>.json in the fake home → not running; no user
        # message in the jsonl → no preview; no subagents/ dir → kind=session.
        for r in results
            @test r["kind"] == "session"
            @test r["running"] === false
            @test r["pid"] === nothing
            @test r["first_prompt"] === nothing
            @test r["agent_type"] === nothing
            @test r["parent_session_id"] === nothing
        end

        # Unique paths (the scanner never duplicates).
        @test length(unique(r["path"] for r in results)) == length(results)
    end
end

# ── default_worker_name + generate_worker_id ─────────────────────────────────
@testset "default_worker_name" begin
    name = BW.default_worker_name("abcd-1234-5678-9012-345678901234")
    @test !isempty(name)
    @test !isnothing(name)
end

@testset "generate_worker_id" begin
    id = BW.generate_worker_id()
    @test length(id) == 36            # 8-4-4-4-12
    @test count(==('-'), id) == 4
    parts = split(id, '-')
    @test length.(parts) == [8, 4, 4, 4, 12]
    @test all(c -> isdigit(c) || ('a' <= lowercase(c) <= 'f'),
              filter(!=( '-'), id))
    # Two calls produce distinct ids (overlap → seed is wrong).
    @test BW.generate_worker_id() != BW.generate_worker_id()
end

end  # BonitoWorker

# Real-agent integration test — separate file because it boots a subprocess
# and stands up an HTTP+WS server. Skipped automatically when
# claude-agent-acp isn't on PATH (so unit-only environments stay green).
include("test_real_agent.jl")
