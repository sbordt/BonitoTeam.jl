# Claude Code on-disk internals

A reference for what Claude Code persists under `~/.claude/` (and adjacent
locations on macOS), and exactly which parts of it BonitoAgents.jl depends on.

## 1. Purpose & scope

Authoritative source for the bits BonitoAgents.jl reads:
`BonitoWorker/src/BonitoWorker.jl` § "Claude session scanner" (lines
606-745). Everything else in this doc is empirical, captured against Claude
Code **2.1.x** on **2026-05-27**. Layouts can and do change between Claude
Code releases — re-verify before relying on anything not marked ★
"load-bearing".

★ marks entries the BonitoAgents.jl codebase reads or writes today.

## 2. Top-level inventory

```
~/.claude.json                       ★ global config + per-project registry
~/.claude/
  projects/<encoded>/...             ★ session content (jsonl chats + subagents)
  history.jsonl                        global prompt log (every prompt ever typed)
  sessions/<pid>.json                  liveness records for running CLI processes
  tasks/<sid>/N.json                   TaskCreate/Update state per session
  file-history/<sid>/<hash>@v<n>       file snapshots powering Claude's undo
  shell-snapshots/snapshot-zsh-*.sh    zsh/bash function+alias snapshot per CLI start
  paste-cache/<hash>.txt               pasted-text cache (the `[Pasted text #N]` bodies)
  cache/                               changelog.md + my-closed-issues.json
  backups/                             rolling backups of ~/.claude.json
  plans/                               Claude Code's plan files (per-session)
  plugins/                             marketplaces + blocklist + installed plugins
  session-env/<sid>/                   per-session env vars (usually empty)
  debug/latest -> <uuid>.txt           debug log symlink
  settings.json                        global settings
  settings.local.json                  per-machine permissions / overrides
  mcp-needs-auth-cache.json            MCP servers needing OAuth re-auth
  .last-cleanup                        ISO-8601 timestamp of last housekeeping run
  telemetry/, downloads/               empty in practice on this install
```

## 3. ★ `~/.claude/projects/<encoded>/` — session content

The canonical place. Every byte of every chat Claude Code persists lives
here. Everything BonitoAgents scans comes from this tree.

### Encoded folder name

Claude Code derives the folder name from the cwd by replacing several
characters with `-`. **Observed mappings:**

```
character in cwd  →  character in encoded name
/                 →  -
.                 →  -
_                 →  -
(                 →  -
)                 →  -
```

The inverse is therefore ambiguous — `BonitoAgents-jl`, `BonitoAgents.jl`,
`BonitoAgents_jl` all encode to the same string. **Do not invert the folder
name.** Read `cwd` from the jsonl content instead (see below).

Worked examples:

```
/Users/sbordt/Nextcloud/BonitoAgents.jl
  → -Users-sbordt-Nextcloud-BonitoAgents-jl

/Users/sbordt/Nextcloud/post-train-hallucinations-the-actual-repo/experiment_2_controlled_bigraphical_data
  → -Users-sbordt-Nextcloud-post-train-hallucinations-the-actual-repo-experiment-2-controlled-bigraphical-data
```

### Top-level `<sid>.jsonl`

UTF-8 JSON-Lines. `<sid>` is the session UUIDv4. One JSON object per line;
no trailing comma; line order is event order.

Observed line types:

```jsonl
{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"..."}
{"type":"isSnapshotUpdate","messageId":"...","snapshot":{...}}
{"cwd":"/Users/.../proj","entrypoint":"...","gitBranch":"...","isSidechain":false,"message":{...},"parentUuid":"...","promptId":"...","sessionId":"...","timestamp":"...","type":"user","userType":"external","uuid":"...","version":"..."}
```

**Load-bearing fields — `cwd` + first user message.** On top-level
session jsonls `cwd` typically appears from line 3 onward (the first
cwd-bearing record is the first user/assistant turn). The first
`{"type":"user","message":{"role":"user","content":…}}` record on the
same scan provides the dashboard's preview text (truncated to ~120
chars). Both are recovered by `scan_jsonl_metadata` in one pass.

### `<sid>/subagents/<agent-id>.jsonl`

Per-subagent log. `<agent-id>` looks like `agent-a56e94ef589608347` (hex
suffix, not a UUID). Same JSONL schema as the top-level, with `cwd` already
on line 1.

Sibling file `<agent-id>.meta.json`:

```json
{"agentType": "Explore"}
```

`agentType` strings observed: `"Explore"`. Others almost certainly exist in
the wild.

### Coexistence

A given session UUID gets both `<sid>.jsonl` AND a directory `<sid>/`
alongside it. The jsonl holds the top-level conversation; the directory
holds `subagents/...` (and may hold future per-session artifacts).

### `memory/`

Directory of `*.md` files — Claude Code's per-project user-memory store
(see `auto memory` section of the Claude Code system prompt). Never
contains `.jsonl`; `find_jsonls` explicitly skips it.

## 4. ★ `~/.claude.json` — global config + project registry

A single JSON file, ~70 KB on this install. The interesting parts:

### `projects` (dict, key = absolute path, unencoded)

Per-path metadata recorded by Claude Code on every CLI invocation in that
directory. **Includes paths that have no `~/.claude/projects/<encoded>/`
folder** — i.e. dirs you ran Claude in but where no jsonl was ever written
(or it was later cleaned). Fields observed:

| Field | Type | Notes |
|---|---|---|
| `lastSessionId` | str (UUID) | session_id of the last session |
| `lastSessionFirstPrompt` | str | first prompt text (truncated) |
| `lastSessionModified` | int (Unix ms) | last activity time |
| `lastCost` | float (USD) | cost of last session |
| `lastTotalInputTokens`, `lastTotalOutputTokens` | int | token usage |
| `lastTotalCacheCreationInputTokens`, `lastTotalCacheReadInputTokens` | int | prompt-cache token usage |
| `lastModelUsage` | dict | model → tokens |
| `lastSessionMetrics` | dict | timing + rate stats |
| `lastLinesAdded`, `lastLinesRemoved` | int | code-change stats |
| `lastDuration`, `lastAPIDuration`, `lastAPIDurationWithoutRetries`, `lastToolDuration` | int (ms) | timings |
| `lastFpsAverage`, `lastFpsLow1Pct` | float | UI render fps |
| `lastGracefulShutdown` | bool | clean exit? |
| `mcpServers` | dict | per-project MCP server config |
| `mcpContextUris` | list | MCP context resources |
| `allowedTools` | list | per-project tool allowlist |
| `enabledMcpjsonServers`, `disabledMcpjsonServers` | list | MCP toggles |
| `hasTrustDialogAccepted` | bool | onboarding state |
| `hasCompletedProjectOnboarding` | bool | onboarding state |
| `hasClaudeMdExternalIncludesApproved`, `hasClaudeMdExternalIncludesWarningShown` | bool | CLAUDE.md @-include consent |
| `projectOnboardingSeenCount` | int | onboarding nudge counter |
| `exampleFiles`, `exampleFilesGeneratedAt` | list, int | suggested-files cache |

### Other top-level keys

- **`oauthAccount`** — `accountUuid`, `emailAddress`, `organizationUuid`,
  `displayName`, billing/seat tier, `claudeCodeTrial*`.
- **`githubRepoPaths`** — dict `"owner/name" → [local-path, ...]`. Useful
  if you want to map a GitHub URL to where the user has it cloned.
- **`userID`** — opaque (sha256-ish) per-user identifier.
- **`firstStartTime`, `numStartups`, `installMethod`** — install
  telemetry; on this Mac `installMethod = "native"`.
- **`hasCompletedOnboarding`, `migrationVersion`** — onboarding state.
- **`cachedExperimentFeatures`, `cachedGrowthBookFeatures`,
  `clientDataCache`** — feature gating caches.
- A long tail of `seen…Count`, `dismissed…`, `hasShown…Notice` flags.

## 5. `~/.claude/history.jsonl` — global prompt history

One JSONL line per **prompt the user has ever typed** into Claude Code,
across every project. 2033 lines on this install (660 KB). Schema:

```json
{
  "display": "consider the file Klausurergebnisse_…",
  "pastedContents": {},
  "timestamp": 1771332957326,
  "project": "/Users/sbordt/Nextcloud/moe-scaling",
  "sessionId": "2e460ea0-2a1c-4b02-922c-741b448899dd"
}
```

`project` is the **cwd** at prompt time (unencoded); `sessionId` is the
session UUID. Assistant turns are NOT recorded here — only the user's input.

### Three-tier session recoverability

For a given path the user has run Claude in:

1. **Full content** — `~/.claude/projects/<encoded>/*.jsonl` exists →
   every assistant turn, tool call, thinking block is recoverable.
2. **Prompts only** — path appears in `history.jsonl` but its encoded
   folder is missing/empty → user prompts recoverable, assistant turns lost.
3. **Metadata only** — path is in `~/.claude.json[projects]` but not in
   `history.jsonl` either → `lastSessionFirstPrompt`, cost, tokens, but
   no per-prompt history.

BonitoAgents.jl today only surfaces tier 1.

## 6. Other `~/.claude/` subdirectories (informational)

- **`sessions/<pid>.json`** — liveness record per *currently running*
  Claude CLI process. Fields: `pid`, `sessionId`, `cwd`, `startedAt`
  (Unix ms), `version`, `kind` (`"interactive"`), `entrypoint` (`"cli"`).
  Deleted when the process exits. Useful for "which Claude CLI is running
  here right now" without OS-specific process inspection.
- **`tasks/<sid>/<n>.json`** — TaskCreate/TaskUpdate state per session.
  Schema: `id`, `subject`, `description`, `activeForm`, `status`,
  `blocks`, `blockedBy`. Plus `.lock` (empty mutex file) and
  `.highwatermark` (next free task id). Could be surfaced as "this
  session has N pending tasks" if useful.
- **`file-history/<sid>/<hash>@v<n>`** — snapshots of every file Claude
  has edited, per session, versioned. Hash is the content hash; `v1` is
  the pre-edit state, `v2` after the first edit, etc. Powers Claude
  Code's undo feature.
- **`shell-snapshots/snapshot-zsh-<unix-ns>-<short>.sh`** — exported
  zsh/bash functions + aliases captured at CLI startup; sourced by
  Claude's Bash tool to preserve the user's shell environment.
- **`paste-cache/<hash>.txt`** — content of `[Pasted text #N]` placeholders
  in user prompts; hashed filename, plain text body.
- **`cache/`** — `changelog.md` (running release notes Claude fetches),
  `my-closed-issues.json` (issue tracker cache).
- **`backups/.claude.json.backup.<unix-ms>`** — rolling backups of
  `~/.claude.json` (5 on this Mac, ~68 KB each).
- **`plugins/`** — `blocklist.json` (Anthropic-published plugin blocklist),
  `known_marketplaces.json` (registered marketplaces),
  `marketplaces/<name>/...` (installed marketplace content).
- **`settings.json` / `settings.local.json`** — global and per-user/per-
  machine config. `settings.local.json` typically holds the user's
  per-tool permission allowlist (e.g. `Bash(curl:*)`).
- **`mcp-needs-auth-cache.json`** — `{ server_name → { timestamp, id } }`
  marking MCP servers awaiting OAuth re-auth.
- **`.last-cleanup`** — ISO-8601 timestamp; marker that Claude housekeeping
  ran. Empty file otherwise.
- **`session-env/<sid>/`** — usually empty; presumably per-session env
  var spill.
- **`debug/latest`** — symlink to `<uuid>.txt`; Claude's debug log.
- **`telemetry/`, `downloads/`** — empty on this install. Reserved.

## 7. ★ BonitoAgents.jl consumption map

The contract between the worker (producer) and the server (consumer).
**This section is the audit surface for future refactors** — if you change
any line cited here, re-read the rest.

### Worker side — what we read from disk

| What we read | Code site | What we extract |
|---|---|---|
| `~/.claude/projects/<encoded>/` recursively | `BonitoWorker/src/BonitoWorker.jl` `find_jsonls` | every `*.jsonl` (skips `memory/`, no symlinks) |
| `<jsonl>` first ≤100 lines | `BonitoWorker.jl` `scan_jsonl_metadata` | first record with non-empty `"cwd"`; first `{"type":"user","message":{"role":"user","content":…}}` text → `first_prompt` preview |
| `<jsonl>` filename + mtime | `BonitoWorker.jl` `entry_from_jsonl` | `session_id` (basename minus `.jsonl`) + `last_used` (mtime) |
| `<sid>/subagents/<agent-id>.meta.json` | `BonitoWorker.jl` `entry_from_jsonl` | `agentType` → `agent_type` |
| `~/.claude/sessions/<pid>.json` | `BonitoWorker.jl` `load_sessions_pid_map` | `sessionId → pid` map (then `process_running` confirms liveness for `running` / `pid` fields) |

`CWD_LINE_LIMIT = 100` (`BonitoWorker.jl:622`). One corrupt line in a
jsonl is skipped (try/catch around `JSON.parse`), but the file is still
walked up to the cap.

### The contract dict

What the worker emits per `.jsonl` (one entry, even for subagents):

```julia
Dict(
  "path"              => String           # absolute cwd from jsonl
  "name"              => String           # basename(path)
  "session_id"        => String           # UUID for sessions; agent-<hex> for subagents
  "last_used"         => Float64          # mtime of the jsonl (Unix seconds)
  "kind"              => "session" | "subagent"
  "agent_type"        => nothing | String # subagents only
  "parent_session_id" => nothing | String # subagents only; UUID dir name
  "running"           => true | false | nothing  # OS confirms PID alive
  "pid"               => nothing | Int    # set only when running === true
  "first_prompt"      => nothing | String # truncated first user-message text
)
```

### Server / UI side — consumers of the dict

| Code site | What it does |
|---|---|
| `BonitoAgents/src/session_widget.jl:16-30` | `SessionRow(c, r)` reads `path`, `session_id`, `last_used`, `agent_type`; renders the row. `Resume` if `session_id` present, else `Import`. |
| `BonitoAgents/src/worker_widget.jl:220-235` | Splits the result list into `active` vs `historical` keyed lists; row_key = `path|session_id`. |
| `BonitoAgents/src/dashboard.jl:1956-1968` | Import handler extracts `path` + `session_id` from the JS click payload; passes them to `add_project(...; resume_session_id=…)`. |
| `BonitoAgents/src/state.jl:64,304,327-328,419-421` | `ProjectInfo.resume_session_id` is persisted into `projects.json` so the resume link survives server restarts. |
| `BonitoAgents/src/transport.jl:62,205-220` | `WorkerTransport.start_session` branches: if `resume_session_id !== nothing`, ACP `session/load`; else ACP `session/new`. |
| `BonitoAgents/src/persistence.jl:5,109,120,128-143` | Chat.md TOML frontmatter stores `session_id` so resuming a chat re-issues `session/load` with the same id. |

### Protocol frames

WS `/worker-ws`:

```json
{"type":"scan_sessions_result","request_id":"…","sessions":[ {…contract dict…}, … ]}
```

Produced by `BonitoWorker.jl:748-765` (`handle_scan_sessions`), consumed by
`BonitoAgents/src/worker_client.jl:171`.

ACP (worker ↔ `claude-agent-acp`):

```json
{"method":"session/load","params":{"sessionId":"…","cwd":"…","mcpServers":[…]}}
{"method":"session/new", "params":{                        "cwd":"…","mcpServers":[…]}}
```

`session/load` deserializes from `~/.claude/projects/<encoded>/<sessionId>.jsonl`
— so the worker's "Resume" path is end-to-end identified by that filename's
basename.

## 8. Tests

- **`BonitoWorker/test/runtests.jl:104-167`** — `scan_claude_sessions`
  scenarios: empty home, two fake encoded projects, mtime sort, required
  keys, no duplicates.
- **Known stale tests** (out of scope of this doc):
  - Lines 54-102 still test `decode_project_path` and `reconstruct_path`,
    which were deleted in the cwd-from-jsonl refactor.
  - The fake jsonls written by the test (`"{}\n"`) have no `cwd`, so the
    new `extract_cwd` returns `nothing` and the test expects 2 entries
    but will get 0.

  Both need to be fixed in a follow-up: drop the deleted-symbol tests, and
  write fake jsonls whose first line is `{"cwd":"<path>"}`.

## 9. Quick recipe — three-tier project discovery

If/when we ever want to surface every dir the user has run Claude in
(not just those with full session history), the three sources are:

```julia
# Tier 1: full content — current scan
scan_claude_sessions()  # reads ~/.claude/projects/

# Tier 2: prompts only — global history
[parse(JSON, line) for line in eachline("~/.claude/history.jsonl")]
# group by `project` and `sessionId`

# Tier 3: metadata only — global config registry
JSON.parsefile("~/.claude.json")["projects"]
# keys() are absolute paths; values have lastSessionId / lastSessionFirstPrompt etc.
```

Merge by absolute path; deduplicate; let tier 1 win where present.
