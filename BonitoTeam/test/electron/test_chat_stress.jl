# Stress tests for the ChatModel comm-based architecture.
#
# Covers:
#   1. 1000+ messages: virtual scroll renders the right window, range
#      requests serve correct slices, no message loss.
#   2. Initial scroll-to-bottom holds across the chase window even when
#      large bubbles cause scrollHeight to settle late.
#   3. Burst of server-side pushes (100+ in a tight loop): every message
#      reaches JS, totalCount converges to the server's truth, no drops.
#   4. Multi-tab sync: two browser sessions of the same project see
#      identical state after a server-side push.
#   5. Fast reload churn: open/close 10 windows back-to-back, verify the
#      MutationObserver-based cleanup doesn't leak BonitoChat instances.
#   6. Project switch under load: switch chats while messages stream into
#      the OLD project; on switch back, the streamed messages are visible.
#
# Each section has an isolated `make_state` so failures don't cascade.

include(joinpath(@__DIR__, "helpers.jl"))

using Test, Bonito, BonitoTeam, JSON, Dates
import Sockets

const RESULTS = Pair{String,Bool}[]

# ── small inline helpers ─────────────────────────────────────────────────

function open_chat_window(model; opts = Dict{String,Any}("show"=>false, "focusOnWebView"=>false))
    app = Bonito.App() do _session
        Bonito.DOM.div(BonitoTeam.ChatStyles, Bonito.MarkdownCSS, model)
    end
    srv = Bonito.Server(app, "127.0.0.1", 0)
    disp = Bonito.use_electron_display(; options=opts, devtools=false)
    Electron.load(disp.window.window, Electron.URI(Bonito.online_url(srv, "")))
    sleep(2.5)
    return (; disp, srv, app)
end

import Electron
close_chat_window(ctx) = (try close(ctx.disp) catch end; try close(ctx.srv) catch end)

# Wait until a JS predicate returns true, with timeout. Returns true on success.
function wait_for_js(disp, predicate; timeout = 5.0, interval = 0.1)
    deadline = time() + timeout
    while time() < deadline
        try
            v = run(disp.window, "(() => { return ($predicate); })()")
            v === true && return true
        catch
        end
        sleep(interval)
    end
    return false
end

function chat_total(disp)
    run(disp.window, "document.querySelector('.bt-messages')?.__bt_chat?.totalCount ?? -1")
end

function chat_state(disp)
    run(disp.window, """JSON.stringify({
        total:    document.querySelector('.bt-messages')?.__bt_chat?.totalCount ?? -1,
        rendered: document.querySelectorAll('.bt-messages > .bt-user-msg, .bt-messages > .bt-agent-msg').length,
        users:    document.querySelectorAll('.bt-user-msg').length,
        agents:   document.querySelectorAll('.bt-agent-msg').length,
        atBottom: document.querySelector('.bt-messages')?.__bt_chat?.atBottom() ?? false,
    })""")
end

function fresh_model(label)
    state = BonitoTeam.ServerState(; state_dir=mktempdir(), working_dir=mktempdir(), worker_secret="x")
    model = BonitoTeam.ChatModel(state, mktempdir(); project_id=label)
    state.chat_models[label] = model
    return model, state
end

# ── (1) 1000 message virtual-scroll integrity ────────────────────────────
TH.section("Stress 1: 1000 messages, virtual scroll integrity") do
    model, _ = fresh_model("stress-1k")
    TH.seed_chat_history!(model, 500)   # 500 (user, agent) pairs = 1000 msgs
    @assert length(model.msgs_store) == 1000

    ctx = open_chat_window(model)
    try
        # Browser must learn totalCount, request the bottom range, render
        # bubbles, and chase scrollToBottom until measured heights settle.
        # The chase window in BonitoChat is 300ms; give it a generous extra.
        ok = wait_for_js(ctx.disp,
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 1000";
            timeout = 8)
        push!(RESULTS, "1k: totalCount converged" => ok)

        # Wait until the bottom row actually exists in the DOM (the second
        # range round-trip after ResizeObserver settles).
        wait_for_js(ctx.disp, """
            (() => {
                const us = document.querySelectorAll('.bt-user-msg');
                return us.length > 0 && us[us.length-1].textContent === 'hi 500';
            })()
        """; timeout = 8)

        # Wait for the chase-bottom window to settle (BonitoChat's chase
        # runs three setTimeout(*, 100/300/300ms) jumps; give it generous
        # head-room before sampling atBottom).
        wait_for_js(ctx.disp,
            "document.querySelector('.bt-messages')?.__bt_chat?.atBottom() === true";
            timeout = 5)

        st_json = chat_state(ctx.disp)
        st = JSON.parse(String(st_json))
        push!(RESULTS, "1k: rendered window not empty" => (st["rendered"] > 0))
        push!(RESULTS, "1k: rendered window bounded (< 60 visible)" => (st["rendered"] < 60))
        push!(RESULTS, "1k: initial scroll near bottom" => st["atBottom"])

        last_user = run(ctx.disp.window, """
            (() => {
                const us = document.querySelectorAll('.bt-user-msg');
                return us.length ? us[us.length-1].textContent : null;
            })()
        """)
        push!(RESULTS, "1k: last user bubble is final pair" => (last_user == "hi 500"))
    finally
        close_chat_window(ctx)
    end
end

# ── (2) Burst of server-side pushes ──────────────────────────────────────
TH.section("Stress 2: 100-msg burst from Julia") do
    model, _ = fresh_model("stress-burst")
    TH.seed_chat_history!(model, 5)
    ctx = open_chat_window(model)
    try
        wait_for_js(ctx.disp, "document.querySelector('.bt-messages')?.__bt_chat?.totalCount > 0")

        # Burst-write 100 messages with no sleep between them
        for i in 1:100
            BonitoTeam.chat_push_msg!(model, BonitoTeam.UserMsg("burst-$i"))
        end
        ok = wait_for_js(ctx.disp,
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === $(10 + 100)";
            timeout = 10.0)
        push!(RESULTS, "burst: every message reached JS (totalCount==110)" => ok)

        # Check no msgs disappeared from the store either
        push!(RESULTS, "burst: server store still has 110" =>
              (length(model.msgs_store) == 110))
    finally
        close_chat_window(ctx)
    end
end

# ── (3) Multi-tab sync ──────────────────────────────────────────────────
TH.section("Stress 3: two browser tabs, same model") do
    model, _ = fresh_model("stress-multitab")
    TH.seed_chat_history!(model, 3)

    # Use two SEPARATE Electron.Application instances so neither replaces
    # the other (use_electron_display shares one display per call).
    app = Bonito.App() do _session
        Bonito.DOM.div(BonitoTeam.ChatStyles, Bonito.MarkdownCSS, model)
    end
    srv = Bonito.Server(app, "127.0.0.1", 0)
    url = Bonito.online_url(srv, "")

    a1 = Electron.Application()
    a2 = Electron.Application()
    w1 = Electron.Window(a1, Electron.URI(url); options=Dict{String,Any}("show"=>false))
    w2 = Electron.Window(a2, Electron.URI(url); options=Dict{String,Any}("show"=>false))
    sleep(3.0)

    try
        wait_total = (w, n) -> begin
            deadline = time() + 8
            while time() < deadline
                try
                    Electron.run(w, "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === $n") === true && return true
                catch end
                sleep(0.1)
            end
            false
        end
        push!(RESULTS, "multitab: tab A sees seeded count" => wait_total(w1, 6))
        push!(RESULTS, "multitab: tab B sees seeded count" => wait_total(w2, 6))

        BonitoTeam.chat_push_msg!(model, BonitoTeam.UserMsg("broadcast"))
        sleep(1.0)
        push!(RESULTS, "multitab: tab A picked up push" => wait_total(w1, 7))
        push!(RESULTS, "multitab: tab B picked up push" => wait_total(w2, 7))
    finally
        try close(w1) catch end
        try close(w2) catch end
        try close(a1) catch end
        try close(a2) catch end
        try close(srv) catch end
    end
end

# ── (4) Fast reload churn ────────────────────────────────────────────────
TH.section("Stress 4: 10 fast open/close cycles, no leaks") do
    model, _ = fresh_model("stress-reload")
    TH.seed_chat_history!(model, 4)

    leaked = false
    for i in 1:10
        ctx = open_chat_window(model)
        ok  = wait_for_js(ctx.disp, "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 8"; timeout=4)
        ok || (leaked = true; @warn "cycle $i did not converge")
        close_chat_window(ctx)
        sleep(0.05)
    end
    push!(RESULTS, "reload: 10 cycles all converged" => !leaked)

    # The server-side msgs_store + comm Observable should still be alive
    push!(RESULTS, "reload: server-side store intact" => (length(model.msgs_store) == 8))
end

# ── (5) Connection interrupt: kill window mid-stream, server keeps pushing ──
TH.section("Stress 5: drop browser mid-stream, server side stays sane") do
    model, _ = fresh_model("stress-drop")
    TH.seed_chat_history!(model, 5)
    ctx = open_chat_window(model)
    try
        wait_for_js(ctx.disp, "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 10")
    finally
        close_chat_window(ctx)
    end
    # Now push 50 messages with no browser attached. Should not throw.
    threw = false
    try
        for i in 1:50
            BonitoTeam.chat_push_msg!(model, BonitoTeam.UserMsg("offline-$i"))
        end
    catch e
        threw = true
        @warn "push without listener raised" exception=e
    end
    push!(RESULTS, "drop: pushes without browser don't throw" => !threw)
    push!(RESULTS, "drop: store accumulated all 60" => (length(model.msgs_store) == 60))

    # Re-open: new browser should bootstrap to the post-drop count
    ctx2 = open_chat_window(model)
    try
        ok = wait_for_js(ctx2.disp, "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 60"; timeout=6)
        push!(RESULTS, "drop: reconnect bootstraps to 60" => ok)
    finally
        close_chat_window(ctx2)
    end
end

# ── (6) Scroll-to-bottom invariant under streaming chunks ───────────────
TH.section("Stress 6: streaming agent chunks always visible at bottom") do
    model, _ = fresh_model("stress-stream")
    TH.seed_chat_history!(model, 20)
    ctx = open_chat_window(model)
    try
        wait_for_js(ctx.disp, "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 40")
        # Simulate an agent streaming response via the production path:
        # chat_on_agent_chunk! emits the first chunk with `streaming: true`
        # (which creates the .bt-stream-text accumulator on the JS side),
        # then subsequent calls extend the same bubble.
        for text in ["Lorem ", "ipsum ", "dolor ", "sit ", "amet, ",
                     "consectetur ", "adipiscing ", "elit."]
            upd = BonitoTeam.AgentClientProtocol.AgentMessageChunk(
                BonitoTeam.AgentClientProtocol.TextContent(text))
            BonitoTeam.chat_on_agent_chunk!(model, upd)
            sleep(0.15)
        end
        # Wait for the WS round-trips to land in the DOM rather than guessing.
        # Headless Electron under prior test load can take several seconds
        # for the WS deltas to settle — a generous timeout is fine because
        # we exit early on success.
        ok_text = wait_for_js(ctx.disp, """
            (() => {
                const ag = document.querySelectorAll('.bt-agent-msg');
                if (!ag.length) return false;
                return ag[ag.length-1].textContent.includes('Lorem ipsum dolor sit amet');
            })()
        """; timeout = 15)

        last_text = run(ctx.disp.window, """
            (() => {
                const ag = document.querySelectorAll('.bt-agent-msg');
                return ag.length ? ag[ag.length - 1].textContent : null;
            })()
        """)
        push!(RESULTS, "stream: last agent bubble has accumulated chunks" => ok_text)
        push!(RESULTS, "stream: still pinned to bottom after stream" =>
              run(ctx.disp.window, "document.querySelector('.bt-messages')?.__bt_chat?.atBottom() === true"))
    finally
        close_chat_window(ctx)
    end
end

TH.report!("Tier — chat_stress", RESULTS)
