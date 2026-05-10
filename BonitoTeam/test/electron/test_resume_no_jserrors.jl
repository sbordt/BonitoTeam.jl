# End-to-end regression for the Key-N-not-found / null-Observable race
# the user hit when clicking "Resume" on a discovered claude session.
#
# Architecture-side fix landed in:
#   - src/sidebar.jl   (sidebar `map(state.projects)` only; no re-render
#                       on `current_view` change → no subsession churn
#                       → no GLOBAL_OBJECT_CACHE refcount race)
#   - src/state.jl     (`state.projects` is itself the Observable)
#
# This test reproduces the user's clicked path:
#   1. real `BonitoTeam.serve()` (NOT a mock Server — the URL is the same
#      one production prints).
#   2. real `BonitoWorker` connected over its actual control WS.
#   3. real Electron window pointed at `Bonito.online_url(state.srv, "")`.
#   4. capture every Chromium console message via the BrowserWindow event.
#   5. drive the navigation that Resume does at the very end:
#      `current_view[] = project_id` — by clicking the sidebar entry
#      exactly the way the user does.
#   6. assert ZERO occurrences of any of:
#        - "Key <N> not found"
#        - "TrackingOnly: Key <N> not found"
#        - "Trying to delete object <N>"
#        - "Cannot read properties of null (reading 'notify')"
#
# The session fires `current_view[] = …` repeatedly across this run; if
# the race were still present each navigation would dump dozens of
# warnings (matching the user's screenshot).

using BonitoTeam, Bonito, HTTP, JSON
import Electron, BonitoWorker

# ── Boot the server ──────────────────────────────────────────────────────
state = BonitoTeam.serve(;
    host          = "127.0.0.1",
    port          = 0,
    worker_secret = "resume-test-secret",
    state_dir     = mktempdir(),
    working_dir   = mktempdir())
url = Bonito.online_url(state.srv, "")
@info "Server up" url

# ── Spawn a real local worker against it ─────────────────────────────────
worker_proj_root = mktempdir()
worker_task = Base.errormonitor(@async try
    BonitoWorker.connect_and_serve(;
        server_url    = url,
        secret        = "resume-test-secret",
        worker_id     = "resume-test-worker-id",
        name          = "ResumeTestWorker",
        mcp_path      = "",
        projects_root = worker_proj_root)
catch e
    @warn "worker task ended" exception=e
end)

# Wait until the worker handshake completes.
deadline = time() + 15
while time() < deadline
    haskey(state.workers[], "resume-test-worker-id") &&
        state.workers[]["resume-test-worker-id"].status == :online && break
    sleep(0.2)
end
@assert haskey(state.workers[], "resume-test-worker-id") "worker never connected"
@info "Worker connected"

# ── Seed two projects so the sidebar has multiple entries to navigate
#    between. This exactly mirrors what `create_project_from_worker!`
#    does at the end of the Resume handler: `state.projects[][id] = p;
#    notify(state.projects); current_view[] = p.id`.
for (pid, name) in (("alpha", "Alpha"), ("beta", "Beta"))
    p = BonitoTeam.ProjectInfo(pid, name, "resume-test-worker-id",
                                joinpath(state.working_dir, name),
                                joinpath(worker_proj_root, name),
                                BonitoTeam.now(BonitoTeam.UTC))
    mkpath(p.server_path); mkpath(p.worker_path)
    state.projects[][pid] = p
end
notify(state.projects)
@info "Projects seeded" ids=collect(keys(state.projects[]))

# ── Open Electron + install a console capture that records EVERYTHING
#    Chromium's renderer prints. `console-message` fires on the main-
#    process side for every `console.log/warn/error/etc.` in the page.
app = Electron.Application()
win = Electron.Window(app, Electron.URI(url);
                      options = Dict{String,Any}("show"=>false, "focusOnWebView"=>false))
sleep(2.5)

console_log = tempname() * ".jsonl"
win_id = win.id
Electron.run(app, """
    const win = electron.BrowserWindow.fromId($win_id);
    const fs  = require('fs');
    win.webContents.on('console-message', (event, level, message, line, source) => {
        try {
            fs.appendFileSync($(JSON.json(console_log)),
                JSON.stringify({level, message, source, line}) + '\\n');
        } catch(e) {}
    });
    null
""")
@info "Console capture armed" path=console_log

# Helper: click the sidebar entry whose data-project-id matches `pid`.
# Empty `pid` selects the Home / dashboard entry.
function navigate_to(win, pid::AbstractString)
    Electron.run(win, """
        (() => {
            const el = document.querySelector(
                '.bt-side-item[data-project-id=$(JSON.json(pid))]');
            if (el) { el.click(); return true; }
            return false;
        })()
    """)
end

wait_for(win, predicate; timeout=5.0) = begin
    deadline = time() + timeout
    while time() < deadline
        try
            Electron.run(win, "(() => { return ($predicate); })()") === true && return true
        catch end
        sleep(0.1)
    end
    false
end

# ── Drive navigation. Each click changes `current_view`. Pre-fix this is
#    where Bonito would spam GLOBAL_OBJECT_CACHE warnings.
@assert wait_for(win,
    "document.querySelector('.bt-side-item[data-project-id=\"alpha\"]') !== null";
    timeout=10) "sidebar didn't render projects"

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    for cycle in 1:5
        navigate_to(win, "alpha"); sleep(0.4)
        navigate_to(win, "beta");  sleep(0.4)
        navigate_to(win, "");      sleep(0.3)
    end
    sleep(1.0)   # let any deferred warnings flush

    # ── Read the captured console and grep for the specific bug
    #    signatures. Render-time warnings, "Key not found",
    #    "TrackingOnly", "Trying to delete object", and the
    #    null-Observable TypeError were all part of the user's
    #    screenshot.
    lines = isfile(console_log) ? readlines(console_log) : String[]
    msgs  = String[]
    for line in lines
        try
            push!(msgs, JSON.parse(line)["message"])
        catch end
    end

    bug_patterns = [
        r"Key \d+ not found",
        r"TrackingOnly: Key \d+ not found",
        r"Trying to delete object \d+, which is not in global session cache",
        r"Cannot read properties of null \(reading 'notify'\)",
    ]
    offenders = String[]
    for m in msgs, pat in bug_patterns
        occursin(pat, m) && push!(offenders, m)
    end

    record("zero Key-not-found warnings during 15 navigations",
           isempty(offenders))
    isempty(offenders) ||
        @info "offending console messages" first_few=first(offenders, min(5, length(offenders)))

    record("alpha entry was reachable",
           Electron.run(win, """
               document.querySelector('.bt-side-item[data-project-id="alpha"]') !== null
           """) === true)
finally
    println("\n", "="^60)
    pass = count(p -> p.second, results)
    fail = length(results) - pass
    println("Resume-flow no-JS-errors: $pass passed, $fail failed")
    for (name, ok) in results
        ok || println("  FAIL  $name")
    end

    try close(win) catch end
    try close(app) catch end
    try close(state.srv) catch end
end
