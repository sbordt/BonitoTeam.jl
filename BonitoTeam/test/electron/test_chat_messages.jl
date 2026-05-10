# Tier 2c — tool / thought / plan messages.
#
# Tool: header renders collapsed; click expands; body lazy-loads via
#       requestToolRender + dom_in_js; click again collapses.
# Thought: bubble renders collapsed; expanding the <details> fires
#       requestThoughtRender; body shows the rendered HTML.
# Plan: rows with status glyphs render directly from the initial event.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)

# Script: first emit a tool_call (execute kind, completed status, with a text
# body so render_tool_body produces a Monaco/markdown block); then a thought
# chunk; then a plan with three entries. Order matters — finalize_streaming
# runs between disjoint event types, so all three end up as separate bubbles.
scripted = [
    (0.05, TH.tool_call_update(
        id="t-1", kind="execute", title="ls -la", status="completed",
        content=[TH.tool_text("file1.txt\nfile2.txt\nfile3.txt")])),
    (0.05, TH.thought_chunk_update("Looking at the three files...")),
    (0.05, TH.thought_chunk_update(" planning next step.")),
    (0.05, TH.plan_update([
        (content="Read files",   status="completed",   priority="medium"),
        (content="Analyze",      status="in_progress", priority="medium"),
        (content="Write report", status="pending",     priority="medium"),
    ])),
]

let proj = state.projects["p-1"]
    model = BonitoTeam.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  client_factory = TH.mock_factory(; scripted))
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

    TH.section("Trigger streaming") do
        TH.type_into(ctx, ".bt-text-input", "do stuff")
        TH.dom_click(ctx, ".bt-send-btn")
        record("user bubble appears",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-user-msg').length >= 1"))
    end

    TH.section("Tool message header") do
        record("tool bubble mounted",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-tool-msg').length >= 1"; timeout = 5.0))
        title = TH.eval_js(ctx, "document.querySelector('.bt-tool-title').innerText")
        record("tool title is 'ls -la'", @TH.test_eq title "ls -la")
        status = TH.eval_js(ctx, "document.querySelector('.bt-tool-status').innerText")
        record("tool status is 'completed'", @TH.test_eq status "completed")
        # Header starts collapsed.
        expanded = TH.eval_js(ctx, "document.querySelector('.bt-tool-header').dataset.expanded")
        record("header collapsed initially", @TH.test_eq expanded "false")
    end

    TH.section("Tool body lazy-loads on click") do
        TH.dom_click(ctx, ".bt-tool-header")
        # First the loading placeholder appears synchronously, then the lazy
        # render handler ships back the body via dom_in_js.
        record("body has content after expand",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const b = document.querySelector('.bt-tool-body');
                       if (!b) return false;
                       const txt = b.innerText || '';
                       return txt.indexOf('file1.txt') !== -1 || txt.indexOf('file2.txt') !== -1;
                   })()
               """; timeout = 6.0))
        expanded = TH.eval_js(ctx, "document.querySelector('.bt-tool-header').dataset.expanded")
        record("header marked expanded", @TH.test_eq expanded "true")
    end

    TH.section("Tool body collapses on second click") do
        TH.dom_click(ctx, ".bt-tool-header")
        record("body cleared after collapse",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-tool-body').innerHTML === ''"; timeout = 2.0))
        expanded = TH.eval_js(ctx, "document.querySelector('.bt-tool-header').dataset.expanded")
        record("header marked collapsed", @TH.test_eq expanded "false")
    end

    TH.section("Thought bubble") do
        record("thought bubble mounted",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-thought-msg').length >= 1"; timeout = 5.0))
        # While streaming, the summary says "Thinking…". After end_turn, the
        # summary swaps to "N lines" (set by msg_to_dict for ThoughtMsg).
        record("summary present",
               @TH.test_true TH.eval_js(ctx, "document.querySelector('.bt-thought-summary') !== null"))
    end

    TH.section("Thought body lazy-loads on expand") do
        # Open the <details>: setting open=true fires the `toggle` event the
        # wireThoughtToggle listener uses.
        TH.eval_js(ctx, """
            const d = document.querySelector('.bt-thought-details');
            if (d) d.open = true;
        """)
        record("thought body has accumulated text",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const d = document.querySelector('.bt-thought-details');
                       const t = d ? d.innerText : '';
                       return t.indexOf('Looking at the three files') !== -1
                           && t.indexOf('planning next step') !== -1;
                   })()
               """; timeout = 6.0))
    end

    TH.section("Plan message") do
        record("plan bubble mounted",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-plan-msg').length >= 1"; timeout = 5.0))
        n_entries = TH.dom_count(ctx, ".bt-plan-entry")
        record("3 plan entries", @TH.test_eq n_entries 3)
        # Status glyphs: ✓ for completed, ▶ for in_progress, ○ for pending.
        # The text content of all .bt-plan-status spans concatenated should
        # contain all three.
        text = TH.eval_js(ctx, """
            Array.from(document.querySelectorAll('.bt-plan-status')).map(e => e.innerText).join('|')
        """)
        record("status glyphs present",
               @TH.test_true (occursin("✓", text) && occursin("▶", text) && occursin("○", text)))
    end

    TH.section("No JS errors") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_true (length(errs) == 0))
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "tier 2c — tool/thought/plan")

finally
    TH.report!("Tier 2c — tool/thought/plan messages", results)
    TH.shutdown(ctx)
end
