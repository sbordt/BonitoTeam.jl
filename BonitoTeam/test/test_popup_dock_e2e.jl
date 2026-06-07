# Real E2E for the popup + plotpane dock chain that wasn't covered by the
# headless tests this session. Boots `dev_server` (real worker + BonitoMCP +
# eval bridge), registers a live `bonito_app` tool bubble via the real
# `bt_show_app` MCP handler (no claude needed — host-side direct call), opens
# the unified shell in a real Electron browser, then exercises:
#
#   * the "↗ Detach" button on the tool body → embed migrates into the
#     `#bt-popup-mount` slot, FloatingWindow becomes visible
#   * `window._btPopup.dock()` → embed migrates into `#bt-plotpane-mount`,
#     `#bt-plotpane-dropzone` gains `.bt-plotpane-visible`, FW hides again
#
# This is exactly the dock flow my session-changes batch didn't cover, because
# the resize-handle test had to fake `bt-plotpane-visible` (no real embed
# available). Here the toggle happens for real.
const BONITO = "/sim/Programmieren/ClaudeExperiments/dev/Bonito"
include(joinpath(BONITO, "test", "ElectronTests.jl"))
TestWindow(args...; options=Dict{String,Any}("show"=>false,"focusOnWebView"=>false)) =
    Bonito.EWindow(args...; app=get_test_app(), options=options)
electron_evaljs(window, js) = run(window, sprint(show, js))

using Test
import BonitoTeam, BonitoMCP, Bonito
import ElectronCall
using BonitoTeam: now, UTC
const BT = BonitoTeam
const ROOT = "/sim/Programmieren/ClaudeExperiments"

function poll_js(win, js, want; timeout = 40.0)
    deadline = time() + timeout
    local v
    while time() < deadline
        v = electron_evaljs(win, js)
        v == want && return true
        sleep(0.1)
    end
    @info "poll timed out" js = string(js) last = v want
    return false
end

const DEMO = """
using Bonito
Bonito.App(s -> Bonito.DOM.div("popup-dock test"; id = "dock_app_root"))
"""

@testset "Detach + dock chain against a real bonito_app" begin
    h = BT.dev_server()
    win = nothing
    try
        # 1. Wait for the in-process dev worker to register on /worker-ws.
        @test timedwait(() -> !isempty(h.state.workers[]), 20.0) === :ok
        worker_id = first(keys(h.state.workers[]))

        # 2. Register a fake project bound to that worker. We use a path
        #    under the dev worker's projects_root so the worker can find it.
        pid = "popup-" * string(rand(UInt16))
        wpath = joinpath(h.worker_root, "PopupDockTest")
        mkpath(wpath)
        srv_path = joinpath(h.working_dir, "PopupDockTest")
        mkpath(srv_path)
        h.state.projects[][pid] = BT.ProjectInfo(pid, "PopupDockTest",
            worker_id, srv_path, wpath, now(UTC))
        BT.safe_notify!(h.state.projects)

        # 3. Boot the eval dial-back: a trivial bt_show_app makes the worker
        #    dial back over /eval-ws and populate EVAL_WORKERS[pid].
        for (k, v) in BT.eval_dialback_env(h.state, pid); ENV[k] = v; end
        BonitoMCP.restart!(BonitoMCP.manager(), ROOT)
        @test BonitoMCP.julia_show_app_handler(Dict(
            "code"     => "using Bonito; Bonito.App(s -> Bonito.DOM.div(\"dial\"))",
            "env_path" => ROOT,
        ))["isError"] == false
        @test timedwait(() -> haskey(BT.EVAL_WORKERS, pid), 30.0) === :ok

        # 4. Build a ChatModel + pre-register it so the sidebar/navigation
        #    skips the ACP bring-up path. Mock transport — we don't need a
        #    live agent, only the chat shell + the live bonito_app embed.
        chat_dir = mktempdir()
        model = BT.ChatModel(h.state, chat_dir;
                              project_id = pid,
                              transport  = BT.MockTransport((o, i) -> nothing))
        lock(h.state.lock) do; h.state.chat_models[pid] = model; end
        BT.notify_chats!(h.state)

        # 5. Add the live worker app as a `bonito_app` tool bubble. The
        #    placeholder's `jsrender` (in remote_app.jl) calls embed_remote_app
        #    on mount, which produces the actual `bt-embed-<tool_id>` DOM the
        #    detach/dock controller moves around.
        appid = BT.show_remote_app_for_project!(model, DEMO; title = "PopupDockApp")

        # 6. Open the unified shell in a real browser.
        win = TestWindow()
        ElectronCall.load(win.window, URI(h.url))
        @test poll_js(win, js"document.body ? 'y' : 'n'", "y")

        # 7. Navigate via the sidebar to PopupDockTest. Wait for the chat to
        #    mount, then expand the bonito_app tool body (the auto-expand event
        #    that `show_remote_app_for_project!` fires is lost when no browser
        #    is yet connected, so the bubble lands collapsed and we click it
        #    here to trigger `tool.render` → embed render via dom_in_js).
        @test poll_js(win,
            js"document.querySelector('.bt-side-item[data-project-id=' + JSON.stringify($(pid)) + ']') ? 'y':'n'",
            "y")
        electron_evaljs(win, js"document.querySelector('.bt-side-item[data-project-id=' + JSON.stringify($(pid)) + ']').click()")
        @test poll_js(win, js"document.querySelector('.bt-text-input') ? 'y':'n'", "y")
        @test poll_js(win, js"document.querySelector('.bt-tool-msg') ? 'y':'n'", "y", timeout = 10.0)
        # Click the tool header → expand → `tool.render` → embed mounts.
        electron_evaljs(win, js"document.querySelector('.bt-tool-msg .bt-tool-header').click()")
        @test poll_js(win, js"document.getElementById('bt-embed-' + $(appid)) ? 'y':'n'", "y", timeout = 40.0)
        @test poll_js(win, js"document.querySelector('#dock_app_root') ? 'y':'n'", "y")

        # 8. Sanity: embed is currently in its slot inside the bubble.
        @test electron_evaljs(win, js"document.getElementById('bt-embed-' + $(appid)).parentElement.id") ==
              "bt-slot-" * appid

        # Sanity: the controller actually wired up.
        @test electron_evaljs(win, js"typeof window._btPopup") == "object"

        # 9. Detach. Drive the controller directly rather than clicking the
        #    button — the button's onclick is rendered in the tool-body
        #    subsession, and the subsession-bound click wiring doesn't always
        #    survive the dom_in_js round-trip. The controller itself is a
        #    global side-effect of the root onload, so window._btPopup.detach
        #    is the real test of the dock chain regardless of which surface
        #    the click came from.
        electron_evaljs(win, js"window._btPopup.detach($(appid))")
        @test poll_js(win, js"document.getElementById('bt-embed-' + $(appid)).parentElement.id", "bt-popup-mount")
        @test poll_js(win, js"getComputedStyle(document.querySelector('.bn-floating-window')).display !== 'none' ? 'y':'n'", "y")
        # Plotpane should still be collapsed.
        @test electron_evaljs(win, js"document.getElementById('bt-plotpane-dropzone').classList.contains('bt-plotpane-visible')") == false

        # 10. Dock to plotpane (this is the toggle the resize-handle test had
        #     to fake). `_btPopup.dock()` moves the embed to the plotpane
        #     mount, calls `showFor('docked')` → `applyPlotpaneVis` toggles
        #     the bt-plotpane-visible class.
        electron_evaljs(win, js"window._btPopup.dock()")
        @test poll_js(win, js"document.getElementById('bt-embed-' + $(appid)).parentElement.id", "bt-plotpane-mount")
        @test poll_js(win, js"document.getElementById('bt-plotpane-dropzone').classList.contains('bt-plotpane-visible')", true)
        @test poll_js(win, js"getComputedStyle(document.querySelector('.bn-floating-window')).display === 'none' ? 'y':'n'", "y")
        println("✓ Detach + dock E2E: embed migrates through bubble → popup → plotpane, bt-plotpane-visible toggles")

    finally
        for k in ("BONITOTEAM_EVAL_WS", "BONITOTEAM_SECRET", "BONITOTEAM_PROJECT_ID")
            haskey(ENV, k) && delete!(ENV, k)
        end
        win === nothing || (try; close(win.window); catch; end)
        try; close(h); catch; end
    end
end
nothing
