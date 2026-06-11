module BonitoAgents

# Server-side dashboard package. Public API:
#
#   BonitoAgents.serve(; worker_secret, port=8038, public_url=nothing, ...)
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
# Used by `current_bonito_install_spec()` to parse `[sources]` out of the
# active project file so the install.jl template ships workers the exact
# Bonito url+rev the server is itself running. Stdlib — zero cost.
import Pkg

# CommonMark for the chat-message renderer. Used in `chat.jl :: markdown_html`
# (strict CommonMark fixes Julia's stdlib bug where `foo_bar_baz` italicizes
# everything between the intraword `_`s) AND in `persistence.jl` for the
# `+++` front-matter parse on chat.md. Hoisted here so the `const` parser in
# chat.jl can resolve at include time — chat.jl is included before persistence.jl.
import CommonMark as CM

import BonitoBook       # MonacoEditor / DiffEditor / Collapsible for tool rendering
import BonitoMCP        # shipped to workers, also used by the bundle build
import BonitoWorker     # ditto

include("state.jl")            # WorkerInfo, ProjectInfo, ServerState (single source of truth)
include("progress.jl")         # notify_progress / format_progress_string — shared by sync + import
include("worker_client.jl")    # probe(...), connect_worker(...) — needs ACP
include("transport.jl")        # ChatTransport + LocalTransport / WorkerTransport / MockTransport
include("styles.jl")
include("plotpane.jl")         # PlotPane handle (window-scoped; built by install_popup!)
include("taskbar.jl")          # TaskBar component (state-first pin-board)
include("chat.jl")             # message types (UserMsg, AgentMsg, ...)
include("remote_app.jl")       # embed_remote_app — interactive worker Bonito apps in the browser
include("floating_window.jl")  # draggable/resizable position:fixed panel — used by popup.jl
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

end # module BonitoAgents
