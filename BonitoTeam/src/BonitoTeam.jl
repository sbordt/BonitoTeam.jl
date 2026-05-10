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

include("state.jl")            # WorkerInfo, ProjectInfo, ServerState (single source of truth)
include("progress.jl")         # notify_progress / format_progress_string — shared by sync + import
include("worker_client.jl")    # probe(...), connect_worker(...) — needs ACP
include("transport.jl")        # ChatTransport + LocalTransport / WorkerTransport / MockTransport
include("styles.jl")
include("chat.jl")             # message types (UserMsg, AgentMsg, ...)
include("persistence.jl")
include("dashboard.jl")        # dashboard_app
include("sidebar.jl")          # project_sidebar + auto-generated icons
include("github.jl")           # "From GitHub" project template
include("server.jl")           # serve()

export serve

end # module BonitoTeam
