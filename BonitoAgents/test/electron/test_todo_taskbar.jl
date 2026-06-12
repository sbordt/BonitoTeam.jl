# The TaskBar component (taskbar.jl): a Julia-owned pin-board.
#
#   • A LIVE todo list is a pinned panel: every item, finished ones crossed
#     out — and NO .bt-plan-msg bubble in the chat while live.
#   • Plan updates mutate that one panel in place.
#   • A bash pins IMMEDIATELY with claude's human description as its label.
#   • THE regression this design exists for: the bar derives from Julia
#     state, so scrolling the chat (virtual scroll recycling the pill
#     nodes) cannot empty it.
#   • Turn end: the todo finalizes into ONE history bubble; the pin drops.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoAgents

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]

scripted = [
    # Todo list: live phase…
    (0.10, TH.plan_update([
        (content = "step one",   status = "in_progress", priority = "medium"),
        (content = "step two",   status = "pending",     priority = "medium"),
    ])),
    (1.50, TH.plan_update([
        (content = "step one",   status = "completed",   priority = "medium"),
        (content = "step two",   status = "in_progress", priority = "medium"),
        (content = "step three", status = "pending",     priority = "medium"),
    ])),

    # A foreground bash that never completes inside this turn — pins
    # immediately (description as label) and holds the turn open. NOTE:
    # the consumer is sequential, so this must come AFTER the plan updates.
    (0.50, TH.tool_call_update(
        id = "fg1", kind = "execute", title = "monitor loop",
        status = "in_progress", tool_name = "Bash",
        raw_input = Dict{String,Any}(
            "command" => "for i in \$(seq 1 900); do date; sleep 2; done",
            "description" => "Monitor system load"))),

    # The mock resolves the prompt after this final delay → turn teardown
    # force-fails fg1 and zombie-finalizes the todo list.
    (8.0, TH.agent_chunk_update("all wrapped up")),
]

model = BonitoAgents.ChatModel(state, proj.server_path;
                              project_id = proj.id,
                              transport  = TH.mock_transport(; scripted))
BonitoAgents.start_chat_client!(model)
# Enough history that scrolling to the top recycles the live pills out of
# the DOM — the scroll-survival regression needs a real virtual window.
TH.seed_chat_history!(model, 40)

ctx = TH.open_window(state)
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    @assert TH.wait_for(ctx,
        """document.querySelector('.bt-side-item[data-project-id="p-1"]') !== null""";
        timeout = 5.0) "no sidebar row"
    TH.eval_js(ctx, """document.querySelector('.bt-side-item[data-project-id="p-1"]').click()""")
    # Generous: the FIRST chat mount compiles the chat view cold on the
    # server (3s default flakes on an isolated cold run; warm in the full
    # suite). 15s is a cold-compile budget, not a hang mask.
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null";
                        timeout = 15.0) "no chat"

    TH.type_into(ctx, ".bt-text-input", "go")
    TH.dom_click(ctx, ".bt-send-btn")

    TH.section("live todo = pinned panel, NOT a chat bubble") do
        record("taskbar todo panel appears",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-taskbar-todo') !== null"; timeout = 5.0))
        record("no NEW plan bubble while live",
               @TH.test_eq TH.eval_js(ctx, """
                   document.querySelectorAll('.bt-plan-msg.bt-plan-live').length
               """) 0)
        record("panel lists every item",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-taskbar-todo-item').length >= 2";
                   timeout = 3.0))
    end

    TH.section("updates mutate the panel: strikethrough + active item") do
        record("second update grows the panel to 3 items",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-taskbar-todo-item').length === 3";
                   timeout = 5.0))
        record("finished item is crossed out",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const done = document.querySelector('.bt-taskbar-todo-item.bt-todo-done');
                       return done !== null && done.textContent === 'step one';
                   })()
               """))
        record("in-progress item is highlighted",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const a = document.querySelector('.bt-taskbar-todo-item.bt-todo-active');
                       return a !== null && a.textContent === 'step two';
                   })()
               """))
    end

    TH.section("bash pins immediately with its description") do
        record("monitor bash slot present with human label",
               @TH.test_true TH.wait_for(ctx, """
                   (() => [...document.querySelectorAll('.bt-taskbar-slot-label')]
                       .some(l => l.textContent.indexOf('Monitor system load') !== -1))()
               """; timeout = 6.0))
    end

    TH.section("REGRESSION: scrolling cannot empty the taskbar") do
        # Scroll to the very top — the virtual scroller recycles the live
        # pills out of the DOM. The old DOM-scanning bar emptied here.
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true;
        })()""")
        sleep(1.0)
        record("todo panel survives the scroll",
               @TH.test_true TH.dom_exists(ctx, ".bt-taskbar-todo"))
        record("bash slot survives the scroll",
               @TH.test_true TH.eval_js(ctx, """
                   (() => [...document.querySelectorAll('.bt-taskbar-slot-label')]
                       .some(l => l.textContent.indexOf('Monitor system load') !== -1))()
               """))
    end

    TH.section("todo panel is a CARD; markers; mini stop buttons") do
        record("todo panel is not a capsule (card radius)",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const el = document.querySelector('.bt-taskbar-todo');
                       return el && getComputedStyle(el).borderRadius === '10px';
                   })()
               """))
        record("items carry ✓/▸/○ markers",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const done = document.querySelector('.bt-todo-done');
                       const act  = document.querySelector('.bt-todo-active');
                       return done && act &&
                           getComputedStyle(done, '::before').content.indexOf('✓') !== -1 &&
                           getComputedStyle(act,  '::before').content.indexOf('▸') !== -1;
                   })()
               """))
        record("bash slot stop is ALWAYS visible (no hover needed)",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const b = document.querySelector('.bt-taskbar-slot-stop.bt-stop-mini');
                       if (!b) return false;
                       const cs = getComputedStyle(b);
                       return cs.opacity === '1' && cs.display !== 'none';
                   })()
               """))
    end

    TH.section("slot click scrolls DETERMINISTICALLY to the source pill") do
        # We're scrolled to the TOP (previous section); the live bash pill is
        # recycled out of the DOM. Clicking its slot must still land on it —
        # the jump goes through the scroller's geometry, not scrollIntoView.
        TH.eval_js(ctx, """document.querySelector('.bt-taskbar-slot[data-msg-index]').click()""")
        record("source pill rendered + in view after click",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const c = document.querySelector('.bt-messages');
                       const pill = [...c.querySelectorAll('.bt-tool-msg')]
                           .find(n => (n.textContent || '').indexOf('Monitor system load') !== -1);
                       if (!pill) return false;
                       const cr = c.getBoundingClientRect(), pr = pill.getBoundingClientRect();
                       return pr.bottom > cr.top && pr.top < cr.bottom;
                   })()
               """; timeout = 4.0))
        record("live tool pill has the mini stop button",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const pill = [...document.querySelectorAll('.bt-tool-msg.bt-tool-live')]
                           .find(n => (n.textContent || '').indexOf('Monitor system load') !== -1);
                       const b = pill && pill.querySelector('.bt-tool-stop.bt-stop-mini');
                       return !!b && getComputedStyle(b).display !== 'none';
                   })()
               """))
    end

    TH.section("turn end: panel retires into ONE history bubble") do
        # We're still scrolled to the TOP from the previous section — the
        # finalize bubble lands at the bottom, outside the virtual window.
        # Wait for the Julia side, then scroll down to see it.
        record("Julia finalizes the list at turn end",
               @TH.test_true timedwait(() ->
                   count(m -> m isa BonitoAgents.TodoListMsg, model.msgs_store) == 1,
                   14.0) === :ok)
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
            c.scrollTop = c.scrollHeight;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true;
        })()""")
        record("plan bubble visible after scrolling back down",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-plan-msg').length >= 1";
                   timeout = 6.0))
        record("taskbar todo panel is gone",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-taskbar-todo') === null"; timeout = 4.0))
        record("exactly one Julia-side history bubble",
               @TH.test_eq count(m -> m isa BonitoAgents.TodoListMsg, model.msgs_store) 1)
        record("bash slot also gone (turn teardown force-failed it)",
               @TH.test_true TH.wait_for(ctx, """
                   (() => ![...document.querySelectorAll('.bt-taskbar-slot-label')]
                       .some(l => l.textContent.indexOf('Monitor system load') !== -1))()
               """; timeout = 4.0))
    end

    TH.section("No JS errors") do
        record("zero JS errors", @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "taskbar component — final")
finally
    TH.report!("TaskBar component lifecycle", results)
    TH.shutdown(ctx)
end
