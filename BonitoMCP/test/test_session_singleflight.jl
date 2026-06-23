# Single-flight session creation. Concurrent `get_or_create!` for one env_path
# must spawn EXACTLY ONE Malt worker (never duplicates), the in-flight marker is
# always cleared afterwards (no per-key lock registry left to leak), and
# restart / failed-build / shutdown keep `sessions` + `creating` consistent.
# Guards the rewrite that replaced the old unbounded `create_locks` dict.

using Test
using BonitoMCP
const M = BonitoMCP

@testset "single-flight session creation" begin
    sm = M.SessionManager()
    try
        env = mktempdir(); write(joinpath(env, "Project.toml"), "")

        @testset "N concurrent calls → one session, marker cleared" begin
            # Threads.@spawn so this is real parallel contention, not just tasks.
            tasks = [Threads.@spawn M.get_or_create!(sm, env) for _ in 1:16]
            ss = [fetch(t) for t in tasks]
            @test all(s -> s === ss[1], ss)     # single-flight: one shared session
            @test M.is_alive(ss[1])
            @test length(sm.sessions) == 1      # exactly one worker, not 16
            @test isempty(sm.creating)          # in-flight marker removed (no leak)
        end

        @testset "fast path reuses the live session" begin
            s1 = M.get_or_create!(sm, env)
            s2 = M.get_or_create!(sm, env)
            @test s1 === s2
            @test isempty(sm.creating)
        end

        @testset "restart! drops it; next call rebuilds fresh" begin
            old = M.get_or_create!(sm, env)
            M.restart!(sm, env)
            @test isempty(sm.sessions)
            @test !M.is_alive(old)
            new = M.get_or_create!(sm, env)
            @test new !== old && M.is_alive(new)
        end

        @testset "failed build rethrows + clears the marker (retry-able)" begin
            bad = mktempdir(); write(joinpath(bad, "Project.toml"), "")
            @test_throws Exception M.get_or_create!(sm, bad;
                                       julia_cmd = "julia +no_such_channel_xyz")
            @test isempty(sm.creating)                  # marker cleared → a retry works
            @test !haskey(sm.sessions, abspath(bad))    # no zombie session entry
        end
    finally
        M.shutdown!(sm)
        @test isempty(sm.sessions)
    end
end
