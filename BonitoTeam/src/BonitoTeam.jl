module BonitoTeam

# Server-side dashboard package. Public API:
#
#   BonitoTeam.serve(; worker_secret, port=8038, public_url=nothing, ...)
#
# Glues together: Bonito UI + AgentClientProtocol + BonitoMCP (for the bundle
# endpoint) + BonitoWorker (the relay package the workers run).

using Bonito
using AgentClientProtocol
using HTTP
using JSON
using Markdown
using UUIDs
using Dates
using TOML
using Base64
using SHA

import BonitoBook       # MonacoEditor / DiffEditor / Collapsible for tool rendering
import BonitoMCP        # shipped to workers, also used by the bundle build
import BonitoWorker     # ditto

include("worker_client.jl")    # probe(...), connect_worker(...) — needs ACP
include("styles.jl")
include("chat.jl")             # message types (UserMsg, AgentMsg, ...)
include("persistence.jl")
include("dashboard.jl")        # WORKERS / PROJECTS state + dashboard_app
include("server.jl")           # serve()

export serve

end # module BonitoTeam
