module BonitoMCP

# Standalone Julia stdio MCP server for Claude Code and other MCP clients.
#
# Protocol: Model Context Protocol 2025-06-18 over stdio with JSON-RPC 2.0.
# Spec mirror: docs/external/mcp-spec-*.md
#
# Run (this is exactly how the BonitoTeam worker launches it — a plain
# `julia` process with an argv array, no shell wrapper, cross-platform):
#   julia --project=@bonito-team -e 'using BonitoMCP; BonitoMCP.run_stdio()'

using JSON

const PROTOCOL_VERSION = "2025-06-18"
const SERVER_NAME = "BonitoMCP"
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
include("session.jl")          # JuliaSession + SessionManager (subprocess-per-env)
include("tools/eval.jl")
include("tools/show.jl")       # bt_show — rich MIME render, audience-tagged

end # module BonitoMCP
