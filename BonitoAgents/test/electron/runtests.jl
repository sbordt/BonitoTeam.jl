# Run every Tier-N electron test in sequence. Each file is self-contained:
# brings up its own Electron window (where applicable), prints a per-tier
# summary via `TH.report!(...)`, and tears down in `finally`.
#
# `TH.report!` pushes its tally into `TH.TIER_RESULTS`; the harness peeks at
# the last entry after each include() to build a cross-tier summary at the end.
#
# Usage:  julia --project=. test/electron/runtests.jl
#
# Set BONITOAGENTS_NO_SCREENSHOT=0 to inline base64 PNGs in the per-test
# output (off by default — keeps CI logs sane).

# Ensure BonitoAgents is in Main scope — individual test files reference
# `BonitoAgents.WorkerInfo`, `BonitoAgents.ChatModel`, etc. at top level.
using BonitoAgents

const HERE = @__DIR__
# Each test saves a screenshot of its final state to /tmp/jl_*.png and
# prints the path; nothing more to configure.

# Bring up TH once so the harness can read TH.TIER_RESULTS. The test files
# also `include("helpers.jl")`, but helpers.jl wraps everything in
# `module TestHelpers ... end`, so re-includes are no-ops at module level
# while still re-defining the body. The TIER_RESULTS const survives across
# includes because it's the same module instance.
include(joinpath(HERE, "helpers.jl"))
empty!(TH.TIER_RESULTS)

# Order: layout/navigation first (cheap, fail fast), then chat features,
# then dashboard, then real-I/O at the end so it doesn't tie up sockets
# during the chat tests.
# NOTE: this is the LEGACY harness (TH wraps `unified_app(state)` directly —
# an internal API). It is being retired in favour of the real-stack,
# UI-only suite under ../e2e (driven by ElectronCall.Testing through the
# mock ACP binary, no internal-API calls). Each behaviour is deleted from
# here once ../e2e covers it; what remains below is the backlog still to
# port. See ../e2e/COVERAGE.md for the full map. Not run in CI.
const FILES = [
    # Chat tool/message variants still to port
    "test_streamed_tool_input.jl",
    "test_virtual_scroll.jl",
    "test_chat_controls.jl",
    "test_cross_worker_sync_ui.jl",
    "test_chat_remount.jl",
    # test_callback_dereg.jl removed — it asserted the old global
    # `window.BonitoChat` + multi-callback architecture. The new ES6
    # module ships a single `comm` subscription with a `destroyed` flag
    # and never returns `false`, so the splice-during-forEach bug class
    # it guarded against can't recur.
    "test_chat_errors.jl",
    "test_chat_show.jl",
    "test_chat_show_extras.jl",
    "test_auto_prompt.jl",
    "test_scroll_chase.jl",
    "test_chat_attach.jl",
    "test_scroll_stress.jl",
    "test_follow_pill.jl",
    "test_keyed_list.jl",
    "test_folder_threads.jl",
    # Real I/O at the end so it doesn't tie up sockets during the chat tests
    "test_remotesync.jl",
    "test_worker_move.jl",
    "test_cross_worker_sync.jl",
]

# (file, label, pass, fail) — populated as each test runs.
const RESULTS = Tuple{String,String,Int,Int}[]

for f in FILES
    println("\n", "█"^60)
    println("▶ Running ", f)
    println("█"^60)
    pre = length(TH.TIER_RESULTS)
    crashed = nothing
    try
        Main.include(joinpath(HERE, f))
    catch e
        crashed = e
        println(stderr, "[runtests] ", f, " raised: ", sprint(showerror, e))
    end
    if length(TH.TIER_RESULTS) > pre
        label, p, fl = TH.TIER_RESULTS[end]
        if crashed !== nothing
            # Test reported its assertions but then errored (e.g. screenshot
            # timeout, cleanup error, or anything in `finally`). Surface it
            # as a failure so the suite summary doesn't lie.
            push!(RESULTS, (f, label * " — crashed after report: " *
                                    sprint(showerror, crashed), p, fl + 1))
        else
            push!(RESULTS, (f, label, p, fl))
        end
    elseif crashed !== nothing
        push!(RESULTS, (f, "(crashed before report) — " *
                            sprint(showerror, crashed), 0, 1))
    else
        push!(RESULTS, (f, "(no report)", 0, 1))
    end
end

println("\n", "═"^60)
println("Electron suite — final summary")
println("═"^60)
let total_pass = 0, total_fail = 0
    for (file, label, p, fl) in RESULTS
        total_pass += p
        total_fail += fl
        sym = fl == 0 ? "✓" : "✗"
        println("  ", sym, "  ", rpad(file, 30),
                lpad(p, 4), " passed, ", lpad(fl, 4), " failed   ", label)
    end
    println("─"^60)
    println("  TOTAL: ", total_pass, " passed, ", total_fail, " failed")
    isinteractive() || exit(total_fail == 0 ? 0 : 1)
end
