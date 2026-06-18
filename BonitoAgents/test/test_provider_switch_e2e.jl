# E2e test for provider switching via the mock-claude-agent-acp BINARY
# (TestKit) — real dev_server, real worker, real WorkerTransport, real ACP
# wire, real Electron browser. Gated on BT_RUN_E2E=1.

using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, end_turn

if get(ENV, "BT_RUN_E2E", "") != "1"
    @info "skipping test_provider_switch_e2e.jl (set BT_RUN_E2E=1)"
else
@testset "e2e: provider switch via UI dropdown (MockCode <-> ClaudeCode)" begin
    s = TK.dev_server(; agent = msg -> [text("reply: $(msg)"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s; title = "switch e2e")
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(3)

        initial_val = TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            return sel ? sel.value : null;
        })()""")
        @test initial_val !== nothing

        # Send initial message
        TK.send_message(s, "hello initial")
        TK.wait_for(s, "agent msg",
            """document.querySelectorAll('.bt-agent-msg').length >= 1"""; timeout = 30)
        sleep(1)

        agent_text = TK.eval_js(s, """(() => {
            const msgs = document.querySelectorAll('.bt-agent-msg');
            return msgs.length > 0 ? msgs[msgs.length-1].textContent : '';
        })()""")
        @test occursin("reply:", agent_text)

        # Switch to MockCode via dropdown
        TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            sel.value = 'MockCode';
            sel.dispatchEvent(new Event('change'));
            return true;
        })()""")
        sleep(4)

        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        @test model.provider[] == BonitoAgents.MockCode
        @test model.session_alive[] == true
        @test isempty(model.last_error[])

        # Send message after MockCode switch
        TK.send_message(s, "hello mock")
        TK.wait_for(s, "agent msg after MockCode",
            """document.querySelectorAll('.bt-agent-msg').length >= 2"""; timeout = 30)
        sleep(1)

        # Switch back to ClaudeCode
        TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            sel.value = 'ClaudeCode';
            sel.dispatchEvent(new Event('change'));
            return true;
        })()""")
        sleep(4)

        val = TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            return sel ? sel.value : null;
        })()""")
        @test val == "ClaudeCode"
        @test model.provider[] == BonitoAgents.ClaudeCode

        # Final message
        TK.send_message(s, "hello back")
        TK.wait_for(s, "agent msg after switch back",
            """document.querySelectorAll('.bt-agent-msg').length >= 3"""; timeout = 30)

        @info "E2E provider switch test passed"
    finally
        close(s)
    end
end
end
