# Cross-platform regression suite for BonitoAgents. Focus on the path-handling
# bugs that surfaced on Windows: JS string escaping, breadcrumb segmentation
# under drive letters, and project-name derivation through the import flow.

using Test
using BonitoAgents
const BT = BonitoAgents

@testset "BonitoAgents paths" begin

# ── js_path ───────────────────────────────────────────────────────────────────
# Bare-minimum invariant: the output contains no backslashes. Backslashes in
# JS string literals are escape characters (`\U`, `\s`, `\n`, …) and either
# produce SyntaxErrors or silently corrupt the round-tripped string.
@testset "js_path" begin
    @test BT.js_path("C:\\Users\\sdani\\Proj") == "C:/Users/sdani/Proj"
    @test BT.js_path("/home/sdani/proj")       == "/home/sdani/proj"
    @test BT.js_path("")                       == ""
    @test BT.js_path("no\\separators\\here")   == "no/separators/here"
    @test !occursin('\\', BT.js_path("C:\\foo\\bar"))
end

# ── breadcrumb_paths ─────────────────────────────────────────────────────────
@testset "breadcrumb_paths" begin
    # Linux paths: always forward slashes, root is "/".
    @test BT.breadcrumb_paths("/home/sdani/proj") ==
          ["/", "/home", "/home/sdani", "/home/sdani/proj"]
    @test BT.breadcrumb_paths("/")        == ["/"]
    @test BT.breadcrumb_paths("")         == ["/"]
    @test BT.breadcrumb_paths("/single")  == ["/", "/single"]

    # Windows-style paths (already normalized to forward slashes by js_path).
    # Root is "<drive>:/", subsequent segments accrete the original drive.
    @test BT.breadcrumb_paths("C:/Users/sdani/Proj") ==
          ["C:/", "C:/Users", "C:/Users/sdani", "C:/Users/sdani/Proj"]
    @test BT.breadcrumb_paths("C:/")        == ["C:/"]
    @test BT.breadcrumb_paths("D:/Single")  == ["D:/", "D:/Single"]

    # Case-insensitive on drive letter (lowercase `c:` appears in real Claude
    # project-encoded dir names, e.g. "c--Users-sdani-Cloudi").
    @test BT.breadcrumb_paths("c:/Users/sdani") == ["c:/", "c:/Users", "c:/Users/sdani"]
end

@testset "breadcrumb_root_label" begin
    @test BT.breadcrumb_root_label("/")     == "/"
    @test BT.breadcrumb_root_label("C:/")   == "C:"
    @test BT.breadcrumb_root_label("D:/")   == "D:"
    @test BT.breadcrumb_root_label("c:/")   == "c:"
end

# ── project-name derivation through the import flow ──────────────────────────
# Mirrors the dashboard.jl line ~1919 logic. The bug: when a Windows worker
# sent its native backslash path and the click handler interpolated it into a
# JS string, the browser stripped the backslashes — the server then derived a
# garbled project name like "C_UserssdaniProgrammierenVulkanDev". After
# js_path-normalizing the path inside the JS string, the path round-trips
# clean and basename works on every OS.
@testset "project name from path" begin
    derive(path) = replace(basename(rstrip(path, '/')), r"[^a-zA-Z0-9_\-]" => "_")

    # Linux path → just the basename (was always fine, kept as the reference).
    @test derive("/home/sdani/Programmieren/VulkanDev") == "VulkanDev"

    # Windows path normalized through js_path (what session_widget now emits).
    # On Julia (any OS) basename splits on '/' here, giving the expected name.
    @test derive(BT.js_path("C:\\Users\\sdani\\Programmieren\\VulkanDev")) == "VulkanDev"
    @test derive("C:/Users/sdani/Programmieren/VulkanDev") == "VulkanDev"

    # The corruption pattern the user actually saw before the fix: a raw
    # Windows path arriving at the server with backslashes already stripped
    # by JS escaping. We don't pin the exact wrong-name shape (Linux's
    # basename returns the whole string; Windows's basename strips the `C:`
    # drive prefix → different garbage on each OS). We just assert the
    # corrupted input does NOT yield the right name — proving the bug, and
    # that the js_path fix above (which keeps separators intact) is what
    # gets us "VulkanDev".
    corrupted = "C:UserssdaniProgrammierenVulkanDev"
    @test derive(corrupted) != "VulkanDev"
end

end  # BonitoAgents paths

@testset "worker state" begin
    include("test_worker_state.jl")
end

# dev_server runs the worker as a real separate-process install (config.json +
# spawn_worker) and cleans it up on close. Spawns a worker subprocess (no
# Electron / agent needed), so it's in the default suite.
include("test_dev_server_worker.jl")
include("test_bg_kill_e2e.jl")

include("test_history_sync.jl")

include("test_summary_msg.jl")

# Stability regressions (T1–T22): duplicate-session funnel, JSON-corruption
# locking, chat-teardown leak, lock coverage. Pure Julia — no Electron/worker.
include("test_stability.jl")

include("test_sidebar_open_chats.jl")

include("test_queued_messages.jl")

include("test_clean_cancel.jl")

include("test_cancel_escalation.jl")

include("test_cancel_stress.jl")

include("test_tool_messages.jl")

include("test_render_extras.jl")

include("test_streamed_rawinput.jl")

include("test_mcp_ctrl.jl")

include("test_tool_close_total.jl")
include("test_concurrent_turns.jl")

include("test_acp_log.jl")

include("test_session_config.jl")

# ── Remote-app proxy bridge (BonitoMCP RemoteProxy ↔ BonitoAgents EvalBridge) ──
# Server-side EvalBridge unit test — disconnect fast-fail, fail_pending!, reply
# routing. Pure headless (a bare HTTPAssetServer stands in for the asset host).
include("test_eval_bridge.jl")

# Headless worker-bridge unit test — no eval worker / Malt / browser needed.
# Guards render_embed (namespaced subsession + init bundle), the observable
# round-trip, the control plane (delegate/register/close), and reconnect
# survival: the pieces a "reuse Bonito's ProxyConnection / render_proxied"
# refactor would touch.
include(joinpath(@__DIR__, "..", "..", "BonitoMCP", "test", "test_remote_proxy.jl"))

# Full live e2e: real dev_server + bt_show_app MCP handler + eval-worker dial-back
# + embed + browser round-trip + asset lifecycle/teardown. Heavy (~30s) and needs
# a worker that can dial back, so it's opt-in.
if get(ENV, "BT_RUN_E2E", "") == "1"
    include("test_real_e2e.jl")
    # discover → Resume → chat: a resumable worker session opens a chat and its
    # discover row disappears (no stuck "Resuming…"). Needs worker + Electron.
    include("test_resume_discover_e2e.jl")
else
    @info "runtests: skipping test_real_e2e.jl + test_resume_discover_e2e.jl (set BT_RUN_E2E=1 to run the live worker-dial-back e2e)"
end

# Real-browser fake-agent churn test: WGLMakie apps + open/collapse in Electron —
# guards the bt_show_app open/collapse trashing (relay head-of-line blocking). Self-
# gates on BT_RUN_E2E (needs a worker + Electron).
include("test_bonito_app_churn.jl")

# Real-browser resident-layout test: plotpane-fills-whitespace + two-stage resize,
# keep-alive DOM preservation across navigation (no re-delegate / no
# null.bonitoKeyedList), per-chat floating/plotpane/divider-width residence, and
# interactivity surviving a hide/show. Self-gates on BT_RUN_E2E.
include("test_resident_layout.jl")
