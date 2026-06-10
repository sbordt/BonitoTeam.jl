"""
TestKit: realistic end-to-end test harness for BonitoTeam.

The whole production stack runs unchanged (real `dev_server`, real worker,
real `LocalTransport` with subprocess spawn, real ACP JSON-RPC over
stdio, real websockets). The ONLY thing swapped is the
`claude-agent-acp` binary — replaced with the Julia
`mocks/mock_claude_agent_acp.jl` script driven by a TCP dispatcher in this
process. The dispatcher invokes a user-supplied `agent::Function` for each
prompt and translates its returned event list into the ACP frames the
chat would have seen from real claude.

Usage:

    using TestKit

    server = dev_server(agent = msg -> [
        text("I'll edit that file."),
        edit("/sim/foo.jl", "old contents", "new contents"),
        text("Done."),
    ])
    try
        open_browser(server)
        navigate(server, "/")
        new_chat(server)
        send_message(server, "please edit foo.jl")
        wait_for(server, "tool message landed",
                 \"\"\"document.querySelector('.bt-tool-msg[data-msg-id]')\"\"\")
        screenshot(server, "/tmp/edit-tool.png")
        click(server, ".bt-tool-msg .bt-tool-header")
        screenshot(server, "/tmp/edit-tool-expanded.png")
    finally
        close(server)
    end

Event constructors (`text`, `edit`, `bash`, `thought`, `end_turn`) build a
small DSL the dispatcher serialises to JSON for the mock binary.
"""
module TestKit

using JSON, Sockets, Base64
import BonitoTeam as BT
import BonitoMCP
import Electron: Application, Window, URI, run as erun

export TestServer, dev_server,
       text, thought, edit, bash, end_turn, bt_eval, bt_show_app,
       open_browser, navigate, new_chat, send_message,
       click, screenshot, eval_js, wait_for, current_chat_id

# ── Event DSL ──────────────────────────────────────────────────────────────
# Each constructor returns a small `Dict` carrying the event type + payload.
# The mock binary's dispatcher loop maps these to ACP frames.

text(s::AbstractString)                 = Dict("type" => "text",    "text"  => String(s))
thought(s::AbstractString)              = Dict("type" => "thought", "text"  => String(s))
edit(path, old, new; id = nothing)      = begin
    d = Dict{String,Any}("type" => "edit", "path" => String(path),
                          "old" => String(old), "new" => String(new))
    id === nothing || (d["id"] = String(id))
    d
end
bash(command, output; id = nothing) = begin
    d = Dict{String,Any}("type" => "bash", "command" => String(command),
                          "output" => String(output))
    id === nothing || (d["id"] = String(id))
    d
end
"""
    bt_eval(code; env_path = nothing, id = nothing) -> Dict

Agent event that runs `code` through `BonitoMCP.julia_eval_handler` exactly
the way the real chat does it: Malt worker per `env_path`, real `--project`
activation, real captured stdout/value/errors. The dispatcher executes it in
the test process and pipes the resulting MCP content blocks back to the mock
as ACP tool_call frames. `env_path = nothing` opts into BonitoMCP's
ephemeral-temp session (same as the default in production).
"""
bt_eval(code; env_path = nothing, id = nothing) = begin
    d = Dict{String,Any}("type" => "bt_eval", "code" => String(code))
    env_path === nothing  || (d["env_path"] = String(env_path))
    id       === nothing  || (d["id"]       = String(id))
    d
end

"""
    bt_show_app(code; env_path = nothing, id = nothing) -> Dict

Agent event that runs a bt_show_app expression through real BonitoMCP. The
expression's last value must be a Bonito-renderable (`Bonito.App`,
`DOM.div`, etc.); the dispatcher registers it on the dial-back eval worker
and ships the `shown_app: <id>` reference back to the chat.
"""
bt_show_app(code; env_path = nothing, id = nothing) = begin
    d = Dict{String,Any}("type" => "bt_show_app", "code" => String(code))
    env_path === nothing || (d["env_path"] = String(env_path))
    id       === nothing || (d["id"]       = String(id))
    d
end

end_turn(; stopReason = "end_turn")  = Dict("type" => "end", "stopReason" => String(stopReason))

# Normalise whatever the agent function returned into a Vector{Dict}. The
# convention is "missing `end` event = auto-append end_turn".
function normalise(events)
    out = Dict[]
    if events isa AbstractDict
        push!(out, events)
    elseif events isa AbstractString
        push!(out, text(events))
    else
        for e in events
            e isa AbstractDict || error("TestKit: agent event must be a Dict, got $(typeof(e))")
            push!(out, e)
        end
    end
    if isempty(out) || String(get(last(out), "type", "")) != "end"
        push!(out, end_turn())
    end
    return out
end

# ── TestServer ────────────────────────────────────────────────────────────

mutable struct TestServer
    h::BT.DevHandle
    agent_fn::Ref{Function}            # mutable so tests can swap mid-run
    dispatcher_sock::Sockets.TCPServer
    dispatcher_port::Int
    dispatcher_task::Task
    # Browser handle, lazily opened by `open_browser` so headless server
    # tests (no GUI) don't pay the Electron cost.
    browser_app::Ref{Any}              # Electron.Application | nothing
    browser_win::Ref{Any}              # Electron.Window | nothing
    closed::Ref{Bool}
end

# The dispatcher's TCP server starts BEFORE `dev_server` returns so the
# worker can connect back the moment it spawns a mock agent. But
# `bt_show_app` needs the server URL + worker-secret to point the eval
# bridge at — these are known only after `dev_server` returns. Stash
# them in a Ref the dispatcher reads each time it invokes a real
# BonitoMCP handler. `nothing` until `TestServer` finishes wiring up.
const SERVER_CONTEXT = Ref{Union{Nothing, NamedTuple{(:url, :secret, :project_id), Tuple{String, String, Ref{String}}}}}(nothing)

"""
    dev_server(; agent = msg -> end_turn(), port = nothing, kwargs...) -> TestServer

Start a real BonitoTeam dev server, swap the worker's `claude-agent-acp`
with the mock script, and route every prompt back to `agent`. The
returned `TestServer` is the handle every helper takes as its first arg.
"""
function dev_server(; agent::Function = (_msg -> end_turn()),
                      port::Union{Int,Nothing} = nothing,
                      browser_width::Int  = 1280,
                      browser_height::Int = 820,
                      kwargs...)
    ensure_display!()
    agent_ref = Ref{Function}(agent)

    # 1. Stand up the TCP dispatcher BEFORE we start the dev server, so the
    #    moment the worker spawns a mock agent for the first chat it can
    #    connect back without retry.
    sock = listen(Sockets.IPv4(0x7f000001), 0)   # 127.0.0.1:<auto>
    disp_port = Sockets.getsockname(sock)[2]
    dispatcher_task = Base.errormonitor(@async begin
        while isopen(sock)
            client = try accept(sock) catch; break end
            Base.errormonitor(@async handle_client(client, agent_ref))
        end
    end)

    # 2. Build the mock-agent invocation. The mock is a bash wrapper that
    #    re-execs Julia with the right project; pass it through wholesale,
    #    threading dispatcher coordinates + scenario via env.
    here = @__DIR__
    mock = joinpath(here, "..", "mocks", "mock_claude_agent_acp")
    isfile(mock) || error("mock_claude_agent_acp not found at $mock")
    Sys.iswindows() || chmod(mock, 0o755)                  # idempotent perm fix
    # The mock binary's wrapper activates `BT_MOCK_PROJECT` for the Julia
    # subprocess; default to the user's root project (the test runs from
    # there and that env has every package the mock needs: JSON, Sockets,
    # …). Honoured the convention "always use the root project."
    mock_project = abspath(get(ENV, "BT_MOCK_PROJECT_OVERRIDE", pwd()))

    agent_env = Dict{String,String}(
        "BT_MOCK_ACP_SCENARIO"   => "dispatcher",
        "BT_MOCK_ACP_DISPATCHER" => "127.0.0.1:$(disp_port)",
        "BT_MOCK_PROJECT"        => mock_project,
    )

    h = BT.dev_server(; port = port, agent_bin = mock, agent_env = agent_env, kwargs...)
    sleep(0.8)   # let the worker WS dial in before tests start poking
    # Now publish the server URL + secret to the dispatcher so that
    # `bt_show_app` / `bt_eval` invocations can route the eval worker's
    # dial-back to the right BonitoTeam instance.
    SERVER_CONTEXT[] = (url = h.url, secret = h.secret, project_id = Ref(""))

    return TestServer(h, agent_ref, sock, disp_port, dispatcher_task,
                       Ref{Any}(nothing), Ref{Any}(nothing), Ref(false))
end

# Dispatcher loop per mock-agent connection. Reads one `{"prompt": "..."}`
# per session/prompt, invokes the agent function, streams the resulting
# events back as line-delimited JSON. For high-level events that need
# real MCP execution (`bt_eval`, `bt_show_app`), the dispatcher runs the
# corresponding BonitoMCP handler IN THIS PROCESS, then forwards the
# result blocks to the mock as a `bt_eval_result` / `bt_show_app_result`
# event the mock knows how to wrap as ACP tool_call frames. This keeps
# the bt_* execution real (same Malt worker, same env_path, same
# package resolution) without making the mock binary itself an MCP
# client.
function handle_client(client, agent_ref::Ref{Function})
    try
        while !eof(client)
            line = try readline(client) catch; break end
            isempty(line) && continue
            msg = JSON.parse(line)
            prompt = String(get(msg, "prompt", ""))
            response = try
                normalise(agent_ref[](prompt))
            catch e
                # Surface the test's agent-fn crash in the chat as a
                # synthetic agent message, so the test still sees something
                # rather than the prompt hanging forever.
                [text("agent fn threw: $(sprint(showerror, e))"), end_turn()]
            end
            for ev in response
                forward_event(client, ev)
            end
        end
    catch e
        e isa Base.IOError || @warn "TestKit dispatcher client crashed" exception=e
    finally
        try close(client) catch end
    end
end

# Per-event dispatch — high-level events get rewritten into the lower-level
# `bt_eval_result` / `bt_show_app_result` events the mock knows how to map
# to ACP frames; everything else is forwarded verbatim.
function forward_event(client, ev::AbstractDict)
    t = String(get(ev, "type", ""))
    if t == "bt_eval"
        invoke_bt_eval(client, ev)
    elseif t == "bt_show_app"
        invoke_bt_show_app(client, ev)
    else
        println(client, JSON.json(ev)); flush(client)
    end
end

# Run BonitoMCP.julia_eval_handler with the args from the event. The
# handler spawns / reuses a Malt worker keyed by `env_path`, executes the
# code with `--project=$env_path`, and returns MCP content blocks +
# isError. We forward those to the mock as a structured event the mock
# turns into ACP `tool_call` + `tool_call_update` frames carrying the
# same content.
function invoke_bt_eval(client, ev::AbstractDict)
    args = Dict{String,Any}("code" => String(get(ev, "code", "")))
    haskey(ev, "env_path") && (args["env_path"] = String(ev["env_path"]))
    haskey(ev, "timeout")  && (args["timeout"]  = ev["timeout"])
    haskey(ev, "max_response_bytes") && (args["max_response_bytes"] = ev["max_response_bytes"])
    haskey(ev, "full_output") && (args["full_output"] = ev["full_output"])

    result = try
        BonitoMCP.julia_eval_handler(args)
    catch e
        Dict{String,Any}(
            "content" => Any[Dict("type" => "text",
                                   "text" => "TestKit bt_eval crash: $(sprint(showerror, e))")],
            "isError" => true,
        )
    end

    out = Dict{String,Any}(
        "type"     => "bt_eval_result",
        "tool_id"  => String(get(ev, "id", "te_$(rand(UInt32))")),
        "code"     => String(get(ev, "code", "")),
        "env_path" => get(ev, "env_path", nothing),
        "content"  => get(result, "content", Any[]),
        "is_error" => Bool(get(result, "isError", false)),
    )
    println(client, JSON.json(out)); flush(client)
end

# bt_show_app result: runs the test's Julia code through real BonitoMCP
# (Malt worker → `RemoteProxy.register_app!` → `prerender_app`). The
# resulting `shown_app: <id>` reference is forwarded to the mock so it
# emits an MCP-style ACP tool_call whose tool_name parses to
# `bt_show_app` — the chat's `is_bonito_app(::MCPCall)` then routes it
# to the `BonitoAppMsg` lifecycle, which mounts the live embed via the
# dial-back eval bridge.
#
# `BONITOTEAM_SERVER_URL` + `BONITOTEAM_SECRET` go into the test process's
# env BEFORE the Malt worker is spawned by `get_or_create!` — the worker
# inherits them and uses them to dial back to OUR dev_server. Without
# this the eval-ws bridge would fall back to the URL the chat MCP
# session was started with (production case) or never connect at all
# (test case, since no agent has populated those env vars here).
function invoke_bt_show_app(client, ev::AbstractDict)
    ctx = SERVER_CONTEXT[]
    if ctx === nothing
        println(client, JSON.json(Dict("type" => "text",
            "text" => "[bt_show_app: SERVER_CONTEXT not set — TestServer wiring race]")))
        flush(client); return
    end
    args = Dict{String,Any}("code" => String(get(ev, "code", "")))
    haskey(ev, "env_path") && (args["env_path"] = String(ev["env_path"]))

    prev_url = get(ENV, "BONITOTEAM_SERVER_URL", nothing)
    prev_sec = get(ENV, "BONITOTEAM_SECRET",     nothing)
    prev_pid = get(ENV, "BONITOTEAM_PROJECT_ID", nothing)
    ENV["BONITOTEAM_SERVER_URL"] = ctx.url
    ENV["BONITOTEAM_SECRET"]     = ctx.secret
    # The eval-WS handshake's `project_id` MUST match the chat's pid so
    # the bridge lands in `EVAL_WORKERS[pid]` — that's the dict the chat
    # looks up when rendering the embed. Override here; restore after.
    isempty(ctx.project_id[]) || (ENV["BONITOTEAM_PROJECT_ID"] = ctx.project_id[])
    result = try
        BonitoMCP.julia_show_app_handler(args)
    catch e
        Dict{String,Any}(
            "content" => Any[Dict("type" => "text",
                                   "text" => "TestKit bt_show_app crash: $(sprint(showerror, e))")],
            "isError" => true,
        )
    finally
        prev_url === nothing ? delete!(ENV, "BONITOTEAM_SERVER_URL") : (ENV["BONITOTEAM_SERVER_URL"] = prev_url)
        prev_sec === nothing ? delete!(ENV, "BONITOTEAM_SECRET")     : (ENV["BONITOTEAM_SECRET"]     = prev_sec)
        prev_pid === nothing ? delete!(ENV, "BONITOTEAM_PROJECT_ID") : (ENV["BONITOTEAM_PROJECT_ID"] = prev_pid)
    end

    out = Dict{String,Any}(
        "type"     => "bt_show_app_result",
        "tool_id"  => String(get(ev, "id", "ta_$(rand(UInt32))")),
        "code"     => String(get(ev, "code", "")),
        "env_path" => get(ev, "env_path", nothing),
        "content"  => get(result, "content", Any[]),
        "is_error" => Bool(get(result, "isError", false)),
    )
    println(client, JSON.json(out)); flush(client)
end

function Base.close(s::TestServer)
    s.closed[] && return s
    s.closed[] = true
    try close(s.browser_win[]) catch end
    try close(s.browser_app[]) catch end
    try close(s.dispatcher_sock) catch end
    try close(s.h) catch end
    return s
end

# ── DISPLAY/XAUTHORITY plumbing ────────────────────────────────────────────
# Subprocesses spawned by claude-agent-acp / the MCP worker don't inherit
# the parent shell's X env. Detect the live X socket + xauth cookie and
# set them so Electron can render into the user's session.
function ensure_display!()
    if isempty(get(ENV, "DISPLAY", ""))
        socks = filter(s -> startswith(s, "X"), readdir("/tmp/.X11-unix"))
        isempty(socks) && return     # no X — caller probably wants headless
        ENV["DISPLAY"] = ":" * first(sort(socks; rev = true))[2:end]
    end
    if isempty(get(ENV, "XAUTHORITY", ""))
        uid = parse(Int, strip(read(`id -u`, String)))
        rdir = "/run/user/$uid"
        if isdir(rdir)
            cands = filter(f -> startswith(f, "xauth"), readdir(rdir; sort = true))
            isempty(cands) || (ENV["XAUTHORITY"] = joinpath(rdir, first(cands)))
        end
    end
    return nothing
end

# ── Browser helpers ───────────────────────────────────────────────────────

"""
    open_browser(s; width = 1280, height = 820, route = "/")

Open one Electron window pointed at the dev server. Idempotent — the
second call closes the prior window and opens a fresh one.
"""
function open_browser(s::TestServer; width::Int = 1280, height::Int = 820,
                       route::AbstractString = "/")
    ensure_display!()
    s.browser_win[] === nothing || (try close(s.browser_win[]) catch end)
    s.browser_app[] === nothing || (try close(s.browser_app[]) catch end)
    url = "http://127.0.0.1:$(s.h.state.srv.port)$(route)"
    app = Application(; additional_electron_args = String["--enable-logging", "--v=0"])
    # `paintWhenInitiallyHidden: true` is the documented Electron default but
    # has been seen as `false` in some configurations — making it explicit
    # so `capturePage` always sees a fresh framebuffer on the headless
    # window. `backgroundThrottling: false` disables Chromium's
    # off-screen render throttling for the same reason: without it, Monaco
    # repaints can get coalesced and a `capturePage` between them returns
    # stale pixels.
    win = Window(app, URI(url);
                 options = Dict{String,Any}(
                     "show" => false, "focusOnWebView" => false,
                     "paintWhenInitiallyHidden" => true,
                     "width" => width, "height" => height,
                     "webPreferences" => Dict("backgroundThrottling" => false)))
    s.browser_app[] = app
    s.browser_win[] = win
    sleep(3.0)   # let the dashboard mount + the chat session boot
    return s
end

"""
    eval_js(s, code) -> Any

Run JavaScript in the browser; the value of the last expression is
returned to Julia (via Electron's JSON bridge). Long-running JS should
return primitive types only — no DOM refs.
"""
function eval_js(s::TestServer, code::AbstractString)
    win = s.browser_win[]
    win === nothing && error("open_browser first")
    return erun(win, String(code))
end

"""
    wait_for(s, label, js_predicate; timeout = 8) -> Bool

Poll `js_predicate` (a JS expression returning truthy/falsy) until it's
truthy or `timeout` seconds elapse. Returns the truthy value (or `false`).
"""
function wait_for(s::TestServer, label::AbstractString, predicate::AbstractString;
                   timeout::Real = 8, interval::Real = 0.1)
    t0 = time()
    code = "(() => { try { return " * String(predicate) * "; } catch (e) { return false; } })()"
    while time() - t0 < timeout
        v = eval_js(s, code)
        v in (false, nothing) || return v
        sleep(interval)
    end
    error("wait_for timed out after $(timeout)s: $label")
end

"""
    click(s, css_selector)

Click the first element matching the CSS selector. Throws if it's missing.
"""
function click(s::TestServer, selector::AbstractString)
    sel = String(selector)
    ok = eval_js(s, """(() => {
        const el = document.querySelector($(json(sel)));
        if (!el) return false;
        el.click();
        return true;
    })()""")
    ok === true || error("click: no element matched $sel")
    return s
end

"""
    navigate(s, route)

Drive the BonitoTeam dashboard to a project / view. `route` can be one of:

  * `"/"`               — root dashboard
  * `"/?pid=<id>"`      — opens the chat for project `<id>` (server pushes
                          `current_view` via its standard URL handling)

For routes that aren't direct URLs, prefer the high-level helpers
(`new_chat`, `open_project`) below.
"""
function navigate(s::TestServer, route::AbstractString)
    win = s.browser_win[]
    win === nothing && error("open_browser first")
    base = "http://127.0.0.1:$(s.h.state.srv.port)"
    erun(win, "location.href = $(json(base * String(route)))")
    sleep(2.0)
    return s
end

"""
    new_chat(s; cwd = mktempdir()) -> String

Programmatically create a fresh chat backed by the test agent. Returns
the project id. Equivalent to "click 'New chat' on the dashboard and pick
a folder" — but driven server-side so the test doesn't need to fight the
folder picker. The dispatcher routes every prompt through the agent fn.
"""
function new_chat(s::TestServer; cwd::AbstractString = mktempdir(),
                                   title::AbstractString = "Test chat")
    state = s.h.state
    wid = first(keys(state.workers[]))
    proj = BT.create_project_from_worker!(state, wid, String(cwd);
                                           name = basename(String(cwd)),
                                           start_session = true)
    pid = proj.id
    # Backfill a title up front: the sidebar's `open_chat_projects` filters
    # on `title !== nothing || resume_session_id !== nothing`, so a chat with
    # neither (the just-created one) would be invisible until the first user
    # message lands. For tests we want it immediately visible so `click` can
    # find its sidebar entry. `notify_chats!` bumps `chat_signal` to drive a
    # sidebar re-render.
    lock(state.lock) do
        state.projects[][pid].title = String(title)
    end
    BT.notify_chats!(state)
    # Wait until the per-project ChatModel is registered + its ACP session
    # has bound (start_chat_client! is async).
    t0 = time()
    while time() - t0 < 15
        lock(state.lock) do
            haskey(state.chat_models, pid)
        end && lock(state.lock) do
            state.chat_models[pid].client[] !== nothing
        end && break
        sleep(0.1)
    end
    # Publish this chat's pid so the bt_show_app dispatcher can override
    # BONITOTEAM_PROJECT_ID when invoking the BonitoMCP handler — the
    # eval-WS bridge keys on that env var for `EVAL_WORKERS` lookup.
    # Without this the bridge dials back under whatever pid the OUTER
    # context (e.g. a parent bt_julia_eval session running these tests)
    # set, and the chat finds no bridge under its own pid.
    ctx = SERVER_CONTEXT[]
    ctx === nothing || (ctx.project_id[] = String(pid))
    return String(pid)
end

"""
    send_message(s, text; pid = current_chat_id(s))

Send `text` to the chat as a user message. Equivalent to typing into the
input box + clicking send. Goes through the same `send_message!` the UI
does, so it exercises the same code path.
"""
function send_message(s::TestServer, txt::AbstractString;
                       pid::AbstractString = current_chat_id(s))
    state = s.h.state
    model = lock(state.lock) do; state.chat_models[String(pid)]; end
    BT.send_message!(model, BT.UserMsg(String(txt)))
    return s
end

"""
    current_chat_id(s) -> String

The most recently created project id (the one `new_chat` returned). If
there's only one chat, that's it; otherwise pick the most recent.
"""
function current_chat_id(s::TestServer)
    state = s.h.state
    pids = lock(state.lock) do; collect(keys(state.chat_models)); end
    isempty(pids) && error("no chat created yet — call new_chat first")
    return last(pids)
end

"""
    screenshot(s, path)

Save a PNG of the current Electron window. Synchronous: blocks until the
file lands on disk so the next `Read` call sees it.
"""
function screenshot(s::TestServer, path::AbstractString; timeout::Real = 8)
    win = s.browser_win[]
    win === nothing && error("open_browser first")
    path = abspath(String(path))
    mkpath(dirname(path))
    flag = path * ".done"
    isfile(flag) && rm(flag; force = true)
    isfile(path) && rm(path; force = true)
    # `capturePage` on a `show:false` window can hand back a stale
    # composited buffer if the renderer was throttled between paints.
    # `invalidate()` forces a fresh paint pass; double-RAF in the page
    # then guarantees the layout/paint we want has actually landed before
    # capturePage grabs pixels. `null` at the end so erun returns
    # immediately (the promise hasn't resolved yet).
    erun(s.browser_app[], """
        const w = electron.BrowserWindow.fromId($(win.id));
        w.webContents.invalidate();
        w.webContents.executeJavaScript(
            'new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))'
        ).then(() => w.webContents.capturePage()).then(img => {
            require('fs').writeFileSync($(json(path)), img.toPNG());
            require('fs').writeFileSync($(json(flag)), '1');
        });
        null
    """)
    t = time()
    while !isfile(flag) && time() - t < timeout; sleep(0.05); end
    isfile(path) || error("screenshot timed out: $path")
    rm(flag; force = true)
    return path
end

# Tiny JSON-encode helper (no JSON3 dep in the test module).
json(x) = JSON.json(x)

end # module
