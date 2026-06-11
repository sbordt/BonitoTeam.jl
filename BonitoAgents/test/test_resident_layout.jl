# Real-browser regression test for the resident-per-chat layout feature:
#   * plotpane fills the right-hand whitespace + two-stage chat|plotpane resize
#   * keep-alive: chat DOM / live embeds / collapse state survive navigation
#     (home↔A↔B↔A) with NO re-delegation and NO `null.bonitoKeyedList` flood
#   * the floating window / plotpane / divider-width are resident PER CHAT
#     (hidden on home + on other chats, restored exactly on return)
#   * embeds stay INTERACTIVE after being hidden and shown again
#   * the ⤢ full-chat-width pill toggle
#
# Heavy (boots a dev_server + real eval worker + WGLMakie + Electron); opt-in via
# BT_RUN_E2E=1 (same gate as the other live e2e tests).

using Test
isdefined(@__MODULE__, :E2E_HELPERS_LOADED) || include(joinpath(@__DIR__, "e2e_helpers.jl"))

if get(ENV, "BT_RUN_E2E", "") != "1"
    @info "skipping test_resident_layout.jl (set BT_RUN_E2E=1 — needs a worker + Electron)"
else

@testset "plotpane fills whitespace + resident per-chat state survives navigation" begin
    h = BT.dev_server()
    appE = nothing
    try
        timedwait(() -> !isempty(h.state.workers[]), 20.0) === :ok || error("no worker")
        pA, modelA = fake_agent_project!(h, 3; name = "alpha")   # WGLMakie chat (owns bridge)
        pB         = nav_target_project!(h; name = "beta")       # empty nav target
        @test haskey(BT.EVAL_WORKERS, pA.id)

        # Wide enough that the stage (viewport − sidebar) exceeds the chat cap,
        # so the closed chat is centered with real whitespace on both sides.
        appE, win, R = open_browser(h; width = 1820, height = 980)
        sleep(8)
        # start clean: clear last-route so we land on home, and install an
        # uncaught-error collector (the keep-alive must not throw in the browser).
        R("localStorage.removeItem('bt-last-pid')")
        R("""window.__errs=[]; window.addEventListener('error',e=>window.__errs.push(''+e.message));true""")
        R("document.querySelector('.bt-side-home-icon')?.closest('.bt-side-item')?.click()"); sleep(1.5)

        sideN(i)  = R("document.querySelectorAll('.bt-side-item')[$i]?.click()")
        gohome()  = (R("document.querySelector('.bt-side-home-icon')?.closest('.bt-side-item')?.click()"); sleep(1.5))
        ncanvas() = R("document.querySelectorAll('canvas').length")
        ppvis()   = R("document.getElementById('bt-plotpane-dropzone')?.classList.contains('bt-plotpane-visible')")
        fwdisp()  = R("(()=>{const f=document.querySelector('.bn-floating-window');return f?getComputedStyle(f).display:'none'})()")
        # Per-chat divider position is now the CHAT column width (the plotpane
        # flex-fills the rest). Also the live gap between chat and plotpane.
        chatVar() = R("document.querySelector('.bt-main')?.style?.getPropertyValue('--bt-chat-width') || ''")
        gap()     = R("Math.round(document.getElementById('bt-plotpane-dropzone').getBoundingClientRect().left - document.querySelector('.bt-main').getBoundingClientRect().right)")

        # Identify which sidebar entry is alpha (3 app pills).
        sideN(1); sleep(2.5)
        a_idx = R("document.querySelectorAll('.bt-tool-toggle').length") >= 3 ? 1 : 2
        b_idx = a_idx == 1 ? 2 : 1

        # ── Closed state: chat column centered + bounded (whitespace both sides) ─
        gohome()
        mainW0 = R("Math.round(document.querySelector('.bt-main').getBoundingClientRect().width)")
        mainL0 = R("Math.round(document.querySelector('.bt-main').getBoundingClientRect().left)")
        sideR0 = R("Math.round(document.querySelector('.bt-sidebar').getBoundingClientRect().right)")
        @test mainW0 <= 1402                       # capped at --bt-main-max (1400)
        @test mainL0 > sideR0 + 50                 # real gap between sidebar and chat ⇒ centered

        # ── Regression: the keep-alive chat-pane overlay must NOT swallow clicks
        #    meant for the dashboard on home (`.bt-view-chats` is stacked on top
        #    of the dashboard; without pointer-events:none it made the whole
        #    dashboard — open project, + New project, … — unclickable). ──────────
        @test R("""(()=>{const d=document.querySelector('.bt-view-dash');const r=d.getBoundingClientRect();
            const t=document.elementFromPoint(Math.round(r.left+r.width/2),Math.round(r.top+40));
            return !!t && !t.closest('.bt-view-chats');})()""")
        # And the worker pill's "projects (N)" <details> actually opens on click
        # (vacuously true until the worker's first discover scan lands).
        @test R("""(()=>{const s=document.querySelector('.bt-card summary');if(!s)return true;
            s.click();return document.querySelector('.bt-card details')?.open===true;})()""")

        # ── Expand alpha's 3 WGLMakie apps ──────────────────────────────────────
        sideN(a_idx); sleep(2.5)
        R("Array.from(document.querySelectorAll('.bt-tool-toggle')).filter(b=>b.innerText.includes('▶')).forEach(b=>b.click())"); sleep(7)
        @test ncanvas() == 3
        mainClosed = R("Math.round(document.querySelector('.bt-main').getBoundingClientRect().width)")

        # ── Detach (⤢ header button, app tools) + dock ⇒ plotpane fills the right
        #    edge, chat shrinks ──────────────────────────────────────────────────
        mainW() = R("Math.round(document.querySelector('.bt-main').getBoundingClientRect().width)")
        @test R("document.querySelectorAll('.bt-chatpane .bt-tool-detach').length") == 3   # one per app pill
        R("document.querySelector('.bt-chatpane .bt-tool-detach')?.click()"); sleep(1)     # detach app 1
        R("window._btPopup.dock()")
        # Poll for the reflow to settle (the plotpane width animates + the heavy
        # WGLMakie embed relayouts) — a fixed sleep races the docked-embed render.
        @test timedwait(() -> ppvis() === true && mainW() < mainClosed, 8.0) === :ok
        ppRight = R("Math.round(document.getElementById('bt-plotpane-dropzone').getBoundingClientRect().right)")
        vw      = R("window.innerWidth")
        @test ppRight >= vw - 2                     # plotpane reaches the viewport's right edge
        @test gap() == 0                            # NO gap: plotpane fills right up to the chat
        mainDocked = mainW()                        # chat shrank to make room for the pane
        # Drag the divider left ⇒ narrower chat, the plotpane fills the rest (still no gap).
        R("""(()=>{const hh=document.querySelector('.bt-pp-resize');const r=hh.getBoundingClientRect();
          hh.dispatchEvent(new PointerEvent('pointerdown',{clientX:r.left+3,clientY:r.top+60,bubbles:true}));
          window.dispatchEvent(new PointerEvent('pointermove',{clientX:r.left-260,clientY:r.top+60,bubbles:true}));
          window.dispatchEvent(new PointerEvent('pointerup',{clientX:r.left-260,clientY:r.top+60,bubbles:true}));})()""")
        @test timedwait(() -> mainW() < mainDocked, 6.0) === :ok
        @test gap() == 0                            # still no gap after resizing

        # ── Keep-alive: A's apps survive A→B→A and A→home→A with no re-delegate ──
        sideN(b_idx); sleep(2.5)
        @test fwdisp() == "none" && ppvis() == false        # surfaces hidden on the other chat
        @test R("document.querySelectorAll('.bt-chatpane').length") == 2   # both panes still mounted
        sideN(a_idx); sleep(0.6)                            # back — must be INSTANT
        @test ncanvas() == 3                                # DOM preserved, no re-expand
        @test ppvis() == true                               # alpha's docked plotpane restored
        w_before = chatVar()
        gohome();  @test ppvis() == false                   # plotpane hidden on home
        sideN(a_idx); sleep(0.6)
        @test ncanvas() == 3
        @test chatVar() == w_before                         # per-chat divider position restored

        # ── Per-chat floating window: undock ⇒ floats; hidden elsewhere ─────────
        R("window._btPopup.undock()"); sleep(1)
        @test fwdisp() == "flex" && ppvis() == false
        sideN(b_idx); sleep(2.0); @test fwdisp() == "none"          # hidden on beta
        sideN(a_idx); sleep(0.6); @test fwdisp() == "flex"          # restored on return
        gohome();                 @test fwdisp() == "none"          # hidden on home
        sideN(a_idx); sleep(0.6); @test fwdisp() == "flex"          # restored again

        # ── » full-chat-width toggle (right-edge, expanded-only) ────────────────
        # Use the LAST app bubble — it stays inline+expanded throughout (we only
        # ever detach the first). The » button is revealed only while expanded.
        last_msg = "document.querySelectorAll('.bt-chatpane .bt-tool-msg')[document.querySelectorAll('.bt-chatpane .bt-tool-msg').length-1]"
        last_wide = "$last_msg.querySelector('.bt-tool-fullwidth')"
        @test R("(()=>{const b=$last_wide;return !!b && getComputedStyle(b).display!=='none'})()")   # visible (expanded)
        wbefore = R("Math.round($last_msg.getBoundingClientRect().width)")
        R("$last_wide.click()"); sleep(0.6)
        @test R("$last_msg.classList.contains('bt-tool-wide-active')")
        wafter = R("Math.round($last_msg.getBoundingClientRect().width)")
        @test wafter > wbefore

        # The whole nav stress must not have thrown an uncaught JS error.
        @test R("window.__errs.length") == 0
    finally
        close_browser(appE)
        try close(h) catch end
    end
end

@testset "embedded app stays interactive across keep-alive navigation" begin
    h = BT.dev_server()
    appE = nothing
    try
        timedwait(() -> !isempty(h.state.workers[]), 20.0) === :ok || error("no worker")
        pG, _ = fake_agent_project!(h, 1; name = "gamma", code = INTERACTIVE_CODE)
        pD    = nav_target_project!(h; name = "delta")
        @test haskey(BT.EVAL_WORKERS, pG.id)

        appE, win, R = open_browser(h; width = 1200, height = 760)
        sleep(8)
        R("localStorage.removeItem('bt-last-pid')")
        sideN(i) = R("document.querySelectorAll('.bt-side-item')[$i]?.click()")
        sideN(1); sleep(2.5)
        g_idx = R("document.querySelectorAll('.bt-tool-toggle').length") >= 1 ? 1 : 2
        d_idx = g_idx == 1 ? 2 : 1
        sideN(g_idx); sleep(2.0)
        R("Array.from(document.querySelectorAll('.bt-tool-toggle')).filter(b=>b.innerText.includes('▶')).forEach(b=>b.click())")
        @test timedwait(() -> R("document.querySelector('.ibtn') !== null"), 20.0) === :ok
        @test R("document.querySelector('.dbl').innerText") == "0"

        # Click and WAIT for each increment to land before the next. The app does
        # `clicks.notify(clicks.value + 1)` — a JS-side read-modify-write — so
        # firing clicks faster than the worker round-trip would read a stale value
        # and lose increments. Serializing proves every click crosses
        # browser→worker→reaction→browser.
        dbl() = R("document.querySelector('.dbl')?.innerText")
        function click_to(target)
            R("document.querySelector('.ibtn')?.click()")
            timedwait(() -> dbl() == string(target), 6.0) === :ok
        end
        @test click_to(2); @test click_to(4); @test click_to(6)

        # Navigate away and back — the embed is hidden (display:none) then shown.
        sideN(d_idx); sleep(2.0)
        sideN(g_idx); sleep(0.8)
        @test dbl() == "6"     # value preserved across nav

        # Click again — if the worker reaction survived the hide/show, it keeps counting.
        @test click_to(8); @test click_to(10)
    finally
        close_browser(appE)
        try close(h) catch end
    end
end

end
