module MCP

# Standalone Julia stdio MCP server for Claude Code and other MCP clients.
#
# Protocol: Model Context Protocol 2025-06-18 over stdio with JSON-RPC 2.0.
# Spec mirror: docs/external/mcp-spec-*.md
#
# Run:
#   julia --project=BonitoTeam -e 'using BonitoTeam; BonitoTeam.MCP.run_stdio()'
# or via the wrapper script:
#   BonitoTeam/bin/bonitoteam-mcp

using JSON

const PROTOCOL_VERSION = "2025-06-18"
const SERVER_NAME = "BonitoTeam.MCP"
const SERVER_VERSION = "0.1.0"

# Tool registry: every tool registers itself at module-init time via register!
struct Tool
    name::String
    description::String
    input_schema::Dict{String,Any}
    handler::Function          # (args::Dict)::Dict (CallToolResult shape)
end

const TOOLS = Tool[]

function register!(name::AbstractString, description::AbstractString,
                   input_schema::AbstractDict, handler)
    push!(TOOLS, Tool(String(name), String(description),
                      Dict{String,Any}(input_schema), handler))
    return nothing
end

include("server.jl")
include("output_discipline.jl")
include("tools/eval.jl")

end # module MCP
