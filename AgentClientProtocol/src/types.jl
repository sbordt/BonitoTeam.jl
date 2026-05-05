# ACP protocol types, ported from agentclientprotocol/python-sdk schema.
# Schema ref: v0.11.2  (PROTOCOL_VERSION = 1)

# ── Content blocks ────────────────────────────────────────────────────────────

struct TextContent
    text::String
end

struct ImageContent
    data::String      # base64
    mime_type::String
end

const ContentBlock = Union{TextContent, ImageContent}

# ── Tool-call content ─────────────────────────────────────────────────────────

struct ToolCallLocation
    path::String
    line::Union{Int,Nothing}
end

struct DiffContent
    path::String
    old_text::Union{String,Nothing}
    new_text::String
end

# ── Session-update notifications (agent → client) ────────────────────────────
# Discriminated by "sessionUpdate" field.

abstract type SessionUpdate end

struct AgentMessageChunk <: SessionUpdate
    content::ContentBlock
end

struct UserMessageChunk <: SessionUpdate
    content::ContentBlock
end

struct AgentThoughtChunk <: SessionUpdate
    content::ContentBlock
end

struct PlanEntry
    content::String
    priority::String   # "high" | "medium" | "low"
    status::String     # "pending" | "in_progress" | "completed"
end

struct PlanUpdate <: SessionUpdate
    entries::Vector{PlanEntry}
end

struct ToolCallNotif <: SessionUpdate
    tool_call_id::String
    title::String
    kind::String       # "read" | "edit" | "delete" | "move" | "search" | "execute" | "think" | "fetch" | "other"
    status::String     # "pending" | "in_progress" | "completed" | "failed"
    content::Vector    # Vector of ContentBlock | DiffContent
    locations::Vector{ToolCallLocation}
    raw::AbstractDict  # untouched ACP update params (for round-trip persistence)
end

struct ToolCallUpdateNotif <: SessionUpdate
    tool_call_id::String
    title::Union{String,Nothing}
    kind::Union{String,Nothing}
    status::Union{String,Nothing}
    content::Vector
    locations::Vector{ToolCallLocation}
    raw::AbstractDict
end

struct UnknownUpdate <: SessionUpdate
    session_update::String
    raw::AbstractDict
end

# ── Parsing helpers ───────────────────────────────────────────────────────────

function parse_content_block(d::AbstractDict)::ContentBlock
    t = get(d, "type", "")
    if t == "image"
        return ImageContent(get(d, "data", ""), get(d, "mimeType", "image/png"))
    end
    # default: text
    return TextContent(get(d, "text", ""))
end

function parse_tool_content_item(d::AbstractDict)
    t = get(d, "type", "")
    if t == "diff"
        return DiffContent(get(d, "path", ""), get(d, "oldText", nothing), get(d, "newText", ""))
    elseif t == "content"
        return parse_content_block(get(d, "content", Dict()))
    else
        return TextContent("[tool content: $t]")
    end
end

function parse_location(d::AbstractDict)
    ToolCallLocation(get(d, "path", ""), get(d, "line", nothing))
end

function parse_session_update(params::AbstractDict)::SessionUpdate
    kind = get(params, "sessionUpdate", "")
    if kind == "agent_message_chunk"
        return AgentMessageChunk(parse_content_block(get(params, "content", Dict())))
    elseif kind == "user_message_chunk"
        return UserMessageChunk(parse_content_block(get(params, "content", Dict())))
    elseif kind == "agent_thought_chunk"
        return AgentThoughtChunk(parse_content_block(get(params, "content", Dict())))
    elseif kind == "plan"
        entries = [PlanEntry(get(e, "content", ""), get(e, "priority", "medium"), get(e, "status", "pending"))
                   for e in get(params, "entries", [])]
        return PlanUpdate(entries)
    elseif kind == "tool_call"
        content = [parse_tool_content_item(c) for c in get(params, "content", [])]
        locs = [parse_location(l) for l in get(params, "locations", [])]
        return ToolCallNotif(
            get(params, "toolCallId", ""),
            get(params, "title", ""),
            get(params, "kind", "other"),
            get(params, "status", "pending"),
            content, locs, params
        )
    elseif kind == "tool_call_update"
        content = [parse_tool_content_item(c) for c in get(params, "content", [])]
        locs = [parse_location(l) for l in get(params, "locations", [])]
        return ToolCallUpdateNotif(
            get(params, "toolCallId", ""),
            get(params, "title", nothing),
            get(params, "kind", nothing),
            get(params, "status", nothing),
            content, locs, params
        )
    else
        return UnknownUpdate(kind, params)
    end
end
