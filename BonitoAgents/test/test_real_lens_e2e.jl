# REAL e2e for lens search + scroll, via the mock-claude-agent-acp BINARY
# (TestKit) — NOT a MockTransport. The whole production stack runs unchanged:
# real dev_server, real worker, real WorkerTransport, real ACP Connection /
# dispatcher / parse_update!. Only the agent's *responses* are scripted (the
# mock binary speaks the real ACP wire). So the lens filters + the virtual
# scroll run against messages that arrived through the real transport, in a
# real browser, against a real server.
#
# Heavy (worker + Electron + agent binary), so opt-in via BT_RUN_E2E=1.
using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, bash, bt_show_app, end_turn

if get(ENV, "BT_RUN_E2E", "") != "1"
    @info "skipping test_real_lens_e2e.jl (set BT_RUN_E2E=1 — needs a worker + Electron + agent binary)"
else
@testset "REAL e2e (mock-acp binary): lens search + scroll over the real wire" begin
    ENV["BONITOAGENTS_LENSES_PATH"] = joinpath(mktempdir(), "lenses.json")
    # Scripted agent: a reply mentioning "monitor", a real Bash tool, a real
    # bt_show_app bubble, and a closing line — varied types + content for the
    # lens. All arrive over the real ACP wire from the mock binary.
    s = TK.dev_server(; agent = _msg -> [
        text("lens-e2e ready — starting the resource monitor"),
        bash("echo hello-from-bash", "hello-from-bash"),
        bt_show_app("using Bonito; Bonito.App(() -> Bonito.DOM.div(\"lens dashboard\"))"),
        text("all done"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 860)
        pid = TK.new_chat(s; title = "lens")
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "lens bar mounted",
            "document.querySelector('.bt-lens-input') !== null"; timeout = 20)
        TK.send_message(s, "please do the lens e2e steps")

        # Wait for the agent's REAL messages to render: ≥2 tools (Bash + app)
        # and an agent reply.
        TK.wait_for(s, "real agent messages rendered",
            "document.querySelectorAll('.bt-tool-msg').length >= 2 && " *
            "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 60)
        sleep(1.0)

        # The model that received the real wire — to compute expected indices.
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        ms = lock(() -> copy(model.msgs_store), model.lock)
        @info "real wire messages" total = length(ms) types = unique(string.(nameof.(typeof.(ms))))

        @testset "vocabulary derived from the real chat" begin
            @test TK.wait_for(s, "vocab has Bash",
                "document.querySelector('.bt-messages').__bt_chat.lensVocab.includes('Bash')"; timeout = 8)
            @test TK.eval_js(s,
                "document.querySelector('.bt-messages').__bt_chat.lensVocab.includes('bt_show_app')")
        end

        @testset "lens /Bash filters to exactly the real Bash tool indices" begin
            bash_idxs = sort([i - 1 for (i, m) in enumerate(ms) if m isa BonitoAgents.BashToolMsg])
            @test !isempty(bash_idxs)
            TK.eval_js(s, """(() => { document.querySelector('.bt-lens-input').value='/Bash';
                  document.querySelector('.bt-lens-go').click(); return true; })()""")
            @test TK.wait_for(s, "lens active",
                "document.querySelector('.bt-messages').__bt_chat.lensActive === true"; timeout = 6)
            vis = TK.eval_js(s,
                "[...document.querySelector('.bt-messages').__bt_chat.lensVisible].sort((a,b)=>a-b)")
            @test Int.(vis) == bash_idxs
            # Clicking Search committed the clause into a PILL.
            @test TK.wait_for(s, "a Bash pill rendered", """(() => {
                  const p = document.querySelectorAll('.bt-lens-pill');
                  return p.length === 1 && /Bash/.test(p[0].textContent); })()"""; timeout = 4)
        end

        @testset "exclude lens `/all - /Bash` hides only the Bash tool (pills)" begin
            bash_idxs = Set(i - 1 for (i, m) in enumerate(ms) if m isa BonitoAgents.BashToolMsg)
            # Load via the saved-lens path so the operator splits into two pills.
            TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat._lensLoadQuery('/all - /Bash'); true")
            @test TK.wait_for(s, "two pills, second is exclude", """(() => {
                  const p = document.querySelectorAll('.bt-lens-pill');
                  return p.length === 2 && p[1].classList.contains('bt-lens-pill-ex'); })()"""; timeout = 6)
            @test TK.wait_for(s, "exclude active",
                "document.querySelector('.bt-messages').__bt_chat.lensActive === true"; timeout = 6)
            vis = Set(Int.(TK.eval_js(s,
                "[...document.querySelector('.bt-messages').__bt_chat.lensVisible]")))
            @test isempty(intersect(vis, bash_idxs))            # bash hidden
            @test length(vis) == length(ms) - length(bash_idxs) # everything else shown
        end

        @testset "collapse action records on the matched indices" begin
            app_idxs = sort([i - 1 for (i, m) in enumerate(ms) if m isa BonitoAgents.BonitoAppMsg])
            TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat._lensLoadQuery('/bt_show_app collapse'); true")
            @test TK.wait_for(s, "collapse recorded for the app", """(() => {
                  const c = document.querySelector('.bt-messages').__bt_chat;
                  return c.lensActive && [...c.lensActions.values()].includes('collapse'); })()"""; timeout = 6)
            vis = TK.eval_js(s,
                "[...document.querySelector('.bt-messages').__bt_chat.lensVisible].sort((a,b)=>a-b)")
            @test Int.(vis) == app_idxs
        end

        @testset "lens /bt_show_app: expand shows + expands the real app" begin
            app_idxs = sort([i - 1 for (i, m) in enumerate(ms) if m isa BonitoAgents.BonitoAppMsg])
            @test !isempty(app_idxs)
            TK.click(s, ".bt-lens-clear")   # drop pills from the previous testset
            TK.eval_js(s, """(() => { document.querySelector('.bt-lens-input').value='/bt_show_app: expand';
                  document.querySelector('.bt-lens-go').click(); return true; })()""")
            @test TK.wait_for(s, "app filtered + expand recorded", """(() => {
                  const c=document.querySelector('.bt-messages').__bt_chat;
                  return c.lensActive && [...c.lensActions.values()].includes('expand'); })()"""; timeout = 6)
            vis = TK.eval_js(s,
                "[...document.querySelector('.bt-messages').__bt_chat.lensVisible].sort((a,b)=>a-b)")
            @test Int.(vis) == app_idxs
        end

        @testset "full-text lens over real agent content" begin
            TK.click(s, ".bt-lens-clear")   # drop the previous testset's pill
            TK.eval_js(s, """(() => { document.querySelector('.bt-lens-input').value='/agent "monitor"';
                  document.querySelector('.bt-lens-go').click(); return true; })()""")
            @test TK.wait_for(s, "found the monitor reply", """(() => {
                  const c=document.querySelector('.bt-messages').__bt_chat;
                  return c.lensActive && c.lensVisible.size >= 1; })()"""; timeout = 6)
        end

        @testset "clear + scroll the real chat, stays functional" begin
            TK.click(s, ".bt-lens-clear")
            @test TK.wait_for(s, "lens cleared",
                "document.querySelector('.bt-messages').__bt_chat.lensActive === false"; timeout = 4)
            TK.eval_js(s, """(() => { const c=document.querySelector('.bt-messages');
                  c.scrollTop=0; c.dispatchEvent(new Event('scroll'));
                  c.scrollTop=c.scrollHeight; c.dispatchEvent(new Event('scroll')); return true; })()""")
            sleep(0.5)
            @test TK.eval_js(s,
                "(document.body.innerText.match(/timed out|unavailable|\\[error:/gi)||[]).length") == 0
        end

        TK.screenshot(s, joinpath(tempdir(), "lens-e2e-real.png"))
    finally
        close(s)
    end
end
end
