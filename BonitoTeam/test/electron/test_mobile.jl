# Mobile breakpoint — sidebar collapses to icons-only at <=640px wide,
# project-name labels go display:none, message bubbles cap at 88-100% so
# they fit a narrow viewport, and the input toolbar uses tighter padding.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 2)
ctx   = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    TH.section("Desktop baseline (1280x800)") do
        TH.set_window_size(ctx, 1280, 800)
        sidebar_w = TH.dom_rect(ctx, ".bt-sidebar")["w"]
        record("sidebar ~200px wide on desktop", @TH.test_true abs(sidebar_w - 200) < 4)
        names_visible = TH.eval_js(ctx, """
            (() => {
                const els = document.querySelectorAll('.bt-side-name');
                return Array.from(els).every(e => e.offsetWidth > 0);
            })()
        """)
        record("project-name labels visible on desktop", @TH.test_true names_visible)
    end

    TH.section("Mobile (480x800) — sidebar collapses, names hide") do
        TH.set_window_size(ctx, 480, 800)
        sleep(0.2)  # let layout settle
        sidebar_w = TH.dom_rect(ctx, ".bt-sidebar")["w"]
        record("sidebar collapsed to ~56px",
               @TH.test_true abs(sidebar_w - 56) < 4)
        # All .bt-side-name spans should be display:none on mobile.
        names_hidden = TH.eval_js(ctx, """
            (() => {
                const els = document.querySelectorAll('.bt-side-name');
                if (els.length === 0) return false;
                return Array.from(els).every(e => e.offsetWidth === 0);
            })()
        """)
        record("project-name labels hidden", @TH.test_true names_hidden)
        # The home + project icons are still rendered (just centered).
        n_icons = TH.dom_count(ctx, ".bt-proj-icon") + TH.dom_count(ctx, ".bt-side-home-icon")
        record("home + 2 project icons still present",
               @TH.test_true (n_icons == 3))
    end

    TH.section("Mobile chat panel still fills available width") do
        # Open a project chat by clicking the first project icon. Without a
        # ChatModel seeded, we land on the placeholder — that's fine, we
        # only care about the .bt-main fitting next to the 56px sidebar.
        TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[1].click()""")
        sleep(0.3)
        sidebar = TH.dom_rect(ctx, ".bt-sidebar")
        main    = TH.dom_rect(ctx, ".bt-main")
        record("main starts right of the collapsed sidebar",
               @TH.test_true abs(main["left"] - sidebar["right"]) < 4)
        # 480 viewport - 56 sidebar = ~424 main width
        record("main width ~424px",
               @TH.test_true abs(main["w"] - 424) < 8)
    end

    TH.section("Resize back to desktop restores the labels") do
        TH.set_window_size(ctx, 1280, 800)
        sleep(0.2)
        sidebar_w = TH.dom_rect(ctx, ".bt-sidebar")["w"]
        record("sidebar back to ~200px", @TH.test_true abs(sidebar_w - 200) < 4)
        names_visible = TH.eval_js(ctx, """
            (() => {
                const els = document.querySelectorAll('.bt-side-name');
                return els.length > 0 && Array.from(els).every(e => e.offsetWidth > 0);
            })()
        """)
        record("project-name labels visible again", @TH.test_true names_visible)
    end

    TH.section("No JS errors") do
        record("zero JS errors after resize cycle",
               @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "mobile breakpoint — final")

finally
    TH.report!("Mobile breakpoint", results)
    TH.shutdown(ctx)
end
