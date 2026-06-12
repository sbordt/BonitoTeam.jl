# End-to-end test for `bt_show_app` via the TestKit dispatcher.
#
# Flow exercised:
#   1. Test boots `dev_server` (real worker, real WorkerTransport, real
#      ACP wire). The dispatcher is wired so a `bt_show_app(code)` event
#      in the agent script lands in `BonitoMCP.julia_show_app_handler`.
#   2. The handler spawns a Malt worker (per env_path), the worker
#      `include_string`s the test's Julia code (which must evaluate to a
#      `Bonito.App`), registers it via `RemoteProxy.register_app!`, then
#      `prerender_app`s it.
#   3. The worker dials back to OUR dev_server via the eval-WS bridge
#      (using BONITOAGENTS_SERVER_URL + BONITOAGENTS_SECRET we publish into
#      ENV before the Malt spawn — production has the worker subprocess
#      set these from its agent_env, the test substitutes them
#      explicitly).
#   4. The handler returns `shown_app: <id>` → dispatcher forwards it to
#      the mock as `bt_show_app_result` → the mock emits an ACP
#      `tool_call` whose `_meta.claudeCode.toolName =
#      mcp__btworker__bt_show_app`. The ACP parser turns that into an
#      `MCPCall` with `tool_name == "bt_show_app"`, which
#      `is_bonito_app(::MCPCall)` recognises so the chat builds a
#      `BonitoAppMsg`.
#   5. The chat embeds the live app body via the eval bridge; the browser
#      renders the actual Bonito DOM. Screenshot verifies.

using Test, JSON
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit
const TK = TestKit
using .TestKit: text, bt_show_app, end_turn

const SHOT_DIR = joinpath(tempdir(), "bt-show-app-e2e")
mkpath(SHOT_DIR)
shot(name) = joinpath(SHOT_DIR, name)

# Tmp project for the app eval session — bare Project.toml is enough since
# the test app uses only Bonito (already loaded in the root project).
function fresh_project(name::AbstractString)
    d = mktempdir(; prefix = "bt-show-app-$(name)-")
    open(joinpath(d, "Project.toml"), "w") do io
        write(io, """
        name = "$(name)"
        uuid = "$(string(Base.UUID(rand(UInt128))))"
        version = "0.0.1"

        [deps]
        """)
    end
    return d
end

# The agent's code that bt_show_app evaluates. Final value must be a
# `Bonito.App` — when included in the Malt worker it lands as
# `Bonito.App` from the inherited environment. The body just renders a
# distinctive `<h2>` so the screenshot probe has a strict pixel anchor.
const APP_CODE = """
using Bonito
Bonito.App() do session
    return DOM.div(
        DOM.h2("TestKit bt_show_app";
               style="color:#0f766e;font-family:ui-sans-serif,system-ui"),
        DOM.p("If you can read this in a screenshot, the embed pipeline works.");
        style="padding:24px 28px;background:#ecfeff;border-radius:12px;
               border:1px solid #67e8f9;margin:8px 0")
end
"""

@testset "bt_show_app e2e — Bonito.App embeds into chat" begin
    # Use the user's root project as env_path. `bt_show_app` requires Bonito
    # available in the eval worker's env to `using Bonito` for the
    # RemoteProxy setup — an empty tmp Project.toml would have no
    # registered Bonito and Pkg.instantiate is off-limits per CLAUDE.md.
    # The root project has the working Bonito the dev test stack uses.
    project = abspath(pwd())
    @info "app project env" project

    s = TK.dev_server(; agent = msg -> [
        text("I'll show you the test app."),
        bt_show_app(APP_CODE; env_path = project, id = "ta-1"),
        text("There it is."),
    ])
    try
        TK.open_browser(s; width = 1280, height = 880)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)
        TK.send_message(s, "please show me a bt_show_app demo")

        # The bt_show_app pipeline is heavier than bt_eval — it spins up a
        # Malt worker, registers an app, dials a fresh WS back. Give the
        # whole chain 90s, which is comfortably more than the prerender +
        # bridge handshake on a cold cache.
        TK.wait_for(s, "BonitoAppMsg mounted",
                    """document.querySelector('.bt-tool-msg .bt-tool-status')?.textContent === 'completed'""";
                    timeout = 90)
        sleep(2)

        # The auto-expand path should have mounted the embed body already
        # (BonitoAppMsg auto_expand_body fires once app_id lands). Verify
        # by checking the embed root + content text. The h2 'TestKit
        # bt_show_app' is the canary string from APP_CODE.
        snap = TK.eval_js(s, """(() => {
            const tool = document.querySelector('.bt-tool-msg');
            if (!tool) return {error: 'no tool'};
            const body_text = (tool.querySelector('.bt-tool-body')?.innerText || '');
            return {
                tool_count: document.querySelectorAll('.bt-tool-msg').length,
                tool_status: tool.querySelector('.bt-tool-status')?.textContent || null,
                tool_title: tool.querySelector('.bt-tool-title')?.textContent || null,
                contains_canary: body_text.includes('TestKit bt_show_app'),
                contains_blurb: body_text.includes('the embed pipeline works'),
                body_snippet: body_text.slice(0, 200),
                iframe_count: tool.querySelectorAll('iframe').length,
            };
        })()""")
        @info "DOM after bt_show_app" snap

        @test snap["tool_count"] >= 1
        @test snap["tool_status"] == "completed"
        @test snap["contains_canary"] === true
        @test snap["contains_blurb"]  === true

        TK.screenshot(s, shot("bt_show_app-rendered.png"))
        @info "screenshot saved" path=shot("bt_show_app-rendered.png")
    finally
        close(s)
    end
end
