#!/usr/bin/env julia
# BonitoTeam worker installer — cross-platform (Linux / macOS / Windows).
#
#   curl -fsSL {{SERVER_URL}}/install.jl | julia -
#
# Windows 10 1803+ ships curl.exe, so the same one-liner works everywhere.
# The server templates {{SERVER_URL}} / {{WORKER_SECRET}} into this file
# before serving it from the /install.jl route.
#
# What it does:
#   1. Verifies the Claude Code prerequisites are on PATH.
#   2. Installs BonitoWorker + BonitoMCP from the public repo into the
#      SHARED `@bonito-team` environment (Pkg url+subdir — no tar bundle,
#      no per-package source trees, cross-platform by construction).
#   3. Hands off to `BonitoWorker.install!` which records the config in a
#      Scratch space and starts the worker process.
#
# No OS service — it just launches the Julia worker process (per request).
import Pkg

const REPO   = "https://github.com/SimonDanisch/BonitoTeam.jl"
const REV    = "main"
const SERVER = "{{SERVER_URL}}"
const SECRET = "{{WORKER_SECRET}}"

# Guard against running the raw template (the `{{ }}` are intact only if this
# file wasn't fetched through the server's rendering route).
if startswith(SERVER, "{{") || startswith(SECRET, "{{")
    error("install.jl must be fetched from a running BonitoTeam server: " *
          "`curl -fsSL <server-url>/install.jl | julia -`")
end

println("==> BonitoTeam worker installer")
println("    server : ", SERVER)
println("    repo   : ", REPO, " @ ", REV)
println("    workdir: ", pwd())

# ── Prerequisites ────────────────────────────────────────────────────────────
# Claude Code itself is user-managed (install + `claude login` once). The
# installer only checks they're reachable. `Sys.which` honours PATHEXT on
# Windows, so a `claude.cmd` shim resolves the same as a Unix binary.
let missing = filter(b -> Sys.which(b) === nothing, ["npm", "claude", "claude-agent-acp"])
    if !isempty(missing)
        error("missing prerequisite(s) on PATH: $(join(missing, ", ")).\n" *
              "    Install Claude Code first:\n" *
              "      npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp\n" *
              "      claude login")
    end
end
println("    prereqs: npm, claude, claude-agent-acp ok")

# ── Shared @bonito-team environment ──────────────────────────────────────────
# RemoteSync is an unregistered package and a dependency of BonitoWorker.
# Pkg does NOT consult a dependency package's own `[sources]`, so we add
# RemoteSync explicitly (url+subdir) — that puts it in the env, and
# BonitoWorker's `[deps] RemoteSync` then resolves against it by UUID.
# All three come from the same repo/rev so they resolve as one set.
println("\n==> Installing into shared @bonito-team env")
Pkg.activate("bonito-team"; shared = true)
Pkg.add([
    Pkg.PackageSpec(url = REPO, subdir = "RemoteSync",   rev = REV),
    Pkg.PackageSpec(url = REPO, subdir = "BonitoWorker", rev = REV),
    Pkg.PackageSpec(url = REPO, subdir = "BonitoMCP",    rev = REV),
])
Pkg.precompile()

# ── Configure + launch ───────────────────────────────────────────────────────
import BonitoWorker
BonitoWorker.install!(; server_url    = SERVER,
                         secret        = SECRET,
                         projects_root = pwd())
