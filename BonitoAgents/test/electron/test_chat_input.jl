# Tier 2a — chat input. Type / Enter / Shift+Enter / send button / textarea grow.
# Uses the loopback mock ACP so user messages get persisted but no agent reply
# arrives (we're only testing the *input* side here; streaming has its own file).
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

import JSON

state = TH.make_state(; n_workers = 1, n_projects = 1)

# Seed an idle ChatModel for p-1 — empty `scripted` means the mock will
# end_turn the prompt immediately with zero updates. That's enough: we only
# care that the user-side bubble appears and the input clears.
let proj = state.projects[]["p-1"]
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport())
    BonitoAgents.start_chat_client!(model)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    # Navigate into the chat
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

    input_val()  = TH.eval_js(ctx, "document.querySelector('.bt-text-input').value")
    send_disabled() = TH.eval_js(ctx, "document.querySelector('.bt-send-btn').disabled")

    TH.section("Initial input state") do
        v = input_val();          record("input value empty",     @TH.test_eq v "")
        d = send_disabled();      record("send button enabled",   @TH.test_eq d false)
        n = TH.dom_count(ctx, ".bt-user-msg")
        record("no user bubbles yet", @TH.test_eq n 0)
    end

    TH.section("Type into input") do
        TH.type_into(ctx, ".bt-text-input", "hello world")
        v = input_val()
        record("value reflects typed text", @TH.test_eq v "hello world")
        # The oninput handler also auto-grows the textarea — height should now
        # be >= 40px (the min-height) but capped at 120px.
        h = TH.eval_js(ctx, "document.querySelector('.bt-text-input').style.height")
        record("textarea reports a height after input",
               @TH.test_true (h !== nothing && h != ""))
    end

    TH.section("Shift+Enter does NOT send") do
        # The onkeydown handler only fires send when Enter is pressed without
        # Shift. With Shift, default behaviour wins (textarea inserts \n at the
        # cursor — which dispatchEvent can't really simulate, so we just assert
        # *send* didn't fire).
        before = TH.dom_count(ctx, ".bt-user-msg")
        TH.press_key(ctx, ".bt-text-input", "Enter"; shift = true)
        sleep(0.2)
        after = TH.dom_count(ctx, ".bt-user-msg")
        record("user bubble count unchanged", @TH.test_eq after before)
        v = input_val()
        record("input value still 'hello world'", @TH.test_eq v "hello world")
    end

    TH.section("Enter sends the message") do
        TH.press_key(ctx, ".bt-text-input", "Enter"; shift = false)
        record("user bubble appears",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-user-msg').length >= 1"))
        record("user bubble has the text",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const b = document.querySelector('.bt-user-msg');
                       return b && b.innerText.indexOf('hello world') !== -1;
                   })()
               """))
        record("input cleared after send",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-text-input').value === ''"))
    end

    TH.section("Send button click also sends") do
        before = TH.dom_count(ctx, ".bt-user-msg")
        TH.type_into(ctx, ".bt-text-input", "second message via button")
        sleep(0.1)
        TH.dom_click(ctx, ".bt-send-btn")
        record("user bubble count increments",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-user-msg').length >= $(before+1)"))
    end

    TH.section("Rapid typing doesn't lose characters") do
        # Pre-fix: the textarea used `value = text_val` two-way bind.
        # Every JS keystroke notified Julia, which (via the implicit
        # `map(session, text_val)` set up by attribute_render) echoed
        # the value back to the DOM one WS round-trip later. With the
        # user typing faster than the round-trip, the stale echoes
        # would overwrite the DOM with shorter values mid-stream — the
        # user sees their typed characters disappear and reappear. Post-
        # fix the input is one-way JS → Julia (oninput) and Julia → DOM
        # clears go via an explicit `onjs` clear signal, so there's no
        # echo to overwrite the user's typing.
        #
        # The final settled state would actually be correct even with
        # the bug (the last echo brings it back to the full string), so
        # we install a setter trap on `.value` that records every write
        # — buggy code shows the value going BACKWARDS (length decrease)
        # mid-stream, fixed code never does.
        expected = "abcdefghijklmnopqrstuvwxyz0123456789!@#\$%^&*()"
        TH.eval_js(ctx, """
            (() => {
                const ta = document.querySelector('.bt-text-input');
                // Clean slate
                ta.value = '';
                ta.dispatchEvent(new Event('input', {bubbles: true}));
                // Install a setter trap — every subsequent ta.value=X
                // gets recorded in window.__tavals.
                window.__tavals = [];
                const proto  = HTMLTextAreaElement.prototype;
                const descr  = Object.getOwnPropertyDescriptor(proto, 'value');
                Object.defineProperty(ta, 'value', {
                    configurable: true,
                    get() { return descr.get.call(this); },
                    set(v) { window.__tavals.push(v); descr.set.call(this, v); }
                });
            })()
        """)
        sleep(0.2)
        # Synchronous loop: 36+ events back-to-back, no time between
        # them. Each oninput sends a WS message to Julia.
        TH.eval_js(ctx, """
            (() => {
                const ta = document.querySelector('.bt-text-input');
                const target = $(JSON.json(expected));
                for (let i = 1; i <= target.length; i++) {
                    ta.value = target.slice(0, i);
                    ta.dispatchEvent(new Event('input', {bubbles: true}));
                }
            })()
        """)
        # Generous wait for every echo to land.
        sleep(1.0)

        # Final state should be the complete string.
        record("DOM value matches every typed character",
               @TH.test_eq input_val() expected)

        # Now examine the trap: every captured write should be at least
        # as long as the previous one. A shorter write means a stale
        # echo overwrote a longer in-DOM value.
        decreases = TH.eval_js(ctx, """
            (() => {
                const v = window.__tavals || [];
                const drops = [];
                for (let i = 1; i < v.length; i++) {
                    if (v[i].length < v[i-1].length) {
                        drops.push({i, prev: v[i-1].length, next: v[i].length});
                    }
                }
                return {count: drops.length, drops: drops.slice(0, 5),
                        total_writes: v.length};
            })()
        """)
        record("no stale echo overwrites the in-DOM value",
               @TH.test_eq decreases["count"] 0)

        # Clear the input so the next section (Empty send) sees empty.
        TH.eval_js(ctx, """
            (() => {
                const ta = document.querySelector('.bt-text-input');
                ta.value = '';
                ta.dispatchEvent(new Event('input', {bubbles: true}));
            })()
        """)
        sleep(0.2)
    end

    TH.section("Empty send is a no-op") do
        before = TH.dom_count(ctx, ".bt-user-msg")
        # Just hitting send with empty input should not push a bubble.
        TH.dom_click(ctx, ".bt-send-btn")
        sleep(0.2)
        record("no new bubble for empty send",
               @TH.test_eq TH.dom_count(ctx, ".bt-user-msg")  before)
    end

    TH.section("No JS errors") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_true (length(errs) == 0))
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "tier 2a — after sends")

finally
    TH.report!("Tier 2a — chat input", results)
    TH.shutdown(ctx)
end
