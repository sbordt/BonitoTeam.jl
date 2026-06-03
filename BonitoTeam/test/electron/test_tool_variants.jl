# Tool-rendering paths beyond the basic execute-with-text case covered in
# test_chat_messages.jl:
#   - kind=edit  → DiffEditor stack (single + multi-edit)
#   - kind=search → row-by-row formatted hits
#   - kind=other with bt_julia_eval-style sections (stdout / result / error)
#   - tool_call_update progression: pending → in_progress → completed in
#     place, header status pill changes, summary refreshes
#   - plan update replaces a previous plan instead of stacking
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)

# Pre-write a couple of files so the diffs reference real on-disk state
# (DiffEditor doesn't strictly need them, but it's closer to production).
proj_cwd = state.projects[]["p-1"].server_path
mkpath(joinpath(proj_cwd, "src"))
write(joinpath(proj_cwd, "src", "a.jl"), "x = 1\n")
write(joinpath(proj_cwd, "src", "b.jl"), "y = 2\n")

scripted = [
    # 1) An edit tool with TWO diffs (multi-edit case).
    (0.05, TH.tool_call_update(
        id="edit-1", kind="edit", title="multi-edit",
        status="completed",
        content=[
            TH.tool_diff(path="src/a.jl", old_text="x = 1\n", new_text="x = 11\n"),
            TH.tool_diff(path="src/b.jl", old_text="y = 2\n", new_text="y = 22\n"),
        ])),

    # 2) A search tool whose body is grep-style hit rows.
    (0.05, TH.tool_call_update(
        id="search-1", kind="search", title="rg foo",
        status="completed",
        content=[TH.tool_text("src/a.jl:1:foo bar\nsrc/b.jl:42:another foo line\nsrc/c.jl:7:and foo here")])),

    # 3) bt_julia_eval-style tool: `stdout:`, `result:` blocks parsed into
    #    separate sections.
    (0.05, TH.tool_call_update(
        id="eval-1", kind="other", title="bt_julia_eval",
        status="completed",
        content=[TH.tool_text("stdout:\nhello world\n"),
                 TH.tool_text("result:\n42\n")])),

    # 3b) bt_julia_eval with ANSI-colored console output — exercises the
    #     Bonito.RichText path: escape codes must become styled spans, not
    #     literal `\e[32m` garbage.
    (0.05, TH.tool_call_update(
        id="ansi-1", kind="other", title="bt_julia_eval",
        status="completed",
        content=[TH.tool_text("stdout:\n\e[32mGREEN\e[0m and \e[1;31mBOLDRED\e[0m\n")])),

    # 3c) Full bt_julia_eval shape: ```julia code echo + stdout + result.
    #     Renders as two collapsibles — Code / Output.
    (0.05, TH.tool_call_update(
        id="evalfull-1", kind="other", title="bt_julia_eval",
        status="completed",
        content=[TH.tool_text("```julia\nusing LinearAlgebra\nx = 1 + 2\nnorm([x, x])\n```"),
                 TH.tool_text("stdout:\nloaded LinearAlgebra\n"),
                 TH.tool_text("result:\n4.242640687119285\n")])),

    # 3d) Raw MCP wire name `mcp__<server>__<tool>` — claude-agent-acp
    #     labels MCP tool calls this way. The header must show the bare
    #     tool name + a separate server badge, not the noisy prefix.
    (0.05, TH.tool_call_update(
        id="mcpname-1", kind="other", title="mcp__bonitoteam__bt_julia_eval",
        status="completed",
        content=[TH.tool_text("done")])),

    # 4) tool_call_update progression: pending → in_progress → completed.
    (0.05, TH.tool_call_update(
        id="prog-1", kind="execute", title="long task",
        status="pending",
        content=[])),
    (0.10, TH.tool_update(id="prog-1", status="in_progress")),
    (0.10, TH.tool_update(id="prog-1", status="completed",
                            content=[TH.tool_text("done")])),

    # 5) Two consecutive plan updates — the second should REPLACE the
    #    first's bubble (we don't currently dedup; assert what actually
    #    happens so a future change is visible).
    (0.05, TH.plan_update([
        (content="step 1", status="in_progress", priority="medium"),
        (content="step 2", status="pending",     priority="medium"),
    ])),
    (0.05, TH.plan_update([
        (content="step 1", status="completed",   priority="medium"),
        (content="step 2", status="in_progress", priority="medium"),
        (content="step 3", status="pending",     priority="medium"),
    ])),
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
    p1_idx = TH.eval_js(ctx, """(() => {
        const items = document.querySelectorAll('.bt-side-item .bt-side-name');
        for (let i = 0; i < items.length; i++) if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
        return -1; })()""")
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "no chat"

    TH.section("Trigger the streaming script") do
        TH.type_into(ctx, ".bt-text-input", "go")
        TH.dom_click(ctx, ".bt-send-btn")
        # All four tool bubbles + at least one plan bubble eventually arrive.
        record("expected tool bubbles arrive",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-tool-msg').length >= 4"; timeout = 8.0))
        record("plan bubble arrives",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-plan-msg').length >= 1"; timeout = 8.0))
    end

    TH.section("Multi-edit DiffEditor stack") do
        # Expand the edit tool body.
        TH.eval_js(ctx, "(() => { const h = document.querySelector('.bt-tool-header[data-expanded=\"false\"]'); if (h && h.parentElement.querySelector('.bt-tool-body[data-tool-id=\"edit-1\"]')) h.click(); else { document.querySelectorAll('.bt-tool-msg').forEach(m => { if (m.querySelector('.bt-tool-body[data-tool-id=\"edit-1\"]')) m.querySelector('.bt-tool-header').click(); }); } })()")
        record("two diff blocks render",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="edit-1"]');
                       return slot && slot.querySelectorAll('.bt-diff-block').length === 2;
                   })()
               """; timeout = 6.0))
        record("file paths surface in diff headers",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="edit-1"]');
                       const t = slot ? slot.innerText : '';
                       return t.indexOf('src/a.jl') !== -1 && t.indexOf('src/b.jl') !== -1;
                   })()
               """))
        # multi-edit class on the wrapping div, separating diffs visually.
        record("wrapper has bt-multi-diff class",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="edit-1"]');
                       return slot && slot.querySelector('.bt-multi-diff') !== null;
                   })()
               """))
    end

    TH.section("Search tool: per-row formatting") do
        TH.eval_js(ctx, "(() => { document.querySelectorAll('.bt-tool-msg').forEach(m => { if (m.querySelector('.bt-tool-body[data-tool-id=\"search-1\"]')) m.querySelector('.bt-tool-header').click(); }); })()")
        record("3 search-row entries",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="search-1"]');
                       return slot && slot.querySelectorAll('.bt-search-row').length === 3;
                   })()
               """; timeout = 5.0))
        # Each row carries the path, line number, and snippet in its own
        # span. Assert the path span contains the file name.
        record("first row path is src/a.jl",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="search-1"]');
                       const path = slot ? slot.querySelector('.bt-search-row .bt-search-path') : null;
                       return path && path.innerText === 'src/a.jl';
                   })()
               """))
    end

    TH.section("Eval sections: stdout / result rendered as labelled cards") do
        TH.eval_js(ctx, "(() => { document.querySelectorAll('.bt-tool-msg').forEach(m => { if (m.querySelector('.bt-tool-body[data-tool-id=\"eval-1\"]')) m.querySelector('.bt-tool-header').click(); }); })()")
        record("two .bt-eval-section blocks render",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="eval-1"]');
                       return slot && slot.querySelectorAll('.bt-eval-section').length === 2;
                   })()
               """; timeout = 5.0))
        labels = TH.eval_js(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="eval-1"]');
                const ls = slot ? slot.querySelectorAll('.bt-section-label') : [];
                return Array.from(ls).map(e => e.innerText).join('|');
            })()
        """)
        record("labels include STDOUT and RESULT",
               @TH.test_true (occursin("STDOUT", labels) && occursin("RESULT", labels)))
    end

    TH.section("ANSI console output renders as styled spans (Bonito.RichText)") do
        TH.eval_js(ctx, "(() => { document.querySelectorAll('.bt-tool-msg').forEach(m => { if (m.querySelector('.bt-tool-body[data-tool-id=\"ansi-1\"]')) m.querySelector('.bt-tool-header').click(); }); })()")
        @assert TH.wait_for(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="ansi-1"]');
                return slot && slot.querySelector('.bt-console') !== null;
            })()
        """; timeout = 5.0) "ansi-1 console block didn't render"
        info = TH.eval_js(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="ansi-1"]');
                const term = slot.querySelector('.terminal-output');
                const text = term ? term.innerText : '';
                return {
                    has_terminal: term !== null,
                    // ANSIColoredPrinters emits `span.sgr32` (green) etc.
                    green_span:  slot.querySelector('span.sgr32') !== null,
                    red_span:    slot.querySelector('span.sgr31') !== null,
                    // The visible text must NOT contain raw escape codes.
                    has_raw_esc: text.indexOf('[32m') !== -1 || text.indexOf('[0m') !== -1,
                    text: text,
                };
            })()
        """)
        record("RichText terminal-output element present",
               @TH.test_true info["has_terminal"])
        record("green ANSI code became span.sgr32",
               @TH.test_true info["green_span"])
        record("red ANSI code became span.sgr31",
               @TH.test_true info["red_span"])
        record("no raw escape codes in the rendered text",
               @TH.test_eq info["has_raw_esc"] false)
        record("decoded text carries the words",
               @TH.test_true (occursin("GREEN", info["text"]) &&
                              occursin("BOLDRED", info["text"])))
    end

    TH.section("Full bt_julia_eval renders Code + Output collapsibles") do
        TH.eval_js(ctx, "(() => { document.querySelectorAll('.bt-tool-msg').forEach(m => { if (m.querySelector('.bt-tool-body[data-tool-id=\"evalfull-1\"]')) m.querySelector('.bt-tool-header').click(); }); })()")
        @assert TH.wait_for(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="evalfull-1"]');
                return slot && slot.querySelector('.bt-eval-body') !== null;
            })()
        """; timeout = 5.0) "evalfull-1 eval body didn't render"
        info = TH.eval_js(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="evalfull-1"]');
                const subs = slot.querySelectorAll('details.bt-subsection');
                const labels = Array.from(subs).map(d =>
                    d.querySelector('.bt-subsection-label').innerText);
                const codeSub = Array.from(subs).find(d =>
                    d.querySelector('.bt-subsection-label').innerText === 'CODE');
                const outSub = Array.from(subs).find(d =>
                    d.querySelector('.bt-subsection-label').innerText === 'OUTPUT');
                // Code preview text in the summary (dim first line).
                const preview = codeSub ?
                    (codeSub.querySelector('.bt-subsection-preview') || {}).innerText : null;
                // Output collapsible should contain the eval-section stack.
                const outSections = outSub ?
                    outSub.querySelectorAll('.bt-eval-section').length : 0;
                return {
                    n_subs: subs.length,
                    labels: labels.join('|'),
                    both_open: subs.length === 2 &&
                               Array.from(subs).every(d => d.open),
                    code_preview: preview,
                    out_sections: outSections,
                };
            })()
        """)
        record("two .bt-subsection collapsibles render",
               @TH.test_eq info["n_subs"] 2)
        record("collapsibles are labelled CODE and OUTPUT",
               @TH.test_eq info["labels"] "CODE|OUTPUT")
        record("both collapsibles open by default",
               @TH.test_true info["both_open"])
        record("Code summary shows a first-line preview",
               @TH.test_true (info["code_preview"] !== nothing &&
                              occursin("using LinearAlgebra", info["code_preview"])))
        record("Output collapsible holds the stdout+result sections",
               @TH.test_eq info["out_sections"] 2)

        # Folding the Code collapsible hides its body but leaves Output.
        TH.eval_js(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="evalfull-1"]');
                const subs = slot.querySelectorAll('details.bt-subsection');
                subs[0].removeAttribute('open');
            })()
        """)
        sleep(0.2)
        folded = TH.eval_js(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="evalfull-1"]');
                const subs = slot.querySelectorAll('details.bt-subsection');
                return {code_open: subs[0].open, output_open: subs[1].open};
            })()
        """)
        record("Code folds independently of Output",
               @TH.test_true (folded["code_open"] == false &&
                              folded["output_open"] == true))
    end

    TH.section("MCP tool header: prefix stripped, server shown as badge") do
        info = TH.eval_js(ctx, """
            (() => {
                const cards = document.querySelectorAll('.bt-tool-msg');
                for (const c of cards) {
                    if (!c.querySelector('.bt-tool-body[data-tool-id="mcpname-1"]')) continue;
                    const title  = c.querySelector('.bt-tool-title');
                    const server = c.querySelector('.bt-tool-server');
                    return {
                        title:  title  ? title.innerText  : null,
                        server: server ? server.innerText : null,
                    };
                }
                return null;
            })()
        """)
        @assert info !== nothing "couldn't find mcpname-1 tool card"
        record("title is the bare tool name (no mcp__ prefix)",
               @TH.test_eq info["title"] "bt_julia_eval")
        record("server badge shows the MCP server name",
               @TH.test_eq info["server"] "bonitoteam")
    end

    TH.section("tool_call_update progression: status pill updates in place") do
        # The 'prog-1' tool started pending and ended up completed; we wait
        # for the final state and then assert the status pill reflects it.
        record("prog-1 status pill shows 'completed'",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const cards = document.querySelectorAll('.bt-tool-msg');
                       for (const c of cards) {
                           const body = c.querySelector('.bt-tool-body[data-tool-id="prog-1"]');
                           if (!body) continue;
                           const s = c.querySelector('.bt-tool-status');
                           return s && s.innerText === 'completed';
                       }
                       return false;
                   })()
               """; timeout = 6.0))
        # Only ONE tool bubble for this id (in-place update, not a stack).
        n_with_id = TH.eval_js(ctx, """
            Array.from(document.querySelectorAll('.bt-tool-body[data-tool-id="prog-1"]')).length
        """)
        record("exactly one bubble for prog-1", @TH.test_eq n_with_id 1)
    end

    TH.section("Plan: the second update absorbs into the first bubble") do
        # The live-tracking consolidation: each new plan/TodoWrite event
        # ABSORBS into the previous TodoListMsg instead of spawning a new
        # bubble. Two events → still one .bt-plan-msg.
        n_plans = TH.eval_js(ctx, "document.querySelectorAll('.bt-plan-msg').length")
        record("one plan bubble after consecutive updates",
               @TH.test_eq Int(n_plans) 1)
        # The latest plan has 3 entries; the earlier had 2.
        latest_entries = TH.eval_js(ctx, """
            (() => {
                const all = document.querySelectorAll('.bt-plan-msg');
                if (all.length === 0) return -1;
                return all[all.length-1].querySelectorAll('.bt-plan-entry').length;
            })()
        """)
        record("latest plan has 3 entries", @TH.test_eq Int(latest_entries) 3)
    end

    TH.section("No JS errors") do
        record("zero JS errors",
               @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "tool variants — final")

finally
    TH.report!("Tool variants", results)
    TH.shutdown(ctx)
end
