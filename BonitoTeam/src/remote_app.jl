# Embed an interactive Bonito App that lives in a worker eval process into a host
# browser Session by piping the Bonito protocol RAW over the worker's dial-back
# websocket. The worker renders + owns the observables; the BonitoTeam server is a
# byte relay between that socket and the browser, plus the one server-side asset
# mirror (the browser fetches assets over HTTP). There is NO Malt on the frame
# path — every Bonito frame is just bytes on the websocket, both directions. Malt
# (via BonitoMCP's own link to its workers) is used ONLY to bootstrap the worker:
# include RemoteProxy, build the bridge, start the dial. See BonitoMCP/RemoteProxy.jl.
#
# Wire format on the dial-back WS: `[tag][payload]`.
#   * `D` (data)    — a Bonito frame, piped verbatim (worker→browser and back).
#   * `C` (control) — a small msgpack dict for the few request/response ops:
#                     `delegate` (render an app subsession → init bundle),
#                     `asset_read` (lazy range fetch), `close` (a subsession),
#                     and the worker→host `asset_add`/`asset_remove` push.

const Malt = BonitoMCP.Malt   # only the BonitoMCP-side bootstrap touches Malt

const TAG_DATA = UInt8('D')
const TAG_CTRL = UInt8('C')

# One per worker process (keyed by project). Owns the dial-back socket, the stable
# per-worker asset registry (a `ChildAssetServer` of the dashboard's one
# `HTTPAssetServer`, so proxied assets outlive any transient render session), the
# pending control-request table, and the current browser root connection that
# worker→browser frames relay onto.
mutable struct EvalBridge
    prefix::String                       # bridge parent.id == route_to_remote namespace
    ws::Any                              # dial-back websocket; swapped on reconnect under wlock
    wlock::ReentrantLock                 # serialize frame sends to the worker AND ws-swap
    asset_host::Bonito.ChildAssetServer
    pending::Dict{Int, Channel{Any}}     # control req-id → reply channel
    pending_lock::ReentrantLock
    reqid::Threads.Atomic{Int}
    root_conn::Base.RefValue{Any}        # current browser root connection (worker→browser target)
    # Set when the WS drops; cancelled if a reconnect arrives before it fires.
    # Defers asset_host close + EVAL_WORKERS eviction so a transient drop doesn't
    # tear down the per-worker registry that the reconnect would have reused.
    teardown_armed::Threads.Atomic{Bool}
end

# Reconnects compare prefix (== BRIDGE[].parent.id on the worker): same prefix
# means same BRIDGE[] / same routes, swap WS; different prefix means worker
# restart, hard-replace.
make_eval_bridge(prefix::AbstractString, ws, host) = EvalBridge(
    String(prefix), ws, ReentrantLock(), host,
    Dict{Int,Channel{Any}}(), ReentrantLock(),
    Threads.Atomic{Int}(0), Base.RefValue{Any}(nothing),
    Threads.Atomic{Bool}(false))

const EVAL_WORKERS = Dict{String, EvalBridge}()    # project_id => EvalBridge

# ── Raw frame transport to the worker ───────────────────────────────────────
function send_tagged(eb::EvalBridge, tag::UInt8, payload::AbstractVector{UInt8})
    buf = Vector{UInt8}(undef, length(payload) + 1)
    @inbounds buf[1] = tag
    copyto!(buf, 2, payload, firstindex(payload), length(payload))
    lock(eb.wlock) do
        try; HTTP.WebSockets.send(eb.ws, buf); catch; end
    end
    return nothing
end
send_data(eb::EvalBridge, bytes::AbstractVector{UInt8}) = send_tagged(eb, TAG_DATA, bytes)
send_ctrl(eb::EvalBridge, dict)                         = send_tagged(eb, TAG_CTRL, Bonito.MsgPack.pack(dict))

# A control request that expects a reply (delegate / asset_read). The dial-back
# relay loop resolves it via `pending`; this runs on a DIFFERENT task (a chat
# command or an HTTP asset handler), so the wait can't deadlock the relay.
function call_ctrl(eb::EvalBridge, op::AbstractString; timeout = 30.0, kw...)
    id = Threads.atomic_add!(eb.reqid, 1)
    ch = Channel{Any}(1)
    lock(eb.pending_lock) do; eb.pending[id] = ch; end
    send_ctrl(eb, Dict{String,Any}("op" => op, "id" => id,
                                   (String(k) => v for (k, v) in kw)...))
    try
        Base.timedwait(() -> isready(ch), timeout) === :ok || error("remote control '$op' timed out")
        result = take!(ch)
        # Worker-side handle_control sends back an `err` field on exception;
        # handle_worker_control wrapped it as an Exception. Rethrow so the
        # caller sees the failure right away rather than a malformed value.
        result isa Exception && throw(result)
        return result
    finally
        lock(eb.pending_lock) do; delete!(eb.pending, id); end
    end
end

# Bonito's MsgPack packs a `Vector{UInt8}` as a binary Extension, so byte payloads
# sent over the control channel come back wrapped — unwrap them.
ctrl_bytes(x) = x === nothing ? nothing :
                x isa Bonito.MsgPack.Extension ? Vector{UInt8}(x.data) : Vector{UInt8}(x)

# Worker→host control frame (runs on the relay loop task).
function handle_worker_control(eb::EvalBridge, msg::AbstractDict)
    op = msg["op"]
    if op == "reply"
        ch = lock(eb.pending_lock) do; get(eb.pending, Int(msg["id"]), nothing); end
        # Worker can reply with `err` (string showerror) instead of `val` when
        # `handle_control` raised. Surface as an Exception so `call_ctrl` throws
        # immediately — no 30 s timedwait, no swallowed failures.
        ch === nothing || put!(ch,
            haskey(msg, "err") ? ErrorException(String(msg["err"])) :
                                 get(msg, "val", nothing))
    elseif op == "asset_add"
        k = String(msg["key"])
        cached = ctrl_bytes(msg["cached"])
        # Lazy fetch for non-eager assets — a control round-trip on a SEPARATE task
        # (the HTTP asset handler), never on this relay loop, so no deadlock.
        fetch = (s, e) -> ctrl_bytes(call_ctrl(eb, "asset_read"; key = k, start = s, stop = e))
        Bonito.register_proxy_asset!(eb.asset_host,
            Bonito.RemoteAsset(k, String(msg["mime"]), Int(msg["total"]), cached, fetch))
    elseif op == "asset_remove"
        Bonito.release_proxy_asset!(eb.asset_host, String(msg["key"]))
    end
    return
end

# Grace period before we tear an EvalBridge down after its WS dropped. The
# worker's `dial_loop` retries with min 0.5 s and max 8 s backoff, so 30 s
# easily covers a network blip; if the worker is truly gone after that, we
# release the asset_host + clear EVAL_WORKERS so the next first-time dial-back
# rebuilds cleanly.
const EVAL_BRIDGE_RECONNECT_GRACE = 30.0

# Fail every in-flight `call_ctrl` waiting on this bridge with a clean error —
# called when the WS drops, so callers don't sit on a 30 s timeout for replies
# that physically can't come back over the dead socket.
function fail_pending!(eb::EvalBridge, why::AbstractString)
    drained = lock(eb.pending_lock) do
        pp = collect(values(eb.pending))
        empty!(eb.pending)
        pp
    end
    err = ErrorException(why)
    for ch in drained
        isready(ch) || put!(ch, err)
    end
    return nothing
end

# `/eval-ws` handler. Handshake is "secret project_id prefix"; after that the
# socket is a raw Bonito frame pipe. This task IS the worker→browser relay (and
# the worker→host control reader) for the bridge's whole lifetime.
function handle_eval_ws(state::ServerState, ws)
    line = try; String(HTTP.WebSockets.receive(ws)); catch; return; end
    parts = split(strip(line), ' '; limit = 3)
    if length(parts) != 3 || parts[1] != state.worker_secret
        @warn "eval dial-back: bad handshake"; return
    end
    project_id = String(parts[2]); prefix = String(parts[3])
    if state.srv === nothing
        @warn "eval dial-back with no live server — cannot proxy assets"; return
    end

    # Existing dial for this project? Decide reconnect vs. replace by comparing
    # `prefix` against `BRIDGE[].parent.id` on the worker side. Same prefix ⇒
    # same `BRIDGE[]` (routes intact) ⇒ swap WS into the existing EvalBridge.
    # Different prefix ⇒ worker restarted ⇒ stale routes, hard-replace.
    existing = get(EVAL_WORKERS, project_id, nothing)
    eb = if existing !== nothing && existing.prefix == prefix
        @info "eval worker reconnected" project_id prefix
        # Fail any orphaned pending — those replies physically can't come back
        # over the old WS, so the callers shouldn't wait for them.
        fail_pending!(existing, "eval bridge reconnected; in-flight request dropped")
        lock(existing.wlock) do
            existing.ws = ws
        end
        existing.teardown_armed[] = false   # cancel any pending teardown
        existing
    else
        if existing !== nothing
            @info "eval worker replaced (new prefix; worker restarted?)" project_id old_prefix = existing.prefix new_prefix = prefix
            # Old bridge's routes are stale — fail orphans, drop the asset host.
            fail_pending!(existing, "eval bridge replaced by a new worker; in-flight request dropped")
            try close(existing.asset_host) catch end
        end
        fresh = make_eval_bridge(prefix, ws, Bonito.HTTPAssetServer(state.srv))
        EVAL_WORKERS[project_id] = fresh
        @info "eval worker dialed back (ws) — raw bridge installed" project_id prefix
        fresh
    end

    try
        for msg in ws
            # Per-frame guard: a single malformed/raising frame must NOT tear down
            # the whole bridge relay (which would strand every pending control reply).
            try
                data = msg isa AbstractVector{UInt8} ? msg : Vector{UInt8}(codeunits(String(msg)))
                isempty(data) && continue
                tag = @inbounds data[1]
                payload = @view data[2:end]
                if tag == TAG_DATA
                    rc = eb.root_conn[]
                    rc === nothing || write(rc, Vector{UInt8}(payload))   # worker → browser
                elseif tag == TAG_CTRL
                    handle_worker_control(eb, Bonito.MsgPack.unpack(Vector{UInt8}(payload)))
                end
            catch e
                @warn "eval dial-back: dropping bad frame" exception = (e, catch_backtrace())
            end
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError || e isa Base.IOError || e isa EOFError ||
            @warn "eval dial-back relay loop ended" exception = (e, catch_backtrace())
    finally
        # WS dropped. Fail in-flight requests immediately (no point waiting for
        # replies over a dead socket), then arm a deferred teardown — if the
        # worker's dial_loop reconnects within the grace window, the reconnect
        # branch above cancels it. Otherwise we drop the proxied assets and
        # evict from EVAL_WORKERS, freeing the entry for a future fresh dial.
        fail_pending!(eb, "eval bridge WS dropped; in-flight request abandoned")
        eb.teardown_armed[] = true
        Base.errormonitor(@async begin
            sleep(EVAL_BRIDGE_RECONNECT_GRACE)
            if eb.teardown_armed[]
                eb.teardown_armed[] = false
                try close(eb.asset_host) catch end
                lock(state.lock) do
                    get(EVAL_WORKERS, project_id, nothing) === eb &&
                        delete!(EVAL_WORKERS, project_id)
                end
                @info "eval bridge teardown after no reconnect" project_id prefix
            end
        end)
    end
    return
end

# Env the server injects into the BonitoMCP MCP server so its eval worker can
# dial `/eval-ws` back. `state.srv` gives the public base URL (http→ws, https→wss).
function eval_dialback_env(state::ServerState, project_id::AbstractString)
    state.srv === nothing && return Dict{String,String}()
    wsurl = replace(Bonito.online_url(state.srv, "/eval-ws"), r"^http" => "ws")
    return Dict{String,String}(
        "BONITOTEAM_EVAL_WS"    => wsurl,
        "BONITOTEAM_SECRET"     => state.worker_secret,
        "BONITOTEAM_PROJECT_ID" => String(project_id),
    )
end

# Host-side renderable: embeds the worker fragment and drives the worker
# session's `init_session` in the browser via on_document_load.
struct RemoteWorkerApp
    html::String
    init_url::String
    session_id::String          # sub.id — passed to `Bonito.init_session(…)` so the browser
                                # bootstraps this exact subsession's queued messages.
    bridge_prefix::String       # `id_prefix(connection(sub))` — the namespace the worker stamps
                                # onto every cache_key / dom-jscall-id / sub-session-id it puts
                                # into the browser's three global namespaces. Used by the host's
                                # `route_to_remote` to forward inbound frames back to the worker,
                                # and exposed via `data-bonito-remote` so callers driving the
                                # embed from JS know what prefix to construct cache keys with.
    compression::Bool
end

function Bonito.jsrender(session::Bonito.Session, app::RemoteWorkerApp)
    # `Base.HTML{String}` is the first-class raw-HTML primitive: Bonito's
    # `RAW_HTML_TAG` msgpack rule (serialization/msgpack.jl) ships the bytes
    # through the dynamic `dom_in_js` path binary-safe — no string-escaping,
    # no JS-literal newline pitfalls.
    node = Bonito.DOM.div(Base.HTML{String}(app.html); dataBonitoRemote = app.bridge_prefix)
    Bonito.onload(session, node, js"""(el) => {
        Bonito.init_session($(app.session_id), Bonito.fetch_binary($(app.init_url)), "sub", $(app.compression));
    }""")
    return Bonito.jsrender(session, node)
end

# ── Host-side bridge attachment (per stable root session) ───────────────────
#
# The worker→host frame relay and the browser→worker routing are bound to the
# tab's STABLE root session (the one that owns the websocket), NOT to a transient
# `dom_in_js` subsession that the chat tears down on every tool-body re-render.
# Attached exactly once per (worker, root); torn down when the root closes.
const BRIDGE_ATTACHED = Set{String}()              # "$prefix|$root_id" already wired
const BRIDGE_ATTACH_LOCK = ReentrantLock()

function attach_bridge_host!(root::Bonito.Session, eb::EvalBridge)
    tag = string(eb.prefix, '|', root.id)
    lock(BRIDGE_ATTACH_LOCK) do
        tag in BRIDGE_ATTACHED && return false
        push!(BRIDGE_ATTACHED, tag); return true
    end || return

    # worker → browser frames are written to this connection by the dial-back
    # relay loop (`handle_eval_ws`); point it at this tab's socket.
    eb.root_conn[] = Bonito.connection(root)

    # browser → worker: the host already decodes each inbound frame to route it
    # (route_to_remote needs the msg_type/session), so we forward the DECODED frame
    # re-packed as plain (uncompressed) msgpack — `to_worker`, not `forward_bytes`.
    # That makes the worker side compression-agnostic (the bridge runs
    # uncompressed) regardless of the browser connection's compression. Routing is
    # by the BRIDGE prefix — any sub.id / object id starts with it.
    Bonito.register_remote!(root, Bonito.RemoteSession(eb.prefix;
        to_worker = data -> send_data(eb, Bonito.MsgPack.pack(data))))

    Bonito.on(root.on_close) do _
        Bonito.unregister_remote!(root, eb.prefix)
        eb.root_conn[] === Bonito.connection(root) && (eb.root_conn[] = nothing)
        # Close any worker subsessions still mounted for this tab so they don't
        # outlive the page.
        for sid in take_mounts!(root, eb); close_remote_sub!(eb, sid); end
        lock(BRIDGE_ATTACH_LOCK) do; delete!(BRIDGE_ATTACHED, tag); end
    end
    return
end

# ── Per-mount subsession bookkeeping ────────────────────────────────────────
#
# `Collapsable` discards a tool body with `innerHTML=''` and re-renders via a
# FRESH `dom_in_js` on the next expand — and that DOM removal does NOT close the
# proxied worker subsession (Bonito's delete-observer doesn't reliably collect
# proxied subs; the reference `embed_app` likewise tears down explicitly on
# `host.on_close`). So we track the current worker sub per (tab, app) and close
# the previous one when a new mount supersedes it, mirroring `embed_app`. Closing
# the worker sub releases its asset (1→0) AND — because the bridge parent is
# marked ready — emits `Bonito.free_session(sub_id)` to the browser, dropping the
# stale listeners a removed mount left on shared observables.
const MOUNTS = Dict{String, String}()              # "$root_id|$prefix|$app_id" => current sub_id
const MOUNTS_LOCK = ReentrantLock()
mount_key(root, eb, app_id) = string(root.id, '|', eb.prefix, '|', app_id)

# Record `sub_id` as the live mount for (root, app); return the superseded one (or nothing).
function swap_mount!(root, eb, app_id, sub_id)
    lock(MOUNTS_LOCK) do
        k = mount_key(root, eb, app_id)
        old = get(MOUNTS, k, nothing); MOUNTS[k] = sub_id; old
    end
end

# Drop + return every mounted sub_id for this (root, bridge) — used on tab close.
function take_mounts!(root, eb)
    lock(MOUNTS_LOCK) do
        pre = string(root.id, '|', eb.prefix, '|')
        ks = filter(k -> startswith(k, pre), collect(keys(MOUNTS)))
        sids = String[MOUNTS[k] for k in ks]; foreach(k -> delete!(MOUNTS, k), ks); sids
    end
end

# Close a proxied worker subsession (best-effort): a `close` control frame. The
# worker's `close_subsession` releases its asset (1→0 → `asset_remove`) and emits
# `free_session(sub_id)` back through the bridge, dropping the browser-side
# objects/listeners a removed mount left on shared observables.
close_remote_sub!(eb::EvalBridge, sub_id::AbstractString) =
    (send_ctrl(eb, Dict("op" => "close", "sub" => String(sub_id))); nothing)

"""
    embed_remote_app(host::Session, eb::EvalBridge, app_id::AbstractString) -> RemoteWorkerApp

Embed a Bonito.App registered on the eval worker's `RemoteProxy` bridge (by
`bt_show_app` / `show_remote_app!`) into `host`'s browser page.

Bridge host-side wiring (the worker→browser frame relay in `handle_eval_ws`, the
browser→worker routing, and the per-worker asset registry) is attached ONCE to
the tab's stable root session — see `attach_bridge_host!`. This call sends a
`delegate` control frame; the worker renders a FRESH subsession of the bridge
parent, packs its init bundle as a `BinaryAsset` (pushing `asset_add` control
frames the relay registers on `eb.asset_host`), and replies `(sub_id, html,
init_url)`. We wait until the init bundle is serveable before returning so the
browser's `fetch(init_url)` can't race ahead to a 404.

Because a `Collapsable` tool body is re-rendered on every expand (and the old
DOM is dropped with `innerHTML=''`, which does NOT close the proxied sub), we
explicitly close the previously-mounted worker sub for this (tab, app) — that
releases its asset and frees its browser-side listeners (see `close_remote_sub!`).
"""
function embed_remote_app(host::Bonito.Session, eb::EvalBridge, app_id::AbstractString)
    root = Bonito.root_session(host)
    attach_bridge_host!(root, eb)
    # One control round-trip: the worker renders a fresh subsession, packs its init
    # bundle as a BinaryAsset (which fires `asset_add` control frames the relay loop
    # registers on `eb.asset_host`), and replies with (sub_id, html, init_url).
    sub_id, html, init_url = call_ctrl(eb, "delegate"; app = String(app_id))
    sub_id = String(sub_id); html = String(html); init_url = String(init_url)
    # The worker sends `asset_add` BEFORE the delegate reply (same socket, in order),
    # so the init bundle is normally already registered; this is just a safety net.
    if Base.timedwait(() -> haskey(eb.asset_host.parent.files, init_url), 10.0) !== :ok
        @warn "embed_remote_app: init asset not registered in time" init_url
    end
    # Supersede the previous mount of this app in this tab: close its worker sub.
    prev = swap_mount!(root, eb, String(app_id), sub_id)
    prev === nothing || prev == sub_id || close_remote_sub!(eb, prev)
    # The bridge runs uncompressed, so the proxied subsession does too.
    return RemoteWorkerApp(html, init_url, sub_id, eb.prefix, false)
end

# ── Chat integration: a live worker app as a chat tool bubble ────────────────
#
# A `bonito_app` ToolMsg in the chat renders its body lazily via
# `render_tool_body` → a `RemoteAppPlaceholder`, whose `jsrender` runs
# `embed_remote_app` against the live per-tab `Bonito.Session` (mounted by the
# existing `ToolRenderCommand` → `dom_in_js` path). Each placeholder carries
# the project's `EvalBridge` + the app id under which the worker registered the
# app on its `RemoteProxy` bridge (the ToolMsg only carries that id, like
# `bt_show` carries a path).
struct RemoteAppPlaceholder
    bridge::Union{Nothing, EvalBridge}   # nothing if eval session not connected yet
    app_id::String                       # registered with RemoteProxy.register_app! on the worker
end

# Each mount embeds a FRESH worker subsession (its own sub_id / init bundle), so
# repeated tool-body renders (auto-expand can fire more than once, and `dom_in_js`
# makes a new subsession each time) never collide on a shared id — the obsolete
# mounts self-clean when their DOM is removed (browser → `CloseSession` → worker).
# The bridge's expensive host wiring (frame relay, routing, asset registry) is
# attached once and shared, so a fresh mount is cheap.
function Bonito.jsrender(session::Bonito.Session, p::RemoteAppPlaceholder)
    p.bridge === nothing &&
        return Bonito.jsrender(session, Bonito.DOM.div("(live app unavailable — eval session not connected)"))
    return Bonito.jsrender(session, embed_remote_app(session, p.bridge, p.app_id))
end

# Build the placeholder for a `bonito_app` tool. `app_id` is the id the worker
# registered the app under on its RemoteProxy bridge (via `RemoteProxy.register_app!`,
# either through `bt_show_app` or `show_remote_app!`).
function remote_app_placeholder(tool_id::AbstractString, project_id::AbstractString, app_id::AbstractString)
    eb = get(EVAL_WORKERS, String(project_id), nothing)
    return RemoteAppPlaceholder(eb, String(app_id))
end

# `shown_app: <id>` reference left by the bt_show_app MCP tool, in tool content.
function find_app_reference(content)
    for c in content
        if c isa AgentClientProtocol.TextContent
            m = match(r"shown_app:\s*(\S+)", c.text)
            m === nothing || return String(m.captures[1])
        end
    end
    return nothing
end

"""
    show_remote_app!(model::ChatModel, eb::EvalBridge, code::AbstractString; title=...) -> id

Add a live interactive worker app to `model`'s chat as an auto-expanded tool
bubble. `code` is Julia source that evaluates to a `Bonito.App`; it's shipped to
the worker over a `register` control frame, `include_string`-d there, and
registered via `RemoteProxy.register_app!`. Each browser tab embeds its own
subsession of the bridge parent on expand. (The primary path is the `bt_show_app`
MCP tool, which registers over BonitoMCP's own Malt link; this is the
BonitoTeam-side convenience over the raw bridge.)
"""
function show_remote_app!(model::ChatModel, eb::EvalBridge, code::AbstractString; title::AbstractString="Interactive app")
    id = string(Bonito.uuid4())
    call_ctrl(eb, "register"; app = id, code = String(code))
    send!(model, ToolMsg(id, "bonito_app", String(title), "completed", "live app"))
    # auto-open the body (JS expands → ToolRenderCommand → render_tool_body)
    chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => id,
        "status" => "completed", "title" => title, "summary" => "live app", "expand" => true))
    return id
end

"""
    show_remote_app_for_project!(model, code; title=...) -> id

Like `show_remote_app!`, but uses the eval bridge that dialed back for this
model's project.
"""
function show_remote_app_for_project!(model::ChatModel, code::AbstractString; title::AbstractString="Interactive app")
    eb = get(EVAL_WORKERS, model.project_id, nothing)
    eb === nothing && error("show_remote_app: no eval bridge dialed back for project $(model.project_id)")
    return show_remote_app!(model, eb, code; title)
end
