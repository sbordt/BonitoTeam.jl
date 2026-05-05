module AgentClientProtocol

using JSON

include("types.jl")
include("connection.jl")
include("client.jl")

export Client, MCPServer, prompt!, cancel!, close!
export SessionUpdate, AgentMessageChunk, UserMessageChunk, AgentThoughtChunk
export ToolCallNotif, ToolCallUpdateNotif, PlanUpdate, UnknownUpdate
export TextContent, ImageContent, DiffContent, ToolCallLocation, PlanEntry

end
