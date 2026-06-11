# Tier 3 — dashboard. Worker cards, project cards, the slide-in forms
# (+ Project, + From GitHub, Discover). No real worker is connected, so the
# tests cover what the operator sees and clicks, not the I/O paths those
# clicks ultimately trigger.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

# Two workers — one we'll mark online for the +Project / Discover paths,
# one stays offline so we can verify the offline pill renders.
state = TH.make_state(; n_workers = 2, n_projects = 2)
state.workers[]["w-1"].status = :online
state.workers[]["w-2"].status = :offline

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    TH.section("Workers section") do
        # Two worker cards present. (The standalone dashboard "Projects"
        # card list was REMOVED by design — projects live in the per-worker
        # tree and the sidebar — so we only count worker cards + the static
        # Agents block here.)
        n_cards = TH.dom_count(ctx, ".bt-card")
        record("at least 2 worker cards",
               @TH.test_true (n_cards >= 2))
        # Online worker shows the "+ Project" button (the folder→threads
        # browser is now always-visible below the card, not behind a Discover
        # toggle). Offline worker shows the "offline" pill.
        has_online_card = TH.eval_js(ctx, """
            (() => {
                const cards = document.querySelectorAll('.bt-card');
                for (const c of cards) {
                    const name = c.querySelector('.bt-card-name');
                    if (!name || (name.value || name.innerText) !== 'w-1') continue;
                    const buttons = Array.from(c.querySelectorAll('button'));
                    return buttons.some(b => b.innerText.indexOf('Project') !== -1);
                }
                return false;
            })()
        """)
        record("online worker shows + Project button", @TH.test_true has_online_card)

        has_offline_pill = TH.eval_js(ctx, """
            (() => {
                const cards = document.querySelectorAll('.bt-card');
                for (const c of cards) {
                    const name = c.querySelector('.bt-card-name');
                    if (!name || (name.value || name.innerText) !== 'w-2') continue;
                    return c.innerText.indexOf('offline') !== -1;
                }
                return false;
            })()
        """)
        record("offline worker shows offline pill", @TH.test_true has_offline_pill)
    end

    # (The old "Project cards" section tested the standalone dashboard
    # project-card list — removed by design. Projects now surface in the
    # sidebar; navigation through it is covered below.)

    TH.section("Sidebar entry → swaps to the chat view") do
        # Mark Project1 as interacted so the open-chats sidebar lists it
        # (pristine projects only show in the per-worker tree).
        BonitoTeam.set_project_title!(state, "p-1", "Dashboard nav test")
        record("Project1 appears in the sidebar",
               @TH.test_true TH.wait_for(ctx,
                   """document.querySelector('.bt-side-item[data-project-id="p-1"]') !== null""";
                   timeout = 3.0))
        TH.eval_js(ctx, """document.querySelector('.bt-side-item[data-project-id="p-1"]').click()""")
        # No ChatModel was seeded, so we land on the bring-up view ("Opening
        # … / Connecting …"). That's still proof navigation worked.
        record("dashboard hidden, loading view shown",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const t = document.body.innerText;
                       return t.indexOf('Opening') !== -1 || t.indexOf('Couldn\\'t open') !== -1;
                   })()
               """; timeout = 4.0))
        # Navigate back via Home for subsequent sections.
        TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[0].click()""")
        @assert TH.wait_for(ctx, "document.body.innerText.indexOf('Workers') !== -1 || document.body.innerText.indexOf('BonitoTeam') !== -1"; timeout = 3.0)
    end

    TH.section("+ Project button fires without errors") do
        # Click "+ Project" on the online worker card. The button toggles
        # picker_state on the Julia side, which feeds a reactive picker
        # rendering — without a real worker connection, the actual picker
        # may or may not render content, but the click itself should never
        # raise a JS error.
        TH.eval_js(ctx, "(() => { const cards = document.querySelectorAll('.bt-card'); for (const c of cards) { const n = c.querySelector('.bt-card-name'); if (!n || n.innerText !== 'w-1') continue; const b = Array.from(c.querySelectorAll('button')).find(x => x.innerText.indexOf('Project') !== -1); if (b) b.click(); break; } })()")
        sleep(0.4)
        record("no JS errors after + Project click",
               @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.section("+ From GitHub form opens") do
        # The "+ From GitHub" button is in the page-level toolbar (not on a
        # worker card). Click it and check that an input for the URL appears.
        TH.eval_js(ctx, """
            const btn = Array.from(document.querySelectorAll('button')).find(b => b.innerText.indexOf('GitHub') !== -1);
            if (btn) btn.click();
        """)
        record("URL input appears after From-GitHub click",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const inputs = document.querySelectorAll('input[type=text], input:not([type])');
                       return Array.from(inputs).some(i => (i.placeholder || '').toLowerCase().indexOf('github') !== -1
                                                         || (i.placeholder || '').toLowerCase().indexOf('url') !== -1
                                                         || (i.placeholder || '').toLowerCase().indexOf('repo') !== -1);
                   })()
               """; timeout = 3.0))
    end

    TH.section("folder→threads browser is always present") do
        # The per-worker discover panel is no longer toggled by a Discover
        # button — it's always rendered (a persistent folder→threads tree fed
        # from the saved scan), with a Rescan button to refresh.
        record("folder→threads panel present",
               @TH.test_true TH.wait_for(ctx, """
                   (() => document.querySelector('.bt-discover-panel') !== null
                          || document.body.innerText.indexOf('Folders & threads') !== -1)()
               """; timeout = 3.0))
        # Rescan should be reachable and clicking it must not raise a JS error.
        TH.eval_js(ctx, """
            (() => { const b = Array.from(document.querySelectorAll('button')).find(x => x.innerText.indexOf('Rescan') !== -1); if (b) b.click(); })()
        """)
        sleep(0.4)
        record("no JS errors after Rescan click",
               @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "tier 3 — dashboard")

finally
    TH.report!("Tier 3 — dashboard", results)
    TH.shutdown(ctx)
end
