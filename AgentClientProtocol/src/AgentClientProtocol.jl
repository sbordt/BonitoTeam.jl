module AgentClientProtocol

using JSON

include("types.jl")
include("connection.jl")
include("client.jl")

export Client, MCPServer, prompt!, cancel!, close!
export SessionUpdate, AgentMessageChunk, UserMessageChunk, AgentThoughtChunk
export ToolCallNotif, ToolCallUpdateNotif, PlanUpdate, UnknownUpdate
export TextContent, ImageContent, DiffContent, ToolCallLocation, PlanEntry
export parse_tool_content_item, parse_session_update, parse_location

end
