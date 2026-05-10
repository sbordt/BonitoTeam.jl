# Tier 2a — chat input. Type / Enter / Shift+Enter / send button / textarea grow.
# Uses the loopback mock ACP so user messages get persisted but no agent reply
# arrives (we're only testing the *input* side here; streaming has its own file).
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)

# Seed an idle ChatModel for p-1 — empty `scripted` means the mock will
# end_turn the prompt immediately with zero updates. That's enough: we only
# care that the user-side bubble appears and the input clears.
let proj = state.projects[]["p-1"]
    model = BonitoTeam.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport())
    BonitoTeam.start_chat_client!(model)
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
                if (items[i].innerText === 'Project1') return i;
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
