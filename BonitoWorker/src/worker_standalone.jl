#!/usr/bin/env julia
# Standalone worker entry point. Outbound-only: dials the BonitoTeam server.
#
#   julia --project=<path>/BonitoWorker worker_standalone.jl
#
# Env (all optional except SECRET + SERVER_URL):
#   BONITOTEAM_WORKER_SECRET   shared secret (required)
#   BONITOTEAM_SERVER_URL      e.g. http://server:8038 (required)
#   BONITOTEAM_WORKER_NAME     display name (default: hostname)
#   BONITOTEAM_PROJECTS_ROOT   default: ~/bonitoteam-projects
#   BONITOTEAM_MCP_BIN         path to bonitoteam-mcp; reported to server for
#                              MCPServer config when spawning claude-agent-acp
#   CLAUDE_AGENT_ACP           path to claude-agent-acp; auto-detected via PATH

using BonitoWorker

const secret     = get(ENV, "BONITOTEAM_WORKER_SECRET", "")
const server_url = get(ENV, "BONITOTEAM_SERVER_URL", "")

isempty(secret)     && error("BONITOTEAM_WORKER_SECRET must be set")
isempty(server_url) && error("BONITOTEAM_SERVER_URL must be set")

BonitoWorker.connect_and_serve(;
    server_url    = server_url,
    secret        = secret,
    name          = get(ENV, "BONITOTEAM_WORKER_NAME", gethostname()),
    mcp_path      = get(ENV, "BONITOTEAM_MCP_BIN",
                        joinpath(get(ENV, "HOME", ""), ".local", "bin", "bonitoteam-mcp")),
    projects_root = get(ENV, "BONITOTEAM_PROJECTS_ROOT",
                        joinpath(get(ENV, "HOME", ""), "bonitoteam-projects")),
)
