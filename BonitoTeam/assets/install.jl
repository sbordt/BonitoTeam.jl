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
# installer only checks they're reachable. npm and claude-agent-acp are
# installed by npm as `.cmd` shims on Windows; `Sys.which` only walks the
# raw name + .exe there, so we fall back to .cmd/.bat explicitly.
@static if Sys.iswindows()
    which_executable(name) = something(Sys.which(name),
                                       Sys.which(name * ".cmd"),
                                       Sys.which(name * ".bat"),
                                       Some(nothing))
else
    which_executable(name) = Sys.which(name)
end
let missing = filter(b -> which_executable(b) === nothing, ["node", "npm", "claude", "claude-agent-acp"])
    if !isempty(missing)
        error("missing prerequisite(s) on PATH: $(join(missing, ", ")).\n" *
              "    Install Node.js 20+ and Claude Code first:\n" *
              "      Node 22 LTS: https://nodejs.org/  (or `winget install OpenJS.NodeJS.LTS`)\n" *
              "      npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp\n" *
              "      claude login")
    end
end
# claude-agent-acp uses `import attributes` syntax which lands in Node 20.10+
# (or the Node 18.20 backport). On older Node the agent dies on first spawn
# with `SyntaxError: Unexpected token 'with'`, which surfaces in the dashboard
# as the opaque "ACP connection closed". Catch it here instead.
let ver = try
        strip(read(`$(which_executable("node")) --version`, String))  # e.g. "v18.17.1"
    catch; "" end
    m = match(r"^v(\d+)\.(\d+)", ver)
    if m === nothing
        error("could not determine node version (got: $(repr(ver)))")
    end
    major, minor = parse(Int, m.captures[1]), parse(Int, m.captures[2])
    too_old = major < 18 || (major == 18 && minor < 20)
    too_old && error("Node $ver is too old; claude-agent-acp needs Node 20+ " *
                     "(or 18.20+). Install Node 22 LTS:\n" *
                     "      https://nodejs.org/  (or `winget install OpenJS.NodeJS.LTS`)")
    println("    prereqs: node $(ver), npm, claude, claude-agent-acp ok")
end

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
