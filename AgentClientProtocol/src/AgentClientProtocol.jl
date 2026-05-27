module AgentClientProtocol

using JSON
using Base64

include("types.jl")
include("connection.jl")
include("client.jl")

export Client, MCPServer, ImageAttachment, prompt!, cancel!
export Transport, SubprocessTransport
export Handler, DiscardHandler
export ConnectionClosed
export SessionUpdate, AgentMessageChunk, UserMessageChunk, AgentThoughtChunk
export ToolCallNotif, ToolCallUpdateNotif, PlanUpdate, UnknownUpdate
export TextContent, ImageContent, DiffContent, ToolCallLocation, PlanEntry
export parse_tool_content_item, parse_session_update, parse_location

# `send`, `recv`, `on_update`, `on_request` are dispatched verbs that callers
# overload on their concrete Transport / Handler types. Intentionally NOT
# exported — `send` would collide with `Sockets.send`, and the handler verbs
# are package-namespaced to avoid clashes with user code.

end
