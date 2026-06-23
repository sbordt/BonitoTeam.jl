# Real-browser proof of the bt_show_app remote-app embed, through the ACTUAL
# chat machinery: a live dev_server, the real bt_show_app MCP handler dialing
# back an eval Malt.Worker, and the app mounted into a page via `dom_in_js`
# (exactly how `ToolRenderCommand` mounts a tool body). Crucially the page is
# served BY THE DEV SERVER, so the worker's init `.bin` resolves against the
# same `asset_host` the bridge registered it on — and we then RE-RENDER (a
# second `dom_in_js` into the same slot), which is what used to drop the init
# asset (404 → empty app) and double-free the shared session id. Driven through
# a real (headless `show=false`) Electron browser.

const BONITO = "/sim/Programmieren/ClaudeExperiments/dev/Bonito"
include(joinpath(BONITO, "test", "ElectronTests.jl"))
TestWindow(args...; options=Dict{String,Any}("show"=>false,"focusOnWebView"=>false)) =
    Bonito.EWindow(args...; app=get_test_app(), options=options)

using Test
import BonitoAgents, BonitoMCP, Bonito
import ElectronCall
const BT = BonitoAgents; const Malt = BonitoAgents.Malt
using Bonito: Session, DOM, @js_str
const ROOT = "/sim/Programmieren/ClaudeExperiments"

# The dial-back is raw Bonito frames now (no Malt on the bridge). For worker
# introspection reach it through BonitoMCP's own Malt link.
function root_worker()
    for s in values(BonitoMCP.manager().sessions)
        s.env_path == ROOT && BonitoMCP.is_alive(s) && return s.worker
    end
    error("no live ROOT eval worker")
end

const APPCODE = """
using Bonito
global E2E_COUNT = Bonito.Observable(0)
global E2E_DOUBLED = Bonito.Observable(0)
Bonito.App() do s
    Bonito.on(s, E2E_COUNT) do c; E2E_DOUBLED[] = 2c; end
    Bonito.onjs(s, E2E_COUNT, Bonito.@js_str("(x)=>{}"))
    Bonito.onjs(s, E2E_DOUBLED, Bonito.@js_str("(x)=>{}"))
    Bonito.DOM.div("doubled = ", Bonito.DOM.span(E2E_DOUBLED; id="result"))
end
"""

@testset "bt_show_app live in a real browser (survives a dom_in_js re-render)" begin
    h = BT.dev_server()
    win = nothing
    try
        pid = "elec-" * string(rand(UInt16))
        env = BT.eval_dialback_env(h.state, pid)
        for (k,v) in env; ENV[k] = v; end
        ENV["BONITOAGENTS_SERVER_URL"] = Bonito.online_url(h.state.srv, "")
        BonitoMCP.restart!(BonitoMCP.manager(), ROOT)

        res = BonitoMCP.julia_show_app_handler(Dict("code"=>APPCODE, "env_path"=>ROOT))
        @test res["isError"] == false
        appid = String(strip(replace(res["content"][1]["text"], "shown_app:"=>"")))
        @test timedwait(()->haskey(h.state.eval_workers, pid), 30.0) === :ok
        eb = h.state.eval_workers[pid]
        count_id = Malt.remote_eval_fetch(root_worker(), :(E2E_COUNT.id))

        # A page on the DEV SERVER: a `#slot` we mount the app body into via
        # `dom_in_js`, just like the chat's `ToolRenderCommand`. Capture the
        # page session so the test can drive `dom_in_js` once the browser is up.
        sref = Ref{Any}(nothing)
        page = Bonito.App() do session
            sref[] = session
            DOM.div(DOM.div(; id="slot"); id="host")
        end
        Bonito.route!(h.state.srv, "/embed-test" => page)
        url = "http://127.0.0.1:$(h.state.srv.port)/embed-test"

        win = TestWindow()
        ElectronCall.load(win.window, URI(url))
        @test timedwait(()-> sref[] !== nothing && isopen(sref[]) && Bonito.isready(sref[]), 40.0) === :ok
        session = sref[]

        ev(js)   = Bonito.evaljs_value(session, js)
        function poll(js, want; t=25)
            tl = time() + t; v = nothing
            while time() < tl; v = ev(js); v == want && return true; sleep(0.05); end
            @info "poll timed out" js=string(js) last=v want; false
        end
        # mount the remote app into #slot exactly like ToolRenderCommand does
        mount!() = Bonito.dom_in_js(session, BT.RemoteAppPlaceholder(eb, appid),
            js"""(elem) => { const s = document.querySelector('#slot'); s.innerHTML=''; s.appendChild(elem); }""")

        # ── first mount ──────────────────────────────────────────────────────
        mount!()
        @test poll(js"document.querySelector('#result') ? 'y' : 'n'", "y")   # init .bin fetched (no 404)
        @test ev(js"document.querySelector('#result').textContent") == "0"
        bp = ev(js"document.querySelector('#host [data-bonito-remote]').getAttribute('data-bonito-remote')")
        key = "$bp/$count_id"
        ev(js"Bonito.lookup_global_object($(key)).notify(7)")
        @test poll(js"document.querySelector('#result').textContent", "14")  # interactive
        @test Malt.remote_eval_fetch(root_worker(), :(E2E_COUNT[])) == 7

        # ── RE-RENDER (the regression) ───────────────────────────────────────
        # slot.innerHTML='' tears down the first mount's subsession; a fresh
        # `dom_in_js` makes a NEW subsession with its OWN sub_id + init bundle.
        # Old behaviour: the shared init asset was gone (404) and the shared id
        # double-freed. Now the asset lives on the bridge's stable asset_host and
        # each mount is independent — so the app must still render and drive.
        mount!()
        @test poll(js"document.querySelector('#result') ? 'y' : 'n'", "y")   # fresh init .bin served
        @test poll(js"document.querySelector('#result').textContent", "14")  # shared observable state
        ev(js"Bonito.lookup_global_object($(key)).notify(9)")
        @test poll(js"document.querySelector('#result').textContent", "18")
        @test Malt.remote_eval_fetch(root_worker(), :(E2E_COUNT[])) == 9
        println("✓ real browser: bt_show_app renders, is interactive, and survives a dom_in_js re-render")
    finally
        for k in ("BONITOAGENTS_SERVER_URL","BONITOAGENTS_SECRET","BONITOAGENTS_PROJECT_ID"); haskey(ENV,k) && delete!(ENV,k); end
        win === nothing || (try; close(win.window); catch; end)
        try; close(h); catch; end
    end
end
nothing
