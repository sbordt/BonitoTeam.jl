# JSON-RPC 2.0 connection over any transport.
# Transport is provided as three functions: send_line, read_line, on_close.
# A convenience constructor for Base.Process (subprocess) is provided for the common case.

mutable struct Connection
    send_line::Function     # (String) → Nothing — write one newline-terminated JSON line
    read_line::Function     # () → String — blocking; returns "" on clean EOF
    on_close::Function      # () → Nothing — release transport resources
    pending::Dict{Int,Channel{Any}}
    next_id::Int
    request_handler::Function   # agent→client requests; must return result or throw
    update_handler::Function    # session/update notifications (non-blocking)
    lock::ReentrantLock
    reader_task::Union{Task,Nothing}
    closed::Bool
end

# Generic transport constructor.
function Connection(send_line::Function, read_line::Function, on_close::Function;
                    request_handler::Function = warn_unhandled_request,
                    update_handler::Function  = identity)
    conn = Connection(send_line, read_line, on_close,
                      Dict{Int,Channel{Any}}(), 0,
                      request_handler, update_handler,
                      ReentrantLock(), nothing, false)
    conn.reader_task = @async reader_loop(conn)
    return conn
end

# Subprocess transport — keeps the existing call site in Client unchanged.
function Connection(proc::Base.Process;
                    request_handler::Function = warn_unhandled_request,
                    update_handler::Function  = identity)
    send_line = line -> (write(proc.in, line); flush(proc.in))
    read_line = ()   -> readline(proc.out; keep=false)
    on_close  = ()   -> (try close(proc.in) catch end; try close(proc) catch end)
    Connection(send_line, read_line, on_close; request_handler, update_handler)
end

function warn_unhandled_request(method::String, ::Any)
    @warn "ACP: unhandled agent request" method
    return nothing
end

# ── Writing ───────────────────────────────────────────────────────────────────

function send_raw(conn::Connection, msg::AbstractDict)
    line = JSON.json(msg) * "\n"
    lock(conn.lock) do
        conn.send_line(line)
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
            line = conn.read_line()
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
    conn.on_close()
end
