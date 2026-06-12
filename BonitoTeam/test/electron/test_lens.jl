# Lens search UI (header bar): autocomplete from the chat vocabulary, applying
# a lens to filter the virtual list + run actions (expand), and saved-lens
# chips. The lens core (parse/search/persist) is unit-tested in test_lens.jl;
# this drives the real browser end-to-end.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))
using BonitoTeam

# Keep saved lenses out of the real ~/.config during the test.
ENV["BONITOTEAM_LENSES_PATH"] = joinpath(mktempdir(), "lenses.json")

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]
model = BonitoTeam.ChatModel(state, proj.server_path; project_id = proj.id,
                             transport = TH.mock_transport(; scripted = []))
BonitoTeam.start_chat_client!(model)

# Mixed history: user messages (one mentions "monitor"), an agent reply, and a
# bt_show_app tool — so the lens has distinct types + tools to filter.
lock(model.lock) do
    push!(model.msgs_store, BonitoTeam.UserMsg("please start a resource monitor"))
    push!(model.msgs_store, BonitoTeam.AgentMsg("a1", "here is your monitor"))
    push!(model.msgs_store, BonitoTeam.UserMsg("show me the lissajous plot"))
    push!(model.msgs_store, BonitoTeam.BonitoAppMsg("app1", "bonito_app", "Dashboard",
        "completed", "", time(), time(), "", "", model))
    push!(model.msgs_store, BonitoTeam.UserMsg("another unrelated question"))
end

ctx = TH.open_window(state)
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    @assert TH.wait_for(ctx,
        """document.querySelector('.bt-side-item[data-project-id="p-1"]') !== null""";
        timeout = 6.0) "no sidebar row"
    TH.eval_js(ctx, """document.querySelector('.bt-side-item[data-project-id="p-1"]').click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-lens-input') !== null";
                        timeout = 15.0) "no lens bar"
    sleep(0.6)

    TH.section("lens bar replaces the toolbar, lives in the header") do
        record("lens bar in the header",
               @TH.test_true TH.eval_js(ctx,
                   "document.querySelector('.bt-header .bt-lens-bar') !== null"))
        record("old filter toolbar hidden",
               @TH.test_true TH.eval_js(ctx, """(() => {
                   const t = document.querySelector('.bt-chat-toolbar');
                   return !t || getComputedStyle(t).display === 'none';
               })()"""))
        record("vocabulary arrived from server",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-messages').__bt_chat.lensVocab.length > 0";
                   timeout = 4.0))
    end

    TH.section("autocomplete from chat vocabulary") do
        TH.eval_js(ctx, """(() => {
            const inp = document.querySelector('.bt-lens-input');
            inp.value = '/user'; inp.focus();
            inp.setSelectionRange(5,5);
            inp.dispatchEvent(new Event('input', {bubbles:true}));
            return true;
        })()""")
        record("autocomplete suggests user_message",
               @TH.test_true TH.wait_for(ctx, """
                   [...document.querySelectorAll('.bt-lens-ac-item')]
                       .some(el => el.dataset.kind === 'key' && el.dataset.val === 'user_message')
               """; timeout = 3.0))
    end

    TH.section("after picking a key, autocomplete offers actions + operators") do
        # Type a full key plus a trailing space → params mode.
        TH.eval_js(ctx, """(() => {
            const inp = document.querySelector('.bt-lens-input');
            inp.value = '/bt_show_app '; inp.focus();
            inp.setSelectionRange(inp.value.length, inp.value.length);
            inp.dispatchEvent(new Event('input', {bubbles:true}));
            return true;
        })()""")
        record("suggests the expand action",
               @TH.test_true TH.wait_for(ctx, """
                   [...document.querySelectorAll('.bt-lens-ac-item')]
                       .some(el => el.dataset.kind === 'action' && el.dataset.val === 'expand')
               """; timeout = 3.0))
        record("suggests the exclude operator",
               @TH.test_true TH.eval_js(ctx, """
                   [...document.querySelectorAll('.bt-lens-ac-item')]
                       .some(el => el.dataset.kind === 'op' && el.dataset.val === '-')
               """))
        # Reset the input for the next section.
        TH.eval_js(ctx, """(() => { const inp=document.querySelector('.bt-lens-input');
            inp.value=''; inp.dispatchEvent(new Event('input',{bubbles:true})); return true; })()""")
    end

    TH.section("apply a lens: filter + action") do
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages').__bt_chat;
            document.querySelector('.bt-lens-input').value =
                '/user_message "monitor" + /bt_show_app: expand';
            document.querySelector('.bt-lens-go').click();
            return true;
        })()""")
        # Server computes visible = {0 (user monitor), 3 (app)}; others hidden.
        record("lens became active",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-messages').__bt_chat.lensActive === true";
                   timeout = 4.0))
        record("only matching indices visible (0 + 3)",
               @TH.test_true TH.wait_for(ctx, """(() => {
                   const c = document.querySelector('.bt-messages').__bt_chat;
                   const v = [...c.lensVisible].sort((a,b)=>a-b);
                   return v.length === 2 && v[0] === 0 && v[1] === 3;
               })()"""; timeout = 4.0))
        record("non-matching user message is display:none",
               @TH.test_true TH.eval_js(ctx, """(() => {
                   const c = document.querySelector('.bt-messages').__bt_chat;
                   const n = c.cache.get(2);   // "lissajous" user msg
                   return !n || n.style.display === 'none';
               })()"""))
        record("expand action recorded for the app (idx 3)",
               @TH.test_true TH.eval_js(ctx,
                   "document.querySelector('.bt-messages').__bt_chat.lensActions.get(3) === 'expand'"))
    end

    TH.section("clear lens shows everything again") do
        TH.eval_js(ctx, "document.querySelector('.bt-lens-clear').click()")
        record("lens cleared",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-messages').__bt_chat.lensActive === false";
                   timeout = 3.0))
    end

    TH.section("save + chip + delete (global, persisted)") do
        TH.eval_js(ctx, """(() => {
            document.querySelector('.bt-lens-input').value = '/bt_show_app: expand';
            document.querySelector('.bt-lens-save').click();
            return true;
        })()""")
        record("saved-lens chip appears with a color",
               @TH.test_true TH.wait_for(ctx, """(() => {
                   const chip = document.querySelector('.bt-lens-chip');
                   return chip && (chip.style.getPropertyValue('--chip')||'').startsWith('hsl(');
               })()"""; timeout = 4.0))
        record("persisted to the lenses file",
               @TH.test_true (sleep(0.3); isfile(ENV["BONITOTEAM_LENSES_PATH"])))
        TH.eval_js(ctx, "document.querySelector('.bt-lens-chip-x').click()")
        record("chip removed after delete",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-lens-chip') === null"; timeout = 3.0))
    end

    TH.section("No JS errors") do
        record("zero JS errors", @TH.test_eq length(TH.js_errors(ctx)) 0)
    end
    TH.emit_screenshot(ctx; label = "lens search bar")
finally
    TH.report!("Lens search UI", results)
    TH.shutdown(ctx)
end
