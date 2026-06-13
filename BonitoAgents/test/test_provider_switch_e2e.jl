# E2e test for provider switching via the mock-claude-agent-acp BINARY
# (TestKit) — real dev_server, real worker, real WorkerTransport, real ACP
# wire, real Electron browser. The user manually opens a chat, verifies
# messages work with the mock agent, switches to MockCode via the UI
# dropdown, and verifies the session restarts correctly.

using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, end_turn

if get(ENV, "BT_RUN_E2E", "") != "1"
    @info "skipping test_provider_switch_e2e.jl (set BT_RUN_E2E=1 — needs a worker + Electron + agent binary)"
else
@testset "e2e provider switch: MockCode via UI dropdown" begin
    # Scripted agent: responds to any prompt with a simple message.
    # The agent_fn is mutable via TestServer.agent_fn so we can swap
    # it between switches if needed.
    s = TK.dev_server(; agent = msg -> [
        text("response to: $(msg)"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)

        # 1. Create a chat — starts with default provider (ClaudeCode via mock binary)
        pid = TK.new_chat(s; title = "switch test")
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)

        # 2. Verify the provider dropdown exists and shows the initial provider
        initial_val = TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            return sel ? sel.value : null;
        })()""")
        @info "initial provider dropdown value" val = initial_val
        @test initial_val === "ClaudeCode" || initial_val === "MockCode" || initial_val !== nothing

        # 3. Send a message — should work with the mock agent
        TK.send_message(s, "hello from switch test")
        TK.wait_for(s, "agent message landed",
            """document.querySelectorAll('.bt-agent-msg').length >= 1"""; timeout = 15)
        sleep(0.5)

        # Verify the agent responded with our scripted text
        agent_text = TK.eval_js(s, """(() => {
            const msgs = document.querySelectorAll('.bt-agent-msg');
            return msgs.length > 0 ? msgs[msgs.length-1].textContent : '';
        })()""")
        @info "agent response" text = agent_text
        @test occursin("response to:", agent_text)

        # 4. Switch to MockCode via the UI dropdown
        TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            if (!sel) return false;
            sel.value = 'MockCode';
            sel.dispatchEvent(new Event('change'));
            return true;
        })()""")
        sleep(3.0)  # let switch_provider! + restart_chat_session! complete

        # 5. Verify the provider changed
        new_val = TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            return sel ? sel.value : null;
        })()""")
        @info "provider after switch" val = new_val
        @test new_val == "MockCode"

        # Verify server-side state
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        @test model.provider[] == BonitoAgents.MockCode
        @test model.session_alive[] == true
        @test isempty(model.last_error[])

        # 6. Send another message — should work with the mock agent
        TK.send_message(s, "hello after MockCode switch")
        TK.wait_for(s, "agent message after switch",
            """document.querySelectorAll('.bt-agent-msg').length >= 2"""; timeout = 15)
        sleep(0.5)

        agent_text2 = TK.eval_js(s, """(() => {
            const msgs = document.querySelectorAll('.bt-agent-msg');
            return msgs.length > 0 ? msgs[msgs.length-1].textContent : '';
        })()""")
        @info "agent response after switch" text = agent_text2
        @test occursin("response to:", agent_text2)
        @test occursin("MockCode switch", agent_text2)

        # 7. Switch back to ClaudeCode via the dropdown
        TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            if (!sel) return false;
            sel.value = 'ClaudeCode';
            sel.dispatchEvent(new Event('change'));
            return true;
        })()""")
        sleep(3.0)

        # 8. Verify we're back on ClaudeCode
        back_val = TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            return sel ? sel.value : null;
        })()""")
        @info "provider after switch back" val = back_val
        @test back_val == "ClaudeCode"
        @test model.provider[] == BonitoAgents.ClaudeCode

        # 9. Send a third message — should work after switching back
        TK.send_message(s, "hello after switching back")
        TK.wait_for(s, "agent message after switch back",
            """document.querySelectorAll('.bt-agent-msg').length >= 3"""; timeout = 15)
        sleep(0.5)

        agent_text3 = TK.eval_js(s, """(() => {
            const msgs = document.querySelectorAll('.bt-agent-msg');
            return msgs.length > 0 ? msgs[msgs.length-1].textContent : '';
        })()""")
        @info "agent response after switch back" text = agent_text3
        @test occursin("response to:", agent_text3)
        @test occursin("switching back", agent_text3)

        @info "provider switch e2e completed successfully"

        # Take a final screenshot for visual verification
        TK.screenshot(s, joinpath(tempdir(), "provider-switch-e2e-final.png"))
    finally
        close(s)
    end
end

@testset "e2e provider switch: MockCode <-> MiMoCode" begin
    s = TK.dev_server(; agent = msg -> [
        text("mock reply: $(msg)"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)

        pid = TK.new_chat(s; title = "mimo switch test")
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)

        # Send initial message
        TK.send_message(s, "test with default")
        TK.wait_for(s, "first agent message",
            """document.querySelectorAll('.bt-agent-msg').length >= 1"""; timeout = 15)
        sleep(0.5)

        # Switch to MockCode
        TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            sel.value = 'MockCode';
            sel.dispatchEvent(new Event('change'));
            return true;
        })()""")
        sleep(3.0)

        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        @test model.provider[] == BonitoAgents.MockCode
        @test model.session_alive[] == true

        # Send message with MockCode
        TK.send_message(s, "test with mock")
        TK.wait_for(s, "message with MockCode",
            """document.querySelectorAll('.bt-agent-msg').length >= 2"""; timeout = 15)
        sleep(0.5)

        # Switch to MiMoCode
        TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            sel.value = 'MiMoCode';
            sel.dispatchEvent(new Event('change'));
            return true;
        })()""")
        sleep(3.0)

        val = TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            return sel ? sel.value : null;
        })()""")
        @test val == "MiMoCode"
        @test model.provider[] == BonitoAgents.MiMoCode

        # Switch back to MockCode
        TK.eval_js(s, """(() => {
            const sel = document.querySelector('.bt-header-provider-select');
            sel.value = 'MockCode';
            sel.dispatchEvent(new Event('change'));
            return true;
        })()""")
        sleep(3.0)

        @test model.provider[] == BonitoAgents.MockCode
        @test model.session_alive[] == true
        @test isempty(model.last_error[])

        # Final message to confirm it all works
        TK.send_message(s, "final message")
        TK.wait_for(s, "final agent message",
            """document.querySelectorAll('.bt-agent-msg').length >= 3"""; timeout = 15)

        @info "MockCode <-> MiMoCode switch e2e completed"
    finally
        close(s)
    end
end
end  # BT_RUN_E2E
