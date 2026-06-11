# Real-browser regression test for the bt_show_app open/collapse trashing bug.
#
# A FAKE AGENT (no claude): a dashboard project with a MockTransport chat model
# and N live WGLMakie app bubbles, registered on a real eval worker. Then a real
# (headless) Electron browser drives the chat through expand + open/collapse churn
# — the exact thing that produced "remote control 'delegate' timed out" / stuck
# "loading…". WGLMakie matters: its heavy frames + headless software-WebGL make
# the browser drain its socket slowly, which is what head-of-line-blocked the
# single relay loop (a blocking worker→browser write starving the delegate/
# asset_read control replies on the same task). The CapConn e2e writes instantly,
# so it structurally cannot catch this; a real browser + heavy app can.
#
# Heavy: boots a dev_server + a real eval worker (WGLMakie ~load) + Electron.
# Opt-in via BT_RUN_E2E=1 (same gate as test_real_e2e.jl).

using Test
# Shared fake-agent harness: APPCODE, INTERACTIVE_CODE, fake_agent_project!,
# nav_target_project!, open_browser/close_browser, BT/ACP/ROOT. Guarded so
# runtests (which includes both e2e files) loads it exactly once.
isdefined(@__MODULE__, :E2E_HELPERS_LOADED) || include(joinpath(@__DIR__, "e2e_helpers.jl"))

if get(ENV, "BT_RUN_E2E", "") != "1"
    @info "skipping test_bonito_app_churn.jl (set BT_RUN_E2E=1 — needs a worker + Electron)"
else
@testset "bt_show_app survives open/collapse churn in a real browser (head-of-line fix)" begin
    h = BT.dev_server()
    EC = Bonito.HTTPServer.current_electron()
    appE = win = nothing
    try
        timedwait(() -> !isempty(h.state.workers[]), 20.0) === :ok || error("no worker")
        p, model = fake_agent_project!(h, 3)
        @test haskey(BT.EVAL_WORKERS, p.id)
        @test count(m -> m isa BT.ToolMsg, model.msgs_store) == 3

        logp = tempname() * ".log"
        appE = EC.Application(; additional_electron_args = vcat(HEADLESS_WEBGL_ARGS, String["--enable-logging", "--log-file=$logp", "--v=0"]))
        win  = EC.Window(appE, EC.URI(h.url); options = Dict("show" => false, "width" => 1300, "height" => 850))
        R(c) = EC.run(win, c)
        sleep(8)

        # Into the project chat, expand all three WGLMakie apps.
        R("document.querySelector('.bt-proj-icon')?.closest('.bt-side-item')?.click()"); sleep(3)
        R("Array.from(document.querySelectorAll('.bt-tool-toggle')).filter(b=>b.innerText.includes('▶')).forEach(b=>b.click())"); sleep(7)
        badtxt() = R("(document.body.innerText.match(/timed out|unavailable/gi)||[]).length")
        @test R("document.querySelectorAll('canvas').length") == 3   # all three rendered
        @test badtxt() == 0

        # Open/collapse churn — each re-open is a fresh `delegate` while a heavy,
        # slow-to-drain browser is streaming. Without the relay fix this starves
        # the delegate replies → timeouts.
        for _ in 1:6
            R("document.querySelectorAll('.bt-tool-toggle').forEach(b=>b.click())"); sleep(2)     # collapse
            R("document.querySelectorAll('.bt-tool-toggle').forEach(b=>b.click())"); sleep(4.5)   # re-open
            @test R("document.querySelectorAll('canvas').length") == 3
            @test badtxt() == 0
        end
    finally
        win  === nothing || try EC.close(appE) catch end
        try close(h) catch end
        for k in ("BONITOAGENTS_SERVER_URL","BONITOAGENTS_SECRET","BONITOAGENTS_PROJECT_ID"); haskey(ENV,k) && delete!(ENV,k); end
    end
end

@testset "WGLMakie apps survive chat↔home↔other-chat navigation + collapse" begin
    h = BT.dev_server()
    EC = Bonito.HTTPServer.current_electron()
    appE = win = nothing
    try
        timedwait(() -> !isempty(h.state.workers[]), 20.0) === :ok || error("no worker")
        pA, _ = fake_agent_project!(h, 3; name = "alpha")    # WGLMakie chat (owns the bridge)
        pB    = nav_target_project!(h; name = "beta")         # empty nav target
        @test haskey(BT.EVAL_WORKERS, pA.id)

        logp = tempname() * ".log"
        appE = EC.Application(; additional_electron_args = vcat(HEADLESS_WEBGL_ARGS, String["--enable-logging", "--log-file=$logp", "--v=0"]))
        win  = EC.Window(appE, EC.URI(h.url); options = Dict("show" => false, "width" => 1300, "height" => 850))
        R(c) = EC.run(win, c)
        sleep(8)

        badtxt()    = R("(document.body.innerText.match(/timed out|unavailable/gi)||[]).length")
        ncanvas()   = R("document.querySelectorAll('canvas').length")
        gohome()    = (R("document.querySelector('.bt-side-home-icon')?.closest('.bt-side-item')?.click()"); sleep(1.3))
        gotoproj(i) = (R("document.querySelectorAll('.bt-proj-icon')[$(i-1)].closest('.bt-side-item').click()"); sleep(2.5))
        expand()    = (R("Array.from(document.querySelectorAll('.bt-tool-toggle')).filter(b=>b.innerText.includes('▶')).forEach(b=>b.click())"); sleep(5))
        collapse()  = (R("document.querySelectorAll('.bt-tool-toggle').forEach(b=>b.click())"); sleep(1.5))

        # Identify which sidebar project icon is the WGLMakie chat (3 app bubbles).
        gotoproj(1)
        a_idx = R("document.querySelectorAll('.bt-tool-toggle').length") >= 3 ? 1 : 2
        b_idx = a_idx == 1 ? 2 : 1
        gotoproj(a_idx); expand()
        @test ncanvas() == 3
        @test badtxt() == 0

        for _ in 1:4
            collapse()
            gohome()                       # chat → home
            gotoproj(a_idx); expand()      # → chat: tab re-delegates the embeds after home
            @test ncanvas() == 3
            @test badtxt() == 0
            collapse()
            gotoproj(b_idx); sleep(1.5)    # chat → OTHER chat
            gotoproj(a_idx); expand()      # → back: re-delegate after switching chats
            @test ncanvas() == 3
            @test badtxt() == 0
        end
    finally
        win  === nothing || try EC.close(appE) catch end
        try close(h) catch end
        for k in ("BONITOAGENTS_SERVER_URL","BONITOAGENTS_SECRET","BONITOAGENTS_PROJECT_ID"); haskey(ENV,k) && delete!(ENV,k); end
    end
end

@testset "embedded app is INTERACTIVE (browser click → worker reaction → re-render)" begin
    h = BT.dev_server()
    EC = Bonito.HTTPServer.current_electron()
    appE = win = nothing
    try
        timedwait(() -> !isempty(h.state.workers[]), 20.0) === :ok || error("no worker")
        pA, _ = fake_agent_project!(h, 1; name = "interact", code = INTERACTIVE_CODE)
        @test haskey(BT.EVAL_WORKERS, pA.id)

        appE = EC.Application(; additional_electron_args = HEADLESS_WEBGL_ARGS)
        win  = EC.Window(appE, EC.URI(h.url); options = Dict("show" => false, "width" => 1100, "height" => 700))
        R(c) = EC.run(win, c)
        sleep(8)
        R("document.querySelector('.bt-proj-icon')?.closest('.bt-side-item')?.click()"); sleep(3)
        R("Array.from(document.querySelectorAll('.bt-tool-toggle')).filter(b=>b.innerText.includes('▶')).forEach(b=>b.click())")
        # The embed mounts async (delegate → init-bundle fetch → render); poll for it.
        @test timedwait(() -> R("document.querySelector('.ibtn') !== null"), 20.0) === :ok
        @test R("document.querySelector('.dbl').innerText") == "0"

        for _ in 1:3                                                # each click rides browser→worker→browser
            R("document.querySelector('.ibtn').click()"); sleep(0.8)
        end
        # "6" can ONLY appear if the click reached the worker observable, the
        # worker-side `on(clicks) → doubled = 2c` reaction ran, and the result was
        # relayed back to the browser DOM. That is true end-to-end interactivity.
        @test timedwait(() -> R("document.querySelector('.dbl')?.innerText") == "6", 5.0) === :ok
    finally
        win  === nothing || try EC.close(appE) catch end
        try close(h) catch end
        for k in ("BONITOAGENTS_SERVER_URL","BONITOAGENTS_SECRET","BONITOAGENTS_PROJECT_ID"); haskey(ENV,k) && delete!(ENV,k); end
    end
end
end
