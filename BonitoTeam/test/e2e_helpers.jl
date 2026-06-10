# Shared harness for the heavy real-browser e2e tests (churn + resident layout).
#
# A FAKE AGENT (no claude): a dashboard project with a MockTransport chat model
# and N live app bubbles, registered on a real eval worker. A headless Electron
# browser then drives the chat. WGLMakie matters for the churn/back-pressure
# tests: its heavy frames + headless software-WebGL make the browser drain its
# socket slowly. This file is included (guarded) by both e2e test files.

using Test
import BonitoTeam, BonitoMCP, Bonito, Electron
# Sentinel so an include site can guard against loading this twice (runtests
# includes both e2e files). Dedicated name — NOT a shared helper like
# `fake_agent_project!`, which a REPL/dev session may already have defined.
const E2E_HELPERS_LOADED = true
const BT   = BonitoTeam
const ACP  = BonitoTeam.AgentClientProtocol
const ROOT = "/sim/Programmieren/ClaudeExperiments"

# A WGLMakie app: heavy enough to exercise slow-browser back-pressure.
const APPCODE = """using Bonito, WGLMakie
Bonito.App() do s
    f = Figure(size=(440,300)); heatmap(f[1,1], rand(70,70)); lines(f[2,1], cumsum(randn(800))); f
end"""

# An interactive app whose displayed value is 2× the click count — and the
# doubling happens in a WORKER-side reaction. So if the browser shows "6" after 3
# clicks, the click MUST have reached the worker observable and the reaction's
# result MUST have been relayed back: real end-to-end interactivity, not "a
# canvas exists". Used to prove interactivity survives keep-alive navigation.
const INTERACTIVE_CODE = """using Bonito
Bonito.App() do s
    clicks = Bonito.Observable(0); doubled = Bonito.Observable(0)
    Bonito.on(s, clicks) do c; doubled[] = 2c; end
    Bonito.DOM.div(
        Bonito.DOM.button("inc"; class="ibtn", onclick=Bonito.js"() => \$(clicks).notify(\$(clicks).value + 1)"),
        Bonito.DOM.span(doubled; class="dbl"))
end"""

# Build a dashboard project with N live app bubbles, no claude. NOTE: this
# restarts the ROOT eval worker (keyed to this project) — create it BEFORE any
# nav-target project so it owns the bridge.
function fake_agent_project!(h, n::Int; name::AbstractString = "churn", code::AbstractString = APPCODE)
    wid = first(keys(h.state.workers[]))
    p = BT.create_project_from_worker!(h.state, wid, ROOT; name = name, start_session = false)
    # The sidebar only lists projects with a title or resume_session_id
    # (open_chat_projects), so without this the project has no .bt-proj-icon and
    # the test can't click into the chat — the chat never opens, no tools/canvas
    # render. Give it a title so it shows up.
    p.title = name
    for (k, v) in BT.eval_dialback_env(h.state, p.id); ENV[k] = v; end
    # In production this is set by the BonitoWorker daemon from its install
    # URL. Tests bypass that daemon (spawn BonitoMCP directly), so we plug it
    # in from the local Bonito server's URL.
    ENV["BONITOTEAM_SERVER_URL"] = Bonito.online_url(h.state.srv, "")
    BonitoMCP.restart!(BonitoMCP.manager(), ROOT)        # eval worker that dials THIS server, keyed to p.id
    appids = String[]
    for _ in 1:n
        r = BonitoMCP.julia_show_app_handler(Dict("code" => code, "env_path" => ROOT))
        r["isError"] == false || error("bt_show_app handler errored: $(r)")
        push!(appids, String(strip(replace(r["content"][1]["text"], "shown_app:" => ""))))
    end
    model = BT.ChatModel(h.state, p.server_path; project_id = p.id,
                         transport = BT.MockTransport((o, i) -> nothing))
    h.state.chat_models[p.id] = model                    # cache for the dashboard (no client bring-up)
    for appid in appids
        tid = string(Bonito.uuid4())
        BT.persist_tool_content!(model.chat_dir,
            ACP.GenericTool(tid, "mcp", "bt_show_app", "completed",
                ACP.ToolContent[ACP.TextContent("shown_app: $appid")], Channel{ACP.ToolCall}(1)))
        # Emit the real typed message a live `bt_show_app` produces — carries its
        # registered app id intrinsically (no content sniffing).
        BT.send!(model, BT.BonitoAppMsg(tid, "bonito_app", "bt_show_app", "completed",
                                        "", time(), time(), "btworker", String(appid), nothing))
    end
    BT.notify_chats!(h.state)   # re-render the sidebar so the project's icon appears
    return p, model
end

# A second dashboard project to navigate TO (different worker_path ⇒ its own
# thread; no apps ⇒ no eval worker, so it doesn't disturb the apps project's
# bridge). Just a navigation target for the chat↔other-chat stress.
function nav_target_project!(h; name::AbstractString = "beta")
    wid = first(keys(h.state.workers[]))
    pB = BT.create_project_from_worker!(h.state, wid, mktempdir(); name = name, start_session = false)
    pB.title = name   # so it shows in the sidebar (open_chat_projects needs a title)
    h.state.chat_models[pB.id] = BT.ChatModel(h.state, pB.server_path; project_id = pB.id,
                                              transport = BT.MockTransport((o, i) -> nothing))
    BT.notify_chats!(h.state)
    return pB
end

# Open a fresh headless Electron window onto the dev server. Returns
# (appE, win, R) where R(js) runs JS in the renderer and returns the value.
# Electron args for the headless e2e tests. `--no-sandbox` (sandbox can't start
# as root / in containers); `--use-gl=swiftshader` + `--enable-unsafe-swiftshader`
# give software WebGL so WGLMakie `<canvas>` actually renders headless (no GPU) —
# without these the plot canvases never paint and screenshots are blank. These
# always run headless (show:false), so we want software GL unconditionally,
# unlike Bonito's default_electron_args which only adds them under GITHUB_ACTIONS.
const HEADLESS_WEBGL_ARGS = String[
    "--no-sandbox",
    # Software WebGL via ANGLE+SwiftShader. NB this Electron rejects the old
    # `--use-gl=swiftshader` (resolves to gl=none); it wants the ANGLE form:
    "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
    "--ignore-gpu-blocklist",
]

function open_browser(h; width = 1300, height = 850, logp = nothing)
    EC   = Bonito.HTTPServer.current_electron()
    args = vcat(HEADLESS_WEBGL_ARGS,
                logp === nothing ? String[] :
                String["--enable-logging", "--log-file=$logp", "--v=0"])
    appE = EC.Application(; additional_electron_args = args)
    win  = EC.Window(appE, EC.URI(h.url); options = Dict("show" => false, "width" => width, "height" => height))
    return appE, win, (c -> EC.run(win, c))
end

# Tear down a worker/browser, clearing the dial-back env the fake agent set.
function close_browser(appE)
    EC = Bonito.HTTPServer.current_electron()
    appE === nothing || try EC.close(appE) catch end
    for k in ("BONITOTEAM_SERVER_URL", "BONITOTEAM_SECRET", "BONITOTEAM_PROJECT_ID")
        haskey(ENV, k) && delete!(ENV, k)
    end
end
