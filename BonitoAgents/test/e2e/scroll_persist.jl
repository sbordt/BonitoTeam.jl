# End-to-end scroll + persistence, UI-only via TestKit. No internal-API calls.
#
# Behaviour these tests are built around (verified by probing the live DOM):
#   * The messages list is windowed/virtualised — `.bt-user-msg` and
#     `.bt-messages.innerText` reflect only the currently-rendered window. So we
#     assert against the NEWEST exchange, which follow-mode keeps pinned at the
#     bottom and therefore rendered.
#   * Reading the chat's own client-side state (`.bt-messages.__bt_chat.*`) is
#     fair game — it's the UI's state, not a Julia internal.
#
# NOT covered here, on purpose: the "scroll up to read history disengages
# follow-mode and surfaces a new-messages pill, click it to re-engage" flow.
# That is correct, desired UX — but the chat uses a custom wheel/pan/spring
# scroller (`__bt_chat._panState/_momentumRaf/_springRaf`) that does not respond
# to a synthetic `wheel`/`scrollTop` change OR to a real
# `webContents.sendInputEvent({type:'mouseWheel'})` in a headless show=false
# window (verified: scrollTop stays pinned across all three). Driving it needs
# real hardware input on a visible window, which is out of scope for this
# headless harness — so it would need a different mechanism, not a faked assert.
#
# Run:  julia --project=. test/e2e/scroll_persist.jl

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# A fenced code block renders as a <pre> that preserves its 90 lines, so the
# messages container genuinely overflows (plain text collapses newlines and
# wouldn't).
const CODE = "```\n" * join(["row $(i) of generated output" for i in 1:90], "\n") * "\n```"

agent_script(prompt) = occursin("code", lowercase(prompt)) ? [TK.text(CODE)] : [TK.text("Echo: $(prompt)")]

const AT_BOTTOM = "(() => { const c=document.querySelector('.bt-messages'); return !!c && (c.scrollHeight - c.scrollTop - c.clientHeight) < 200; })()"
marker_present(s, m) = TK.wait_for(s, "marker $(m)",
    "(() => { const c=document.querySelector('.bt-messages'); return !!c && c.innerText.includes($(TK.json(m))); })()"; timeout = 20)

server = TK.dev_server(agent = agent_script)
try
    TK.open_browser(server)

    @testset "BonitoAgents scroll + persistence (UI-only)" begin
        pid = TK.new_chat(server; title = "Scroll")

        @testset "new content follows to the bottom" begin
            TK.send_message(server, "show me code")
            @test TK.wait_for(server, "code rendered",
                "!!document.querySelector('.bt-agent-msg pre')"; timeout = 20) == true
            # the message overflows the viewport...
            @test TK.wait_for(server, "overflowing",
                "(() => { const c=document.querySelector('.bt-messages'); return !!c && c.scrollHeight > c.clientHeight + 500; })()"; timeout = 8) == true
            # ...and the newest content is pinned at the bottom, follow-mode on.
            @test TK.wait_for(server, "pinned at bottom", AT_BOTTOM; timeout = 8) == true
            @test TK.eval_js(server, "document.querySelector('.bt-messages').__bt_chat.followMode") == true
        end

        @testset "history survives a browser reconnect" begin
            # A short, distinctive LAST message (echo, not a tall block) so the
            # marker stays in the bottom render window follow-mode pins to.
            marker = "MARKER-7f3a91"
            TK.send_message(server, marker)
            @test marker_present(server, marker) == true
            @test TK.wait_for(server, "pinned at bottom", AT_BOTTOM; timeout = 20) == true

            # Reconnect: a fresh Electron window onto the same running server.
            TK.open_browser(server)
            TK.open_chat(server, pid)
            @test marker_present(server, marker) == true
        end
    end
finally
    close(server)
end
