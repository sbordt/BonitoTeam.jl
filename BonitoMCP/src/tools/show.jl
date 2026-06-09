# bt_show — display a file from the worker's disk in the chat as a
# collapsible preview. Trivial wrapper: takes a path, returns a `shown:`
# text reference. The chat-side render_tool_body parses the reference,
# fetches the file via the worker control WS's fetch_blob command, and
# renders an inline preview based on the file's extension/MIME.
#
# bt_julia_eval already auto-saves rich values to <env>/.bonitoTeam/show/
# when their richest MIME is image/HTML/SVG, so the typical flow is:
#
#   1. agent calls bt_julia_eval(some_makie_figure) — gets `shown: …`
#      reference back alongside the text repr; bytes stay on disk
#   2. agent decides the user should see it; calls bt_show(path=…)
#      with the path from step 1, OR with any other file already on
#      the worker's disk (downloads, generated files, etc.)
#
# The bt_show response intentionally has no MIME chain or eval — those
# live in bt_julia_eval. Here we just emit a reference; the chat side
# infers MIME from the extension at render time.

const SHOW_KNOWN_MIMES = Dict{String,String}(
    ".png" => "image/png",   ".jpg" => "image/jpeg",  ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",   ".webp" => "image/webp", ".svg" => "image/svg+xml",
    ".bmp" => "image/bmp",
    ".mp4" => "video/mp4",   ".webm" => "video/webm", ".mov" => "video/quicktime",
    ".html" => "text/html",  ".htm" => "text/html",
    ".json" => "application/json",
    ".md" => "text/markdown", ".txt" => "text/plain",  ".log" => "text/plain",
    ".jl" => "text/x-julia",  ".py" => "text/x-python", ".js" => "text/javascript",
    ".csv" => "text/csv",
)

function show_mime_from_path(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    return get(SHOW_KNOWN_MIMES, ext, "application/octet-stream")
end

function bt_show_format_bytes(n::Integer)
    n < 1024     && return "$(n)B"
    n < 1024^2   && return string(round(n / 1024;     digits = 1), "KB")
    n < 1024^3   && return string(round(n / 1024^2;   digits = 1), "MB")
                    return string(round(n / 1024^3;   digits = 2), "GB")
end

function julia_show_handler(args::AbstractDict)
    path = String(get(args, "path", ""))
    isempty(path) && return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => "error: missing `path`")],
        "isError" => true,
    )
    isfile(path) || return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => "error: not a file: $path")],
        "isError" => true,
    )
    mime = show_mime_from_path(path)
    sz   = filesize(path)
    text = "shown: $path ($mime, $(bt_show_format_bytes(sz)))"
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => text)],
        "isError" => false,
    )
end

const SHOW_DESCRIPTION = """
Display a file from the worker's disk in the chat as a collapsible preview.

Trivial: just hand it a path. The chat-side renderer fetches the file
lazily and inlines a preview based on the file's extension:

  • image/png · jpeg · gif · webp · svg · bmp → inline `<img>`
  • video/mp4 · webm · mov                    → `<video controls>`
  • text/html                                 → sandboxed `<iframe>`
  • text/* and code files                     → Monaco editor
  • anything else                             → caption only

The file's bytes never enter your conversation context. You only emit a
reference; the chat does the rest.

Common flow:
  1. Run `bt_julia_eval` for any value with rich output (Makie / Plots
     figure, Colorant matrix, DataFrame with HTML show). The eval
     auto-writes the rendered output to <env>/.bonitoTeam/show/<id>.<ext>
     and returns the `shown: …` path alongside the text repr.
  2. Pass that path to `bt_show` (or any other path on the worker) when
     you want the user to see the file inline.

Use this for: showing a Makie figure you just rendered; surfacing a log
or HTML report you just generated; displaying any image / video on the
worker's disk.
"""

register!(
    "bt_show", SHOW_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "path" => Dict("type"=>"string",
                            "description"=>"Path on the worker to a file to display in the chat. Absolute or relative to the worker's cwd."),
        ),
        "required" => ["path"],
    ),
    julia_show_handler,
)

# bt_show_app — display a LIVE, interactive Bonito app in the chat. The `code`
# (which must evaluate to a `Bonito.App`) runs in the eval session; the server
# renders it there and proxies it into the browser, so widgets/observables stay
# fully interactive (unlike bt_show, which snapshots a file). Requires the eval
# session to have dialed back to the server (automatic under BonitoTeam).
const SHOW_APP_DESCRIPTION = """
Display a LIVE, interactive Bonito app in the chat. `code` must evaluate to a
`Bonito.App(...)`. Pass the SAME `env_path` you use for bt_julia_eval (the
project directory) — the app then runs in that exact session, so state and
`using Bonito` from earlier evals are in scope, AND it uses the project's Bonito
which the server proxies the app through. Omitting `env_path` spins up a separate
temp-env session whose Bonito may differ from the server's and fail to proxy.
The app renders live in the browser — sliders, buttons, WGLMakie plots etc. stay
interactive. Use bt_show instead for a static file/plot snapshot.

Build apps the Bonito way — these rules matter MORE here than in a regular
Bonito server because every `bt_show_app` call mounts a fresh chat-side
sub-session, and stale subscribers on shared state will pile up across calls
and eventually wedge the worker:

  * Construct ALL Observables INSIDE `App() do session ... end`. A
    `const X = Observable(...)` at module/eval scope is shared across every
    `bt_show_app` invocation, every browser tab, and every threaded writer —
    listeners accumulate, dead-session callbacks block on closed sockets, and
    notify() can hang the writing task.

  * To bridge external state (e.g. a `Threads.@spawn` background loop pushing
    samples) into an App, ALWAYS use `map(f, session, parent_obs)` — the
    session-scoped overload registers the parent→child callback on
    `session.deregister_callbacks` so it auto-tears down when the chat
    sub-session closes. Plain `map(f, parent_obs)` and `on(parent_obs)` leave
    callbacks attached forever; after a few `bt_show_app` rounds the parent's
    listener list is full of dead bridges and the writer task wedges.

  * Inter-thread stop flags need `Threads.Atomic{Bool}` (or `@atomic`), not
    `Ref{Bool}` — visibility of plain Ref writes across threads under load
    is not guaranteed and the background task may never see your stop signal.
"""

function julia_show_app_handler(args::AbstractDict)
    code     = String(get(args, "code", ""))
    env_path = get(args, "env_path", nothing)
    julia_cmd = get(args, "julia_cmd", nothing)
    isempty(strip(code)) && return Dict{String,Any}(
        "content" => [Dict("type"=>"text", "text"=>"error: missing `code`")], "isError" => true)
    s = try
        get_or_create!(manager(), env_path; julia_cmd)
    catch e
        return Dict{String,Any}("content"=>[Dict("type"=>"text",
            "text"=>"error starting session: $(sprint(showerror, e))")], "isError"=>true)
    end
    ensure_eval_dialed!(s)   # also waits for RemoteProxy bridge to be installed
    # Hard-verify the bridge ACTUALLY connected: if `ensure_eval_dialed!` ran
    # but the worker's bridge WS still isn't open (dial wedged, server gone,
    # secret mismatch), returning `shown_app:<id>` is a silent failure — the
    # server's EVAL_WORKERS has no entry for this project, the chat renders
    # "live app unavailable", and there's no signal back to the agent that
    # the call WAS the failure. Fail explicitly here so the agent sees it.
    bridge_live = try
        Malt.remote_eval_fetch(s.worker,
            :(isdefined(Main, :RemoteProxy) &&
              Main.RemoteProxy.BRIDGE[] !== nothing &&
              Main.RemoteProxy.BRIDGE[].driver.ws[] !== nothing))
    catch
        false
    end
    bridge_live || return Dict{String,Any}(
        "content" => [Dict("type"=>"text",
            "text"=>"error: eval-ws bridge not connected — the worker could not dial back to the BonitoTeam server. Common causes: server restarted while the worker session was running (the worker keeps a stale dial state); BONITOTEAM_SERVER_URL not set in the MCP env; BONITOTEAM_SECRET mismatch. Try bt_julia_restart to rebuild the worker process, or restart the BonitoTeam server cleanly.")],
        "isError" => true)
    id = string(rand(UInt64); base = 16)
    try
        Malt.remote_eval_fetch(s.worker, quote
            # Build the Bonito.App from the agent's code and register it on the
            # worker's RemoteProxy bridge. `include_string` evaluates the code
            # as a top-level file — each statement runs in its own world so
            # `global X = …` definitions are visible to the App's handler
            # closure that comes after them; the return value is the value of
            # the last expression (the `Bonito.App(...)`).
            Main.RemoteProxy.register_app!($id, include_string(Main, $code))
        end)
    catch e
        return Dict{String,Any}("content"=>[Dict("type"=>"text",
            "text"=>"error building app: $(sprint(showerror, e))")], "isError"=>true)
    end
    # Render the app ONCE now (cached for the first display): this surfaces a
    # render-time failure — a throwing `jsrender` / `App` body — back to the
    # AGENT as a tool error here, instead of only painting it into the browser
    # when the bubble is expanded later. The display reuses this render, so the
    # happy path renders exactly once.
    try
        Malt.remote_eval_fetch(s.worker, quote
            Main.RemoteProxy.prerender_app($id)
        end)
    catch e
        return Dict{String,Any}("content"=>[Dict("type"=>"text",
            "text"=>"error rendering app: $(sprint(showerror, e))")], "isError"=>true)
    end
    # The server's `find_app_reference` picks up this token and embeds the
    # bridge-registered app into the chat-bubble subsession (see remote_app.jl).
    return Dict{String,Any}(
        "content" => [Dict("type"=>"text", "text"=>"shown_app: $id")], "isError" => false)
end

register!(
    "bt_show_app", SHOW_APP_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "code" => Dict("type"=>"string",
                "description"=>"Julia code that evaluates to a Bonito.App to display live in the chat."),
            "env_path" => Dict("type"=>"string",
                "description"=>"Project directory of the eval session — use the SAME value as bt_julia_eval so the app runs in that session and the project's Bonito. Omit only for a throwaway temp env (proxying may fail)."),
            "julia_cmd" => Dict("type"=>"string",
                "description"=>"Custom Julia invocation, e.g. `julia +1.11`. Use rarely; match bt_julia_eval if you set it there."),
        ),
        "required" => ["code"],
    ),
    julia_show_app_handler,
)
