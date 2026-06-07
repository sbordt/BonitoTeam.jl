# Tier 2b — chat streaming. Agent message chunks accumulate in a single
# bubble, then swap to rendered markdown on `agent_final`. The busy indicator
# fades in while the prompt is in flight and out when end_turn arrives.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)

# Script: a markdown document streamed as agent_message_chunk events, split
# at awkward boundaries (mid-word, mid-`\n\n`) so we exercise newline-safe
# accumulation. The doc has a heading, two paragraphs, bold text, and a
# table — finalize must turn this into STRUCTURED html (`<h2>`, `<p>`,
# `<table>`), not a run-on blob.
scripted = [
    (0.05, TH.agent_chunk_update("## Build sum")),
    (0.05, TH.agent_chunk_update("mary\n\nThe pipeline ran with **bo")),
    (0.05, TH.agent_chunk_update("ld** success.\n\nGenerated files:\n\n| File |")),
    (0.05, TH.agent_chunk_update(" Size |\n|------|------|\n| a.png | 2.5 MB |")),
    (0.05, TH.agent_chunk_update("\n| b.png | 1.9 MB |\n\nDone.")),
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
                if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
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
        # All chunks accumulate into the SAME bubble — assert by waiting for
        # text from the first and last chunk to coexist in one bubble.
        record("all chunks landed in one bubble",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const bubbles = document.querySelectorAll('.bt-agent-msg');
                       if (bubbles.length !== 1) return false;
                       const t = bubbles[0].innerText;
                       return t.indexOf('Build summary') !== -1 && t.indexOf('Done.') !== -1;
                   })()
               """; timeout = 5.0))
        # The streaming bubble's text span must preserve newlines — without
        # `white-space: pre-wrap` on `.bt-stream-text` the markdown collapses
        # to one run-on line until finalize. Check the CSS rule is live.
        record("stream-text preserves newlines (white-space: pre-wrap)",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       for (const sheet of document.styleSheets) {
                           let rules; try { rules = sheet.cssRules; } catch(e) { continue; }
                           if (!rules) continue;
                           for (const r of rules) {
                               if (r.selectorText === '.bt-stream-text' &&
                                   /pre-wrap/.test(r.style.whiteSpace)) return true;
                           }
                       }
                       return false;
                   })()
               """))
    end

    TH.section("agent_final swaps in STRUCTURED markdown") do
        # finalize runs Markdown.parse on the accumulated text. The result
        # must be real block structure — `<strong>`, `<h2>`, a `<table>`,
        # and ≥2 `<p>` — NOT a run-on paragraph. This is the regression
        # guard for "markdown sometimes has no line breaks".
        @assert TH.wait_for(ctx, """
            (() => {
                const b = document.querySelector('.bt-agent-msg');
                return b && b.innerHTML.indexOf('<strong>bold</strong>') !== -1;
            })()
        """; timeout = 5.0) "agent_final didn't render markdown"
        structure = TH.eval_js(ctx, """
            (() => {
                const b = document.querySelector('.bt-agent-msg');
                return {
                    has_h2:     b.querySelector('h2') !== null,
                    has_table:  b.querySelector('table') !== null,
                    table_rows: b.querySelectorAll('table tr').length,
                    n_paras:    b.querySelectorAll('p').length,
                    has_strong: b.querySelector('strong') !== null,
                };
            })()
        """)
        record("heading rendered as <h2>",        @TH.test_true structure["has_h2"])
        record("bold rendered as <strong>",       @TH.test_true structure["has_strong"])
        record("table rendered as <table>",       @TH.test_true structure["has_table"])
        record("table has 3 rows (header + 2)",   @TH.test_eq structure["table_rows"] 3)
        record("paragraphs are separate blocks",
               @TH.test_true (structure["n_paras"] >= 2))
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
