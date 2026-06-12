#!/usr/bin/env julia
# Standalone worker entry point for dev / env-driven setups. Outbound-only:
# dials the BonitoAgents server. The normal install path is `install.jl` →
# `BonitoWorker.install!` → `BonitoWorker.start()` (config from a Scratch
# space); this script is the env-var alternative for the monorepo dev loop.
#
#   julia --project=<path>/BonitoWorker worker_standalone.jl
#
# Env (all optional except SECRET + SERVER_URL):
#   BONITOAGENTS_WORKER_SECRET   shared secret (required)
#   BONITOAGENTS_SERVER_URL      e.g. http://server:8038 (required)
#   BONITOAGENTS_WORKER_NAME     display name (default: hostname; if hostname is
#                              "localhost" we fall back to "$USER-<short-id>"
#                              so two installs don't collide on the dashboard)
#   BONITOAGENTS_PROJECTS_ROOT   default: ~/bonitoagents-projects
#   CLAUDE_AGENT_ACP           path to claude-agent-acp; auto-detected via PATH
#
# The BonitoMCP launch command is derived automatically (`julia` + args against
# the active project) — no env var or wrapper script needed.

using BonitoWorker

const secret     = get(ENV, "BONITOAGENTS_WORKER_SECRET", "")
const server_url = get(ENV, "BONITOAGENTS_SERVER_URL", "")

isempty(secret)     && error("BONITOAGENTS_WORKER_SECRET must be set")
isempty(server_url) && error("BONITOAGENTS_SERVER_URL must be set")

const worker_id = BonitoWorker.load_or_generate_worker_id()
const default_name = BonitoWorker.default_worker_name(worker_id)

BonitoWorker.connect_and_serve(;
    server_url    = server_url,
    secret        = secret,
    worker_id     = worker_id,
    name          = get(ENV, "BONITOAGENTS_WORKER_NAME", default_name),
    projects_root = get(ENV, "BONITOAGENTS_PROJECTS_ROOT",
                        joinpath(homedir(), "bonitoagents-projects")),
)
