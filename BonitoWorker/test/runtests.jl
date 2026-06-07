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

# ── first_prompt extraction ──────────────────────────────────────────────────
# The discover preview must show what the user TYPED, not the pseudo-XML context
# Claude Code injects into the first user messages (ide_opened_file, system
# reminders, slash-command wrappers, local-command caveats). meaningful_prompt
# strips leading context blocks and skips wholly-injected messages (→ nothing,
# so the scan keeps looking for a real prompt).
@testset "first_prompt extraction (skip injected context)" begin
    # Wholly injected / tooling-noise messages → nothing (scan skips them).
    @test BW.meaningful_prompt("<ide_opened_file>The user opened /x/a.md in the IDE.</ide_opened_file>") === nothing
    @test BW.meaningful_prompt("Caveat: The messages below were generated by the user while running local commands. DO NOT respond") === nothing
    @test BW.meaningful_prompt("<command-name>/compact</command-name><command-message>compact</command-message>") === nothing
    @test BW.meaningful_prompt("<system-reminder>As you answer…</system-reminder>") === nothing
    @test BW.meaningful_prompt("   ") === nothing

    # Real prose survives, and leading context blocks are stripped off it.
    @test BW.meaningful_prompt("fix the parser bug") == "fix the parser bug"
    @test BW.meaningful_prompt("<ide_selection>lines 1-2</ide_selection>Ich arbeite am Plan!") == "Ich arbeite am Plan!"
    @test BW.meaningful_prompt("<ide_opened_file>opened X</ide_opened_file>\n\nrun the tests") == "run the tests"

    # first_user_text: returns nothing for non-user / injected records, prose
    # (clean_preview-collapsed) for real ones.
    mkrec(content) = Dict("type"=>"user", "message"=>Dict("role"=>"user","content"=>content))
    @test BW.first_user_text(mkrec("<ide_opened_file>opened</ide_opened_file>")) === nothing
    @test BW.first_user_text(mkrec("hello   world")) == "hello world"
    @test BW.first_user_text(mkrec([Dict("type"=>"text","text"=>"<system-reminder>x</system-reminder>")])) === nothing
    @test BW.first_user_text(mkrec([Dict("type"=>"text","text"=>"real question?")])) == "real question?"
    @test BW.first_user_text(Dict("type"=>"assistant","message"=>Dict("role"=>"assistant","content"=>"hi"))) === nothing
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

# ── singleton pidfile guard ──────────────────────────────────────────────────
# A duplicate worker sharing the persisted worker_id fights the original over
# the server's control-WS registration. The pidfile guard makes start()/
# spawn_worker refuse when a live worker already holds the slot. We test the
# path-injectable predicates against a temp file so the real scratch pidfile is
# never touched (which would block the user's actual worker).
@testset "pidfile singleton guard" begin
    mktempdir() do dir
        pf = joinpath(dir, "sub", "worker.pid")   # nested → also tests mkpath

        # Empty slot: no file → free.
        @test BW.read_pidfile(pf) === nothing
        @test BW.running_worker_pid(pf) === nothing

        # Our own pid recorded → not "another" worker (re-entry is fine).
        mkpath(dirname(pf))
        write(pf, string(getpid()))
        @test BW.read_pidfile(pf) == getpid()
        @test BW.running_worker_pid(pf) === nothing

        # Stale file pointing at a dead pid → slot free (overwritable).
        write(pf, "999999")
        @test BW.process_running(999999) === false
        @test BW.running_worker_pid(pf) === nothing

        # A live OTHER pid → blocked. pid 1 (init/launchd) is always alive and
        # never us; on Unix kill(1,0) → EPERM which process_running maps to true.
        write(pf, "1")
        @test BW.process_running(1) === true
        @test BW.running_worker_pid(pf) == 1

        # Garbage content → nothing (never throws).
        write(pf, "not-a-pid")
        @test BW.read_pidfile(pf) === nothing
        @test BW.running_worker_pid(pf) === nothing

        # claim_pidfile! records our pid and creates parent dirs.
        rm(pf; force = true)
        BW.claim_pidfile!(pf)
        @test BW.read_pidfile(pf) == getpid()
    end
end

# ── systemd service: unit rendering + run-mode decision ──────────────────────
# Only the PURE pieces are tested here — we never invoke `systemctl` (that would
# touch the real user systemd). render_service_unit is a pure string builder;
# decide_run_mode is the pure answer→mode map factored out of the tty IO.
@testset "service unit rendering" begin
    u = BW.render_service_unit(; julia = "/opt/julia/bin/julia",
                                 projects_root = "/home/u/projs",
                                 memory_max = "80%",
                                 path_env = "/usr/bin:/home/u/.local/bin")
    # ExecStart launches start() in the shared env.
    @test occursin("ExecStart=/opt/julia/bin/julia --project=@bonito-team", u)
    @test occursin("BonitoWorker.start()", u)
    # PATH is baked in (systemd --user doesn't inherit the shell PATH; without
    # this the worker can't find claude-agent-acp/node/git at runtime).
    @test occursin("Environment=PATH=/usr/bin:/home/u/.local/bin", u)
    # Crash-restart, memory cap, boot target, workdir.
    @test occursin("Restart=on-failure", u)
    @test occursin("MemoryMax=80%", u)
    @test occursin("WantedBy=default.target", u)
    @test occursin("WorkingDirectory=/home/u/projs", u)
    # Pure: identical inputs → byte-identical output (so install can diff for
    # idempotency — only rewrite+reload when the unit actually changed).
    @test u == BW.render_service_unit(; julia = "/opt/julia/bin/julia",
                                        projects_root = "/home/u/projs",
                                        memory_max = "80%",
                                        path_env = "/usr/bin:/home/u/.local/bin")
end

@testset "run-mode decision" begin
    # Explicit answers.
    @test BW.decide_run_mode("1", false) == :service
    @test BW.decide_run_mode("1", true)  == :service
    @test BW.decide_run_mode("2", false) == :background
    @test BW.decide_run_mode("2", true)  == :background
    @test BW.decide_run_mode("", false)  == :service       # bare Enter → default
    @test BW.decide_run_mode("yes", true) == :service      # anything not "2" → service
    # No answer (no tty / timed out): keep an existing service, else background —
    # never silently enable a boot service in a non-interactive context, never
    # silently downgrade an existing one.
    @test BW.decide_run_mode(nothing, true)  == :service
    @test BW.decide_run_mode(nothing, false) == :background
end

end  # BonitoWorker

# Real-agent integration test — separate file because it boots a subprocess
# and stands up an HTTP+WS server. Skipped automatically when
# claude-agent-acp isn't on PATH (so unit-only environments stay green).
include("test_real_agent.jl")
