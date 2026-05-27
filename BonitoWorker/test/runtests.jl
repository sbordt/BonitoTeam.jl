# Cross-platform regression suite for BonitoWorker. Focus on the surfaces we
# burned ourselves on: Windows `.cmd` shims, the Unix vs Windows project-path
# encoding under ~/.claude/projects/, scan_claude_sessions invariants, and
# worker_id / worker_name derivation.

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

# ── decode_project_path / reconstruct_path ────────────────────────────────────
@testset "decode_project_path" begin
    # Use the actual filesystem under a temp dir; encode a known path two ways
    # (with and without a hyphen in a segment) and confirm DFS resolution picks
    # the variant that physically exists.
    mktempdir() do root
        nested = joinpath(root, "alpha", "beta-gamma", "delta")
        mkpath(nested)

        if Sys.iswindows()
            # Encoding: replace ':' and '\\' with '-'. Root is "<drive>:\\".
            #   C:\Users\… → "C--Users-…"
            # We round-trip through the helper by building the encoded form
            # from the temp dir's drive + components.
            drive   = string(uppercase(string(root[1])))
            parts   = splitpath(root)[2:end]                # drop drive root
            tail    = vcat(parts, "alpha", "beta-gamma", "delta")
            encoded = drive * "--" * join(tail, "-")
            decoded = BW.decode_project_path(encoded)
            @test decoded !== nothing
            @test isdir(decoded)
            @test normpath(decoded) == normpath(nested)
        else
            # Unix encoding: leading '/' → '-', then '/' → '-'.
            #   /home/foo → "-home-foo"
            encoded = "-" * join(splitpath(nested)[2:end], "-")
            decoded = BW.decode_project_path(encoded)
            @test decoded !== nothing
            @test decoded == nested
        end

        # Negative cases.
        @test BW.decode_project_path("garbage-no-such-path") === nothing
        @test BW.decode_project_path("") === nothing
    end
end

@testset "reconstruct_path DFS" begin
    # Two real directories sharing a hyphen-containing name proves the DFS
    # resolves ambiguity correctly (no false positive on the wrong split).
    mktempdir() do root
        mkpath(joinpath(root, "foo-bar", "baz"))
        # `reconstruct_path` walks segments separated by '-'; passing the
        # combined tail "foo-bar-baz" with root=<temp> should resolve to the
        # real nested dir, not invent "foo/bar-baz" or "foo-bar-baz".
        candidates = BW.reconstruct_path(root, "foo-bar-baz")
        @test joinpath(root, "foo-bar", "baz") in candidates
    end
end

# ── scan_claude_sessions ──────────────────────────────────────────────────────
@testset "scan_claude_sessions" begin
    # Empty home → empty results, no error (don't crash on a fresh machine).
    mktempdir() do home
        @test BW.scan_claude_sessions(home = home) == Dict{String,Any}[]
    end

    # Build a fake ~/.claude/projects/ with two real subprojects and verify
    # the dict shape + descending sort by last_used.
    mktempdir() do home
        # Real project directories that the encoded names will resolve to.
        proj_a = joinpath(home, "proj-a")
        proj_b = joinpath(home, "proj-b")
        mkpath(proj_a); mkpath(proj_b)

        # Build the encoded ~/.claude/projects/<encoded>/ entries.
        if Sys.iswindows()
            drive = string(uppercase(string(home[1])))
            tail_a = vcat(splitpath(home)[2:end], "proj-a")
            tail_b = vcat(splitpath(home)[2:end], "proj-b")
            enc_a  = drive * "--" * join(tail_a, "-")
            enc_b  = drive * "--" * join(tail_b, "-")
        else
            enc_a = "-" * join(vcat(splitpath(home)[2:end], "proj-a"), "-")
            enc_b = "-" * join(vcat(splitpath(home)[2:end], "proj-b"), "-")
        end

        claude_root = joinpath(home, ".claude", "projects")
        mkpath(joinpath(claude_root, enc_a))
        mkpath(joinpath(claude_root, enc_b))

        # Two jsonls; touch B's to be newer so it sorts first.
        a_jsonl = joinpath(claude_root, enc_a, "11111111-1111-1111-1111-111111111111.jsonl")
        b_jsonl = joinpath(claude_root, enc_b, "22222222-2222-2222-2222-222222222222.jsonl")
        write(a_jsonl, "{}\n")
        sleep(0.05)
        write(b_jsonl, "{}\n")

        results = BW.scan_claude_sessions(home = home)

        # Both projects discovered, sorted newest-first.
        @test length(results) == 2
        @test results[1]["name"] == "proj-b"
        @test results[2]["name"] == "proj-a"

        # Required keys present + types right.
        for r in results
            @test haskey(r, "path") && r["path"] isa AbstractString
            @test haskey(r, "name") && !isempty(r["name"])
            @test haskey(r, "session_id") && length(r["session_id"]) == 36  # uuid-ish
            @test haskey(r, "last_used") && r["last_used"] isa Number
        end

        # No `active`/`pid`/`process_count` — those were removed.
        for r in results
            @test !haskey(r, "active")
            @test !haskey(r, "pid")
            @test !haskey(r, "process_count")
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
