# BonitoTeam

Self-hosted multi-host orchestrator for agentic coding sessions. Architecture:
[../BonitoTeam-Design.md](../BonitoTeam-Design.md). Conventions:
[../CONVENTIONS.md](../CONVENTIONS.md). External SDK / MCP specs:
[../docs/external/](../docs/external/).

## Layout

```
BonitoTeam/
├── Project.toml                # Package deps
├── README.md                   # this file
├── bin/
│   └── bonitoteam-mcp          # standalone wrapper for Claude Code MCP config
├── src/
│   ├── BonitoTeam.jl           # umbrella module
│   └── MCP/                    # Julia stdio MCP server
│       ├── MCP.jl
│       ├── server.jl           # JSON-RPC 2.0 dispatch loop
│       ├── output_discipline.jl # truncation, image detect, summary
│       └── tools/
│           └── eval.jl         # julia_eval, julia_restart, julia_list_sessions
└── test/
    └── smoke_mcp.jl            # in-process + subprocess smoke tests
```

`Worker/` (thin claude-CLI adapter) and `Server/` (Bonito dashboard) come in
later milestones (see Design doc).

## First-time setup

```bash
cd /sim/Programmieren/ClaudeExperiments/BonitoTeam
julia --project=. -e 'import Pkg; Pkg.instantiate()'
```

This creates the Manifest.toml and downloads JSON.

## Use as standalone Julia MCP server (Claude Code)

After `Pkg.instantiate`, add this to Claude Code's MCP config (e.g. project-level
`.mcp.json` or user `~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "bonitoteam": {
      "command": "/sim/Programmieren/ClaudeExperiments/BonitoTeam/bin/bonitoteam-mcp"
    }
  }
}
```

Tools exposed (Milestone 2 set):

- `julia_eval(code, env_path?, full_output?, max_response_bytes?)` — persistent
  session per env_path; auto-truncates output, summarizes large containers,
  returns 2-D color-arrays as image blocks. See output_discipline.jl for rules.
- `julia_restart(env_path?)` — drop the persistent session for env_path
- `julia_list_sessions()` — list active per-env sessions

Coming in Milestone 2:
- `julia_doc`, `julia_methods`, `code_typed`, `code_warntype`, `macro_expand`
- `bonito_evaljs`, `bonito_screenshot`, `bonito_console_log`, `bonito_dom`
- `makie_screenshot`, `makie_inject_mouse`, `makie_inject_key`, `makie_scene_state`

## Running the smoke test

After instantiate:

```bash
julia --project=. test/smoke_mcp.jl
```

Or interactively from this project's root via julia_eval:

```julia
import Pkg; Pkg.activate("/sim/Programmieren/ClaudeExperiments")
include("/sim/Programmieren/ClaudeExperiments/BonitoTeam/src/MCP/MCP.jl")
# in-process tests work without instantiating BonitoTeam env
```

The 9 in-process tests in [test/smoke_mcp.jl](test/smoke_mcp.jl) cover:
initialize handshake, tools/list, simple eval, state persistence, stdout
capture, error handling, output truncation, full_output bypass, large-container
summarization. The subprocess test additionally drives the binary end-to-end
over real stdio.

## Output discipline (enforced server-side)

LLM-prompt rules like "always end with `nothing`" are unreliable. Instead, this
MCP server enforces output hygiene at the tool layer:

| Rule                                            | Behavior                                                             |
|-------------------------------------------------|----------------------------------------------------------------------|
| Total response > `max_response_bytes` (10 KB)   | Truncate with `[truncated: ...]` marker                              |
| Return value is `Matrix{<:Colorant}`, Figure, ..| Return as MCP `image` block (PNG, base64), not text repr             |
| Container with > 100 elements                   | Summarize: `Vector{Int} with 500 elements; first 10: [1, 2, ...]`    |
| `full_output=true` argument                     | Bypass all of the above                                              |

See [src/MCP/output_discipline.jl](src/MCP/output_discipline.jl).
