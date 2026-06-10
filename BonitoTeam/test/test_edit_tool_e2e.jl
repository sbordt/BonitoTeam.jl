# End-to-end test for the edit-tool diff-preview refactor.
#
# Stack reality: REAL `dev_server`, REAL worker, REAL `LocalTransport` with
# subprocess spawn, REAL ACP JSON-RPC over stdio, REAL websockets, REAL
# Bonito UI. The only swap is the `claude-agent-acp` binary →
# `mock_claude_agent_acp.jl` in dispatcher mode, which calls back into this
# process so the test can provide `agent(msg) → events` directly.
#
# What this test pins:
#
#   1. After the user sends a message that triggers an edit, the chat
#      eager-mounts the body — no separate HTML preview, no click required.
#   2. The mounted body is a Monaco DiffEditor sized at the compact cap
#      (`EDIT_BODY_COMPACT_PX`).
#   3. Clicking the tool header resizes the SAME Monaco instance via the
#      `setMaxHeight` API — content height grows past the compact cap.
#   4. Clicking again shrinks it back to the compact size.
#   5. Screenshots are saved at each stage so a human reviewer (or me,
#      via `Read`) can confirm the visual is right, not just the metrics.

using Test, JSON
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
# `using .TestKit` to bring in the helpers AS the test surface (no module
# prefix on every line); `import BonitoTeam: …` for the two compact/expanded
# constants. The wrapper mustn't `using BonitoTeam` first — TestKit and
# BonitoTeam both export `dev_server`, and Main pulling both creates an
# ambiguity. Using TestKit's `dev_server` is the whole point here.
import .TestKit
const TK = TestKit
# Selective `using` for the event-DSL constructors so the agent function
# can write `text("…")` instead of `TK.text("…")`. `dev_server` /
# `open_browser` / `click` / … stay qualified as `TK.<name>` since
# `dev_server` collides with `BonitoTeam.dev_server` and I don't want
# Main to randomly choose one.
using .TestKit: text, thought, edit, bash, end_turn
import BonitoTeam: EDIT_BODY_COMPACT_PX, EDIT_BODY_EXPANDED_PX

const OLD = """
function greet(name)
    println("Hello, ", name)
    return nothing
end

# A handful of follow-up lines to make the natural diff height exceed the
# compact cap — otherwise we wouldn't be able to tell that capping is what
# limits the rendered height vs. just "Monaco's content is short."
struct OldThing
    a::Int
    b::String
end

OldThing(a::Int) = OldThing(a, "")
"""

const NEW = """
function greet(name; greeting = "Hello")
    println(greeting, ", ", name)
    return name
end

# A handful of follow-up lines to make the natural diff height exceed the
# compact cap — otherwise we wouldn't be able to tell that capping is what
# limits the rendered height vs. just "Monaco's content is short."
struct NewThing
    a::Int
    b::String
    c::Float64
end

NewThing(a::Int) = NewThing(a, "", 0.0)
NewThing(a::Int, b::String) = NewThing(a, b, 0.0)
"""

# The agent: ANY user prompt triggers an edit of /sim/test/foo.jl, with a
# short text bookended around it. A real claude turn would interleave text
# and tool calls similarly.
agent_fn(msg::AbstractString) = [
    text("I'll edit foo.jl for you."),
    edit("/sim/test/foo.jl", OLD, NEW; id = "edit-1"),
    text("Done — added a greeting kwarg and renamed OldThing → NewThing."),
]

# Screenshots land in a stable place so I can `Read` them after the run.
const SHOT_DIR = joinpath(tempdir(), "bt-edit-e2e")
mkpath(SHOT_DIR)
shot(name) = joinpath(SHOT_DIR, name)

const TOOL_SEL  = ".bt-tool-msg[data-msg-id]"
const MONACO_SEL = "$TOOL_SEL .monaco-diff-editor-div"
const HEADER_SEL = "$TOOL_SEL .bt-tool-header"

# Probe the mounted Monaco editor's live state: pixel height,
# the max_height it's been told to honor, whether the body element is
# visible. Returns a NamedTuple of the JSON object the JS hands back.
function probe(s)
    return TK.eval_js(s, """(() => {
        const md = document.querySelector($(JSON.json(MONACO_SEL)));
        if (!md) return {error: 'monaco missing'};
        const node = md.closest('.bt-tool-msg');
        const body = node.querySelector('.bt-tool-body');
        const r = md.getBoundingClientRect();
        return {
            style_height: md.style.height,
            rect_height: Math.round(r.height),
            monaco_max_height: md.__btMonacoDiff ? md.__btMonacoDiff.max_height : null,
            body_visible: getComputedStyle(body).display !== 'none',
            body_visibility: getComputedStyle(body).visibility,
            body_offsetheight: body.offsetHeight,
            md_offsetheight: md.offsetHeight,
            md_children_count: md.childElementCount,
            md_inner_classes: [...md.children].map(el => el.className).join('|'),
            md_innerHTML_len: md.innerHTML.length,
            header_expanded: node.querySelector('.bt-tool-header').dataset.expanded || 'false',
            tool_status: node.querySelector('.bt-tool-status') ?
                          node.querySelector('.bt-tool-status').textContent : null,
            all_monaco_count: document.querySelectorAll('.monaco-diff-editor-div').length,
        };
    })()""")
end

server = TK.dev_server(; agent = agent_fn)
try
    TK.open_browser(server; width = 1280, height = 820)

    pid = TK.new_chat(server)
    @info "chat created" pid
    # Click the sidebar entry for this project so the chat becomes the
    # current view (otherwise the dashboard renders the home/empty state
    # and the tool messages stream into an off-screen ChatModel).
    TK.click(server, ".bt-side-item[data-project-id=\"$pid\"]")
    sleep(1.5)
    TK.send_message(server, "please edit foo.jl to add a greeting kwarg")
    sleep(3)
    @info "DOM after send" snapshot=TK.eval_js(server, """(() => ({
        tool_msgs: document.querySelectorAll('.bt-tool-msg').length,
        side_items: [...document.querySelectorAll('.bt-side-item')].map(el => el.dataset.projectId),
        current_pid_localStorage: localStorage.getItem('bt-last-pid'),
        chat_panes: document.querySelectorAll('.bt-chat, .bt-main, .bt-messages').length,
        body_html_length: document.body.innerHTML.length,
        user_msgs: document.querySelectorAll('.bt-user-msg').length,
        agent_msgs: document.querySelectorAll('.bt-agent-msg').length,
    }))()""")
    TK.screenshot(server, shot("00-debug-after-send.png"))

    # Wait for the tool message to mount AND Monaco's `monaco.then(...)`
    # promise to resolve AND the inner editor DOM to actually paint. The
    # `editor_div`'s `style.height` is set synchronously by JS, but the
    # inner `.monaco-diff-editor` container is created async via the
    # Monaco loader — capturing the screenshot before that lands gives an
    # empty box. Probe for the inner painted height as the readiness gate.
    TK.wait_for(server, "Monaco diff editor painted",
             """(() => {
                 const md = document.querySelector($(JSON.json(MONACO_SEL)));
                 if (!md || !md.__btMonacoDiff) return false;
                 const inner = md.querySelector('.monaco-diff-editor, .monaco-editor');
                 return inner != null && inner.getBoundingClientRect().height > 0;
             })()""";
             timeout = 30)
    sleep(0.5)   # give Monaco one more frame to finalize syntax highlighting

    compact = probe(server)
    @info "COMPACT" compact
    TK.screenshot(server, shot("01-compact.png"))

    TK.click(server, HEADER_SEL)
    TK.wait_for(server, "Monaco resized past compact cap",
             """(() => {
                 const md = document.querySelector($(JSON.json(MONACO_SEL)));
                 return md && md.__btMonacoDiff && md.__btMonacoDiff.max_height > 1000;
             })()""";
             timeout = 5)
    sleep(1.0)   # let Monaco paint the new viewport before screenshotting
    expanded = probe(server)
    @info "EXPANDED" expanded
    TK.screenshot(server, shot("02-expanded.png"))

    TK.click(server, HEADER_SEL)
    TK.wait_for(server, "Monaco resized back to compact cap",
             """(() => {
                 const md = document.querySelector($(JSON.json(MONACO_SEL)));
                 return md && md.__btMonacoDiff && md.__btMonacoDiff.max_height <= 300;
             })()""";
             timeout = 5)
    sleep(1.0)   # let Monaco paint the shrunk viewport before screenshotting
    recollapsed = probe(server)
    @info "RECOLLAPSED" recollapsed
    TK.screenshot(server, shot("03-recollapsed.png"))

    # ── Assertions on the live state ──────────────────────────────────────
    @testset "edit tool e2e — visual + metrics" begin
        # 1. Body mounted eagerly (no click), visible, capped at compact.
        @test compact["body_visible"] === true
        @test compact["monaco_max_height"] == EDIT_BODY_COMPACT_PX
        @test compact["rect_height"] == EDIT_BODY_COMPACT_PX
        @test compact["header_expanded"] == "false"

        # 2. Click expands Monaco via setMaxHeight — same instance, taller.
        @test expanded["monaco_max_height"] == EDIT_BODY_EXPANDED_PX
        @test expanded["rect_height"] >  compact["rect_height"]
        @test expanded["rect_height"] <= EDIT_BODY_EXPANDED_PX
        @test expanded["header_expanded"] == "true"

        # 3. Recollapse shrinks back to compact.
        @test recollapsed["monaco_max_height"] == EDIT_BODY_COMPACT_PX
        @test recollapsed["rect_height"] == EDIT_BODY_COMPACT_PX
    end

    @info "screenshots saved" dir=SHOT_DIR files=readdir(SHOT_DIR)
finally
    close(server)
end
