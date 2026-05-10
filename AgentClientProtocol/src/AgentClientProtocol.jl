module AgentClientProtocol

using JSON

include("types.jl")
include("connection.jl")
include("client.jl")

export Client, MCPServer, prompt!, cancel!, close!
export Transport, SubprocessTransport
export SessionUpdate, AgentMessageChunk, UserMessageChunk, AgentThoughtChunk
export ToolCallNotif, ToolCallUpdateNotif, PlanUpdate, UnknownUpdate
export TextContent, ImageContent, DiffContent, ToolCallLocation, PlanEntry
export parse_tool_content_item, parse_session_update, parse_location

# `send` and `recv` are the per-Transport verbs; intentionally NOT exported
# because they collide with Sockets.send / similar in user code. Callers
# overload them as `AgentClientProtocol.send(t::MyTransport, line) = ...`

end
