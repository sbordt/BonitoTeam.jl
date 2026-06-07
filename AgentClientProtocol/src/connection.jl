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

# Raised on any pending `send_request` when the underlying `Connection`
# tears down (transport EOF, peer hang-up, explicit `close(conn)`). The
# typed form lets callers dispatch on `e isa ConnectionClosed` instead of
# parsing `showerror` output.
struct ConnectionClosed <: Exception
    reason::String
end
ConnectionClosed() = ConnectionClosed("")
Base.showerror(io::IO, e::ConnectionClosed) =
    print(io, "ACP connection closed",
              isempty(e.reason) ? "" : ": $(e.reason)")

# Channel buffer for a turn's update stream and for each message's own stream.
# Generous enough that the dispatcher rarely blocks; backpressure still applies
# past it (a slow consumer eventually backpressures the agent over TCP).
const BUF = 256

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
# A `Handler` owns the agent→client RPC verb:
#
#   on_request(h::Handler, method::String, params)   - agent→client RPCs (must
#                                                       return the JSON-serializable
#                                                       result or throw)
#
# Session updates are NOT handled here — they belong to a prompt turn and are
# delivered as a `Channel{SessionUpdate}` from `prompt_updates` (see below), so
# the consumer gets them as a bounded, ordered stream rather than via callback.
#
# Why dispatch instead of a `::Function` field on `Connection`:
#   - The handler's identity shows up in stack traces / `methods(...)` / `@which`;
#     closures stored on the struct are anonymous.
#   - New handlers don't touch `Connection`; they're a new struct + a method.
abstract type Handler end

# Default: warn on agent→client RPCs.
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

    # Optional wire tap: called as `on_frame(dir::Symbol, msg::AbstractDict)`
    # with dir ∈ (:in, :out) for every ACP JSON-RPC frame that crosses the
    # connection — and ONLY those (internal events never pass through here).
    # `nothing` = disabled. A throwing tap never breaks the connection
    # (see `notify_frame`).
    on_frame::Union{Function,Nothing}

    # The currently-active prompt turn. `prompt_updates` sets these; the
    # dispatcher feeds `session/update` notifications into `active_updates`
    # and closes it when the matching `session/prompt` response (id ==
    # `active_id`) arrives. `nothing` between turns. Only one prompt is in
    # flight per session, so a single slot suffices.
    active_updates::Union{Channel{SessionUpdate},Nothing}
    active_id::Union{Int,Nothing}

    # Single inbox for EVERY inbound frame (notifications, requests,
    # responses). `reader_loop` parses each WS line into a raw JSON-RPC
    # Dict and `put!`s it here; a SINGLE dispatcher task drains and
    # routes by message kind. The key property this gives us:
    #
    #   When a response (e.g. `session/prompt`'s end_turn) is delivered
    #   to its pending channel, EVERY earlier frame in WS order has
    #   already been processed by the same dispatcher.
    #
    # That makes "prompt! returned" a sufficient signal for "every
    # session/update for this turn has been applied" — no external
    # drain barrier needed.
    #
    # Properties:
    #
    #   1. STRICT FIFO ORDER end-to-end. reader_loop parses serially,
    #      put!s serially, dispatcher pops serially.
    #   2. BACKPRESSURE. Bound (1024) is generous for any realistic
    #      agent rate. A slow handler blocks the reader → WS buffer
    #      fills → TCP backpressures the agent. No unbounded memory.
    #   3. CLEAN SHUTDOWN. `Base.close(conn)` closes the transport;
    #      reader_loop sees EOF and closes the inbox; dispatcher drains
    #      whatever remains, then its `finally` unblocks any pending
    #      RPCs with `ConnectionClosed`.
    #
    # Agent→client REQUESTS still spawn `@async` per request (inside
    # `dispatch_message`) — those are independent and can be slow (file
    # I/O, terminal); we don't want them blocking the chunk stream
    # behind them on the dispatcher.
    inbox::Channel{Any}

    lock::ReentrantLock
    reader_task::Union{Task,Nothing}
    dispatcher_task::Union{Task,Nothing}
    closed::Bool

    # Set true by `cancel!` for the active turn. The `prompt!` consumer then
    # fast-discards remaining buffered `session/update`s instead of coalescing +
    # rendering them, so a token backlog can't keep the dispatcher from reaching
    # the `cancelled` response (strict-FIFO head-of-line). Reset to false when
    # the next turn starts (`request_updates`). Atomic for cross-task visibility
    # (set on the cancel task, read in the consumer loop).
    @atomic cancelling::Bool
    # `time()` of the FIRST cancel for the active turn (0.0 if none). Lets the
    # chat layer tell a deliberate re-cancel ("force it, it's wedged") from an
    # impatient double-click — only the former, after the agent's had a real
    # chance, escalates to a force-close. Reset to 0.0 at each turn start.
    @atomic cancel_at::Float64
end

function Connection(transport::Transport, handler::Handler = DiscardHandler();
                    on_frame::Union{Function,Nothing} = nothing)
    conn = Connection(transport,
                      Dict{Int,Channel{Any}}(), 0,
                      handler,
                      on_frame,
                      nothing, nothing,          # active_updates, active_id
                      Channel{Any}(1024),
                      ReentrantLock(), nothing, nothing, false,
                      false,                     # cancelling
                      0.0)                       # cancel_at
    conn.dispatcher_task = @async dispatcher_loop(conn)
    conn.reader_task     = @async reader_loop(conn)
    return conn
end

# Convenience: `Connection(proc::Base.Process)` still works for the local
# subprocess case — wraps `proc` in a SubprocessTransport.
Connection(proc::Base.Process, handler::Handler = DiscardHandler();
           on_frame::Union{Function,Nothing} = nothing) =
    Connection(SubprocessTransport(proc), handler; on_frame)

# Feed one frame to the wire tap. Isolated so a throwing tap can never take
# down the reader loop or fail a send — the tap is observability, not flow.
function notify_frame(conn::Connection, dir::Symbol, msg::AbstractDict)
    conn.on_frame === nothing && return nothing
    try
        conn.on_frame(dir, msg)
    catch e
        @warn "ACP frame tap failed" exception=e maxlog=3
    end
    return nothing
end

# Single consumer of the inbox. Drains every inbound frame in wire order
# and routes by kind via `dispatch_message`. Per-frame exceptions are
# caught + logged so one bad frame can't kill the loop. When the inbox
# closes (transport EOF / explicit `close`), the `for` finishes draining
# and the `finally` unblocks any pending RPCs that never got a response.
function dispatcher_loop(conn::Connection)
    try
        for msg in conn.inbox
            try
                dispatch_message(conn, msg)
            catch e
                @warn "ACP dispatch failed" exception=e
            end
        end
    finally
        # Teardown: close any in-flight turn stream so its parse loop ends,
        # then unblock every pending RPC (including the turn's response) with
        # ConnectionClosed so `prompt!` surfaces a dead session.
        conn.active_updates === nothing || close(conn.active_updates)
        conn.active_updates = nothing
        conn.active_id = nothing
        for (_, ch) in conn.pending
            put!(ch, ConnectionClosed())
        end
        empty!(conn.pending)
    end
end

# ── Writing ───────────────────────────────────────────────────────────────────

function send_raw(conn::Connection, msg::AbstractDict)
    # Tap outside `conn.lock` — the tap (e.g. a file logger) does its own
    # locking and must not serialize against wire writes.
    notify_frame(conn, :out, msg)
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

# Begin a request that streams `session/update` notifications back while it runs.
# Both `session/prompt` (live turn) and `session/load` (the agent re-streams the
# resumed session's history) do this. Returns `(updates, response)`:
#   * `updates`  - a Channel{SessionUpdate} carrying this request's session/update
#                  notifications in wire order, CLOSED when the request's response
#                  arrives or the connection tears down.
#   * `response` - a one-shot channel that receives the result (or a
#                  ConnectionClosed on teardown), so the caller can detect a
#                  dead session after draining `updates`.
# Only one such request may be in flight per connection at a time — true here:
# bring-up's `session/load` completes before the prompt consumer is started.
function request_updates(conn::Connection, method::String, params)
    @atomic conn.cancelling = false   # fresh turn renders normally
    @atomic conn.cancel_at  = 0.0     # fresh turn: no cancel recorded yet
    id = lock(conn.lock) do
        i = conn.next_id; conn.next_id += 1; i
    end
    response = Channel{Any}(1)
    updates  = Channel{SessionUpdate}(BUF)
    conn.pending[id]     = response
    conn.active_updates  = updates
    conn.active_id       = id
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id,
                        "method" => method, "params" => params))
    return updates, response
end

# A `session/prompt` turn — the original entry point, unchanged for callers.
prompt_updates(conn::Connection, params) = request_updates(conn, "session/prompt", params)

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
        # Agent→client request — must respond. Spawn off-task so a slow
        # handler (file I/O, terminal RPCs) doesn't hold up the chunk
        # stream behind it on the dispatcher.
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
            # Belongs to the active request that streams (session/prompt or
            # session/load); deliver to its stream. If none is active (the agent
            # shouldn't stream otherwise), drop it.
            #
            # DROP the moment cancel is requested. This single dispatcher task
            # processes the inbox strictly in order, so if it BLOCKS here on
            # `put!` into a backed-up `active_updates` (slow browser / heavy token
            # or tool-call stream), it can never reach the `cancelled` response
            # sitting behind the backlog — the turn would look wedged for as long
            # as the browser takes to drain. Once cancel is requested we don't
            # render any more of this turn anyway (the consumer fast-discards),
            # so dropping here keeps the dispatcher free to reach the response
            # immediately, regardless of downstream speed.
            ch = conn.active_updates
            (ch === nothing || (@atomic conn.cancelling)) || put!(ch, update)
        end
        # Other notifications silently ignored.

    elseif has_id
        # Response to one of our outgoing requests. Because the dispatcher
        # processes the inbox strictly in order, delivering the response here
        # is also a synchronization point: every earlier frame in WS order
        # has already been dispatched.
        id = msg["id"]
        # The active prompt's response ends the turn: close its update stream
        # (its parse loop drains the buffer, then exits). The response itself
        # still flows to the pending channel below so `prompt!` can read the
        # stopReason / surface an rpc error.
        if id == conn.active_id
            conn.active_updates === nothing || close(conn.active_updates)
            conn.active_updates = nothing
            conn.active_id = nothing
        end
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
            local msg
            try
                msg = JSON.parse(line)
            catch e
                @warn "ACP: failed to parse line" exception=e line
                continue
            end
            notify_frame(conn, :in, msg)
            put!(conn.inbox, msg)
        end
    catch e
        # EOFError / IOError = subprocess or socket EOF; InvalidStateException =
        # a channel-based transport (MockTransport) closed under us. All three
        # are clean teardown signals, not failures.
        if !(e isa EOFError || e isa Base.IOError || e isa InvalidStateException)
            @warn "ACP reader failed" exception=e
        end
    finally
        # Closing the inbox lets the dispatcher's `for msg in inbox`
        # finish draining any in-flight messages, then its `finally`
        # cleans up pending RPCs with ConnectionClosed.
        close(conn.inbox)
    end
end

function Base.close(conn::Connection)
    conn.closed = true
    # Cascade: close(transport) → reader_loop's recv returns "" → loop
    # exits → reader_loop.finally closes inbox → dispatcher.for finishes
    # → dispatcher.finally drains pending RPCs. One call, full teardown.
    close(conn.transport)
    return nothing
end
