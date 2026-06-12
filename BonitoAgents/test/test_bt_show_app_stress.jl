# Stress + interactivity + scroll-lifecycle for `bt_show_app` in ONE
# integrated test. The three behaviors the trivial embed test didn't
# cover:
#
#   * Real Bonito reactivity (Slider → Observable → DOM update). Sets
#     the slider's value, dispatches an `input` event, asserts the
#     reactive label reflects the new value through the eval-WS bridge.
#   * Multiple bt_show_app calls in one chat reusing the same bridge.
#     All sliders must mount, all output spans must render.
#   * Scrolling across the chat: scroll to top + back; the embed bodies
#     must stay alive (or remount cleanly) and still respond to drags.
#
# One TestServer for the whole run because BonitoMCP's `manager()` is
# process-global — running back-to-back TestServers in one Julia
# process leaves a stale eval-WS bridge keyed to the previous
# dev_server, and new apps registered on that bridge never reach the
# new chat. Per-test isolation would need either a manager reset or a
# fresh env_path per test, both out of scope here. Single-session is
# also the production-realistic shape: the agent calls bt_show_app
# multiple times within one user turn.

using Test, JSON
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit
const TK = TestKit
using .TestKit: text, bt_show_app, end_turn

const SHOT_DIR = joinpath(tempdir(), "bt-show-app-stress")
mkpath(SHOT_DIR)
shot(name) = joinpath(SHOT_DIR, name)

# An app with a real Slider + a reactive label.
# `Slider(1:100; value = 13)` makes the input's HTML `value` attribute
# (which Bonito binds to the slider's INDEX, not the value) equal the
# displayed value — the test can drive `input.value = '77'` and assert
# the output says `= 77`.
slider_app_code(seed) = """
using Bonito
const seed = $(seed)
Bonito.App() do session
    s = Bonito.Slider(1:100; value = 13)
    out = map(v -> "slider#\$(seed) = \$(v) (x7 = \$(v*7))", s.value)
    return DOM.div(
        DOM.h3("App #\$(seed)";
               style = "color:#0f766e;margin:0 0 6px 0;font:600 14px ui-sans-serif"),
        DOM.div(s;
                class = "stress-app-slider-\$(seed)",
                style = "margin:6px 0"),
        DOM.div(out;
                class = "stress-app-output-\$(seed)",
                style = "font:13px ui-monospace,monospace;color:#1f2937;
                         background:#f0fdfa;padding:6px 10px;
                         border-radius:6px;border:1px solid #99f6e4");
        style = "padding:14px 18px;background:#ecfeff;border-radius:10px;
                 border:1px solid #67e8f9;margin:6px 0")
end
"""

# Helper: set the slider in app `seed` to `target_val` (a Number in 1..100)
# via the same input dispatch the user would trigger by dragging. Bonito's
# Slider attaches `oninput` to the `<input type="range">`; dispatching a
# bubbling `input` event triggers it, which notifies the index Observable,
# which (via onjs) notifies the value Observable.
function drag_slider!(s::TK.TestServer, seed::Int, target_val::Int)
    TK.eval_js(s, """(() => {
        const sl = document.querySelector('.stress-app-slider-$(seed) input[type="range"]');
        if (!sl) return false;
        sl.value = '$(target_val)';
        // Both events: some Bonito hosts listen for `input`, browsers fire
        // `change` after drag-end — sending both is a no-op for the second
        // but covers either binding.
        sl.dispatchEvent(new Event('input',  {bubbles: true}));
        sl.dispatchEvent(new Event('change', {bubbles: true}));
        return true;
    })()""")
end

read_output(s::TK.TestServer, seed::Int) =
    TK.eval_js(s, "document.querySelector('.stress-app-output-$(seed)')?.innerText || ''")

const N_APPS = 6

@testset "bt_show_app stress + slider drag + scroll: $(N_APPS) apps in one chat" begin
    project = abspath(pwd())   # root env — has Bonito.

    s = TK.dev_server(; agent = msg -> begin
        events = Any[text("Mounting $(N_APPS) interactive apps.")]
        for i in 1:N_APPS
            push!(events, bt_show_app(slider_app_code(i);
                                       env_path = project,
                                       id = "stress-$(i)"))
        end
        push!(events, text("Done."))
        push!(events, end_turn())
        events
    end)
    try
        TK.open_browser(s; width = 1280, height = 1000)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)
        TK.send_message(s, "please mount $(N_APPS) apps for me")

        # Wait for ALL N_APPS tool messages to land + be marked completed.
        # The first call sets up the bridge (~5s); each subsequent call is
        # ~1-2s for register + prerender. Generous timeout for cold compile.
        TK.wait_for(s, "all $(N_APPS) tools completed",
                    """document.querySelectorAll('.bt-tool-msg .bt-status-completed').length >= $(N_APPS)""";
                    timeout = 300)

        # Wait for the embeds themselves to render — the chat auto-expands
        # BonitoAppMsg bodies once their app_id lands, but the dom_in_js
        # mount + first paint is async after that. Probe for the actual
        # `<input type="range">` elements.
        TK.wait_for(s, "all $(N_APPS) sliders rendered in DOM",
                    """document.querySelectorAll('input[type="range"]').length >= $(N_APPS)""";
                    timeout = 60)
        sleep(2.0)

        # Initial state probe.
        counts = TK.eval_js(s, """(() => ({
            tool_msgs:      document.querySelectorAll('.bt-tool-msg').length,
            completed:      document.querySelectorAll('.bt-tool-msg .bt-status-completed').length,
            sliders_in_dom: document.querySelectorAll('input[type="range"]').length,
            outputs_in_dom: document.querySelectorAll('[class^="stress-app-output-"]').length,
        }))()""")
        @info "initial DOM" counts
        @test counts["tool_msgs"]      >= N_APPS
        @test counts["completed"]      >= N_APPS
        @test counts["sliders_in_dom"] == N_APPS
        @test counts["outputs_in_dom"] == N_APPS

        TK.screenshot(s, shot("01-six-apps-mounted.png"))

        # Each app's default value is 13 — verify all outputs match before
        # we drive any inputs. Catches an app that mounted but is wired to
        # a stale Observable from a previous session.
        for i in 1:N_APPS
            txt = read_output(s, i)
            @test occursin("slider#$(i) = 13", txt)
            @test occursin("x7 = 91", txt)
        end

        # ── Interaction: drag app #1 to 77, verify reactive output ──
        @info "drag app #1 slider to 77"
        @test drag_slider!(s, 1, 77) === true
        TK.wait_for(s, "app#1 reacted to drag",
                    """document.querySelector('.stress-app-output-1')?.innerText?.includes('= 77 (x7 = 539)')""";
                    timeout = 10)
        @test occursin("= 77 (x7 = 539)", read_output(s, 1))
        TK.screenshot(s, shot("02-app1-dragged.png"))

        # ── Interaction: drag the LAST app, the one furthest from the
        # first interaction. Verifies the bridge is multiplexing
        # correctly — both apps share one eval-WS connection.
        @info "drag app #$(N_APPS) slider to 42"
        @test drag_slider!(s, N_APPS, 42) === true
        TK.wait_for(s, "app#$(N_APPS) reacted to drag",
                    """document.querySelector('.stress-app-output-$(N_APPS)')?.innerText?.includes('= 42 (x7 = 294)')""";
                    timeout = 10)
        @test occursin("= 42 (x7 = 294)", read_output(s, N_APPS))

        # ── Scroll lifecycle: scroll the chat to the top so app #1 is in
        # view + the newest is out of view, then drive app #1 again from
        # a NEW value. The live Bonito session must still be wired up.
        TK.eval_js(s, """document.querySelector('.bt-messages')?.scrollTo({top: 0, behavior: 'instant'})""")
        sleep(2.0)
        scroll_top_view = TK.eval_js(s, """(() => {
            const s1 = document.querySelector('.stress-app-slider-1 input[type="range"]');
            const sN = document.querySelector('.stress-app-slider-$(N_APPS) input[type="range"]');
            return {
                s1_present:        s1 !== null,
                sN_present:        sN !== null,
                sliders_total:     document.querySelectorAll('input[type="range"]').length,
                scroll_top:        Math.round(document.querySelector('.bt-messages').scrollTop),
            };
        })()""")
        @info "after scroll to top" scroll_top_view
        @test scroll_top_view["s1_present"] === true   # oldest still alive

        @test drag_slider!(s, 1, 88) === true
        TK.wait_for(s, "app#1 reacted to second drag after scroll",
                    """document.querySelector('.stress-app-output-1')?.innerText?.includes('= 88 (x7 = 616)')""";
                    timeout = 10)
        @test occursin("= 88 (x7 = 616)", read_output(s, 1))
        # Scroll app #1 into the viewport so the screenshot actually
        # shows the dragged value visually. `.bt-messages` is the scroll
        # container; calling scrollIntoView on a descendant works even
        # when the absolute scrollTo missed (the chat may have rebounded
        # toward the latest message after our scrollTo).
        TK.eval_js(s, """document.querySelector('.stress-app-slider-1')?.scrollIntoView({block: 'center', behavior: 'instant'})""")
        sleep(1.0)
        TK.screenshot(s, shot("03-scrolled-top-app1-dragged.png"))

        # Scroll back to bottom and drive the last app again. Verifies the
        # newest app is still functional after a round-trip scroll.
        TK.eval_js(s, """document.querySelector('.bt-messages')?.scrollTo({top: 99999, behavior: 'instant'})""")
        sleep(2.0)
        @test drag_slider!(s, N_APPS, 21) === true
        TK.wait_for(s, "app#$(N_APPS) reacted to second drag after scroll-back",
                    """document.querySelector('.stress-app-output-$(N_APPS)')?.innerText?.includes('= 21 (x7 = 147)')""";
                    timeout = 10)
        @test occursin("= 21 (x7 = 147)", read_output(s, N_APPS))
        TK.screenshot(s, shot("04-scrolled-bottom-appN-dragged.png"))

        # Canary: no "unavailable" / "timed out" / "live app unavailable"
        # text anywhere on the page after the churn — the test_bonito_app_churn
        # suite's regression check, applied here too.
        bad = TK.eval_js(s, """(document.body.innerText.match(/timed out|unavailable/gi)||[]).length""")
        @info "page error-text count" bad
        @test bad == 0

        @info "screenshots" dir=SHOT_DIR files=readdir(SHOT_DIR)
    finally
        close(s)
    end
end
