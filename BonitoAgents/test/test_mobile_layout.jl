# End-to-end mobile layout regression. Drives a real `BT.dev_server()` (so the
# server-side `const Styles` rules from sidebar.jl + styles.jl are exercised —
# JS-injected CSS does NOT count) through Electron at three viewport widths.
# Asserts the geometry invariants the user reported as broken:
#
#   * Mobile (393px): the chat/dashboard `.bt-main` column must FIT next to
#     the icon-only sidebar (sidebar.right + main.width <= viewport.width).
#     The earlier `--bt-main-min: 480px` floor forced .bt-main wider than the
#     viewport on phones, clipping header/messages/input/toolbar off the
#     right edge.
#   * Sidebar's "RUNNING ON WORKER" divider must be hidden on mobile — it's
#     68px-wide text in a 56px column, would wrap into three lines and push
#     the sidebar wider.
#   * Sidebar's "No open chats yet — …" empty-state placeholder must be
#     hidden on mobile — same reason as the section divider.
#   * Desktop (1280px): nothing in the mobile media queries leaks out;
#     section header + main floor must still be live there.
#
# This is a real Electron + Bonito test — no JS-injected CSS. If you change
# the breakpoint or remove the rule, this test catches it.

using Test
import BonitoAgents as BT
import BonitoAgents.AgentClientProtocol as ACP
using Bonito
using Electron: Application, Window, URI, run as erun

# Inflate a chat with fake tool calls so the per-tool hide-toggle filter row
# accumulates real toggles — that's the row whose mobile geometry we're
# verifying. Uses BT.MockTransport (in-memory loopback, no claude binary, no
# tokens burned) via the BT.fake_agent_chat-style path. Sends a single ToolMsg
# per distinct kind/name so the JS-side `noteKey` registers one filter
# checkbox per tool. The messages are completed-state so the chat doesn't
# wait for any further updates.
function inflate_chat_with_tools!(model::BT.ChatModel, tools::Vector{<:NamedTuple})
    for (i, t) in enumerate(tools)
        ch = Channel{ACP.ToolCall}(0); close(ch)
        tid = "synth-$i"
        # Real typed builder so the kind/title/name flow exactly mirrors what
        # a live ACP frame would produce.
        if t.kind == "Bash"
            tc = ACP.BashCall(tid, "execute", t.title, "completed",
                              ACP.ToolContent[ACP.TextContent("(synth)")], ch,
                              t.title, false, nothing)
        elseif t.kind == "MCP"
            tc = ACP.MCPCall(tid, "other", t.title, "completed",
                             ACP.ToolContent[ACP.TextContent("(synth)")], ch,
                             "btworker", t.name, Dict{String,Any}())
        else
            tc = ACP.GenericTool(tid, t.kind, t.title, "completed",
                                 ACP.ToolContent[ACP.TextContent("(synth)")], ch,
                                 t.name, Dict{String,Any}())
        end
        msg = BT.build_tool_msg(model, tc)
        BT.send!(model, msg)
    end
    return nothing
end

# Stand up a dashboard project backed by MockTransport (no claude binary).
function fake_chat_project!(h; name::AbstractString = "mobile-test")
    wid = first(keys(h.state.workers[]))
    p = BT.create_project_from_worker!(h.state, wid, mktempdir();
                                        name = name, start_session = false)
    model = BT.ChatModel(h.state, p.server_path; project_id = p.id,
                         transport = BT.MockTransport((o, i) -> nothing))
    h.state.chat_models[p.id] = model
    return p, model
end

# Geometry probe: returns a dict mirroring what we visually verify.
const PROBE_JS = """
(()=>{
    const rect = el => el ? Object.entries(el.getBoundingClientRect().toJSON())
        .filter(([k]) => ['top','left','width','height','right','bottom'].includes(k))
        .reduce((o,[k,v]) => (o[k]=v,o), {}) : null;
    const side = document.querySelector('.bt-sidebar');
    const main = document.querySelector('.bt-main');
    const sect = [...document.querySelectorAll('.bt-side-section')];
    const empty = [...document.querySelectorAll('.bt-side-empty')];
    return {
        vw: window.innerWidth, vh: window.innerHeight,
        sidebar: rect(side),
        main: rect(main),
        section_visible: sect.filter(e => e.offsetHeight > 0).length,
        empty_visible:   empty.filter(e => e.offsetHeight > 0).length,
    };
})()
"""

# Drive a fresh Electron window at the given viewport and run `js` inside it.
function with_window(f, url::String, width::Int, height::Int)
    apple = Application(; additional_electron_args = String["--enable-logging", "--v=0"])
    win = Window(apple, URI(url);
        options = Dict{String,Any}("show" => false, "focusOnWebView" => false,
                                    "width" => width, "height" => height,
                                    "webPreferences" => Dict{String,Any}("deviceScaleFactor" => 1)))
    try
        sleep(3)   # let the page hydrate
        return f(win)
    finally
        try close(win) catch end
        try close(apple) catch end
    end
end

probe_viewport(url, w, h) = with_window(url, w, h) do win
    erun(win, PROBE_JS)
end

# Synthesize a .bt-side-section + .bt-side-empty inside the sidebar at the
# given viewport and report their computed `display`. We do this rather than
# relying on the live state having those elements (a fresh dev_server has no
# chats / no "Running on worker" group to render).
run_css_probe(url, w, h) = with_window(url, w, h) do win
    erun(win, """
    (()=>{
        const side = document.querySelector('.bt-sidebar');
        if (!side) return null;
        const sect = document.createElement('div');
        sect.className = 'bt-side-section'; sect.textContent = 'PROBE';
        side.appendChild(sect);
        const empty = document.createElement('div');
        empty.className = 'bt-side-empty'; empty.textContent = 'PROBE';
        side.appendChild(empty);
        const out = {
            section_display: getComputedStyle(sect).display,
            empty_display:   getComputedStyle(empty).display,
        };
        sect.remove(); empty.remove();
        return out;
    })()
    """)
end

@testset "mobile layout — main column fits + dividers hidden" begin
    h = BT.dev_server()
    url = "http://127.0.0.1:$(h.state.srv.port)/"
    sleep(2)   # let the worker daemon dial in
    try
        @testset "viewport 393×852 (iPhone)" begin
            m   = probe_viewport(url, 393, 852)
            css = run_css_probe(url, 393, 852)
            sb, mn, vw = m["sidebar"], m["main"], m["vw"]

            # The chat/dashboard column MUST fit next to the sidebar.
            # This is the bug the user reported: pre-fix main.width was 480
            # on a 393-wide viewport, so main.right exceeded vw by 132px,
            # clipping the input and toolbar off the right edge.
            @test sb["right"] + mn["width"] <= vw + 1   # 1px tolerance for subpixel
            @test mn["right"] <= vw + 1

            # The mobile rules `:root { --bt-main-min: 0px }` + `.bt-main { min-width: 0 }`
            # let the column shrink. Sanity-check it actually shrunk below
            # the desktop floor.
            @test mn["width"] < 480

            # Locks the actual CSS rule, not just "the element doesn't exist".
            @test css["section_display"] == "none"
            @test css["empty_display"]   == "none"
        end

        @testset "viewport 360×640 (smallest common phone)" begin
            m   = probe_viewport(url, 360, 640)
            css = run_css_probe(url, 360, 640)
            @test m["sidebar"]["right"] + m["main"]["width"] <= m["vw"] + 1
            @test m["main"]["right"] <= m["vw"] + 1
            @test css["section_display"] == "none"
            @test css["empty_display"]   == "none"
        end

        @testset "viewport 1280×800 (desktop) — mobile rules don't leak" begin
            m   = probe_viewport(url, 1280, 800)
            css = run_css_probe(url, 1280, 800)
            # On desktop the column should hit its 480px floor or wider —
            # NOT the mobile shrink-to-fit.
            @test m["main"]["width"] >= 480
            # The mobile `display: none` rules must NOT be in effect.
            @test css["section_display"] != "none"
            @test css["empty_display"]   != "none"
        end
    finally
        try close(h) catch end
    end
end

# ── Chat-toolbar mobile geometry ─────────────────────────────────────────────
# The per-tool hide-toggles toolbar (`.bt-chat-toolbar`) lives below the
# composer. The user's complaint: with 15+ filter checkboxes wrapping across
# 4–6 rows on a phone, the toolbar grew to ~120px tall and ate the message
# area. The mobile rule (styles.jl @media max-width:480px) collapses it to a
# single horizontally-scrollable row.

@testset "mobile chat-toolbar — single-row scroll instead of multi-row wrap" begin
    h = BT.dev_server()
    url = "http://127.0.0.1:$(h.state.srv.port)/"
    sleep(2)
    try
        # MockTransport-backed project + 15 distinct tool messages so the
        # filter row has 15 toggles — same surface the user hit.
        p, model = fake_chat_project!(h; name = "mobile-toolbar-test")
        tools = NamedTuple[
            (kind="Bash", title="ls -la",      name=""),
            (kind="Bash", title="grep foo",    name=""),
            (kind="MCP",  title="bt_julia_eval",     name="bt_julia_eval"),
            (kind="MCP",  title="bt_julia_continue", name="bt_julia_continue"),
            (kind="MCP",  title="bt_show_app",       name="bt_show_app"),
            (kind="MCP",  title="bt_show",           name="bt_show"),
            (kind="other", title="Read",  name="Read"),
            (kind="other", title="Write", name="Write"),
            (kind="other", title="Edit",  name="Edit"),
            (kind="other", title="Grep",  name="Grep"),
            (kind="other", title="Glob",  name="Glob"),
            (kind="other", title="WebFetch",   name="WebFetch"),
            (kind="other", title="WebSearch",  name="WebSearch"),
            (kind="other", title="TaskCreate", name="TaskCreate"),
            (kind="other", title="TaskList",   name="TaskList"),
        ]
        inflate_chat_with_tools!(model, tools)
        sleep(0.5)   # let the in-memory model settle

        # Click into the chat (separate run) → sleep Julia-side → probe. The
        # probe was earlier wrapped in `new Promise(setTimeout)` to wait for
        # the click to settle, but Electron.run doesn't await Promises; it
        # returned the unresolved Promise object and every probe field came
        # back undefined. Splitting the steps with a Julia sleep makes the
        # round-trip synchronous on both sides.
        click_js(pid) = """
        (()=>{
            const item = document.querySelector('.bt-side-item[data-project-id="$pid"]');
            if (item) { item.click(); return 'clicked'; }
            return 'no-item';
        })()
        """

        toolbar_probe(pid) = """
        (()=>{
            const p = document.querySelector('.bt-chatpane[data-pane-pid="$pid"]');
            const t = p ? p.querySelector('.bt-chat-toolbar') : null;
            const fr = p ? p.querySelector('.bt-toolbar-filters') : null;
            const rect = el => el ? Object.entries(el.getBoundingClientRect().toJSON())
                .filter(([k]) => ['top','left','width','height','right','bottom'].includes(k))
                .reduce((o,[k,v]) => (o[k]=v,o), {}) : null;
            return {
                vw: window.innerWidth,
                pane_visible: p && getComputedStyle(p).display !== 'none',
                pane: rect(p),
                toolbar: rect(t),
                filters: rect(fr),
                filter_toggles: t ? t.querySelectorAll('.bt-filter-toggle').length : 0,
                filters_flex_wrap:  fr ? getComputedStyle(fr).flexWrap  : null,
                filters_overflow_x: fr ? getComputedStyle(fr).overflowX : null,
                filters_scrollW:    fr ? fr.scrollWidth                 : null,
                filters_clientW:    fr ? fr.clientWidth                 : null,
            };
        })()
        """

        function drive_toolbar(width, height)
            with_window(url, width, height) do win
                @test erun(win, click_js(p.id)) == "clicked"
                sleep(1.0)   # chat pane mount + JS noteKey accumulation
                return erun(win, toolbar_probe(p.id))
            end
        end

        @testset "mobile 393×852 toolbar is single-row + horizontally scrollable" begin
            m = drive_toolbar(393, 852)
            @test m["pane_visible"]    == true
            @test m["filter_toggles"]  >= 10   # the inflate took effect
            # The mobile rule must have switched flex-wrap to nowrap and
            # given the row its own horizontal scroll.
            @test m["filters_flex_wrap"]  == "nowrap"
            @test m["filters_overflow_x"] == "auto"
            # The row contents are wider than the visible area (proves the
            # toggles ARE there waiting to be scrolled to, not collapsed away).
            @test m["filters_scrollW"] > m["filters_clientW"]
            # And the whole toolbar fits inside the chat pane vertically — no
            # 4-row wrap blowout. The toolbar is ≤ 90px tall (toggles ~22px +
            # padding + bottom options row); pre-fix it was 120+.
            @test m["toolbar"]["height"] < 90
            # Toolbar's right edge stays inside the viewport.
            @test m["toolbar"]["right"] <= m["vw"] + 1
        end

        @testset "desktop 1280×800 toolbar still wraps normally" begin
            m = drive_toolbar(1280, 800)
            @test m["pane_visible"]   == true
            @test m["filter_toggles"] >= 10
            # Mobile rule MUST NOT apply on desktop — flex-wrap stays `wrap`.
            @test m["filters_flex_wrap"] == "wrap"
            # 15 toggles fit horizontally in a 1280-wide window, so the row
            # doesn't need horizontal scrolling.
            @test m["filters_scrollW"] <= m["filters_clientW"] + 1
        end
    finally
        try close(h) catch end
    end
end

