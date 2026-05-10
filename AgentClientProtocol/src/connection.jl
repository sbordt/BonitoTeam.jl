# JSON-RPC 2.0 connection over any Transport.
#
# A `Transport` is the long-lived I/O channel underneath: a subprocess, a
# WebSocket, a pair of channels for tests. Each concrete transport
# overloads three verbs:
#
#   send(t::Transport, line::String)  - write one newline-terminated JSON line
#   recv(t::Transport)::String        - blocking; returns "" on clean EOF
#   close!(t::Transport)              - release transport resources
#
# `Connection` uses these via dispatch — no callbacks stored on the
# struct. Adding a new transport (e.g. SSH-piped subprocess) is just a
# new struct + three method definitions.

abstract type Transport end

# Default fallback for transports that don't need extra teardown.
close!(::Transport) = nothing

# Local subprocess transport — the original `Connection(::Base.Process)`
# path. Kept here because every consumer of ACP today goes through this
# shape; new transports live in their own packages.
struct SubprocessTransport <: Transport
    proc::Base.Process
end

send(t::SubprocessTransport, line::AbstractString) =
    (write(t.proc.in, line); flush(t.proc.in); nothing)

recv(t::SubprocessTransport) = readline(t.proc.out; keep = false)

function close!(t::SubprocessTransport)
    try close(t.proc.in) catch end
    try close(t.proc)    catch end
    return nothing
end

mutable struct Connection
    transport::Transport
    pending::Dict{Int,Channel{Any}}
    next_id::Int
    request_handler::Function   # agent→client requests; must return result or throw
    update_handler::Function    # session/update notifications (non-blocking)
    lock::ReentrantLock
    reader_task::Union{Task,Nothing}
    closed::Bool
end

function Connection(transport::Transport;
                    request_handler::Function = warn_unhandled_request,
                    update_handler::Function  = identity)
    conn = Connection(transport,
                      Dict{Int,Channel{Any}}(), 0,
                      request_handler, update_handler,
                      ReentrantLock(), nothing, false)
    conn.reader_task = @async reader_loop(conn)
    return conn
end

# Convenience: `Connection(proc::Base.Process)` still works for the local
# subprocess case — wraps `proc` in a SubprocessTransport.
Connection(proc::Base.Process; kw...) =
    Connection(SubprocessTransport(proc); kw...)

function warn_unhandled_request(method::String, ::Any)
    @warn "ACP: unhandled agent request" method
    return nothing
end

# ── Writing ───────────────────────────────────────────────────────────────────

function send_raw(conn::Connection, msg::AbstractDict)
    line = JSON.json(msg) * "\n"
    lock(conn.lock) do
        send(conn.transport, line)
    end
end

function send_request(conn::Connection, method::String, params)::Any
    id = lock(conn.lock) do
        id = conn.next_id
        conn.next_id += 1
        id
    end
    ch = Channel{Any}(1)
    conn.pending[id] = ch
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    result = take!(ch)
    result isa Exception && throw(result)
    return result
end

function send_notification(conn::Connection, method::String, params)
    send_raw(conn, Dict("jsonrpc" => "2.0", "method" => method, "params" => params))
end

function send_response(conn::Connection, id, result)
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
end

function send_error_response(conn::Connection, id, code::Int, message::String)
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id,
                        "error" => Dict("code" => code, "message" => message)))
end

# ── Receiving ─────────────────────────────────────────────────────────────────

function dispatch_message(conn::Connection, msg::AbstractDict)
    method = get(msg, "method", nothing)
    has_id = haskey(msg, "id")

    if method !== nothing && has_id
        # Agent→client request; we must respond.
        id = msg["id"]
        params = get(msg, "params", nothing)
        @async begin
            try
                result = conn.request_handler(method, params)
                send_response(conn, id, result)
            catch e
                send_error_response(conn, id, -32603, string(e))
            end
        end

    elseif method !== nothing
        if method == "session/update"
            params = get(msg, "params", Dict{String,Any}())
            # ACP wraps the actual update object under "update" key
            update_obj = get(params, "update", params)
            update = parse_session_update(update_obj)
            @async try
                conn.update_handler(update)
            catch e
                @warn "ACP update handler error" exception=e
            end
        end
        # Other notifications silently ignored.

    elseif has_id
        # Response to one of our requests.
        id = msg["id"]
        ch = get(conn.pending, id, nothing)
        if ch !== nothing
            delete!(conn.pending, id)
            if haskey(msg, "error")
                put!(ch, ErrorException(get(msg["error"], "message", "rpc error")))
            else
                put!(ch, get(msg, "result", nothing))
            end
        end
    end
end

function reader_loop(conn::Connection)
    try
        while !conn.closed
            line = recv(conn.transport)
            isempty(line) && break
            try
                msg = JSON.parse(line)
                dispatch_message(conn, msg)
            catch e
                @warn "ACP: failed to parse line" exception=e line
            end
        end
    catch e
        if !(e isa EOFError || e isa Base.IOError)
            @warn "ACP reader failed" exception=e
        end
    finally
        for (_, ch) in conn.pending
            put!(ch, ErrorException("ACP connection closed"))
        end
        empty!(conn.pending)
    end
end

function close!(conn::Connection)
    conn.closed = true
    close!(conn.transport)
end
