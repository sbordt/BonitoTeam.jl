# IO-like adapter that turns a frame-oriented transport (e.g. an
# HTTP.WebSocket) into a byte stream the librsync drive loop and our wire
# protocol can use directly. We present a byte-stream view by buffering the
# latest received frame and serving `read`/`readbytes!` requests out of it.
#
# We deliberately use the *parametric* type signature `WebSocketIO{WS}` so this
# module compiles without a hard dep on HTTP.jl. Callers construct via
# `WebSocketIO(ws)` where `ws` is anything implementing the small surface
# `send_frame!(ws, bytes)` / `recv_frame(ws)::Vector{UInt8}` / `is_closed(ws)`.
# The HTTP.WebSockets adapters live in ext/RemoteSyncHTTPExt.jl and are loaded
# automatically by Julia's package-extension mechanism when HTTP is present.

mutable struct WebSocketIO{WS} <: IO
    ws        :: WS
    inbuf     :: Vector{UInt8}        # bytes from the last received frame
    inpos     :: Int                  # next byte of inbuf to deliver (1-based)
    outbuf    :: IOBuffer             # accumulates writes until `flush`
    closed    :: Bool
    eof_seen  :: Bool                 # true once the peer has closed
end

WebSocketIO(ws) = WebSocketIO{typeof(ws)}(ws, UInt8[], 1, IOBuffer(), false, false)

# Receive the next frame. Returns `nothing` on close. Implementations
# specialise on `WS` — see ext/RemoteSyncHTTPExt.jl for HTTP.WebSocket.
function recv_frame end
function send_frame! end
function is_closed end

# ── IO interface ───────────────────────────────────────────────────────────
function _refill!(io::WebSocketIO)
    io.eof_seen && return false
    frame = recv_frame(io.ws)
    if frame === nothing
        io.eof_seen = true
        return false
    end
    io.inbuf = frame
    io.inpos = 1
    return true
end

function Base.eof(io::WebSocketIO)
    io.inpos <= length(io.inbuf) && return false
    return !_refill!(io)
end

Base.isopen(io::WebSocketIO) = !io.closed && !is_closed(io.ws)

function Base.close(io::WebSocketIO)
    io.closed && return
    io.closed = true
    try
        # `position` rather than `bytesavailable`: after a series of writes,
        # `bytesavailable(IOBuffer)` returns 0 (it counts unread bytes from
        # the current position, not the total writes pending).
        position(io.outbuf) > 0 && send_frame!(io.ws, take!(io.outbuf))
    catch
    end
    return nothing
end

function Base.read(io::WebSocketIO, ::Type{UInt8})
    while io.inpos > length(io.inbuf)
        _refill!(io) || throw(EOFError())
    end
    b = io.inbuf[io.inpos]
    io.inpos += 1
    return b
end

function Base.readbytes!(io::WebSocketIO, dst::Vector{UInt8}, n = length(dst))
    n = Int(n)
    n > length(dst) && resize!(dst, n)
    written = 0
    while written < n
        avail = length(io.inbuf) - io.inpos + 1
        if avail == 0
            _refill!(io) || break
            avail = length(io.inbuf) - io.inpos + 1
            avail == 0 && break
        end
        take = min(avail, n - written)
        @inbounds copyto!(dst, written + 1, io.inbuf, io.inpos, take)
        io.inpos += take
        written  += take
    end
    return written
end

# Read exactly `n` bytes or throw EOFError. Matches `Base.read(io, n)` shape
# used by our wire protocol's read_frame.
function Base.read(io::WebSocketIO, n::Integer)
    n = Int(n)
    out = Vector{UInt8}(undef, n)
    got = readbytes!(io, out, n)
    got == n || throw(EOFError())
    return out
end

# Buffered writes: librsync makes lots of small writes during signature/delta
# generation. We coalesce them into one WS frame per `flush`, which matches
# our wire protocol (write_frame ends with flush).
function Base.write(io::WebSocketIO, b::UInt8)
    write(io.outbuf, b)
    return 1
end

function Base.unsafe_write(io::WebSocketIO, p::Ptr{UInt8}, n::UInt)
    return UInt(unsafe_write(io.outbuf, p, n))
end

function Base.flush(io::WebSocketIO)
    # See note in `close` — must use `position`, not `bytesavailable`.
    position(io.outbuf) == 0 && return nothing
    send_frame!(io.ws, take!(io.outbuf))
    return nothing
end
