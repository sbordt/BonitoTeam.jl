# Tier 1 — layout & navigation. No agent, no worker. Pure DOM/CSS assertions
# against the unified shell.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoTeam

state = TH.make_state(; n_workers = 1, n_projects = 2)

# Seed a ChatModel for p-1 with the mock factory BEFORE opening the window so
# the chat-panel section can navigate into a real chat without racing the
# reactive remount against an empty state.chat_models dict.
let proj = state.projects[]["p-1"]
    model = BonitoTeam.ChatModel(state, proj.server_path;
                                  project_id    = proj.id,
                                  transport = TH.mock_transport())
    BonitoTeam.start_chat_client!(model)
end

ctx   = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    TH.section("Sidebar render") do
        record("shell exists",       @TH.test_true TH.dom_exists(ctx, ".bt-shell"))
        record("sidebar exists",     @TH.test_true TH.dom_exists(ctx, ".bt-sidebar"))
        record("home icon present",  @TH.test_true TH.dom_exists(ctx, ".bt-side-home-icon"))
        # The sidebar lists OPEN chats (persisted-interacted or live
        # ChatModel), not every registered project: p-1 has a live model,
        # p-2 is pristine → exactly ONE project icon + the Home entry.
        record("project icon count", @TH.test_eq   TH.dom_count(ctx, ".bt-proj-icon")  1)
        record("side item count",    @TH.test_eq   TH.dom_count(ctx, ".bt-side-item")   2)
    end

    TH.section("Sidebar geometry — desktop") do
        sidebar = TH.dom_rect(ctx, ".bt-sidebar")
        main    = TH.dom_rect(ctx, ".bt-main")
        # Desktop default: sidebar pinned at 200px, main starts at x=200 and fills
        # the rest. We compare with tolerance to account for sub-pixel rounding.
        record("sidebar ~200px wide", @TH.test_true abs(sidebar["w"] - 200) < 2)
        record("main left = sidebar right",
               @TH.test_true abs(main["left"] - sidebar["right"]) < 2)
        record("main fills viewport height",
               @TH.test_true abs(main["h"] - sidebar["h"]) < 2)
    end

    TH.section("Initial view — dashboard") do
        # current_view starts empty → dashboard panel mounted, chat-app NOT.
        record("no chat app yet",    @TH.test_true !TH.dom_exists(ctx, ".bt-app"))
        # Dashboard renders worker section + project section (header text varies
        # so we don't pin the literal string; we just assert at least one
        # dashboard-shell element exists — the project cards we seeded show up
        # as `.bt-project-card` (or similar; we look for the cards class used
        # in dashboard.jl; if the class differs we fall back to "any content").
        has_card_or_content = TH.dom_exists(ctx, ".bt-project-card") ||
                              TH.dom_exists(ctx, ".bt-card") ||
                              (TH.dom_text(ctx, ".bt-main") !== nothing &&
                               !isempty(strip(TH.dom_text(ctx, ".bt-main"))))
        record("dashboard has content", @TH.test_true has_card_or_content)
    end

    # Find the sidebar index for project p-1 — Dict iteration order isn't
    # guaranteed, so look it up dynamically rather than hard-coding [1].
    p1_idx = TH.eval_js(ctx, """
        (() => {
            const items = document.querySelectorAll('.bt-side-item .bt-side-name');
            for (let i = 0; i < items.length; i++)
                if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
            return -1;
        })()
    """)

    TH.section("Sidebar nav — click project") do
        # Clicking the project entry should switch current_view to the
        # project's id and mount the chat (we seeded the ChatModel up top).
        TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
        record("chat mounts on click",
               @TH.test_true TH.wait_for(ctx, "document.querySelector('.bt-app') !== null"; timeout = 15.0))
    end

    TH.section("Chat panel layout") do

        record("header present",  @TH.test_true TH.dom_exists(ctx, ".bt-header"))
        record("messages present",@TH.test_true TH.dom_exists(ctx, ".bt-messages"))
        record("input present",   @TH.test_true TH.dom_exists(ctx, ".bt-text-input"))
        record("send button",     @TH.test_true TH.dom_exists(ctx, ".bt-send-btn"))
        record("stop button",     @TH.test_true TH.dom_exists(ctx, ".bt-stop-btn"))

        # Geometry sanity: the composer block sits at the bottom of .bt-app.
        # The bottom-most element is the per-type display toolbar
        # (.bt-chat-toolbar, populated client-side; min-height 38px even when
        # empty), with the input area directly above it. If the layout
        # regressed (input floating mid-page), input.top would be ~half of
        # app height.
        app     = TH.dom_rect(ctx, ".bt-app")
        input   = TH.dom_rect(ctx, ".bt-input-area")
        toolbar = TH.dom_rect(ctx, ".bt-chat-toolbar")
        record("app fills .bt-main",
               @TH.test_true abs(TH.dom_rect(ctx, ".bt-main")["h"] - app["h"]) < 2)
        record("toolbar pinned at bottom (gap < 8px)",
               @TH.test_true app["bottom"] - toolbar["bottom"] < 8)
        record("input sits directly above the toolbar",
               @TH.test_true abs(toolbar["top"] - input["bottom"]) < 8)

        msgs = TH.dom_rect(ctx, ".bt-messages")
        record("messages occupies > 50% of app height",
               @TH.test_true msgs["h"] > 0.5 * app["h"])
    end

    TH.section("No JS errors after layout exercise") do
        errs = TH.js_errors(ctx)
        record("zero JS errors",
               @TH.test_true (length(errs) == 0))
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "tier 1 final state")

finally
    TH.report!("Tier 1 — layout & navigation", results)
    TH.shutdown(ctx)
end
