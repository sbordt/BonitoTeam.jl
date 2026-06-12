# Responsive layout matrix: chat + sidebar + OPEN PLOTPANE across viewport
# widths. Locks the rules:
#   • wide (> 1100): pane is a side column; the chat keeps a readable width
#     (≥ --bt-main-min) and NOTHING overflows horizontally.
#   • narrow (≤ 1100): the pane switches to a full-stage OVERLAY — the chat
#     underneath keeps its full width (no squeeze, no clipped messages).
#   • closing the pane restores the centered chat at every width.
#   • at every step: no horizontal document overflow, the composer is
#     on-screen, and message bubbles fit their container.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoAgents

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]
write(joinpath(proj.server_path, "long.md"),
      "# A heading\n\n" * join(("line $(i) — " *
          "/some/deeply/nested/path/segment_$(i)/file_$(i).jl" for i in 1:40), "\n"))

scripted = [
    (0.05, TH.agent_chunk_update(
        "Here is a longer reply with an inline path `src/very_long_module_name.jl` " *
        "and quite a bit of text so the bubble actually wraps across lines on " *
        "narrow viewports instead of being a single short row.")),
]

let model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id = proj.id,
                                  transport  = TH.mock_transport(; scripted))
    BonitoAgents.start_chat_client!(model)
end

ctx = TH.open_window(state)
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

no_x_overflow() = TH.eval_js(ctx, """
    (() => document.documentElement.scrollWidth <= window.innerWidth + 1 &&
           document.body.scrollWidth <= window.innerWidth + 1)()
""")
composer_visible() = TH.eval_js(ctx, """
    (() => {
        const r = document.querySelector('.bt-input-area').getBoundingClientRect();
        return r.left >= -1 && r.right <= window.innerWidth + 1 &&
               r.bottom <= window.innerHeight + 1 && r.width > 100;
    })()
""")
bubbles_fit() = TH.eval_js(ctx, """
    (() => {
        const c = document.querySelector('.bt-messages').getBoundingClientRect();
        return [...document.querySelectorAll('.bt-agent-msg, .bt-user-msg')]
            .every(b => {
                const r = b.getBoundingClientRect();
                return r.left >= c.left - 1 && r.right <= c.right + 1;
            });
    })()
""")
pane_rect()  = TH.dom_rect(ctx, "#bt-plotpane-dropzone")
stage_rect() = TH.dom_rect(ctx, ".bt-stage")
main_rect()  = TH.dom_rect(ctx, ".bt-main")

try
    @assert TH.wait_for(ctx,
        """document.querySelector('.bt-side-item[data-project-id="p-1"]') !== null""";
        timeout = 5.0) "no sidebar row"
    TH.eval_js(ctx, """document.querySelector('.bt-side-item[data-project-id="p-1"]').click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "no chat"
    TH.type_into(ctx, ".bt-text-input", "go")
    TH.dom_click(ctx, ".bt-send-btn")
    @assert TH.wait_for(ctx, "document.querySelectorAll('.bt-agent-msg').length >= 1";
                        timeout = 5.0) "no reply"

    # Open the pane with a file tab (path-link route, explicit path).
    TH.eval_js(ctx, """
        document.querySelector('.bt-messages').__bt_chat.comm.notify(
            { type: 'edit_file', path: 'long.md' });
    """)
    @assert TH.wait_for(ctx,
        "document.getElementById('bt-plotpane-dropzone').classList.contains('bt-plotpane-visible')";
        timeout = 8.0) "pane never opened"

    for (w, h) in ((1700, 950), (1280, 850))
        TH.section("pane open as a COLUMN @ $(w)x$(h)") do
            TH.set_window_size(ctx, w, h)
            sleep(0.3)
            record("no horizontal overflow", @TH.test_true no_x_overflow())
            record("composer visible",       @TH.test_true composer_visible())
            record("bubbles fit",            @TH.test_true bubbles_fit())
            pr, mr = pane_rect(), main_rect()
            record("pane is a side column (right of the chat)",
                   @TH.test_true (pr["left"] >= mr["right"] - 2 && pr["w"] > 150))
            record("chat keeps a readable width",
                   @TH.test_true (mr["w"] >= 440))
        end
        TH.emit_screenshot(ctx; label = "responsive — column $(w)x$(h)")
    end

    for (w, h) in ((1024, 800), (800, 800), (640, 800))
        TH.section("pane open as an OVERLAY @ $(w)x$(h)") do
            TH.set_window_size(ctx, w, h)
            sleep(0.3)
            record("no horizontal overflow", @TH.test_true no_x_overflow())
            pr, sr = pane_rect(), stage_rect()
            record("pane overlays the full stage",
                   @TH.test_true (abs(pr["w"] - sr["w"]) < 4 && abs(pr["left"] - sr["left"]) < 4))
            record("chat underneath keeps full width (no squeeze)",
                   @TH.test_true (main_rect()["w"] >= min(sr["w"], 1000) * 0.9))
        end
        TH.emit_screenshot(ctx; label = "responsive — overlay $(w)x$(h)")
    end

    TH.section("closing the pane restores the centered chat") do
        TH.eval_js(ctx, """
            (() => { const c = document.querySelector('.bt-pp-tab-close'); c && c.click(); })()
        """)
        record("pane collapses",
               @TH.test_true TH.wait_for(ctx,
                   "!document.getElementById('bt-plotpane-dropzone').classList.contains('bt-plotpane-visible')";
                   timeout = 4.0))
        TH.set_window_size(ctx, 1280, 850)
        sleep(0.3)
        record("no horizontal overflow", @TH.test_true no_x_overflow())
        record("composer visible",       @TH.test_true composer_visible())
        record("bubbles fit",            @TH.test_true bubbles_fit())
    end

    TH.section("mobile (480) with the pane re-opened: overlay + intact chat") do
        TH.set_window_size(ctx, 480, 800)
        sleep(0.3)
        TH.eval_js(ctx, """
            document.querySelector('.bt-messages').__bt_chat.comm.notify(
                { type: 'edit_file', path: 'long.md' });
        """)
        record("pane reveals as overlay",
               @TH.test_true TH.wait_for(ctx,
                   "document.getElementById('bt-plotpane-dropzone').classList.contains('bt-plotpane-visible')";
                   timeout = 6.0))
        pr, sr = pane_rect(), stage_rect()
        record("overlay fills the stage",
               @TH.test_true (abs(pr["w"] - sr["w"]) < 4))
        record("no horizontal overflow", @TH.test_true no_x_overflow())
        TH.eval_js(ctx, """
            (() => { const c = document.querySelector('.bt-pp-tab-close'); c && c.click(); })()
        """)
        sleep(0.3)
        record("after close: composer visible", @TH.test_true composer_visible())
        record("after close: bubbles fit",      @TH.test_true bubbles_fit())
    end
    TH.emit_screenshot(ctx; label = "responsive — mobile 480 final")

    TH.section("No JS errors") do
        record("zero JS errors", @TH.test_eq length(TH.js_errors(ctx)) 0)
    end
finally
    TH.report!("Responsive pane matrix", results)
    TH.shutdown(ctx)
end
