# Agent message markdown rendering — beyond the **bold** check in
# test_chat_streaming.jl. After the agent_final event, the accumulated
# text gets Markdown.parse'd to HTML; verify each common construct comes
# out with the right tag and that the bubble's overrides (in styles.jl)
# don't accidentally hide the rendered content.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

# `JSON.json(...)` is interpolated into the test's eval_js strings at Main scope.
using JSON

state = TH.make_state(; n_workers = 1, n_projects = 1)

# One big agent message exercising several markdown constructs at once.
# Sent as a single chunk so the stream-then-finalize path renders it.
const RICH = """
# A heading

A paragraph with `inline code` and **bold** and *italic*.

- bullet one
- bullet two
- bullet three

```julia
x = 1 + 2
println(x)
```

> a quoted aside

And a [link to Bonito](https://github.com/SimonDanisch/Bonito.jl).
"""

scripted = [(0.05, TH.agent_chunk_update(RICH))]

let proj = state.projects[]["p-1"]
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport(; scripted))
    BonitoAgents.start_chat_client!(model)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    p1_idx = TH.eval_js(ctx, """(() => { const items = document.querySelectorAll('.bt-side-item .bt-side-name'); for (let i=0; i<items.length; i++) if (items[i].innerText.split(' · ')[0]==='Project1') return i; return -1; })()""")
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "no chat"

    TH.section("Send + receive the rich agent message") do
        TH.type_into(ctx, ".bt-text-input", "give me the works")
        TH.dom_click(ctx, ".bt-send-btn")
        # Wait for finalize → markdown HTML to appear (heading is the
        # most distinctive single-tag landmark).
        record("agent bubble + finalised markdown",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const b = document.querySelector('.bt-agent-msg');
                       return b && b.querySelector('h1') !== null;
                   })()
               """; timeout = 5.0))
    end

    # Helper: search the agent bubble for a tag and assert it carries
    # given inner text (or substring).
    function bubble_contains(tag::AbstractString, needle::AbstractString)
        TH.eval_js(ctx, """
            (() => {
                const b = document.querySelector('.bt-agent-msg');
                if (!b) return false;
                const els = b.querySelectorAll($(JSON.json(tag)));
                return Array.from(els).some(e => (e.innerText || '').indexOf($(JSON.json(needle))) !== -1);
            })()
        """)
    end

    TH.section("Headings, emphasis, bold, inline code") do
        record("h1 'A heading'",     @TH.test_true bubble_contains("h1",     "A heading"))
        record("strong 'bold'",      @TH.test_true bubble_contains("strong", "bold"))
        record("em 'italic'",        @TH.test_true bubble_contains("em",     "italic"))
        record("code 'inline code'", @TH.test_true bubble_contains("code",   "inline code"))
    end

    TH.section("Lists") do
        n_items = TH.eval_js(ctx, """
            (() => {
                const b = document.querySelector('.bt-agent-msg');
                if (!b) return 0;
                const ul = b.querySelector('ul');
                return ul ? ul.querySelectorAll('li').length : 0;
            })()
        """)
        record("ul has 3 li children", @TH.test_eq Int(n_items) 3)
    end

    TH.section("Code block (fenced ```julia ...``` → <pre><code>)") do
        record("pre block present",
               @TH.test_true TH.eval_js(ctx, "document.querySelector('.bt-agent-msg pre') !== null"))
        record("code block contains 'x = 1 + 2'",
               @TH.test_true bubble_contains("pre", "x = 1 + 2"))
        # The chat's CSS overrides (styles.jl) flip pre to dark-bg with
        # contrasting text. Assert the computed background isn't the
        # bubble's white surface — that proves the override applied.
        bg = TH.eval_js(ctx, """
            (() => {
                const pre = document.querySelector('.bt-agent-msg pre');
                if (!pre) return null;
                return getComputedStyle(pre).backgroundColor;
            })()
        """)
        record("pre has a non-white background (style override applied)",
               @TH.test_true (bg !== nothing && bg != "rgb(255, 255, 255)"
                              && bg != "rgba(0, 0, 0, 0)"))
    end

    TH.section("Blockquote") do
        record("blockquote 'a quoted aside'",
               @TH.test_true bubble_contains("blockquote", "a quoted aside"))
    end

    TH.section("Link") do
        record("anchor with the right href",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const a = document.querySelector('.bt-agent-msg a');
                       return a && a.getAttribute('href') === 'https://github.com/SimonDanisch/Bonito.jl';
                   })()
               """))
        record("anchor text is 'link to Bonito'",
               @TH.test_true bubble_contains("a", "link to Bonito"))
    end

    TH.section("Bubble overrides don't blank the rendered content") do
        # The bubble's font/color overrides (styles.jl ~line 376-399)
        # explicitly inherit so the markdown renders. Assert visible text.
        text = TH.eval_js(ctx, "document.querySelector('.bt-agent-msg').innerText")
        record("agent bubble has substantial text",
               @TH.test_true (text isa AbstractString && length(text) > 80))
    end

    TH.section("No JS errors") do
        record("zero JS errors", @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "markdown variants — final")

finally
    TH.report!("Agent markdown variants", results)
    TH.shutdown(ctx)
end
