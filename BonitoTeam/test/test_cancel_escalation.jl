# Headless test: a user cancel must ALWAYS recover the UI, even when the agent
# ignores `session/cancel` (a wedged session — e.g. resumed onto an orphaned
# tool call after a worker died mid-eval). The connection stays alive, so no
# `ConnectionClosed` ever fires on its own; without escalation the busy spinner
# would stick forever. `handle_command!(::CancelCommand)` escalates: graceful
# cancel first, then a forceful connection teardown after `CANCEL_FORCE_GRACE`
# if still busy — which breaks the wedged `prompt!` loop and clears busy.

using Test
using JSON
using BonitoTeam
const BT  = BonitoTeam
const ACP = BonitoTeam.AgentClientProtocol

# A transport that completes bring-up (initialize + session/new) but then WEDGES:
# it never replies to `session/prompt` and ignores `session/cancel`. That is the
# server-visible shape of a hung agent on a live connection.
function wedged_transport()
    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg = JSON.parse(line)
                method = get(msg, "method", "")
                id     = get(msg, "id", nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>Dict())))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                        "result"=>Dict("sessionId"=>"wedged-sess"))))
                # session/prompt: deliberately NO reply, NO updates → prompt! blocks.
                # session/cancel: a notification with no id → deliberately ignored.
                end
            end
        catch e
            e isa InvalidStateException || @warn "wedged responder failed" exception=e
        end)
        return nothing
    end
    return BT.MockTransport(on_setup)
end

@testset "cancel escalation recovers a wedged turn" begin
    state = BT.ServerState(; state_dir = mktempdir(),
                             working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir(); transport = wedged_transport())
    BT.start_chat_client!(model)             # brings up the (mock) client + consumer task

    # Fire a turn. The consumer picks it up, calls prompt!, which blocks forever
    # against the wedged mock → busy goes true and stays true.
    BT.send_message!(model, BT.UserMsg("hello?"))

    @test timedwait(() -> model.busy_active[], 5.0) === :ok   # turn is in flight, spinner on

    # Graceful cancel (ignored by the mock) + escalation. After CANCEL_FORCE_GRACE
    # the handler force-closes the connection, which breaks the wedged loop. The
    # session arg is unused by the cancel handler, so `nothing` is fine.
    BT.handle_command!(model, nothing, BT.CancelCommand())

    # The core guarantee: busy clears within the grace + a beat for teardown to
    # propagate, and the session lands in the recoverable dead state (so the UI
    # shows the Restart banner). The exact `last_error` wording is best-effort —
    # the consumer's own ConnectionClosed handler may overwrite the escalation's
    # message with "ACP connection closed"; both surface a working Restart.
    @test timedwait(() -> !model.busy_active[], BT.CANCEL_FORCE_GRACE + 4.0) === :ok
    @test model.session_alive[] == false
    @test !isempty(model.last_error[])
end
