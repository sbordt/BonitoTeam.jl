module RemoteSyncHTTPExt

# Methods that bridge HTTP.WebSockets.WebSocket to RemoteSync's IO adapter.
# Loaded automatically by Julia 1.9+ when both RemoteSync and HTTP are present.
# Defining the methods at module-load time (rather than via runtime `@eval`)
# avoids "method too new to be called from this world context" errors when
# tasks spawned earlier try to dispatch on the new methods.

using RemoteSync, HTTP, HTTP.WebSockets

function RemoteSync.recv_frame(ws::HTTP.WebSockets.WebSocket)
    try
        HTTP.WebSockets.isclosed(ws) && return nothing
        frame = HTTP.WebSockets.receive(ws)
        return frame isa AbstractVector{UInt8} ?
            Vector{UInt8}(frame) :
            Vector{UInt8}(codeunits(String(frame)))
    catch e
        e isa HTTP.WebSockets.WebSocketError && return nothing
        e isa Base.IOError              && return nothing
        e isa EOFError                  && return nothing
        rethrow()
    end
end

function RemoteSync.send_frame!(ws::HTTP.WebSockets.WebSocket,
                                  bytes::AbstractVector{UInt8})
    HTTP.WebSockets.send(ws, bytes)
    return nothing
end

RemoteSync.is_closed(ws::HTTP.WebSockets.WebSocket) =
    HTTP.WebSockets.isclosed(ws)

end # module
