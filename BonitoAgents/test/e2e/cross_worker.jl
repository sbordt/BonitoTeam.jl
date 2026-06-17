# End-to-end cross-worker registration, UI-only via TestKit. A second worker
# process registers against the same dev server (as a second machine running
# the installer would), the dashboard shows both online, and killing one drops
# the online count. We read only the rendered DOM; spawning/killing worker
# processes are real-world actions, not fake state pokes.
#
# Run:  julia --project=. test/e2e/cross_worker.jl

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# Predicate: the "N /M workers online" header has exactly `n` online.
online_is(n) = "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*workers online/); return m && parseInt(m[1]) === $(n); })()"

server = TK.dev_server(agent = p -> [TK.text("hi")])
try
    TK.open_browser(server)
    TK.to_dashboard(server)

    @testset "BonitoAgents cross-worker (UI-only)" begin
        @testset "one worker online initially" begin
            @test TK.wait_for(server, "1 online", online_is(1); timeout = 15) == true
        end

        local w2
        @testset "a second worker registers and shows online" begin
            w2 = TK.add_worker!(server; name = "worker-2")
            # The always-visible header count is the definitive signal that a
            # distinct second worker registered (its card lives under the
            # collapsible "Add another worker" section, so its name isn't in the
            # visible innerText — the count is what we assert on).
            @test TK.wait_for(server, "2 online", online_is(2); timeout = 20) == true
        end

        @testset "killing the second worker drops the online count" begin
            kill(w2)   # the second machine goes offline
            @test TK.wait_for(server, "back to 1 online", online_is(1); timeout = 15) == true
        end
    end
finally
    close(server)
end
