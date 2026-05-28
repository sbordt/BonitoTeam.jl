# Whole, ordered messages coalesced from the raw `session/update` soup.
#
# The dispatcher feeds one turn's `SessionUpdate`s into a channel; `prompt!`
# runs a bounded loop that turns them into clean `Message`s. A streaming
# message (agent text, thought, user echo) carries its OWN `updates` channel,
# closed at the message boundary, so the chat layer renders one bubble per
# message and drains that bubble's stream with `append!`. The wire-parse types
# (`AgentMessageChunk`, `ToolCallNotif`, …) never escape this file.

abstract type Message end

const ToolContent = Union{TextContent, DiffContent, ImageContent}

mutable struct AgentMessage <: Message
    text::String                 # seeded with the first chunk
    updates::Channel{String}     # later deltas; closed when the message ends
end
mutable struct Thought <: Message
    text::String
    updates::Channel{String}
end
mutable struct UserMessage <: Message
    text::String
    updates::Channel{String}
end
mutable struct ToolCall <: Message
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}   # yields `self` after each change; closed when terminal
end
struct Plan <: Message
    entries::Vector{PlanEntry}
end

# A fresh streaming message, seeded with its first chunk.
AgentMessage(t::AbstractString) = AgentMessage(String(t), Channel{String}(BUF))
Thought(t::AbstractString)      = Thought(String(t), Channel{String}(BUF))
UserMessage(t::AbstractString)  = UserMessage(String(t), Channel{String}(BUF))

# Closing a message closes its own stream.
Base.close(m::AgentMessage) = close(m.updates)
Base.close(m::Thought)      = close(m.updates)
Base.close(m::UserMessage)  = close(m.updates)
Base.close(m::ToolCall)     = close(m.updates)

# Appending a chunk feeds the message's stream.
Base.append!(m::AgentMessage, t::AbstractString) = (put!(m.updates, String(t)); m)
Base.append!(m::Thought, t::AbstractString)      = (put!(m.updates, String(t)); m)
Base.append!(m::UserMessage, t::AbstractString)  = (put!(m.updates, String(t)); m)

# Materialize a streaming message by draining its own stream into its fields, so
# the fully-assembled value can outlive the stream. Used for history replay,
# which has no live UI to stream into — we want the whole message at once. Must
# run concurrently with the producer (the stream closes at the next message
# boundary). Text messages accumulate `text`; a `ToolCall` is mutated in place
# by `parse_update!`, so draining just advances to its final state.
function drain_message!(m::Union{AgentMessage,Thought,UserMessage})
    for delta in m.updates
        m.text *= delta
    end
    return m
end
function drain_message!(m::ToolCall)
    for _ in m.updates
    end
    return m
end
drain_message!(m::Plan) = m

# ── Per-turn parser ─────────────────────────────────────────────────────────
# State local to a single prompt loop: the text message currently being
# streamed (if any) plus the set of tools still awaiting completion.
mutable struct TurnState
    current_message::Union{Message,Nothing}
    tools::Dict{String,ToolCall}
end
TurnState() = TurnState(nothing, Dict{String,ToolCall}())

# Closing the turn finishes the trailing message and any still-open tools.
function Base.close(st::TurnState)
    st.current_message === nothing || close(st.current_message)
    st.current_message = nothing
    foreach(close, values(st.tools))
    empty!(st.tools)
    return nothing
end

is_terminal(status::AbstractString) = status in ("completed", "failed")

text_of(u::AgentMessageChunk) = u.content isa TextContent ? u.content.text : nothing
text_of(u::AgentThoughtChunk) = u.content isa TextContent ? u.content.text : nothing
text_of(u::UserMessageChunk)  = u.content isa TextContent ? u.content.text : nothing

# Three thin arms — the only place the wire chunk types appear — pick which
# message kind a text delta belongs to; everything else is `append!`/`close`.
parse_update!(out, st, u::AgentMessageChunk) = text!(out, st, AgentMessage, text_of(u))
parse_update!(out, st, u::AgentThoughtChunk) = text!(out, st, Thought,      text_of(u))
parse_update!(out, st, u::UserMessageChunk)  = text!(out, st, UserMessage,  text_of(u))

function parse_update!(out, st, u::ToolCallNotif)
    st.current_message === nothing || (close(st.current_message); st.current_message = nothing)
    tc = ToolCall(u.tool_call_id, u.kind, u.title, u.status,
                  Vector{ToolContent}(u.content), Channel{ToolCall}(BUF))
    put!(out, tc)
    is_terminal(tc.status) ? close(tc) : (st.tools[tc.id] = tc)
    return nothing
end

function parse_update!(out, st, u::ToolCallUpdateNotif)   # routed by id; never touches the text bubble
    tc = get(st.tools, u.tool_call_id, nothing)
    tc === nothing && return nothing
    u.status !== nothing && (tc.status = u.status)
    u.title  !== nothing && (tc.title  = u.title)
    isempty(u.content) || (tc.content = Vector{ToolContent}(u.content))
    put!(tc.updates, tc)
    is_terminal(tc.status) && (close(tc); delete!(st.tools, tc.id))
    return nothing
end

function parse_update!(out, st, u::PlanUpdate)
    st.current_message === nothing || (close(st.current_message); st.current_message = nothing)
    put!(out, Plan(u.entries))
    return nothing
end

parse_update!(::Any, ::Any, ::SessionUpdate) = nothing   # UnknownUpdate: ignore, don't disturb the stream

# Extend the open message if it's the same kind; else finish it and open a new one.
function text!(out, st, ::Type{T}, text) where {T<:Message}
    text === nothing && return nothing               # non-text / empty replay thought
    if st.current_message isa T
        append!(st.current_message, text)
    else
        st.current_message === nothing || close(st.current_message)
        st.current_message = T(text)
        put!(out, st.current_message)                # delivered seeded with the first chunk
    end
    return nothing
end
