# Coverage for the tool kinds that didn't have a dedicated test:
#   - read   → render_tool_body picks Monaco lang from filename extension
#   - delete → falls through to render_text_block default
#   - move   → content_summary parses "src → dst" from text, default body
#   - think  → falls through (kind is distinct from ThoughtMsg type!)
#   - fetch  → content_summary extracts URL domain
#
# Plus the new `edit` inline preview: shown above the lazy body, capped at
# ~100px with a fade, includes -/+ lines and the file path.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]

# Pre-write the file the `read` tool will reference, so render_tool_body
# can run detect_language("a.py") → "python".
mkpath(joinpath(proj.server_path, "src"))
write(joinpath(proj.server_path, "src", "a.py"),
      "def hello():\n    print('hi from python')\n")

scripted = [
    # 1) read kind — body should mount Monaco with python highlighting
    (0.05, TH.tool_call_update(
        id="read-1", kind="read", title="src/a.py",
        status="completed",
        content=[TH.tool_text("def hello():\n    print('hi from python')\n")])),

    # 2) delete kind — default body, just the text
    (0.05, TH.tool_call_update(
        id="del-1", kind="delete", title="rm tmp.txt",
        status="completed",
        content=[TH.tool_text("removed: /tmp/scratch/tmp.txt")])),

    # 3) move kind — content_summary should pull "src → dst"
    (0.05, TH.tool_call_update(
        id="mv-1", kind="move", title="mv",
        status="completed",
        content=[TH.tool_text("moved /tmp/old.txt -> /tmp/new.txt successfully")])),

    # 4) think kind (TOOL kind, not the streaming ThoughtMsg)
    (0.05, TH.tool_call_update(
        id="think-1", kind="think", title="reflection",
        status="completed",
        content=[TH.tool_text("considering the trade-offs between A and B...")])),

    # 5) fetch kind — content_summary should pull the domain
    (0.05, TH.tool_call_update(
        id="fetch-1", kind="fetch", title="https://example.com/docs",
        status="completed",
        content=[TH.tool_text("Fetched 4321 bytes from https://example.com/docs/page.html")])),

    # 6) edit kind — exercises the new inline preview path
    (0.05, TH.tool_call_update(
        id="edit-prev-1", kind="edit", title="src/a.py",
        status="completed",
        content=[TH.tool_diff(
            path     = "src/a.py",
            old_text = "def hello():\n    print('hi from python')\n",
            new_text = "def hello(name):\n    print(f'hi {name} from python')\n    return 0\n")])),

    # 7) multi-edit — preview should mention "+ N more files"
    (0.05, TH.tool_call_update(
        id="edit-multi-1", kind="edit", title="multi",
        status="completed",
        content=[
            TH.tool_diff(path="a.jl", old_text="x = 1\n", new_text="x = 11\n"),
            TH.tool_diff(path="b.jl", old_text="y = 2\n", new_text="y = 22\n"),
            TH.tool_diff(path="c.jl", old_text="z = 3\n", new_text="z = 33\n"),
        ])),
]

let
    model = BonitoTeam.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport(; scripted))
    BonitoTeam.start_chat_client!(model)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

# Helper: click the header of a tool by its id.
expand_tool(id) = TH.eval_js(ctx, """
    (() => {
        document.querySelectorAll('.bt-tool-msg').forEach(m => {
            if (m.querySelector(`.bt-tool-body[data-tool-id="$id"]`))
                m.querySelector('.bt-tool-header').click();
        });
    })()
""")

try
    p1_idx = TH.eval_js(ctx, """(() => { const items = document.querySelectorAll('.bt-side-item .bt-side-name'); for (let i=0; i<items.length; i++) if (items[i].innerText.split(' · ')[0]==='Project1') return i; return -1; })()""")
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "no chat"

    TH.section("Trigger the script") do
        TH.type_into(ctx, ".bt-text-input", "exercise tool kinds")
        TH.dom_click(ctx, ".bt-send-btn")
        record("seven tool bubbles arrive",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-tool-msg').length >= 7"; timeout = 8.0))
    end

    TH.section("Tool icons map by kind") do
        # Every kind we sent has its own icon character; verify the .bt-tool-kind
        # span carries the right one for at least the distinctive ones.
        function icon_for(id)
            TH.eval_js(ctx, """
                (() => {
                    const cards = document.querySelectorAll('.bt-tool-msg');
                    for (const c of cards) {
                        const body = c.querySelector('.bt-tool-body[data-tool-id="$id"]');
                        if (!body) continue;
                        const k = c.querySelector('.bt-tool-kind');
                        return k ? k.innerText : null;
                    }
                    return null;
                })()
            """)
        end
        record("read icon 📄",   @TH.test_eq icon_for("read-1")  "📄")
        record("delete icon 🗑️", @TH.test_eq icon_for("del-1")   "🗑️")
        record("move icon 📦",   @TH.test_eq icon_for("mv-1")    "📦")
        record("think icon 💭",  @TH.test_eq icon_for("think-1") "💭")
        record("fetch icon 🌐",  @TH.test_eq icon_for("fetch-1") "🌐")
    end

    TH.section("read body → Monaco mounts (python language)") do
        expand_tool("read-1")
        record("monaco editor mounts in read body",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="read-1"]');
                       return slot && slot.querySelector('.monaco-editor') !== null;
                   })()
               """; timeout = 6.0))
    end

    TH.section("move tool: summary shows 'old.txt → new.txt'") do
        summary = TH.eval_js(ctx, """
            (() => {
                const cards = document.querySelectorAll('.bt-tool-msg');
                for (const c of cards) {
                    const body = c.querySelector('.bt-tool-body[data-tool-id="mv-1"]');
                    if (!body) continue;
                    const s = c.querySelector('.bt-tool-summary');
                    return s ? s.innerText : null;
                }
                return null;
            })()
        """)
        record("summary contains 'old.txt → new.txt'",
               @TH.test_true (summary isa AbstractString
                              && occursin("old.txt", summary)
                              && occursin("new.txt", summary)))
    end

    TH.section("fetch tool: summary shows the domain") do
        summary = TH.eval_js(ctx, """
            (() => {
                const cards = document.querySelectorAll('.bt-tool-msg');
                for (const c of cards) {
                    const body = c.querySelector('.bt-tool-body[data-tool-id="fetch-1"]');
                    if (!body) continue;
                    const s = c.querySelector('.bt-tool-summary');
                    return s ? s.innerText : null;
                }
                return null;
            })()
        """)
        record("summary contains 'example.com'",
               @TH.test_true (summary isa AbstractString && occursin("example.com", summary)))
    end

    TH.section("delete + think tools: default text body renders cleanly") do
        for id in ("del-1", "think-1")
            expand_tool(id)
        end
        record("delete body has the text",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="del-1"]');
                       return slot && (slot.innerText || '').indexOf('removed') !== -1;
                   })()
               """; timeout = 5.0))
        record("think body has the text",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="think-1"]');
                       return slot && (slot.innerText || '').indexOf('trade-offs') !== -1;
                   })()
               """; timeout = 5.0))
    end

    TH.section("Edit inline preview (single diff) — visible BEFORE expanding") do
        # No click — assert the preview is already in the DOM right under the
        # collapsed header.
        record("preview present without expansion",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const cards = document.querySelectorAll('.bt-tool-msg');
                       for (const c of cards) {
                           if (!c.querySelector('.bt-tool-body[data-tool-id="edit-prev-1"]')) continue;
                           return c.querySelector('.bt-edit-preview') !== null;
                       }
                       return false;
                   })()
               """; timeout = 5.0))
        # Header still says collapsed.
        expanded = TH.eval_js(ctx, """
            (() => {
                const cards = document.querySelectorAll('.bt-tool-msg');
                for (const c of cards) {
                    if (!c.querySelector('.bt-tool-body[data-tool-id="edit-prev-1"]')) continue;
                    const h = c.querySelector('.bt-tool-header');
                    return h ? h.dataset.expanded : null;
                }
                return null;
            })()
        """)
        record("body still collapsed", @TH.test_eq expanded "false")

        # Path label, removed line, added line all present.
        text = TH.eval_js(ctx, """
            (() => {
                const cards = document.querySelectorAll('.bt-tool-msg');
                for (const c of cards) {
                    if (!c.querySelector('.bt-tool-body[data-tool-id="edit-prev-1"]')) continue;
                    const p = c.querySelector('.bt-edit-preview');
                    return p ? p.innerText : null;
                }
                return null;
            })()
        """)
        record("preview shows file path",
               @TH.test_true (text isa AbstractString && occursin("src/a.py", text)))
        record("preview shows removed line",
               @TH.test_true (text isa AbstractString && occursin("- def hello():", text)))
        record("preview shows added line",
               @TH.test_true (text isa AbstractString && occursin("+ def hello(name):", text)))

        # Height capped — overflow hidden + max-height: 100px in CSS.
        h = TH.eval_js(ctx, """
            (() => {
                const cards = document.querySelectorAll('.bt-tool-msg');
                for (const c of cards) {
                    if (!c.querySelector('.bt-tool-body[data-tool-id="edit-prev-1"]')) continue;
                    const p = c.querySelector('.bt-edit-preview');
                    return p ? p.getBoundingClientRect().height : null;
                }
                return null;
            })()
        """)
        record("preview height ≤ 100px (lightweight)",
               @TH.test_true (h !== nothing && h <= 101))
    end

    TH.section("Edit preview: multi-edit shows 'N more files' footnote") do
        text = TH.eval_js(ctx, """
            (() => {
                const cards = document.querySelectorAll('.bt-tool-msg');
                for (const c of cards) {
                    if (!c.querySelector('.bt-tool-body[data-tool-id="edit-multi-1"]')) continue;
                    const p = c.querySelector('.bt-edit-preview');
                    return p ? p.innerText : null;
                }
                return null;
            })()
        """)
        record("multi-edit preview mentions '2 more files'",
               @TH.test_true (text isa AbstractString && occursin("2 more file", text)))
    end

    TH.section("Non-edit tools do NOT get an inline preview") do
        # Read, fetch, etc. — no .bt-edit-preview should be a sibling of those bodies.
        n_extra_previews = TH.eval_js(ctx, """
            (() => {
                let n = 0;
                document.querySelectorAll('.bt-tool-msg').forEach(c => {
                    const body = c.querySelector('.bt-tool-body');
                    const id   = body ? body.getAttribute('data-tool-id') : '';
                    if (!id || id.indexOf('edit') !== -1) return;
                    if (c.querySelector('.bt-edit-preview')) n++;
                });
                return n;
            })()
        """)
        record("no preview on non-edit tools", @TH.test_eq Int(n_extra_previews) 0)
    end

    TH.section("No JS errors") do
        record("zero JS errors",
               @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "tool kinds + edit preview — final")

finally
    TH.report!("Tool kinds + edit preview", results)
    TH.shutdown(ctx)
end
