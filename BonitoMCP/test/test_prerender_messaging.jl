# Verify that the prerender → delegate → JSDoneLoading-flush flow doesn't drop
# messages, USING ONLY BONITO'S OWN MECHANISMS (queue + `init_session` flushing
# on `on_connection_ready`). No WGLMakie — we synthesize the exact pattern an
# async-init plot creates: a message emitted AFTER `prerender_app` drained the
# initial queue, but BEFORE the browser's `JSDoneLoading` opens the sub.
#
# The assertion: a Bonito frame (TAG_DATA) emitted AFTER prerender's drain
# does NOT hit the wire until the browser's JSDoneLoading flips the sub to
# OPEN. Asset-registration control frames (TAG_CTRL "asset_add") ARE allowed
# to flow earlier — they go through the asset server, not the session's
# message queue, and don't depend on connection_ready.

using Test
using Bonito
import BonitoMCP

mutable struct CaptureWS
    out::Vector{Vector{UInt8}}
end
Bonito.HTTP.WebSockets.send(c::CaptureWS, bytes::AbstractVector{UInt8}) =
    (push!(c.out, Vector{UInt8}(bytes)); nothing)

# Count writes by tag. TAG_DATA = 'D' = session frames. TAG_CTRL = 'C' = bridge
# control (asset_add/asset_remove). Only TAG_DATA writes are gated by the
# session's connection_ready / message_queue.
data_writes(c::CaptureWS) = count(b -> !isempty(b) && b[1] == UInt8('D'), c.out)
ctrl_writes(c::CaptureWS) = count(b -> !isempty(b) && b[1] == UInt8('C'), c.out)

@testset "prerender → late session-frame waits for JSDoneLoading, then flushes" begin
    include(joinpath(@__DIR__, "..", "src", "RemoteProxy.jl"))
    Main.RemoteProxy.BRIDGE[] = nothing
    Main.RemoteProxy.ensure_bridge!()
    b = Main.RemoteProxy.BRIDGE[]

    cap = CaptureWS(Vector{UInt8}[])
    b.driver.ws[] = cap

    app = Bonito.App() do session
        Bonito.onjs(session, Bonito.Observable(0), Bonito.js"(v)=>{}")
        Bonito.DOM.div("hello")
    end
    app_id = "test-late-" * string(rand(UInt32))
    Main.RemoteProxy.register_app!(app_id, app)

    # Prerender drains the initial queue into the cached bundle. The cached
    # bundle is shipped via BinaryAsset → control-frame asset_add (NOT a
    # session frame). Side effect: ctrl_writes may go up, data_writes does not.
    Main.RemoteProxy.prerender_app(app_id)
    @test haskey(Main.RemoteProxy.PRERENDERED, app_id)

    cached_sub_id, _, _ = Main.RemoteProxy.PRERENDERED[app_id]
    sub = get(b.parent.children, cached_sub_id, nothing)
    @test sub !== nothing
    @test sub.status === Bonito.RENDERED
    @test !isready(sub.connection_ready)
    data_writes_after_prerender = data_writes(cap)
    @test data_writes_after_prerender == 0   # NO session frames before browser opens sub

    # The first delegate pops the cache. Pure dict return — no transport writes.
    sub_id, html, init_url = Main.RemoteProxy.render_embed(b, app_id)
    @test sub_id == cached_sub_id
    @test data_writes(cap) == data_writes_after_prerender

    # The race window: emit a session frame AFTER prerender's drain but BEFORE
    # JSDoneLoading. Under the queue+flush contract this MUST queue, not write.
    Bonito.send(sub, Dict(:msg_type => Bonito.EvalJavascript,
                          :payload  => Bonito.js"window.LATE = true"))
    @test data_writes(cap) == data_writes_after_prerender   # still no session-frame writes
    @test length(sub.message_queue) >= 1                    # the late message is queued

    # Browser → JSDoneLoading → `sub.on_connection_ready(sub)` (= init_session).
    # NOW the queue flushes; late message reaches the wire as a TAG_DATA frame.
    sub.on_connection_ready(sub)

    @test isready(sub.connection_ready)
    @test sub.status === Bonito.OPEN
    @test isempty(sub.message_queue)
    @test data_writes(cap) > data_writes_after_prerender    # session frame(s) hit the wire
end
