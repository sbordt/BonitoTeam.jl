module BonitoTeam

# Umbrella module. Submodules are independent and can be imported individually.
#
# BonitoTeam.MCP  — lean, self-contained; usable from BonitoTeam's own slim env
#                   (the bonitoteam-mcp binary uses --project=BonitoTeam)
#
# BonitoTeam.Worker — requires AgentClientProtocol + HTTP, so it is NOT included here.
#                     Load it from the root project via:
#                     include("<BonitoTeam>/src/Worker/Worker.jl")

include("MCP/MCP.jl")

end # module BonitoTeam
