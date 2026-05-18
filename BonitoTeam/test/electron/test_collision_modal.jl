# Tier 2m — collision-resolution modal rendering + button wiring.
#
# Scope: the *modal component* (`render_collision_modal` +
# `collision_side_panel`) given a fixed comparison payload. Verifies:
#   - both sides render with the right counts, ages, and recent-file
#     listings
#   - the side with the newer mtime gets the `bt-collision-newer`
#     highlight class
#   - "Use candidate" and "Keep existing" call the supplied do_import
#     function with the matching on_collision symbol
#   - "Cancel" clears the modal (collision_state -> nothing)
#
# The collision-DETECTION path (raising ProjectCollisionError) lives in
# test_project_collision.jl; this file is only about how the modal renders
# the resulting comparison + dispatches the user's choice.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using JSON, Dates, Bonito

# ── Fake state + fake collision payload ────────────────────────────────────
state = TH.make_state(; n_workers = 2, n_projects = 0)
wa = state.workers[]["w-1"]; wa.name = "PC"
wb = state.workers[]["w-2"]; wb.name = "Laptop"
notify(state.workers)

# Existing project bound to PC. server_path doesn't need to exist on disk
# for the modal — the summary dicts carry everything the panel reads.
existing_p = BonitoTeam.ProjectInfo(
    "p-exist", "myproject", "w-1",
    mktempdir(),               # server_path
    "/home/agent/projects/myproject",
    now(UTC))
state.projects[]["p-exist"] = existing_p

# Hand-built comparison: PC (existing) was touched a week ago, laptop
# (candidate) was touched 5 minutes ago. Laptop should win the
# auto-highlight.
PC_MTIME     = time() - 86400 * 7
LAPTOP_MTIME = time() - 60 * 5

fake_comparison = (
    existing = Dict{String,Any}(
        "total_files"  => 47,
        "total_bytes"  => 124_500,
        "latest_mtime" => PC_MTIME,
        "recent_files" => Dict{String,Any}[
            Dict("path" => "src/main.jl",   "size" => 1_200, "mtime" => PC_MTIME),
            Dict("path" => "README.md",     "size" =>   400, "mtime" => PC_MTIME - 3600),
            Dict("path" => "dev/lib/a.jl",  "size" =>   800, "mtime" => PC_MTIME - 7200),
        ],
        "git_subrepos" => Dict{String,Any}[
            Dict("path"        => "dev/lib",
                  "head_sha"    => "abc1234567890def1234567890abcdef12345678",
                  "head_time"   => PC_MTIME - 86400,
                  "dirty_count" => 0,
                  "branch"      => "main"),
        ],
    ),
    existing_source = :worker,
    candidate = Dict{String,Any}(
        "total_files"  => 49,
        "total_bytes"  => 130_000,
        "latest_mtime" => LAPTOP_MTIME,
        "recent_files" => Dict{String,Any}[
            Dict("path" => "src/main.jl",     "size" => 1_280, "mtime" => LAPTOP_MTIME),
            Dict("path" => "new_feature.jl",  "size" =>   600, "mtime" => LAPTOP_MTIME - 60),
            Dict("path" => "README.md",       "size" =>   420, "mtime" => LAPTOP_MTIME - 600),
        ],
        "git_subrepos" => Dict{String,Any}[
            Dict("path"        => "dev/lib",
                  "head_sha"    => "fed7654321098765432109876543210987654321",
                  "head_time"   => LAPTOP_MTIME - 3600,
                  "dirty_count" => 3,
                  "branch"      => "main"),
        ],
    ),
)

# ── Bonito harness ─────────────────────────────────────────────────────────
# Mount the modal inside a minimal App so we can drive it from electron.
# `do_import_calls` records what the modal asks for so we can assert the
# right symbol got dispatched per button.
collision_state = Bonito.Observable{Union{Nothing,NamedTuple}}(nothing)
do_import_calls = Tuple{String,String,Symbol}[]   # (worker, path, on_collision)

function fake_do_import(w_name::String, path::String;
                         name::Union{Nothing,String} = nothing,
                         resume_session_id::Union{Nothing,String} = nothing,
                         on_collision::Symbol = :detect)
    push!(do_import_calls, (w_name, path, on_collision))
    # The real do_import would re-invoke create_project_from_worker! and
    # only clear collision_state on success. For this test, the modal
    # should hide as soon as the click commits.
    collision_state[] = nothing
end

app = Bonito.App() do session
    Bonito.DOM.div(
        BonitoTeam.DashboardStyles,
        BonitoTeam.render_collision_modal(state, collision_state, fake_do_import))
end

disp = Bonito.use_electron_display(;
    devtools = false,
    options  = Dict{String,Any}("show" => false, "width" => 1280, "height" => 800),
    electron_args = ["--ozone-platform=x11"])
display(disp, app)
sleep(0.6)

ctx = (; disp = disp, app = app, session = app.session[], state = state)
# Install JS error sink like helpers.open_window does.
run(disp.window, """
    window.__errs = [];
    window.addEventListener('error', e => window.__errs.push(String(e.message)));
""")

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    TH.section("Initial: no modal when collision_state is nothing") do
        record("no .bt-collision-card on initial mount",
               @TH.test_eq TH.dom_count(ctx, ".bt-collision-card") 0)
    end

    TH.section("Populate collision_state → modal appears") do
        # Set on the Julia side; Bonito propagates.
        collision_state[] = (
            existing         = existing_p,
            candidate_worker = "w-2",
            candidate_path   = "/home/agent/projects/myproject",
            candidate_name   = "myproject",
            comparison       = fake_comparison,
        )
        record("modal appeared within 2s",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-collision-card') !== null";
                   timeout = 2.0))
        # Two sides rendered.
        record("two .bt-collision-side rendered",
               @TH.test_eq TH.dom_count(ctx, ".bt-collision-side")  2)
        # Heading carries the colliding name.
        h3 = TH.eval_js(ctx,
            "document.querySelector('.bt-collision-card h3').innerText")
        record("heading mentions 'myproject'",
               @TH.test_true occursin("myproject", String(h3)))
    end

    TH.section("Side panels render headline stats + recent files + git rows") do
        # Sides are in DOM order: existing first, then candidate.
        text = TH.eval_js(ctx, """
            (() => Array.from(document.querySelectorAll('.bt-collision-side'))
                .map(el => el.innerText))()
        """)
        @assert text isa AbstractVector && length(text) == 2
        ex_text   = String(text[1])
        cand_text = String(text[2])
        record("existing side names the existing worker (PC)",
               @TH.test_true occursin("PC", ex_text))
        record("candidate side names the candidate worker (Laptop)",
               @TH.test_true occursin("Laptop", cand_text))
        record("existing shows file count (47)",
               @TH.test_true occursin("47", ex_text))
        record("candidate shows file count (49)",
               @TH.test_true occursin("49", cand_text))
        # Recent files appear.
        record("existing lists src/main.jl",
               @TH.test_true occursin("src/main.jl", ex_text))
        record("candidate lists new_feature.jl",
               @TH.test_true occursin("new_feature.jl", cand_text))
        # Git rows render with branch + dirty status.
        record("existing git shows 'clean' (0 dirty)",
               @TH.test_true occursin("clean", ex_text))
        record("candidate git shows '3 dirty'",
               @TH.test_true occursin("3 dirty", cand_text))
        # Age strings are formatted "Xd ago" etc.
        record("existing shows 'd ago' (week-old mtime)",
               @TH.test_true occursin("d ago", ex_text))
        record("candidate shows 'm ago' (5-minute-old mtime)",
               @TH.test_true occursin("m ago", cand_text))
    end

    TH.section("Newer side gets the .bt-collision-newer highlight class") do
        # The wrapping div carries the class; query for it and check
        # its inner side title says Laptop (the candidate).
        newer_title = TH.eval_js(ctx, """
            (() => {
                const el = document.querySelector('.bt-collision-newer .bt-collision-side-title');
                return el ? el.innerText : '';
            })()
        """)
        record("highlighted side title contains 'Laptop'",
               @TH.test_true occursin("Laptop", String(newer_title)))
    end

    TH.section("Clicking 'Use candidate' dispatches :take_candidate and closes modal") do
        empty!(do_import_calls)
        # The Bonito Buttons render as <button> elements with the
        # provided class. Pick the one whose text matches.
        TH.eval_js(ctx, """
            (() => {
                const btns = Array.from(document.querySelectorAll('button'));
                const target = btns.find(b => b.innerText.trim() === 'Use candidate');
                if (target) target.click();
                return !!target;
            })()
        """)
        sleep(0.5)
        record("do_import called exactly once",
               @TH.test_eq length(do_import_calls)  1)
        if !isempty(do_import_calls)
            (w, p, oc) = do_import_calls[1]
            record("dispatched to candidate worker 'w-2'",  @TH.test_eq w "w-2")
            record("dispatched candidate path",
                   @TH.test_eq p "/home/agent/projects/myproject")
            record("on_collision = :take_candidate",        @TH.test_eq oc :take_candidate)
        end
        record("modal closes after dispatch",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-collision-card') === null";
                   timeout = 2.0))
    end

    TH.section("Re-populate, then click 'Keep existing' → :keep_existing") do
        empty!(do_import_calls)
        collision_state[] = (
            existing         = existing_p,
            candidate_worker = "w-2",
            candidate_path   = "/home/agent/projects/myproject",
            candidate_name   = "myproject",
            comparison       = fake_comparison,
        )
        @assert TH.wait_for(ctx,
            "document.querySelector('.bt-collision-card') !== null"; timeout = 2.0)
        TH.eval_js(ctx, """
            (() => {
                const btns = Array.from(document.querySelectorAll('button'));
                const target = btns.find(b => b.innerText.trim() === 'Keep existing');
                if (target) target.click();
                return !!target;
            })()
        """)
        sleep(0.5)
        record("do_import called once",
               @TH.test_eq length(do_import_calls) 1)
        if !isempty(do_import_calls)
            (_, _, oc) = do_import_calls[1]
            record("on_collision = :keep_existing", @TH.test_eq oc :keep_existing)
        end
    end

    TH.section("Cancel button clears collision_state, no do_import call") do
        empty!(do_import_calls)
        collision_state[] = (
            existing         = existing_p,
            candidate_worker = "w-2",
            candidate_path   = "/home/agent/projects/myproject",
            candidate_name   = "myproject",
            comparison       = fake_comparison,
        )
        @assert TH.wait_for(ctx,
            "document.querySelector('.bt-collision-card') !== null"; timeout = 2.0)
        TH.eval_js(ctx, """
            (() => {
                const btns = Array.from(document.querySelectorAll('button'));
                const target = btns.find(b => b.innerText.trim() === 'Cancel');
                if (target) target.click();
                return !!target;
            })()
        """)
        sleep(0.4)
        record("modal hidden after cancel",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-collision-card') === null";
                   timeout = 2.0))
        record("do_import NOT called by cancel",
               @TH.test_eq length(do_import_calls) 0)
        record("collision_state observable cleared",
               @TH.test_true (collision_state[] === nothing))
    end

    TH.section("No JS errors") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_eq length(errs) 0)
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "collision-modal final")

finally
    TH.report!("Tier 2m — collision modal", results)
    try close(disp) catch end
end
