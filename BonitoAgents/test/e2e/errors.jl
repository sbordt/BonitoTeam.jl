# End-to-end error rendering, UI-only via TestKit. No internal-API calls.
#
# When the agent is alive but answers a prompt with a JSON-RPC error, the chat
# shows the failure inline as an `[error: ...]` bubble, in line with the
# conversation, and the busy indicator clears (the turn's finally block runs).
#
# NOT covered here: the transport-DEATH path (agent process dies mid-turn ->
# session_alive=false -> the header restart button goes "dead"). That depends
# on the transport error being classified by `is_session_dead_error`, and
# overlaps the restart suite — left in ../electron/test_chat_errors.jl.
#
# Run:  julia --project=. test/e2e/errors.jl

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const ERR_MSG = "model overloaded, please retry"
agent_script(_prompt) = [TK.error_reply(ERR_MSG)]

has_inline_error = "[...document.querySelectorAll('.bt-agent-msg')].some(b => (b.innerText || '').includes('[error:'))"
busy_inactive = "!(document.querySelector('.bt-busy') || {classList:{contains:() => false}}).classList.contains('bt-busy-active')"

server = TK.dev_server(agent = agent_script)
try
    TK.open_browser(server)

    @testset "BonitoAgents error rendering (UI-only)" begin
        TK.new_chat(server; title = "Errors")
        TK.send_message(server, "do the thing")

        @testset "an error reply becomes an inline [error: ...] bubble" begin
            @test TK.wait_for(server, "inline error bubble", has_inline_error; timeout = 12) == true
            @test occursin(ERR_MSG, TK.eval_js(server,
                "([...document.querySelectorAll('.bt-agent-msg')].find(b => (b.innerText || '').includes('[error:')) || {}).innerText || ''"))
        end

        @testset "the busy indicator clears after the failed turn" begin
            @test TK.wait_for(server, "busy cleared", busy_inactive; timeout = 8) == true
        end
    end
finally
    close(server)
end

# Suite passed if we reach here (a failing @testset throws first); force-terminate.
# A degraded headless Electron / wedged poller thread can otherwise stall Julia's
# normal exit until the CI step timeout. See TestKit.exit_success.
TK.exit_success()
