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
include("remote_app.jl")       # embed_remote_app — interactive worker Bonito apps in the browser
include("popup.jl")            # chat-global FloatingWindow for detaching bt_show_app
include("persistence.jl")
include("dashboard.jl")        # dashboard_app
include("worker_widget.jl")    # WorkerCard widget (stable per worker_id, used by KeyedList)
include("session_widget.jl")   # SessionRow widget (one row per discovered Claude Code session)
include("project_widget.jl")   # ProjectCard widget (stable per project_id, used by KeyedList)
include("sidebar.jl")          # project_sidebar + auto-generated icons
include("github.jl")           # "From GitHub" project template
include("server.jl")           # serve()
include("dev.jl")              # dev_server() — self-contained dev rig

export serve, dev_server

end # module BonitoTeam
