# BonitoAgents walkthrough, recorded with ElectronCall's animated-cursor
# recorder. Drives the real app (dev server + worker + mock ACP agent) through
# the UI: type a prompt, send it, watch the agent stream a reply and an edit
# tool call, expand the tool to reveal the diff.
#
# Run:  julia --project=. test/../examples/walkthrough.jl   (from BonitoAgents/)
# Out:  examples/walkthrough.mp4

include(joinpath(@__DIR__, "..", "test", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

import ElectronCall
const ECT = ElectronCall.Testing
using .ECT: install_cursor, record_video, play, MouseTo, Click, TypeText, Wait, Sel, Do, eval_js

function agent_script(prompt::AbstractString)
    p = lowercase(prompt)
    if occursin("edit", p)
        return [TK.text("Sure — I'll update the config for you."),
                TK.edit("/project/config.toml",
                        "timeout = 30\nretries = 3",
                        "timeout = 60\nretries = 5"),
                TK.text("Done. Bumped the timeout to 60s and retries to 5.")]
    else
        return [TK.text("You said: $(prompt)")]
    end
end

function run(; outpath = joinpath(@__DIR__, "walkthrough.mp4"))
    server = TK.dev_server(agent = agent_script)
    try
        TK.open_browser(server)
        ctx = server.browser[]
        # Set up an open chat before recording (the folder picker isn't the
        # interesting part of this demo).
        TK.new_chat(server; title = "ConfigEdit")
        TK.set_window_size(server, 1280, 860)
        sleep(1.0)

        install_cursor(ctx; start = (250, 760))
        sleep(0.5)

        prompt = "please edit the config file"
        record_video(ctx, outpath; fps = 30) do
            play(ctx, [
                Wait(1.0),
                # Compose a prompt (animated typing for the look)
                MouseTo(Sel(".bt-text-input")), Click(),
                TypeText(prompt; char_duration = 0.045),
                Wait(0.3),
                # Guarantee the composer value is registered, then send.
                Do(_ -> TK.set_input(server, ".bt-text-input", prompt)),
                MouseTo(Sel(".bt-send-btn")), Click(),
                # Wait for the agent's edit tool to render before pointing at it.
                Do(_ -> TK.wait_for(server, "edit tool",
                                    "document.querySelectorAll('.bt-tool-msg').length > 0"; timeout = 20)),
                Wait(0.8),
                # Expand the tool to reveal the diff.
                MouseTo(Sel(".bt-tool-header")), Click(),
                Wait(2.5),
                MouseTo((640, 430)), Wait(1.0),
            ])
        end

        errs = eval_js(ctx, "window.__errs || []")
        isempty(errs) || @warn "JS errors during walkthrough" errs
        @info "wrote $outpath"
    finally
        close(server)
    end
    return outpath
end

run()
