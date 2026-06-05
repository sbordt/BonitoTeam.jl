module RemoteProxy

# Worker-side bridge for proxying a Bonito.App's session through to the BonitoTeam
# server, which fronts the browser.
#
# This is the REMOTE driver for Bonito's transport-agnostic proxy framework (see
# Bonito/src/connection/proxy.jl + asset-serving/proxy.jl). The worker session is
# a stock `Bonito.ProxyConnection` whose driver — `BridgeDriver` here — relays the
# proxy verbs over ONE dial-back websocket, RAW (no Malt on this socket):
#   * `proxy_send`         → a Bonito frame, tagged `D` (worker → browser)
#   * `proxy_asset_add/remove` → an `asset_add`/`asset_remove` control frame (`C`)
# Inbound (browser→worker) `D` frames go straight onto `parent.inbox`, where
# Bonito's stock inbox-reader runs the normal decompress + unpack + dispatch.
#
# `C` (control) frames are the few request/response ops that aren't a plain Bonito
# frame: `delegate` an app (render a subsession, return its init bundle),
# `asset_read` (lazy range fetch), `register` (eval + register an app), `close` a
# subsession. The worker reuses Bonito's `render_subsession` / `get_messages!` /
# `ProxyAssetServer` — none of that is re-implemented here.
#
# Bootstrapping (include this module, build the bridge, start the dial) happens
# over BonitoMCP's OWN Malt link to its worker — Malt stays there, never on this
# socket / in the per-frame path.

import Bonito
using Bonito.HTTP.WebSockets: WebSockets

const TAG_DATA = UInt8('D')
const TAG_CTRL = UInt8('C')

# ── Worker-side proxy driver: relays Bonito's proxy verbs onto the dial-back ws ──
mutable struct BridgeDriver
    ws::Ref{Any}            # current dial-back websocket (set by serve_bridge); nothing ⇒ disconnected
    wlock::ReentrantLock    # serialize concurrent frame sends
end
BridgeDriver() = BridgeDriver(Ref{Any}(nothing), ReentrantLock())

function send_frame(d::BridgeDriver, tag::UInt8, payload::AbstractVector{UInt8})
    ws = d.ws[]
    ws === nothing && return nothing
    buf = Vector{UInt8}(undef, length(payload) + 1)
    @inbounds buf[1] = tag
    copyto!(buf, 2, payload, firstindex(payload), length(payload))
    lock(d.wlock) do
        try
            WebSockets.send(ws, buf)
        catch e
            # A send racing socket teardown/reconnect throws routinely; that's the
            # only expected failure. Log (don't swallow) so a real fault is visible.
            @debug "RemoteProxy: frame send failed (socket closing?)" exception = e
        end
    end
    return nothing
end
send_control(d::BridgeDriver, dict) = send_frame(d, TAG_CTRL, Bonito.MsgPack.pack(dict))

# Bonito proxy verbs (worker side). `proxy_send` ships a serialized Bonito frame;
# the asset verbs push the host the net 0→1 / 1→0 transitions as control frames.
Bonito.proxy_send(d::BridgeDriver, bytes) = send_frame(d, TAG_DATA, bytes)
Bonito.proxy_asset_add(d::BridgeDriver, key, mime, total, cached) =
    send_control(d, Dict("op" => "asset_add", "key" => key, "mime" => mime,
                         "total" => total, "cached" => cached))
Bonito.proxy_asset_remove(d::BridgeDriver, key) =
    send_control(d, Dict("op" => "asset_remove", "key" => key))

# ── The bridge: one long-lived proxied root session + an app route table ─────
mutable struct RemoteBridge
    parent::Bonito.Session
    driver::BridgeDriver
    routes::Bonito.Routes
end

const BRIDGE = Ref{Union{Nothing, RemoteBridge}}(nothing)

"""
    RemoteBridge(; compression=false)

Build the worker-side bridge: a long-lived proxied root `Session` (a stock
`Bonito.ProxyConnection` + `ProxyAssetServer` over a shared `BridgeDriver`).
Subsessions (one per embed) inherit the connection + asset_server + compression
through Bonito's normal parent/sub path; the driver relays every frame and asset
event down the dial-back socket.
"""
function RemoteBridge(; compression::Bool = false)
    prefix = string(Bonito.uuid4())
    driver = BridgeDriver()
    conn   = Bonito.ProxyConnection(prefix, driver)
    parent = Bonito.Session(conn; id = prefix,
                            asset_server = Bonito.ProxyAssetServer(driver),
                            compression_enabled = compression)
    # The parent never gets its own `JSDoneLoading` (it's not a page), but its
    # writes reach the browser through the host relay — mark it ready so
    # `close`ing a subsession can emit `free_session` through the bridge.
    isready(parent.connection_ready) || put!(parent.connection_ready, true)
    return RemoteBridge(parent, driver, Bonito.Routes())
end

"""
    ensure_bridge!(; compression=false) -> prefix::String

Create the one-and-only bridge for this worker process if absent; return its
namespace prefix. Bootstrapped over BonitoMCP's Malt link; the prefix is handed to
the dial handshake so the host knows the namespace before any frame flows.
"""
function ensure_bridge!(; compression::Bool = false)
    if BRIDGE[] === nothing
        BRIDGE[] = RemoteBridge(; compression)
        # Log every (re)build with the prefix — a rebuild discards prior
        # `register_app!` routes, which is otherwise invisible.
        @info "RemoteProxy: BRIDGE built" prefix = BRIDGE[].parent.id
    end
    return BRIDGE[].parent.id
end

"""
    dial_loop(wsurl, handshake; min_backoff=0.5, max_backoff=8.0)

Run the dial-and-serve loop until BRIDGE[] goes away. Each iteration opens a
fresh websocket to `wsurl`, sends the `handshake` line, and runs `serve_bridge`.
When the socket dies (clean EOF, network drop, host restart), we sleep with
exponential backoff and dial again — so a transient WS drop doesn't leave the
bridge silently disconnected. `BRIDGE[].routes` survives the drop, so
already-registered apps keep working on the new socket (the host recognises the
dial-back as a *reconnect* by `prefix` and swaps the WS rather than rebuilding).
"""
function dial_loop(wsurl::AbstractString, handshake::AbstractString;
                   min_backoff::Float64 = 0.5, max_backoff::Float64 = 8.0)
    backoff = min_backoff
    while BRIDGE[] !== nothing
        connected = false
        try
            Bonito.HTTP.WebSockets.open(wsurl) do ws
                Bonito.HTTP.WebSockets.send(ws, handshake)
                connected = true
                serve_bridge(ws)
            end
        catch e
            @warn "RemoteProxy: dial failed; will retry" wsurl backoff exception = e
        end
        # `connected` is the right signal — `serve_bridge` returning is normal
        # (peer EOF); never getting past `open` is a real failure → grow backoff.
        backoff = connected ? min_backoff : min(backoff * 2, max_backoff)
        sleep(backoff)
    end
    @info "RemoteProxy: dial loop exiting (BRIDGE cleared)"
    return
end

"""
    serve_bridge(ws)

Run the bridge's frame loop on the dial-back websocket `ws`. Points the driver at
the socket, then pumps inbound frames: `D` → `parent.inbox` (stock dispatch),
`C` → control. Clears the driver's socket on exit; does NOT tear the bridge down
(its lifetime is the worker's Julia session, not this socket).
"""
function serve_bridge(ws)
    b = BRIDGE[]
    b === nothing && error("RemoteProxy: bridge not built before serve_bridge")
    d = b.driver
    d.ws[] = ws
    try
        for msg in ws
            data = msg isa AbstractVector{UInt8} ? msg :
                   Vector{UInt8}(codeunits(String(msg)))
            isempty(data) && continue
            tag = @inbounds data[1]
            payload = Vector{UInt8}(@view data[2:end])
            if tag == TAG_DATA
                # Inbound Bonito frame → stock inbox dispatch (kept in order).
                isopen(b.parent.inbox) && put!(b.parent.inbox, payload)
            elseif tag == TAG_CTRL
                # Control can render (slow) or read assets — run it OFF the receive
                # loop so it never starves inbound frames; guard so one bad control
                # frame can't kill the bridge.
                @async try
                    handle_control(b, Bonito.MsgPack.unpack(payload))
                catch e
                    @warn "RemoteProxy: control frame failed" exception = (e, catch_backtrace())
                end
            end
        end
    catch e
        e isa WebSockets.WebSocketError || e isa EOFError || e isa Base.IOError ||
            @warn "RemoteProxy.serve_bridge loop ended" exception = (e, catch_backtrace())
    finally
        d.ws[] = nothing
    end
    return
end

# Control request/response (the only ops that aren't a plain frame).
#
# The request-shaped ops (`delegate`, `asset_read`, `register`) carry an `id` the
# host waits on. Any exception below MUST come back as a reply with an `err` field
# — otherwise the host's `call_ctrl` only learns about the failure after a 30s
# timeout, freezing the chat tool-render path. Notifications (`close`) carry no id.
function handle_control(b::RemoteBridge, msg::AbstractDict)
    op = msg["op"]
    d = b.driver
    id = get(msg, "id", nothing)
    try
        if op == "delegate"
            sub_id, html, init_url = render_embed(b, String(msg["app"]))
            send_control(d, Dict("op" => "reply", "id" => id,
                                 "val" => Any[sub_id, html, init_url]))
        elseif op == "asset_read"
            bytes = Bonito.read_proxy_asset(b.parent.asset_server.registry,
                        String(msg["key"]), Int(msg["start"]), Int(msg["stop"]))
            send_control(d, Dict("op" => "reply", "id" => id, "val" => bytes))
        elseif op == "register"
            app = Base.include_string(Main, String(msg["code"]))
            register_app!(String(msg["app"]), app)
            send_control(d, Dict("op" => "reply", "id" => id, "val" => String(msg["app"])))
        elseif op == "close"
            s = Bonito.get_session(b.parent, String(msg["sub"]))
            s === nothing || close(s)
        end
    catch e
        # Surface the failure to the host so its 30s timedwait turns into a fast,
        # informative error. Then rethrow so serve_bridge's @warn keeps the
        # worker-side stacktrace for diagnosis.
        if id !== nothing
            try
                send_control(d, Dict("op" => "reply", "id" => id,
                                     "err" => sprint(showerror, e)))
            catch
            end
        end
        rethrow()
    end
    return
end

# ── App registration + per-embed render ──────────────────────────────────────
register_app!(id::AbstractString, app::Bonito.App) =
    (Bonito.HTTPServer.route!(BRIDGE[], String(id) => app); nothing)

Bonito.HTTPServer.route!(b::RemoteBridge, p::Pair{String, <:Bonito.App}) =
    (b.routes[p.first] = p.second; nothing)

# Render a registered app into a FRESH subsession of the bridge parent and pack
# its init bundle. `render_subsession` = `sub = Session(parent); session_dom(sub,
# app)`; `init=false` keeps the bootstrap script out — the host calls
# `init_session` with the returned `init_url` bundle from the embed's `jsrender`.
function render_embed(b::RemoteBridge, app_id::AbstractString)
    app = b.routes.routes[String(app_id)]
    sub, dom = Bonito.render_subsession(b.parent, app; init = false)
    html     = sprint(io -> show(io, dom))
    msgs     = Bonito.get_messages!(sub)
    init_url = Bonito.url(sub, Bonito.BinaryAsset(sub, msgs))
    return sub.id, html, init_url
end

end # module RemoteProxy
