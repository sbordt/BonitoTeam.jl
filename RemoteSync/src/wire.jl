# Length-prefixed framing on top of a single bidirectional IO. All multi-byte
# integers are little-endian. We never use Julia's stdlib Serialization because
# both ends might run different Julia versions and the format is fragile;
# instead each frame type has a hand-rolled, version-tolerant decoder.

# Frame layout: [tag::UInt8] [length::UInt32 LE] [payload::length bytes]
#
# Tags (one byte, free room to grow):
const TAG_MANIFEST = 0x01    # sender → receiver: list of source files
const TAG_PLAN     = 0x02    # receiver → sender: per-file action + signature
const TAG_DELTA    = 0x03    # sender → receiver: delta payload for one file
const TAG_DONE     = 0x04    # sender → receiver: end-of-stream
const TAG_OK       = 0x05    # receiver → sender: file applied OK
const TAG_PROGRESS = 0x06    # either direction: human-readable status string

# Action codes inside a Plan entry:
const ACTION_SKIP   = 0x00   # file matches, do nothing
const ACTION_FULL   = 0x01   # receiver has nothing — send literal contents
const ACTION_PATCH  = 0x02   # receiver sent a signature, send a delta against it
const ACTION_DELETE = 0x03   # receiver should delete this file

# ── Low-level frame IO ─────────────────────────────────────────────────────
function write_frame(io::IO, tag::UInt8, payload::AbstractVector{UInt8})
    length(payload) > typemax(UInt32) &&
        error("RemoteSync: frame payload too large ($(length(payload)) bytes)")
    write(io, tag)
    write(io, htol(UInt32(length(payload))))
    isempty(payload) || write(io, payload)
    flush(io)
    return nothing
end

write_frame(io::IO, tag::UInt8) = write_frame(io, tag, UInt8[])

# Returns (tag, payload). Throws EOFError on clean EOF mid-frame.
function read_frame(io::IO)
    tag = read(io, UInt8)
    len = ltoh(read(io, UInt32))
    payload = len == 0 ? UInt8[] : read(io, Int(len))
    length(payload) == Int(len) ||
        throw(EOFError())
    return (tag, payload)
end

# ── Manifest encoding ──────────────────────────────────────────────────────
# Manifest entries are (relpath, size, mtime). mtime is Float64 seconds since
# Unix epoch (matches stat().mtime).
struct ManifestEntry
    rel   :: String
    size  :: UInt64
    mtime :: Float64
end

function encode_manifest(entries::Vector{ManifestEntry})
    io = IOBuffer()
    write(io, htol(UInt32(length(entries))))
    for e in entries
        bytes = codeunits(e.rel)
        write(io, htol(UInt32(length(bytes))))
        write(io, bytes)
        write(io, htol(e.size))
        write(io, htol(reinterpret(UInt64, e.mtime)))
    end
    return take!(io)
end

function decode_manifest(payload::AbstractVector{UInt8})
    io = IOBuffer(payload)
    n = ltoh(read(io, UInt32))
    out = Vector{ManifestEntry}(undef, n)
    for i in 1:n
        rel_len = ltoh(read(io, UInt32))
        rel     = String(read(io, Int(rel_len)))
        size    = ltoh(read(io, UInt64))
        mtime   = reinterpret(Float64, ltoh(read(io, UInt64)))
        out[i]  = ManifestEntry(rel, size, mtime)
    end
    return out
end

# ── Plan encoding ──────────────────────────────────────────────────────────
# A Plan is the receiver's response: for each file in the manifest (and any
# extra deletes), what action does the sender need to take, and (for PATCH)
# the signature bytes the sender should compute the delta against.
struct PlanEntry
    rel    :: String
    action :: UInt8
    sig    :: Vector{UInt8}    # only populated when action == ACTION_PATCH
end

function encode_plan(entries::Vector{PlanEntry})
    io = IOBuffer()
    write(io, htol(UInt32(length(entries))))
    for e in entries
        bytes = codeunits(e.rel)
        write(io, htol(UInt32(length(bytes))))
        write(io, bytes)
        write(io, e.action)
        write(io, htol(UInt32(length(e.sig))))
        isempty(e.sig) || write(io, e.sig)
    end
    return take!(io)
end

function decode_plan(payload::AbstractVector{UInt8})
    io = IOBuffer(payload)
    n = ltoh(read(io, UInt32))
    out = Vector{PlanEntry}(undef, n)
    for i in 1:n
        rel_len = ltoh(read(io, UInt32))
        rel     = String(read(io, Int(rel_len)))
        action  = read(io, UInt8)
        sig_len = ltoh(read(io, UInt32))
        sig     = sig_len == 0 ? UInt8[] : read(io, Int(sig_len))
        out[i]  = PlanEntry(rel, action, sig)
    end
    return out
end

# ── Delta envelope ─────────────────────────────────────────────────────────
# DELTA frame = [rel_len::UInt32][rel bytes][delta bytes]. The frame's outer
# length tells us where the delta ends; the rel_len + rel give us the path.
function encode_delta_frame(rel::AbstractString, delta::AbstractVector{UInt8})
    io = IOBuffer()
    bytes = codeunits(rel)
    write(io, htol(UInt32(length(bytes))))
    write(io, bytes)
    write(io, delta)
    return take!(io)
end

function decode_delta_frame(payload::AbstractVector{UInt8})
    io = IOBuffer(payload)
    rel_len = ltoh(read(io, UInt32))
    rel     = String(read(io, Int(rel_len)))
    delta   = read(io)
    return (rel, delta)
end
