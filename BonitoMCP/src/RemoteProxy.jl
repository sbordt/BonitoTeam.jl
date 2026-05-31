module RemoteProxy

# Worker-side bridge for proxying a Bonito.App's session through to the BonitoTeam
# server, which fronts the browser.
#
# Transport: the worker dials the server over ONE websocket and pipes the Bonito
# protocol over it RAW — no Malt on this socket. Each WS frame is `[tag][payload]`:
#   * `D` (data)    — a Bonito frame. Inbound (browser→worker) frames go straight
#                     onto `parent.inbox`, where Bonito's stock inbox-reader runs
#                     the normal decompress+unpack+dispatch. Outbound frames are
#                     whatever `parent.connection.write` produces, sent verbatim.
#   * `C` (control) — a tiny msgpack dict for the handful of request/response ops
#                     that genuinely need it: `delegate` an app (render a subsession,
#                     return its init bundle), `asset_read` (lazy range fetch), and
#                     `close` a subsession. Asset register/release events are pushed
#                     as `asset_add`/`asset_remove` control frames.
#
# Bootstrapping (include this module, build the bridge, start the dial) happens
# over BonitoMCP's OWN Malt link to its worker — Malt stays there, never on this
# socket / in the per-frame path.

import Bonito
using Bonito.HTTP.WebSockets: WebSockets

const TAG_DATA = UInt8('D')
const TAG_CTRL = UInt8('C')

# ── Worker-side connection: a Bonito websocket connection whose frames ride the
#    dial-back socket directly. ───────────────────────────────────────────────
mutable struct BridgeConnection <: Bonito.AbstractWebsocketConnection
    prefix::String              # `id_prefix` namespace for this bridge
    ws::Ref{Any}                # the dial-back websocket, set by `serve_bridge`
    wlock::ReentrantLock        # serialize concurrent frame sends
    open::Threads.Atomic{Bool}
    session::Union{Nothing, Bonito.Session}
end
BridgeConnection(prefix::AbstractString) =
    BridgeConnection(String(prefix), Ref{Any}(nothing), ReentrantLock(),
                     Threads.Atomic{Bool}(true), nothing)

Bonito.id_prefix(c::BridgeConnection) = c.prefix
Base.isopen(c::BridgeConnection) =
    c.open[] && c.ws[] !== nothing && !WebSockets.isclosed(c.ws[])

function send_frame(c::BridgeConnection, tag::UInt8, payload::AbstractVector{UInt8})
    ws = c.ws[]
    ws === nothing && return nothing
    buf = Vector{UInt8}(undef, length(payload) + 1)
    @inbounds buf[1] = tag
    copyto!(buf, 2, payload, firstindex(payload), length(payload))
    lock(c.wlock) do
        try; WebSockets.send(ws, buf); catch; end
    end
    return nothing
end

# Bonito calls this to ship a serialized frame to the "browser" — here, raw down
# the dial-back socket. No Malt, no channel, no per-frame serialization tax.
Base.write(c::BridgeConnection, bytes::AbstractVector{UInt8}) =
    (c.open[] && send_frame(c, TAG_DATA, bytes); nothing)

send_control(c::BridgeConnection, dict) =
    send_frame(c, TAG_CTRL, Bonito.MsgPack.pack(dict))

function Base.close(c::BridgeConnection)
    c.open[] = false
    ws = c.ws[]
    ws === nothing || try; close(ws); catch; end
    return nothing
end

# No browser-side JS to emit (the browser talks to the host, which bridges); just
# capture the session backref. The inbox-reader Bonito spawned at `Session(conn)`
# drains `parent.inbox`, which `serve_bridge` feeds.
Bonito.setup_connection(s::Bonito.Session{BridgeConnection}) =
    (s.connection.session = s; nothing)

# ── The bridge: one long-lived root session + an app route table per worker ──
mutable struct RemoteBridge
    parent::Bonito.Session
    routes::Bonito.Routes
end

const BRIDGE = Ref{Union{Nothing, RemoteBridge}}(nothing)

"""
    RemoteBridge(; compression=false)

Build the worker-side bridge: a long-lived root `Session` whose connection writes
frames down the dial-back socket and whose inbox is fed by `serve_bridge`, with a
shared `ProxyAssetServer` whose register/release events are pushed to the host as
`asset_add`/`asset_remove` control frames. Subsessions (one per embed) inherit the
connection + asset_server + compression through Bonito's normal parent/sub path.
"""
function RemoteBridge(; compression::Bool = false)
    prefix = string(Bonito.uuid4())
    conn = BridgeConnection(prefix)
    assets = Bonito.ProxyAssetServer(
        (key, mime, total, cached) -> send_control(conn,
            Dict("op" => "asset_add", "key" => key, "mime" => mime,
                 "total" => total, "cached" => cached)),
        key -> send_control(conn, Dict("op" => "asset_remove", "key" => key)))
    # Mirror `render_proxied`: the session id IS the connection's namespace prefix,
    # so the host's `route_to_remote` and the browser's id-cache agree.
    parent = Bonito.Session(conn; id = prefix, asset_server = assets,
                            compression_enabled = compression)
    Bonito.setup_connection(parent)
    # The parent never gets its own `JSDoneLoading` (it's not a page), but its
    # writes reach the browser through the host relay — mark it ready so
    # `close_subsession` can emit `free_session` through the bridge on teardown.
    isready(parent.connection_ready) || put!(parent.connection_ready, true)
    return RemoteBridge(parent, Bonito.Routes())
end

"""
    ensure_bridge!(; compression=false) -> prefix::String

Create the one-and-only bridge for this worker process if absent; return its
namespace prefix. Bootstrapped over BonitoMCP's Malt link; the prefix is handed to
the dial handshake so the host knows the namespace before any frame flows.
"""
function ensure_bridge!(; compression::Bool = false)
    BRIDGE[] === nothing && (BRIDGE[] = RemoteBridge(; compression))
    return BRIDGE[].parent.id
end

"""
    serve_bridge(ws)

Run the bridge's frame loop on the dial-back websocket `ws` (called by the worker
right after it dials, over BonitoMCP's Malt link). Sets the connection's socket,
then pumps inbound frames: `D` → `parent.inbox` (stock dispatch), `C` → control.
"""
function serve_bridge(ws)
    b = BRIDGE[]
    b === nothing && error("RemoteProxy: bridge not built before serve_bridge")
    c = b.parent.connection
    c.ws[] = ws
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
        c.ws[] = nothing
    end
    return
end

# Control request/response (the only ops that aren't a plain frame).
function handle_control(b::RemoteBridge, msg::AbstractDict)
    op = msg["op"]
    c = b.parent.connection
    if op == "delegate"
        sub_id, html, init_url = render_embed(b, String(msg["app"]))
        send_control(c, Dict("op" => "reply", "id" => msg["id"],
                             "val" => Any[sub_id, html, init_url]))
    elseif op == "asset_read"
        bytes = Bonito.read_proxy_asset(b.parent.asset_server.registry,
                    String(msg["key"]), Int(msg["start"]), Int(msg["stop"]))
        send_control(c, Dict("op" => "reply", "id" => msg["id"], "val" => bytes))
    elseif op == "register"
        app = Base.include_string(Main, String(msg["code"]))
        register_app!(String(msg["app"]), app)
        send_control(c, Dict("op" => "reply", "id" => msg["id"], "val" => String(msg["app"])))
    elseif op == "close"
        s = Bonito.get_session(b.parent, String(msg["sub"]))
        s === nothing || close(s)
    end
    return
end

# ── App registration + per-embed render (unchanged in spirit) ───────────────
register_app!(id::AbstractString, app::Bonito.App) =
    (Bonito.HTTPServer.route!(BRIDGE[], String(id) => app); nothing)

Bonito.HTTPServer.route!(b::RemoteBridge, p::Pair{String, <:Bonito.App}) =
    (b.routes[p.first] = p.second; nothing)

# Render a registered app into a FRESH subsession of the bridge parent and pack its
# init bundle. `render_subsession` is `sub = Session(parent); session_dom(sub, app)`;
# `init=false` keeps the bootstrap script out — the host calls `init_session` with
# the returned `init_url` bundle from the embed's `jsrender`.
function render_embed(b::RemoteBridge, app_id::AbstractString)
    app = b.routes.routes[String(app_id)]
    sub, dom = Bonito.render_subsession(b.parent, app; init = false)
    html     = sprint(io -> show(io, dom))
    msgs     = Bonito.get_messages!(sub)
    init_url = Bonito.url(sub, Bonito.BinaryAsset(sub, msgs))
    return sub.id, html, init_url
end

end # module RemoteProxy
