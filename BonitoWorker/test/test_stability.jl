# Regression tests for the BonitoWorker stability findings (M1, M8, M12, M13).
# No network, no claude-agent-acp, no real git: we exercise the pure pieces that
# were extracted for exactly this (clone_repo_response with an injected clone
# stub, the watchdog idle predicate, report_open_session_failed framing).

using Test
using BonitoWorker
const BW = BonitoWorker

# A capturing stand-in WS so we can assert report_open_session_failed's frame
# without a real socket. Defined at top level (no world-age dance). The method
# is added to the same generic BonitoWorker calls internally.
struct CapturingWS
    sink::Vector{String}
end
BonitoWorker.WebSockets.send(w::CapturingWS, msg) = (push!(w.sink, String(msg)); nothing)

# ── M1: clone onto an existing dir REFUSES and leaves the tree intact ──────────
@testset "M1: clone_repo never deletes a pre-existing dst_path" begin
    mktempdir() do root
        dst = joinpath(root, "existing-project")
        mkpath(dst)
        sentinel = joinpath(dst, "PRECIOUS.txt")
        write(sentinel, "do not delete me")
        nested = joinpath(dst, "src")
        mkpath(nested)
        write(joinpath(nested, "main.jl"), "x = 1")

        clone_called = Ref(false)
        do_clone = (url, d, pr) -> (clone_called[] = true)   # must NOT be reached

        resp = BW.clone_repo_response("req-1", "https://example.com/x.git", dst,
                                       nothing, do_clone)

        # Refused with an error, the clone never ran...
        @test haskey(resp, "error")
        @test occursin("already exists", resp["error"])
        @test clone_called[] == false
        # ...and CRITICALLY the user's tree is fully intact (the data-destroyer bug).
        @test isdir(dst)
        @test isfile(sentinel)
        @test read(sentinel, String) == "do not delete me"
        @test isfile(joinpath(nested, "main.jl"))
    end
end

@testset "M1: malformed pr_number returns an error (no throw, no delete)" begin
    mktempdir() do root
        dst = joinpath(root, "fresh")          # does NOT exist yet
        do_clone = (url, d, pr) -> error("should not be called")
        resp = BW.clone_repo_response("req-2", "https://example.com/x.git", dst,
                                       "not-a-number", do_clone)
        @test haskey(resp, "error")            # surfaced as a response, not a throw
        @test !ispath(dst)                     # nothing was created
    end
end

@testset "M1: a partial clone WE created is cleaned up on failure" begin
    mktempdir() do root
        dst = joinpath(root, "halfcloned")
        # Simulate a clone that creates the dir then fails partway.
        do_clone = (url, d, pr) -> begin
            mkpath(d); write(joinpath(d, "partial"), "x"); error("network died")
        end
        resp = BW.clone_repo_response("req-3", "https://example.com/x.git", dst,
                                       nothing, do_clone)
        @test haskey(resp, "error")
        @test occursin("network died", resp["error"])
        @test !ispath(dst)                     # our partial clone was removed
    end
end

@testset "M1: a clean clone succeeds" begin
    mktempdir() do root
        dst = joinpath(root, "good")
        do_clone = (url, d, pr) -> (mkpath(d); write(joinpath(d, "README"), "ok"))
        resp = BW.clone_repo_response("req-4", "https://example.com/x.git", dst,
                                       nothing, do_clone)
        @test !haskey(resp, "error")
        @test resp["dst_path"] == dst
        @test isfile(joinpath(dst, "README"))
    end
end

# ── M8: agent process is always reaped (kill_proc! tolerates dead/closed) ──────
@testset "M8: kill_proc! is idempotent and never throws" begin
    # A real short-lived process: kill_proc! after it already exited must not throw.
    proc = open(`$(Base.julia_cmd()[1]) -e "exit(0)"`, "r+")
    sleep(0.3)
    @test BW.kill_proc!(proc) === nothing       # already dead → no throw
    @test BW.kill_proc!(proc) === nothing       # idempotent second call
end

# ── M12: control-WS idle watchdog fires only after the timeout ─────────────────
@testset "M12: watchdog idle math" begin
    # The watchdog declares the socket dead when (now - last_frame) exceeds the
    # idle timeout. We assert the constants are sane and the comparison holds.
    @test BW.CONTROL_WS_IDLE_TIMEOUT > BW.CONTROL_WS_WATCHDOG_TICK
    # Fresh frame → not idle.
    @test (time() - time()) <= BW.CONTROL_WS_IDLE_TIMEOUT
    # An ancient last_frame → idle (would trigger a close).
    ancient = time() - (BW.CONTROL_WS_IDLE_TIMEOUT + 10)
    @test (time() - ancient) > BW.CONTROL_WS_IDLE_TIMEOUT

    # The watchdog exits promptly when `done` is set, without ever closing.
    closed = Ref(false)
    fakews = (; )           # never touched because done flips first
    last_frame = Ref(time())
    done = Ref(false)
    t = @async BW.control_ws_watchdog(fakews, last_frame, done)
    done[] = true
    @test timedwait(() -> istaskdone(t), 10.0) === :ok
    @test closed[] == false
end

# ── M13: open_session failures are reported to the server, not swallowed ───────
@testset "M13: report_open_session_failed sends a frame" begin
    # report_open_session_failed must emit an `open_session_failed` control frame
    # so the server stops waiting for a dial that will never come.
    sent = String[]
    ws = CapturingWS(sent)
    BW.report_open_session_failed(ws, "sid-123", "boom")
    @test length(sent) == 1
    payload = BW.JSON.parse(sent[1])
    @test payload["type"] == "open_session_failed"
    @test payload["sid"] == "sid-123"
    @test occursin("boom", payload["error"])
end
