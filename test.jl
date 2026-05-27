using AgentClientProtocol

cwd  = pwd()
text = "Reply with one word: pong"

println("env in julia: ANTHROPIC_API_KEY=", get(ENV, "ANTHROPIC_API_KEY", "(unset)"))

client = AgentClientProtocol.Client(cwd; on_update = upd -> begin
    if upd isa AgentMessageChunk && upd.content isa TextContent
        print(upd.content.text)
    elseif upd isa AgentThoughtChunk && upd.content isa TextContent
        print("\e[90m"); print(upd.content.text); print("\e[0m")
    end
end, mcp_servers = AgentClientProtocol.MCPServer[])

println("session: ", client.session_id)
result = AgentClientProtocol.prompt!(client, text)
println()
println("result: ", result)
AgentClientProtocol.close!(client)
