# End-to-end test of the signature BonitoAgents feature: the agent renders a
# LIVE Bonito app inline in the chat (bt_show_app). This exercises the real
# path — BonitoMCP runs the code in a Malt worker, registers the app, and the
# chat mounts it over the dial-back eval bridge. UI-only assertions, no internal
# API calls.
#
# Run:  julia --project=. test/e2e/embedded_app.jl

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# The bt_show_app code runs in a Malt worker; point it at an env that has Bonito
# (the BonitoAgents package dir).
const APP_ENV = abspath(joinpath(@__DIR__, "..", ".."))

function agent_script(prompt::AbstractString)
    if occursin("app", lowercase(prompt))
        return [TK.text("Here's a little app for you:"),
                TK.bt_show_app(
                    """using Bonito; App(() -> DOM.div("EMBEDDED-OK-42"; style="padding:24px;font-size:20px"))""";
                    env_path = APP_ENV)]
    else
        return [TK.text("Echo: $(prompt)")]
    end
end

server = TK.dev_server(agent = agent_script)
try
    TK.open_browser(server)

    @testset "BonitoAgents embedded app (bt_show_app, UI-only)" begin
        TK.new_chat(server; title = "AppDemo")
        TK.send_message(server, "show me an app")

        # The Malt worker cold start + Bonito load is heavy; allow plenty of time.
        @test TK.wait_for(server, "embed container",
            "!!document.querySelector('.bt-embed-frame, .bt-app-mount, .bt-embed')"; timeout = 180) == true
        # The app's own content renders inside the embed.
        @test TK.wait_for(server, "embedded content",
            "document.body.innerText.includes('EMBEDDED-OK-42')"; timeout = 90) == true
    end
finally
    close(server)
end

# Suite passed if we reach here (a failing @testset throws first); force-terminate.
# A degraded headless Electron / wedged poller thread can otherwise stall Julia's
# normal exit until the CI step timeout. See TestKit.exit_success.
TK.exit_success()
