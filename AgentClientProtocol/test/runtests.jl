using AgentClientProtocol
using Test
using JSON

const ACP = AgentClientProtocol

# ── Mock transport ──────────────────────────────────────────────────────────
# A channel-backed Transport: `send` captures the client's outgoing JSON lines
# (so the test can inspect ids / reply to them) and `recv` blocks on an inbox
# the test feeds. No subprocess, no node, no claude-agent-acp.
mutable struct MockTransport <: ACP.Transport
    inbox     :: Channel{String}      # test → client (frames the client reads)
    outbox    :: Channel{String}      # client → test (frames the client wrote)
    closed    :: Bool
    eof       :: Bool                 # when true, recv returns "" and reports EOF
end
MockTransport() = MockTransport(Channel{String}(Inf), Channel{String}(Inf), false, false)

ACP.send(t::MockTransport, line::AbstractString) = (put!(t.outbox, String(line)); nothing)
function ACP.recv(t::MockTransport)
    t.eof && return ""
    try
        return take!(t.inbox)
    catch
        return ""
    end
end
ACP.transport_eof(t::MockTransport) = t.eof || t.closed
function Base.close(t::MockTransport)
    t.closed = true
    t.eof = true
    isopen(t.inbox) && close(t.inbox)
    return nothing
end

# Feed a JSON-RPC response frame for request `id` into the client.
push_response!(t::MockTransport, id, result) =
    put!(t.inbox, JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "result" => result)))

# Read the next outgoing frame the client wrote (the request it just sent).
next_out(t::MockTransport) = JSON.parse(take!(t.outbox))

@testset "AgentClientProtocol stability" begin

    # ── A1: concurrent register/respond never drops a pending entry ──────────
    # Many tasks each fire a send_request concurrently; a responder task replies
    # to every id it sees. With the lock around pending, every caller gets its
    # reply; an unlocked dict would drop entries under contention → take! hangs.
    @testset "A1 concurrent register/respond loses nothing" begin
        t = MockTransport()
        conn = ACP.Connection(t)
        N = 200
        # Responder: for each outgoing request, echo a response with the same id.
        responder = @async begin
            for _ in 1:N
                msg = next_out(t)
                push_response!(t, msg["id"], Dict("ok" => msg["id"]))
            end
        end
        results = Vector{Any}(undef, N)
        @sync for i in 1:N
            @async begin
                r = ACP.send_request(conn, "ping", Dict("n" => i))
                results[i] = r["ok"]
            end
        end
        wait(responder)
        @test sort(Int.(results)) == collect(0:N-1)   # ids 0..N-1, none lost
        close(conn)
    end

    # ── A2: requests after teardown throw ConnectionClosed, never hang ───────
    @testset "A2 send_request after close throws ConnectionClosed" begin
        t = MockTransport()
        conn = ACP.Connection(t)
        close(conn)
        # Give the dispatcher's finally a moment to flip `closed` under the lock.
        for _ in 1:100
            conn.closed && break
            sleep(0.01)
        end
        @test conn.closed
        @test_throws ACP.ConnectionClosed ACP.send_request(conn, "ping", Dict())
        @test_throws ACP.ConnectionClosed ACP.request_updates(conn, "session/load", Dict())
    end

    # ── A2/teardown: a pending request in flight is failed with ConnectionClosed
    @testset "A2 in-flight request fails with ConnectionClosed on teardown" begin
        t = MockTransport()
        conn = ACP.Connection(t)
        fut = @async ACP.send_request(conn, "ping", Dict())
        _ = next_out(t)            # ensure it registered + sent
        close(conn)
        # `fetch` on a failed Task wraps the cause in TaskFailedException;
        # unwrap to assert the in-flight request was failed with ConnectionClosed.
        cause = try
            fetch(fut); nothing
        catch e
            e isa TaskFailedException ? e.task.exception : e
        end
        @test cause isa ACP.ConnectionClosed
    end

    # ── A8: a second concurrent turn errors instead of orphaning the first ───
    @testset "A8 overlapping turn errors" begin
        t = MockTransport()
        conn = ACP.Connection(t)
        u1, r1 = ACP.request_updates(conn, "session/prompt", Dict())
        _ = next_out(t)
        @test_throws ErrorException ACP.request_updates(conn, "session/prompt", Dict())
        close(conn)
    end

    # ── A7: drop-oldest delivery never blocks the dispatcher ─────────────────
    # Fill the active-updates channel past its bound while the consumer is
    # absent; deliver_update! must keep returning (dropping oldest) rather than
    # blocking forever.
    @testset "A7 deliver_update! drop-oldest never blocks" begin
        ch = Channel{ACP.SessionUpdate}(4)
        mk(i) = ACP.UnknownUpdate("u$i", Dict{String,Any}())
        done = Channel{Bool}(1)
        @async begin
            for i in 1:1000
                ACP.deliver_update!(ch, mk(i))
            end
            put!(done, true)
        end
        # Without drop-oldest this @async would block at slot 5 forever.
        @test take!(done) == true
        @test Base.n_avail(ch) <= 4         # never exceeded the bound
        # Closed channel is a no-op, not an error.
        close(ch)
        @test ACP.deliver_update!(ch, mk(1)) === nothing
    end

    # ── A7 (tool updates): push_snapshot! drop-oldest never blocks ───────────
    @testset "A7 push_snapshot! drop-oldest never blocks" begin
        ch = Channel{ACP.ToolCall}(2)
        tc = ACP.GenericTool("id1", "execute", "t", "in_progress", ACP.ToolContent[])
        done = Channel{Bool}(1)
        @async begin
            for _ in 1:500
                ACP.push_snapshot!(ch, tc)
            end
            put!(done, true)
        end
        @test take!(done) == true
        @test Base.n_avail(ch) <= 2
    end

    # ── A4: a stray blank line does NOT tear the connection down ─────────────
    @testset "A4 blank line is skipped, not treated as EOF" begin
        t = MockTransport()
        conn = ACP.Connection(t)
        put!(t.inbox, "")                     # stray blank line (not EOF)
        # Now a real request still works: register + reply.
        fut = @async ACP.send_request(conn, "ping", Dict())
        msg = next_out(t)
        push_response!(t, msg["id"], Dict("ok" => true))
        @test fetch(fut)["ok"] == true
        @test !conn.closed                    # blank line didn't tear us down
        close(conn)
    end

    # ── A3: setup failure closes the transport (no leaked process) ───────────
    # We exercise the Client setup path's contract via a Connection over a mock
    # transport: when a setup RPC errors, the caller closes the connection,
    # which closes the transport. (Client() itself can't be tested without a
    # binary, but it wraps exactly this in try/catch → close(conn) + rethrow.)
    @testset "A3 setup RPC error closes the connection/transport" begin
        t = MockTransport()
        conn = ACP.Connection(t)
        # Reply to the first request with a JSON-RPC error.
        responder = @async begin
            msg = next_out(t)
            put!(t.inbox, JSON.json(Dict("jsonrpc" => "2.0", "id" => msg["id"],
                "error" => Dict("code" => -32000, "message" => "boom"))))
        end
        threw = false
        try
            ACP.send_request(conn, "initialize", Dict())
        catch
            threw = true
            close(conn)               # mirrors Client()'s catch → close(conn)
        end
        wait(responder)
        @test threw
        @test t.closed                # transport torn down, process would be reaped
    end

    # ── A3 (timeout): a wedged setup RPC times out instead of hanging ────────
    @testset "A3 setup RPC times out on a silent agent" begin
        t = MockTransport()
        conn = ACP.Connection(t)
        # Never reply. The timeout variant must raise ConnectionClosed.
        @test_throws ACP.ConnectionClosed ACP.send_request(conn, "initialize", Dict(), 0.2)
        close(conn)
    end

    # ── A8: cancel! is a no-op when idle (no active turn) ────────────────────
    @testset "A8 cancel is a no-op when idle" begin
        t = MockTransport()
        conn = ACP.Connection(t)
        client = ACP.Client(conn, "sess-1", pwd())
        ACP.cancel!(client)
        @test !(@atomic conn.cancelling)      # not latched → next turn renders
        @test !isready(t.outbox)              # no session/cancel sent
        close(conn)
    end
end
