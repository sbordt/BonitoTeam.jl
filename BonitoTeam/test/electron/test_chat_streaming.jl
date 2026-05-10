# Tier 2b — chat streaming. Agent message chunks accumulate in a single
# bubble, then swap to rendered markdown on `agent_final`. The busy indicator
# fades in while the prompt is in flight and out when end_turn arrives.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)

# Script: three agent_message_chunk events ("Hello, ", "**world**", "!"), with
# small delays so the JS side has time to apply each chunk before the next.
# Final result should be a single agent bubble, with `<strong>world</strong>`
# in the rendered HTML once the prompt completes.
scripted = [
    (0.05, TH.agent_chunk_update("Hello, ")),
    (0.05, TH.agent_chunk_update("**world**")),
    (0.05, TH.agent_chunk_update("!")),
]

let proj = state.projects[]["p-1"]
    model = BonitoTeam.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport(; scripted))
    BonitoTeam.start_chat_client!(model)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    p1_idx = TH.eval_js(ctx, """
        (() => {
            const items = document.querySelectorAll('.bt-side-item .bt-side-name');
            for (let i = 0; i < items.length; i++)
                if (items[i].innerText === 'Project1') return i;
            return -1;
        })()
    """)
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "chat didn't mount"

    TH.section("Send prompt → triggers streaming") do
        TH.type_into(ctx, ".bt-text-input", "say hi")
        TH.dom_click(ctx, ".bt-send-btn")
        record("user bubble appears",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-user-msg').length >= 1"))
    end

    TH.section("Agent bubble accumulates chunks") do
        # First chunk should produce one agent bubble.
        record("agent bubble appears",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-agent-msg').length >= 1";
                   timeout = 5.0))
        # All three chunks accumulate into the SAME bubble — assert by waiting
        # for the full text "Hello, **world**!" to be present (rendered as raw
        # text during streaming, before the agent_final swap to markdown).
        record("all three chunks landed in one bubble",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const bubbles = document.querySelectorAll('.bt-agent-msg');
                       if (bubbles.length !== 1) return false;
                       const t = bubbles[0].innerText;
                       return t.indexOf('Hello,') !== -1 && t.indexOf('world') !== -1 && t.indexOf('!') !== -1;
                   })()
               """; timeout = 5.0))
    end

    TH.section("agent_final swaps in rendered markdown") do
        # The final event runs Markdown.parse on the accumulated text, so
        # `**world**` becomes `<strong>world</strong>`. Wait for it.
        record("strong tag appears",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const b = document.querySelector('.bt-agent-msg');
                       return b && b.innerHTML.indexOf('<strong>world</strong>') !== -1;
                   })()
               """; timeout = 5.0))
    end

    TH.section("Busy indicator clears at end_turn") do
        # `.bt-busy.bt-busy-active` is the visible state; without `bt-busy-active`
        # the height: 0 collapses the indicator to invisible. After end_turn,
        # busy_end fires and the active class is removed.
        record("busy indicator inactive after stream finishes",
               @TH.test_true TH.wait_for(ctx,
                   "!document.querySelector('.bt-busy').classList.contains('bt-busy-active')";
                   timeout = 5.0))
    end

    TH.section("Send a second prompt — still works after first ends") do
        before = TH.dom_count(ctx, ".bt-agent-msg")
        TH.type_into(ctx, ".bt-text-input", "again")
        TH.dom_click(ctx, ".bt-send-btn")
        record("second agent bubble appears",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-agent-msg').length >= $(before+1)";
                   timeout = 5.0))
    end

    TH.section("No JS errors") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_true (length(errs) == 0))
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "tier 2b — after streaming")

finally
    TH.report!("Tier 2b — chat streaming", results)
    TH.shutdown(ctx)
end
