# JSON-RPC 2.0 connection over any Transport.
#
# A `Transport` is the long-lived I/O channel underneath: a subprocess, a
# WebSocket, a pair of channels for tests. Each concrete transport
# overloads three verbs:
#
#   send(t::Transport, line::String)  - write one newline-terminated JSON line
#   recv(t::Transport)::String        - blocking; returns "" on clean EOF
#   Base.close(t::Transport)          - release transport resources (idempotent)
#
# `Connection` uses these via dispatch — no callbacks stored on the
# struct. Adding a new transport (e.g. SSH-piped subprocess) is just a
# new struct + three method definitions.

abstract type Transport end

# Default fallback for transports that don't need extra teardown.
Base.close(::Transport) = nothing

# Local subprocess transport — the original `Connection(::Base.Process)`
# path. Kept here because every consumer of ACP today goes through this
# shape; new transports live in their own packages.
struct SubprocessTransport <: Transport
    proc::Base.Process
end

send(t::SubprocessTransport, line::AbstractString) =
    (write(t.proc.in, line); flush(t.proc.in); nothing)

recv(t::SubprocessTransport) = readline(t.proc.out; keep = false)

# Idempotent + total: safe to call on a already-torn-down process.
# Closing stdin signals EOF to the agent so it exits cleanly; if it's
# still alive after that, we kill it. `isopen` / `process_running`
# guard against the throw conditions, so no try/catch is needed.
function Base.close(t::SubprocessTransport)
    isopen(t.proc.in) && close(t.proc.in)
    process_running(t.proc) && kill(t.proc)
    return nothing
end

# ── Handler protocol ──────────────────────────────────────────────────────────
#
# A `Handler` owns two dispatched verbs:
#
#   on_update(h::Handler, upd::SessionUpdate)        - session/update notifications
#   on_request(h::Handler, method::String, params)   - agent→client RPCs (must
#                                                       return the JSON-serializable
#                                                       result or throw)
#
# Why dispatch instead of `::Function` fields on `Connection`:
#   - The handler's identity shows up in stack traces / `methods(...)` /
#     `@which`; closures stored on the struct are anonymous.
#   - Subtypes can specialize per concrete update type (`on_update(::ChatHandler,
#     ::AgentMessageChunk)`), which is exactly the routing the chat layer wants
#     — no manual `if upd isa ...` chain.
#   - New handlers don't touch `Connection`; they're a new struct + a few
#     methods.
abstract type Handler end

# Defaults: ignore updates, warn on agent→client RPCs.
on_update(::Handler, ::Any) = nothing
on_request(::Handler, method::AbstractString, ::Any) = warn_unhandled_request(method)

function warn_unhandled_request(method)
    @warn "ACP: unhandled agent request" method
    return nothing
end

# The default handler. Used when callers don't care about either kind of
# message — e.g. one-shot scripts that drive `prompt!` and discard output.
struct DiscardHandler <: Handler end


mutable struct Connection
    transport::Transport
    pending::Dict{Int,Channel{Any}}
    next_id::Int
    handler::Handler

    # Inbox the reader_loop `put!`s incoming session/update notifications
    # into; a SINGLE dispatcher task drains it. The Channel is typed `Any`
    # (rather than `SessionUpdate`) so callers can also enqueue
    # `DrainBarrier` sentinels — see `drain_updates` below. The dispatcher
    # branches on the item type.
    #
    # Properties of this layout:
    #
    #   1. STRICT FIFO ORDER. Frames are parsed serially by reader_loop,
    #      queued serially into the channel, consumed serially by the
    #      dispatcher. There is no `@async`-per-update spawning, so no
    #      scheduler shuffle can reorder them.
    #   2. BACKPRESSURE. The bound (1024) is generous for any realistic
    #      agent rate (~50 chunks/sec ≈ 20s buffer). If a slow handler
    #      stalls, `put!` blocks the reader_loop → WS buffer fills → TCP
    #      backpressures the agent. No unbounded memory growth.
    #   3. ATOMIC HANDOFF AT CLOSE. `Base.close(conn)` closes the inbox,
    #      which terminates the dispatcher's `for item in inbox` loop
    #      cleanly once the queue drains.
    #   4. EXTERNAL SYNCHRONIZATION. `drain_updates(conn)` enqueues a
    #      barrier sentinel and blocks until the dispatcher pops it — by
    #      construction, every update queued before the call has been
    #      delivered to the handler. Used by the chat layer to gate
    #      "the turn is over" on "every chunk has been ingested".
    #
    # Agent→client REQUESTS still spawn `@async` per request (in
    # dispatch_message) — those are rare, independent, and need
    # concurrency to handle long-running fs/terminal RPCs without
    # blocking the update stream.
    update_inbox::Channel{Any}

    lock::ReentrantLock
    reader_task::Union{Task,Nothing}
    dispatcher_task::Union{Task,Nothing}
    closed::Bool
end

# Synchronization sentinel for `drain_updates`. Carries a `Base.Event` the
# dispatcher fires when it pops the barrier off the inbox FIFO.
struct DrainBarrier
    sig::Base.Event
end

function Connection(transport::Transport, handler::Handler = DiscardHandler())
    conn = Connection(transport,
                      Dict{Int,Channel{Any}}(), 0,
                      handler,
                      Channel{Any}(1024),
                      ReentrantLock(), nothing, nothing, false)
    conn.dispatcher_task = @async update_dispatcher_loop(conn)
    conn.reader_task     = @async reader_loop(conn)
    return conn
end

# Convenience: `Connection(proc::Base.Process)` still works for the local
# subprocess case — wraps `proc` in a SubprocessTransport.
Connection(proc::Base.Process, handler::Handler = DiscardHandler()) =
    Connection(SubprocessTransport(proc), handler)

# Single consumer of the update inbox. Runs for the connection's lifetime
# (one task per Connection). Handler exceptions are caught locally so one
# bad update doesn't kill the dispatcher and silently stall every later
# event.
function update_dispatcher_loop(conn::Connection)
    for item in conn.update_inbox
        if item isa DrainBarrier
            notify(item.sig)
        else
            try
                on_update(conn.handler, item)
            catch e
                @warn "ACP update handler error" exception=e
            end
        end
    end
end

"""
    drain_updates(conn::Connection)

Block until every `session/update` that has been put! on the inbox so
far has been delivered to `on_update`. The implementation enqueues a
`DrainBarrier` sentinel and waits for the dispatcher to pop it — since
the inbox is strict FIFO, popping the barrier is proof that every
earlier item has already been consumed.

Used by the chat layer to gate "the turn is over" on "every chunk has
been ingested" — without this, `PromptCompleted` can race the tail of
the chunk stream and finalize the wrong streaming state.

No-op on an already-closed Connection (the dispatcher is gone, there's
nothing left in flight).
"""
function drain_updates(conn::Connection)
    conn.closed && return nothing
    barrier = DrainBarrier(Base.Event())
    try
        put!(conn.update_inbox, barrier)
    catch e
        # Channel closed under us — dispatcher is gone, nothing to drain.
        e isa InvalidStateException && return nothing
        rethrow()
    end
    wait(barrier.sig)
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
                result = on_request(conn.handler, method, params)
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
            # Queue for the dispatcher task. FIFO + single consumer = wire
            # order is preserved end-to-end. `put!` blocks if the inbox is
            # full, which is the right backpressure path.
            put!(conn.update_inbox, update)
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

function Base.close(conn::Connection)
    conn.closed = true
    # Closing the inbox ends `update_dispatcher_loop`'s `for upd in inbox`
    # once the queue drains, without losing in-flight events. Idempotent:
    # closing an already-closed Channel is a no-op in Base.
    close(conn.update_inbox)
    close(conn.transport)
    return nothing
end
