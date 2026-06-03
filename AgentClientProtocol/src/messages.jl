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
"""
    ToolCall <: Message

Abstract family for one tool invocation in a turn. Concrete subtypes carry
tool-specific arguments (`BashCall.run_in_background`, `TodoWriteCall.entries`,
…) so consumers dispatch on the type instead of probing strings.

All variants share the five "header" fields the ACP wire defines (`id`,
`kind`, `title`, `status`, `content`) plus an `updates::Channel` that yields
the (mutated) call after each `tool_call_update`. New variants get added when
a tool's behavior diverges enough that an opaque arg dict isn't enough — for
everything else, `GenericTool` carries the raw input.
"""
abstract type ToolCall <: Message end

# Every concrete variant declares the same five header fields + `updates`,
# either via Composition (header struct field) or by direct duplication.
# Direct duplication wins on dispatch transparency: `tc.kind` and `tc.status`
# Just Work without `getproperty` overrides.

mutable struct GenericTool <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    name::String                       # actual tool name from `_meta.claudeCode.toolName`
    raw_input::Dict{String,Any}
end

mutable struct BashCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    command::String
    run_in_background::Bool
    description::Union{String,Nothing}
end

mutable struct TodoWriteCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    entries::Vector{PlanEntry}
end

mutable struct TaskCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    description::String
    prompt::String
    run_in_background::Bool
    task_name::Union{String,Nothing}
end

mutable struct MCPCall <: ToolCall
    id::String
    kind::String
    title::String
    status::String
    content::Vector{ToolContent}
    updates::Channel{ToolCall}
    server::String                     # "bonitoteam"
    tool_name::String                  # bare name without `mcp__server__` prefix
    raw_input::Dict{String,Any}
end

struct Plan <: Message
    entries::Vector{PlanEntry}
end

# A fresh streaming message, seeded with its first chunk.
AgentMessage(t::AbstractString) = AgentMessage(String(t), Channel{String}(BUF))
Thought(t::AbstractString)      = Thought(String(t), Channel{String}(BUF))
UserMessage(t::AbstractString)  = UserMessage(String(t), Channel{String}(BUF))

# Closing a message closes its own stream. The ToolCall arm is one method that
# covers every concrete variant (GenericTool / BashCall / TodoWriteCall / …)
# because they all share the `updates::Channel{ToolCall}` field.
Base.close(m::AgentMessage) = close(m.updates)
Base.close(m::Thought)      = close(m.updates)
Base.close(m::UserMessage)  = close(m.updates)
Base.close(m::ToolCall)     = close(m.updates)

# Appending a chunk feeds the message's stream.
Base.append!(m::AgentMessage, t::AbstractString) = (put!(m.updates, String(t)); m)
Base.append!(m::Thought, t::AbstractString)      = (put!(m.updates, String(t)); m)
Base.append!(m::UserMessage, t::AbstractString)  = (put!(m.updates, String(t)); m)

# Materialize a streaming message by draining its own stream into its fields,
# so the fully-assembled value can outlive the stream. Used for history replay,
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

# ── Wire → typed dispatch ────────────────────────────────────────────────────
# One place maps Claude Code's tool name to a concrete `ToolCall` subtype.
# After this, downstream code (BonitoTeam's `build_msg`, persistence, taskbar)
# dispatches on the subtype — no more `tool.kind == "execute" && ...` probes.
build_tool_call(n::ToolCallNotif) =
    build_tool_call(Val(Symbol(n.tool_name)), n)

# Bash (one-shot or background) — pull command + the run_in_background flag
# out of the raw input so consumers can route background bashes to the taskbar
# without re-probing the args dict.
function build_tool_call(::Val{:Bash}, n::ToolCallNotif)
    return BashCall(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
        String(get(n.raw_input, "command", "")),
        get(n.raw_input, "run_in_background", false) === true,
        _opt_str(get(n.raw_input, "description", nothing)),
    )
end

function build_tool_call(::Val{:TodoWrite}, n::ToolCallNotif)
    entries = PlanEntry[]
    raw_entries = get(n.raw_input, "todos", get(n.raw_input, "entries", []))
    if raw_entries isa AbstractVector
        for e in raw_entries
            e isa AbstractDict || continue
            push!(entries, PlanEntry(
                String(get(e, "content", "")),
                String(get(e, "priority", "medium")),
                String(get(e, "status", "pending"))))
        end
    end
    return TodoWriteCall(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
        entries,
    )
end

# Claude Code calls its subagent tool `Task` (legacy) and `Agent` (newer SDK).
# Both carry the same shape; we treat them identically.
for sdk_name in (:Task, :Agent)
    @eval function build_tool_call(::Val{$(QuoteNode(sdk_name))}, n::ToolCallNotif)
        return TaskCall(
            n.tool_call_id, n.kind, n.title, n.status,
            Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
            String(get(n.raw_input, "description", "")),
            String(get(n.raw_input, "prompt", "")),
            get(n.raw_input, "run_in_background", false) === true,
            _opt_str(get(n.raw_input, "name", nothing)),
        )
    end
end

# MCP tool names land here as `mcp__<server>__<tool>` (see the BonitoMCP
# routes registered as `bt_*`). Strip the prefix once at parse time so the
# message carries the bare name + server.
function build_tool_call(::Val{name}, n::ToolCallNotif) where {name}
    s = string(name)
    if startswith(s, "mcp__")
        rest = SubString(s, 6)               # drop "mcp__"
        sep = findfirst("__", String(rest))
        if sep !== nothing
            server = String(SubString(rest, 1, prevind(rest, first(sep))))
            tname  = String(SubString(rest, nextind(rest, last(sep))))
            return MCPCall(
                n.tool_call_id, n.kind, n.title, n.status,
                Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
                server, tname,
                n.raw_input,
            )
        end
    end
    return GenericTool(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
        s, n.raw_input,
    )
end

# Fallback when claude-agent-acp didn't fill the meta (`tool_name == ""`):
# we have no name to dispatch on, so the call lands as `GenericTool` with an
# empty name. UX will show the ACP `kind` + `title` like before.
function build_tool_call(::Val{Symbol("")}, n::ToolCallNotif)
    return GenericTool(
        n.tool_call_id, n.kind, n.title, n.status,
        Vector{ToolContent}(n.content), Channel{ToolCall}(BUF),
        "", n.raw_input,
    )
end

# Small helpers used by the builders above.
_opt_str(x) = x isa AbstractString && !isempty(x) ? String(x) : nothing

# Convenience for tests / fixtures that build a synthetic ToolCall without
# going through the wire-parse: drop the typed-args, pin name + raw_input
# to defaults. Production code never goes through here — the wire dispatcher
# does — but tests like to construct from positional fields and pass a fresh
# channel. `GenericTool` doubles as the fallback subtype, so existing test
# call sites mechanically port `ACP.ToolCall(...)` → `ACP.GenericTool(...)`.
GenericTool(id::AbstractString, kind::AbstractString, title::AbstractString,
            status::AbstractString, content::AbstractVector,
            updates::Channel = Channel{ToolCall}(BUF)) =
    GenericTool(String(id), String(kind), String(title), String(status),
                Vector{ToolContent}(content), updates,
                "", Dict{String,Any}())

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
    tc = build_tool_call(u)
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
