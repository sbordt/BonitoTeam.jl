# bonitoteam.js is now an ES6 module — see `ChatLib` further down. It's
# loaded lazily by the `Bonito.ES6Module(...).then(...)` interpolation
# inside ChatModel's jsrender, NOT injected as a classic <script> tag.
# Loading it as a classic script would syntax-error on the `export`
# statements.

# Message types. `ChatModel` is defined FIRST so each message can hold a `chat`
# back-ref — its emit/persist sink, used by `send!`/`append!`/`close` (the
# message IS the streaming target). History-loaded messages carry `chat ===
# nothing` and are never appended to. Mirrors the existing `ChatModel.parent`
# back-ref pattern, so it's idiomatic here.
abstract type ChatMsg end

# A user's submission, pushed onto `ChatModel.user_messages` by the browser send
# handler and consumed by the `run_chat!` loop. Distinct from `ACP.UserMessage`
# (the replay-echo message kind) — this is purely the chat-side request item.
struct UserMessage
    text::String
    images::Vector{AgentClientProtocol.ImageAttachment}
end
UserMessage(text::AbstractString) = UserMessage(String(text), AgentClientProtocol.ImageAttachment[])

# ── ChatModel ──────────────────────────────────────────────────────────────
# Shared per project, lifetime = project's lifetime. One instance lives in
# `state.chat_models[project_id]`; every browser tab viewing the project gets
# a per-session view via `Base.copy(::ChatModel)`. The shared bits — message
# store, ACP client, persistent chat session, the user-message queue — are
# shared across sessions; the Observable fields are per-session connected
# children so their JS bridges GC cleanly when the tab closes.
mutable struct ChatModel
    # Convention: lock first. Now only a guard around `msgs_store` for the
    # read-only comm handlers (msgs.request / tool.render) that read it
    # concurrently with the single `run_chat!` consumer — NOT a mutation
    # funnel. All chat-state mutation happens on the one `run_chat!` task.
    lock::ReentrantLock
    state::ServerState
    cwd::String
    project_id::String

    # Where chat.md + tools/<id>.json live (resolved via `chat_storage_dir`).
    chat_dir::String

    # Persistent state (loaded from disk on construction)
    chat_session::Any                    # ChatSession from persistence.jl
    msgs_store::Vector{ChatMsg}

    # ACP client + the typed Transport that knows how to (re)build it.
    client::Ref{Union{AgentClientProtocol.Client,Nothing}}
    mcp_servers::Vector{AgentClientProtocol.MCPServer}
    transport::ChatTransport

    # The user's turns. The browser send handler `put!`s a `UserMessage`; the
    # `run_chat!` task is the SOLE consumer (one turn at a time). Shared across
    # per-session views so every tab feeds the same queue.
    user_messages::Channel{UserMessage}

    # One-shot history prelude prepended to the next prompt after a session
    # change that lost claude's jsonl (see `arm_history_replay!`). Empty = none.
    pending_history_replay::Ref{String}

    # Single bidirectional channel between Julia and the browser BonitoChat.
    # Tagged-dict wire format; see chat_emit / chat_dispatch! below.
    comm::Observable{Dict{String,Any}}

    # Status surface for the chat header (banner + reconnect state).
    session_alive::Observable{Bool}
    last_error::Observable{String}

    # True while a turn is in flight (set/cleared around the `run_chat!` turn).
    # The single source of truth for the busy spinner — the header binds its
    # class to this, so no separate busy_start/busy_end comm events are needed.
    busy_active::Observable{Bool}

    # Session metadata for the chat header: a heterogeneous list of TYPED
    # items rendered by `header_pill` dispatch. Today: the agent's
    # `ACP.ConfigOption`s (model / permission mode / effort) parsed from the
    # session-setup result; future agents add their own item types + a
    # `header_pill` method — the header skeleton never changes. Reset on every
    # bring-up (`start_chat_client!`); ephemeral, never persisted.
    session_meta::Observable{Vector{Any}}

    # The single `run_chat!` consumer task. Started once (guarded) by
    # `start_chat_client!`; survives `restart_chat_session!` (which only swaps
    # the ACP client, not the consumer). Shared across per-session views.
    consumer_task::Ref{Union{Task,Nothing}}

    # Backreference for per-session copies. `nothing` for the shared parent;
    # points back to it for any `copy(model, session)` view so writes to the
    # broadcast observables reach every tab via the parent→child bridges.
    parent::Union{ChatModel,Nothing}
end

function ChatModel(state::ServerState, cwd::AbstractString;
    project_id::AbstractString="",
    mcp_servers=AgentClientProtocol.MCPServer[],
    transport::Union{ChatTransport,Nothing}=nothing)
    chat_dir = chat_storage_dir(state, project_id, cwd)
    chat_session = load_session(chat_dir, cwd)
    msgs_store = load_history(chat_session)
    actual_transport = transport === nothing ?
                       LocalTransport(cwd; mcp_servers=collect(AgentClientProtocol.MCPServer, mcp_servers)) :
                       transport
    return ChatModel(
        ReentrantLock(),
        state, String(cwd), String(project_id),
        chat_dir,
        chat_session, msgs_store,
        Ref{Union{AgentClientProtocol.Client,Nothing}}(nothing),
        collect(AgentClientProtocol.MCPServer, mcp_servers),
        actual_transport,
        Channel{UserMessage}(64),
        Ref(""),                    # pending_history_replay
        Observable(Dict{String,Any}()),
        Observable(true),
        Observable(""),
        Observable(false),          # busy_active
        Observable(Any[]),          # session_meta
        Ref{Union{Task,Nothing}}(nothing),   # consumer_task
        nothing,                    # parent: this is the shared instance itself
    )
end

# Per-session view. SHARES the lock, client, msgs_store, chat_session, the
# user-message queue, etc. with the parent. Observable fields are bridged via
# `map(identity, session, obs)` so each tab gets its own connected child
# (auto-GC'd on session close).
function Base.copy(m::ChatModel, session::Bonito.Session)
    lock(m.lock) do
        ChatModel(
            m.lock,
            m.state, m.cwd, m.project_id,
            m.chat_dir,
            m.chat_session, m.msgs_store,
            m.client, m.mcp_servers, m.transport,
            m.user_messages,           # shared queue → all sessions feed one consumer
            m.pending_history_replay,
            map(identity, session, m.comm),
            map(identity, session, m.session_alive),
            map(identity, session, m.last_error),
            map(identity, session, m.busy_active),
            map(identity, session, m.session_meta),
            m.consumer_task,           # shared → only the parent runs the loop
            m,    # parent → the shared instance we copied from
        )
    end
end

# Resolve to the shared parent so writes to broadcast observables reach every
# connected tab via the parent→child bridges.
shared(m::ChatModel) = m.parent === nothing ? m : m.parent

# `chat_emit` writes the SHARED comm so every connected tab sees the event via
# its own per-session bridge. Callers may pass either the shared parent or a
# per-session view — `shared(model)` resolves the right target.
chat_emit(model::ChatModel, event::AbstractDict) =
    (shared(model).comm[] = Dict{String,Any}(event); nothing)

# ── Concrete message types (carry the `chat` back-ref) ──────────────────────
mutable struct UserMsg <: ChatMsg
    text::String
    # `true` when this bubble was submitted while an earlier turn was still in
    # flight — the consumer hasn't picked it up yet, so we show it dimmed with
    # a "queued" badge. Cleared via the `user_unqueue` wire event when
    # `run_turn!` finally pops it off `user_messages`.
    queued::Bool
    chat::Union{ChatModel,Nothing}
end
UserMsg(text::AbstractString) = UserMsg(String(text), false, nothing)
UserMsg(chat::ChatModel, text::AbstractString) = UserMsg(String(text), false, chat)

# A `/compact` session summary, rendered as a centered separator block — NOT a
# user message. Claude Code persists it in its jsonl as a synthetic user record
# with `isCompactSummary: true`, but claude-agent-acp doesn't surface that flag
# over ACP — only the body text. We route on the stable prefix instead (see
# `SUMMARY_PREFIX` / `is_summary_text`). `html` caches the rendered markdown the
# same way `AgentMsg` does.
mutable struct SummaryMsg <: ChatMsg
    text::String
    html::String
    chat::Union{ChatModel,Nothing}
end
SummaryMsg(text::AbstractString) = SummaryMsg(String(text), "", nothing)
SummaryMsg(chat::ChatModel, text::AbstractString) = SummaryMsg(String(text), "", chat)
ensure_html!(m::SummaryMsg) =
    isempty(m.html) ? (m.html = markdown_html(m.text)) : m.html

# The exact opening Claude Code writes on `/compact` resume. Verbatim Claude
# Code text — extremely unlikely as a real user message, and the only signal we
# get from ACP (claude-agent-acp drops `isCompactSummary` on the wire).
const SUMMARY_PREFIX = "This session is being continued from a previous conversation that ran out of context."
is_summary_text(text::AbstractString) = startswith(lstrip(text), SUMMARY_PREFIX)

mutable struct AgentMsg <: ChatMsg
    id::String
    text::String
    # Cached rendered HTML so scrolling never has to re-run `Markdown.parse`.
    # Empty = not yet built; `ensure_html!` populates it lazily. Set eagerly
    # by the 2-arg constructor (history-load / replay-adopt: text is final),
    # and at `close(::AgentMsg)` for streaming (text becomes final there).
    # `append!` clears it (defensive; streaming bubbles aren't asked for via
    # `msgs.request`, but a stale cache would silently lose the trailing chunks).
    html::String
    chat::Union{ChatModel,Nothing}
    # True between `send!` (streaming start) and `close` (turn-end finalize).
    # The orphan sweep keys on this so an ACP session that drops mid-stream
    # — and never runs the normal `close` — gets the bubble finalized + the
    # `agent_final` wire event emitted from `sweep_turn_orphans!`. Also makes
    # `close` idempotent: re-close on an already-final bubble is a no-op
    # instead of double-appending to chat.md.
    in_flight::Bool
end
# Cache starts empty in BOTH paths (history-load/replay-adopt AND streaming):
# `ensure_html!` populates on first request, then every subsequent fetch is free.
# Eagerly pre-building here would push the per-message parse onto chat-open;
# lazy distributes it across the scroll events that actually need it (~3 ms
# per 30-msg visible window) while keeping repeat fetches allocation-free.
# History-load / replay-adopt: `in_flight = false` (text is already final).
# Streaming construction: `in_flight = true`, flipped in `close(::AgentMsg)`.
AgentMsg(id::AbstractString, text::AbstractString) =
    AgentMsg(String(id), String(text), "", nothing, false)
AgentMsg(chat::ChatModel, text::AbstractString) =
    AgentMsg(string(uuid4()), String(text), "", chat, true)

# Lazy cache populate. Used by `msg_to_dict` / `wire_final`.
ensure_html!(m::AgentMsg) =
    isempty(m.html) ? (m.html = markdown_html(m.text)) : m.html

# ── Tool messages — abstract + typed variants ──────────────────────────────
# Replaces the previous "one ToolMsg struct with a `kind::String` discriminator"
# pattern: every Claude tool family with distinct UX (Bash background, MCP,
# subagent Task, generic) gets its own concrete subtype so renderers,
# persistence and the taskbar dispatch on the type instead of probing strings.
# The five header fields (id/kind/title/status/summary) plus the
# elapsed-time tracking (started_at/finished_at) are duplicated across the
# variants — small cost, big dispatch clarity. `kind` here is still the ACP
# abstraction ("read"/"execute"/…); the *actual* tool name lives in
# subtype-specific fields (e.g. `MCPToolMsg.tool_name`).
"""
    ToolMsg <: ChatMsg

Abstract supertype for one tool-call bubble in the chat. Concrete subtypes:

  • `GenericToolMsg` — fallback (Read, Edit, Grep, … plus any future tool)
  • `BashToolMsg`    — Claude's Bash tool; carries `is_background`
  • `TaskToolMsg`    — subagent `Task` / `Agent` tool; carries `task_name`
  • `MCPToolMsg`     — `mcp__<server>__<tool>` calls (our `bt_*` tools, others)
  • `BonitoAppMsg`   — a live worker Bonito app (`bt_show_app` / `show_remote_app!`)

All variants share `id` / `kind` / `title` / `status` / `summary`, plus
`started_at` / `finished_at` epoch seconds used by the tool-pill timer.
"""
abstract type ToolMsg <: ChatMsg end

mutable struct GenericToolMsg <: ToolMsg
    id::String
    kind::String
    name::String                          # ACP tool name ("Read", "ToolSearch", …); "" if the agent sent no meta
    title::String
    status::String
    summary::String                       # cached header summary; full content on disk
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    chat::Union{ChatModel,Nothing}
end

# Back-compat 8-arg form (pre-`name`): used by test fixtures and any caller
# without a tool name to hand over.
GenericToolMsg(id, kind, title, status, summary, started_at, finished_at, chat) =
    GenericToolMsg(id, kind, "", title, status, summary, started_at, finished_at, chat)

mutable struct BashToolMsg <: ToolMsg
    id::String
    kind::String
    title::String
    status::String
    summary::String
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    command::String
    is_background::Bool
    # Background-task streaming (`run_in_background`): the agent's tool_call
    # "completes" the moment the command is LAUNCHED, but the shell keeps running.
    # The poller tails the agent's output file (`bg_output_path`, from byte
    # `bg_offset`), accumulates into `bg_text`, and flips `bg_running` off when
    # the file's fd closes (shell exited). `is_live` keys off `bg_running` so a
    # launched-but-running task stays live instead of "finishing immediately".
    bg_output_path::String
    bg_offset::Int
    bg_running::Bool
    bg_text::String
    chat::Union{ChatModel,Nothing}
end

mutable struct TaskToolMsg <: ToolMsg
    id::String
    kind::String
    title::String
    status::String
    summary::String
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    description::String
    is_background::Bool
    task_name::Union{String,Nothing}      # SDK `name` — for SendMessage addressing
    chat::Union{ChatModel,Nothing}
end

mutable struct MCPToolMsg <: ToolMsg
    id::String
    kind::String
    title::String
    status::String
    summary::String
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    server::String                        # "bonitoteam" / "playwright" / …
    tool_name::String                     # bare name (without `mcp__<server>__`)
    chat::Union{ChatModel,Nothing}
end

# A live worker Bonito app (its own type, NOT a generic/MCP tool — it renders an
# interactive embed and offers Detach, see render_tool_body / augment_header!
# below). Recognised at BUILD time from the tool NAME (`bt_show_app`) or KIND
# (`bonito_app`, the programmatic `show_remote_app!` path) — never by sniffing
# the persisted result content, which isn't on disk yet for a just-completed
# live tool (that race is why the detach button vanished on fresh apps). The
# registered app id is resolved lazily at render time (it lives in the result
# content for `bt_show_app`, or is the tool id itself for `show_remote_app!`).
mutable struct BonitoAppMsg <: ToolMsg
    id::String
    kind::String                          # always "bonito_app"
    title::String
    status::String
    summary::String
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    server::String                        # MCP server badge ("" for programmatic)
    # The id the worker registered the app under. `show_remote_app!` registers
    # under the message id (so it's known immediately); `bt_show_app` returns it
    # in its result, captured ONCE on completion. Empty ⇒ fall back to `id` at
    # render. Render/header read this field — NEVER the content.
    app_id::String
    chat::Union{ChatModel,Nothing}
end

mutable struct ThoughtMsg <: ChatMsg
    id::String
    text::String
    chat::Union{ChatModel,Nothing}
    # Same semantics as `AgentMsg.in_flight` — orphan-sweep target + makes
    # `close` idempotent (so a session-died sweep can't double-persist).
    in_flight::Bool
end
ThoughtMsg(id::AbstractString, text::AbstractString) = ThoughtMsg(String(id), String(text), nothing, false)
ThoughtMsg(chat::ChatModel, text::AbstractString)    = ThoughtMsg(string(uuid4()), String(text), chat, true)

# TodoWrite stays a top-level ChatMsg (NOT under ToolMsg) because it arrives
# as its own `Plan` wire variant — distinct from the `tool_call` channel —
# and is the canonical LiveTracking message (each new PlanUpdate ABSORBS into
# the previous bubble; see `absorb!` further down).
mutable struct TodoListMsg <: ChatMsg
    id::String                            # synthetic UUID, used by JS for DOM keying
    entries::Vector{PlanEntry}
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    chat::Union{ChatModel,Nothing}
end
TodoListMsg(entries::Vector{PlanEntry}) =
    TodoListMsg(string(uuid4()), entries, time(), nothing, nothing)
TodoListMsg(chat::ChatModel, entries) =
    TodoListMsg(string(uuid4()), collect(PlanEntry, entries), time(), nothing, chat)

# ── Trait helpers ──────────────────────────────────────────────────────────
# A live tool message is one whose `status` hasn't yet hit a terminal state.
# The tool pill's pulsing glow + the taskbar slot both subscribe to this.
is_live(m::ToolMsg) =
    m.finished_at === nothing && !(m.status in ("completed", "failed"))
# A background bash's tool_call "completes" at LAUNCH but the shell runs on. Once
# we know its output file, liveness is the poller's `bg_running` (the output
# file's fd still open), NOT the tool_call status — so the bubble keeps pulsing
# (and its taskbar slot + timer stay) until the shell actually exits.
function is_live(m::BashToolMsg)
    (m.is_background && !isempty(m.bg_output_path)) && return m.bg_running
    return m.finished_at === nothing && !(m.status in ("completed", "failed"))
end
# `finished_at` flips to non-nothing inside `try_absorb_todo!` once the
# absorbed entries become all-done — `is_live` checking that field is what
# lets the next TodoWrite start a fresh bubble instead of absorbing into
# the just-finished list. While entries are still in flight we trust
# claude's per-item status to drive the live decision.
is_live(t::TodoListMsg) =
    t.finished_at === nothing &&
    any(e -> e.status in ("pending", "in_progress"), t.entries)
is_live(::ChatMsg) = false

# "This tool started but never reached terminal status" — used by the
# `run_turn!` end-of-turn sweep as a defense-in-depth backstop. Keyed on
# `status` (NOT `is_live`) so it does NOT match a backgrounded bash whose
# tool_call already reported `"completed"` at launch (those have a separate
# lifecycle owned by the bg poller). A live worker app (`BonitoAppMsg`) also
# stays terminal-status here for the same reason — its app lifetime is owned
# by the EvalBridge, not the chat-message close.
is_turn_orphan(m::ToolMsg)    = !(m.status in ("completed", "failed"))
# Streaming AgentMsg / ThoughtMsg whose `close` never ran (session died
# mid-stream so `process_update!` / `process!` exited via exception before
# their close-in-finally). The sweep's `close(m)` ships the missing wire
# final and persists to chat.md — without this they'd remain forever as
# half-rendered streaming bubbles in JS and missing from disk.
is_turn_orphan(m::AgentMsg)   = m.in_flight
is_turn_orphan(m::ThoughtMsg) = m.in_flight
# Live plan (any pending/in_progress entry) whose driving agent disappeared:
# `close(::TodoListMsg)` stamps `finished_at` so the JS taskbar removes
# the slot and the next agent's first `TodoWrite` starts a fresh plan
# instead of absorbing into the abandoned one. A plan whose entries are
# all-done already has `finished_at` set; `is_live` is false; we skip.
is_turn_orphan(m::TodoListMsg) = is_live(m)
# NOTE: background `BashToolMsg` (status="completed" + bg_running=true) is
# DELIBERATELY NOT an orphan. The shell IS a child of the ACP subprocess
# we just killed — it may or may not have died with its parent depending
# on process-group / nohup setup. What's stable is the OUTPUT FILE
# already on disk (and the tail RPC over the WS to the worker), so the
# poller's existing "fd closed / no growth" detection finalises the
# bubble naturally if the shell did die, or keeps streaming if it
# didn't. Force-failing in the sweep would discard accumulated output
# and skip the natural completion event — worse UX than letting the
# poller settle it.
is_turn_orphan(::ChatMsg)     = false

# A background-or-streamy task that deserves a taskbar slot. Default false;
# Bash with `run_in_background`, Task/Agent with `run_in_background`, and
# TodoListMsg opt in.
is_taskbar_item(t::BashToolMsg) = t.is_background
is_taskbar_item(t::TaskToolMsg) = t.is_background
is_taskbar_item(::TodoListMsg)  = true
is_taskbar_item(::ChatMsg)      = false

# Tool kind → icon
const TOOL_ICONS = Dict(
    "read" => "📄",
    "edit" => "✏️",
    "delete" => "🗑️",
    "move" => "📦",
    "search" => "🔍",
    "execute" => "▶",
    "think" => "💭",
    "fetch" => "🌐",
    "other" => "⚙",
)

tool_icon(kind) = get(TOOL_ICONS, kind, "⚙")

# claude-agent-acp labels MCP tool calls with their raw wire name,
# `mcp__<server>__<tool>` (e.g. `mcp__bonitoteam__bt_julia_eval`). That's
# noise in the chat header — strip the `mcp__<server>__` prefix so the
# header reads `bt_julia_eval`. Returns `(pretty_title, server)`; `server`
# is "" for non-MCP tools. The non-greedy server capture stops at the
# first `__`, so tool names keeping single underscores survive intact.
function pretty_tool_title(title::AbstractString)
    m = match(r"^mcp__(.+?)__(.+)$", title)
    m === nothing && return (String(title), "")
    return (String(m.captures[2]), String(m.captures[1]))
end

# Short summary shown on the collapsed tool header (before expand).
# Per-kind summaries are tuned for at-a-glance comprehension:
#   edit:   one file → "name · ±N lines";  many → "K files · ±N lines"
#   search: count of result rows that look like grep hits
#   move:   "src → dst" extracted from the content text
#   fetch:  domain of the URL extracted from the content
#   else:   line / byte count of the first text block
function content_summary(kind::AbstractString, content::AbstractVector)
    isempty(content) && return ""

    if kind == "edit"
        diffs = [c for c in content if c isa DiffContent]
        if !isempty(diffs)
            total_delta = 0
            for d in diffs
                total_delta += length(split(d.new_text, '\n')) -
                               length(split(something(d.old_text, ""), '\n'))
            end
            sign_str = total_delta > 0 ? "+$total_delta" : string(total_delta)
            line_word = abs(total_delta) == 1 ? "line" : "lines"
            return length(diffs) == 1 ?
                   "$(basename(diffs[1].path)) · $sign_str $line_word" :
                   "$(length(diffs)) files · $sign_str $line_word"
        end
    end

    if kind == "search"
        text = join((c.text for c in content if c isa TextContent), "\n")
        if !isempty(text)
            hits = count(line -> match(r"^[^\s:]+:\d+[:\-]", line) !== nothing,
                split(text, '\n'))
            if hits > 0
                return "$hits $(hits == 1 ? "match" : "matches")"
            end
        end
    end

    if kind == "move"
        text = join((c.text for c in content if c isa TextContent), "\n")
        m = match(r"([\S]+)\s*(?:->|→|to)\s*([\S]+)", text)
        if m !== nothing
            return "$(basename(m.captures[1])) → $(basename(m.captures[2]))"
        end
    end

    if kind == "fetch"
        text = join((c.text for c in content if c isa TextContent), "\n")
        m = match(r"https?://([^/\s]+)", text)
        if m !== nothing
            return String(m.captures[1])
        end
    end

    # MCP tools (kind=="other") whose first text block is a fenced ```julia
    # code block — show the first code line as the summary so calls like
    # bt_julia_eval show "x = 1 + 2" instead of "5 lines · 124 bytes".
    if !isempty(content) && content[1] isa TextContent
        m = match(r"^\s*```julia\r?\n(.*?)\r?\n```"s, content[1].text)
        if m !== nothing
            first_line = strip(split(String(m.captures[1]), '\n')[1])
            if !isempty(first_line)
                return length(first_line) > 50 ?
                       SubString(first_line, 1, prevind(first_line, 50)) * "…" :
                       first_line
            end
        end
    end

    for c in content
        if c isa TextContent
            n = count('\n', c.text) + 1
            b = sizeof(c.text)
            return n <= 1 ? "$(b) bytes" : "$(n) lines · $(b) bytes"
        elseif c isa DiffContent
            return basename(c.path)
        end
    end
    return ""
end

# Header info shipped to JS at message-create time. Full content is NOT
# included — JS asks via requestToolRender(id), Julia loads the persisted
# ACP params from disk and ships the rendered DOM via Bonito.dom_in_js.
#
# Exception: edit tools embed a small "preview" HTML snippet in the header
# itself so the user can skim what changed without expanding the body.
# `chat_dir` is needed so we can read the persisted DiffContent from disk;
# pass "" when no on-disk content is available (preview is then omitted).
#
# Dispatches on the abstract `ToolMsg` — the four header fields plus
# `started_at` / `finished_at` are shared across every concrete variant.
# Subtype-specific augmentations (e.g. the `server` badge for `MCPToolMsg`)
# patch the dict in their own dispatch arm below.
# Stable per-tool filter key, the identity the message-type filter toolbar
# groups by. The ACP tool NAME, not the title (a Bash title is the literal
# command line). Reloads land as `GenericToolMsg` with the persisted key in
# `name` (see `append_tool`); pre-name chats fall back to the ACP kind.
tool_key(m::GenericToolMsg) = isempty(m.name) ? m.kind : m.name
tool_key(::BashToolMsg)     = "Bash"
tool_key(::TaskToolMsg)     = "Task"
tool_key(m::MCPToolMsg)     = m.tool_name          # bare name: "bt_show", "bt_julia_eval"
tool_key(::BonitoAppMsg)    = "bt_show_app"

function tool_header_dict(m::ToolMsg, chat_dir::AbstractString="")
    pretty_title, server = pretty_tool_title(m.title)
    d = Dict{String,Any}(
        "type" => "tool",
        "id" => m.id,
        "kind" => m.kind,
        # Filter identity for the per-tool show/hide toolbar (see filterKey
        # in bonitoteam.js).
        "tool" => tool_key(m),
        "icon" => tool_icon(m.kind),
        "title" => pretty_title,
        # "" for non-MCP tools; the MCP server name otherwise so the JS
        # header can show it as a dim prefix badge.
        "server" => server,
        "status" => m.status,
        "summary" => m.summary,
        "started_at" => m.started_at,
        # Only background-y tools deserve a taskbar slot. A regular Read in
        # `in_progress` pulses briefly but doesn't crowd the taskbar.
        "taskbar" => is_taskbar_item(m),
    )
    m.finished_at === nothing || (d["finished_at"] = m.finished_at)
    augment_header!(d, m, chat_dir)
    return d
end

# Per-variant tweaks. The base header is enough for `GenericToolMsg`; the
# typed variants opt in to their extras here.
augment_header!(d::Dict, ::GenericToolMsg, chat_dir::AbstractString) =
    augment_generic_header!(d, chat_dir)
function augment_header!(d::Dict, m::BashToolMsg, chat_dir::AbstractString)
    m.is_background && (d["background"] = true)
    augment_generic_header!(d, chat_dir)
end
function augment_header!(d::Dict, m::TaskToolMsg, chat_dir::AbstractString)
    m.is_background && (d["background"] = true)
    m.task_name === nothing || (d["task_name"] = m.task_name)
    augment_generic_header!(d, chat_dir)
end
function augment_header!(d::Dict, m::MCPToolMsg, chat_dir::AbstractString)
    # Server already lives in `d` from `pretty_tool_title`, but the raw bare
    # tool name (without `mcp__server__`) is more authoritative — prefer it.
    isempty(m.server)    || (d["server"] = m.server)
    isempty(m.tool_name) || (d["title"]  = m.tool_name)
    augment_generic_header!(d, chat_dir)
end
# A live worker app. Its `kind` is already "bonito_app" (the JS gates the ⤢
# detach button on that), and its body always auto-opens. Both come from the
# TYPE — no content is read to decide either.
function augment_header!(d::Dict, m::BonitoAppMsg, chat_dir::AbstractString)
    isempty(m.server) || (d["server"] = m.server)
    d["expand"] = true
    return d
end

# `kind == "edit"` preview + `bt_show` auto-expand are shared across the generic
# tool variants and depend on persisted on-disk content, so they live here once.
function augment_generic_header!(d::Dict, chat_dir::AbstractString)
    if d["kind"] == "edit" && !isempty(chat_dir)
        prev = render_edit_preview(chat_dir, d["id"])
        prev === nothing || (d["preview"] = prev)
    end
    if !isempty(chat_dir)
        content = load_tool_content(chat_dir, d["id"])
        # bt_show references auto-expand the pill; inline image content
        # (Read on a PNG, …) only ships its mime — the client's Native
        # Images mode decides the depiction.
        has_show_reference(content) && (d["expand"] = true)
        mime = tool_media_mime(content)
        mime === nothing || (d["show_mime"] = mime)
    end
    return d
end

# Same shape used by msg_to_dict so the JS virtual-scroll renderer treats
# all messages uniformly. The `cwd` argument is only consulted for ToolMsg
# (to render the edit preview); other variants ignore it.
msg_to_dict(m::UserMsg, _chat_dir::AbstractString="") =
    Dict{String,Any}("type" => "user", "text" => m.text, "queued" => m.queued)

function msg_to_dict(m::AgentMsg, _chat_dir::AbstractString="")
    Dict{String,Any}("type" => "agent", "id" => m.id, "html" => ensure_html!(m))
end

function msg_to_dict(m::SummaryMsg, _chat_dir::AbstractString="")
    Dict{String,Any}("type" => "summary", "html" => ensure_html!(m))
end

msg_to_dict(m::ToolMsg, chat_dir::AbstractString="") = tool_header_dict(m, chat_dir)

# Thoughts are lazy-loaded: header carries only id + a size hint. JS asks for
# the body via requestThoughtRender(id) when the user expands the <details>.
# Avoids shipping potentially huge thinking transcripts on every range fetch.
function msg_to_dict(m::ThoughtMsg, _chat_dir::AbstractString="")
    n = count('\n', m.text) + 1
    Dict{String,Any}("type" => "thought", "id" => m.id,
        "summary" => "$n $(n == 1 ? "line" : "lines")")
end

function msg_to_dict(m::TodoListMsg, _chat_dir::AbstractString="")
    rows = join(["""<div class="bt-plan-entry">
        <span class="bt-plan-status">$(e.status == "completed" ? "✓" : e.status == "in_progress" ? "▶" : "○")</span>
        <span>$(e.content)</span></div>""" for e in m.entries])
    d = Dict{String,Any}("type" => "plan", "id" => m.id, "html" => rows,
        "started_at" => m.started_at, "live" => is_live(m),
        # Cheap label for the taskbar slot — "3/5 done" reads at a glance.
        "summary" => todolist_summary(m.entries))
    m.finished_at === nothing || (d["finished_at"] = m.finished_at)
    return d
end

function todolist_summary(entries)
    isempty(entries) && return "todos"
    done = count(e -> e.status == "completed", entries)
    return "$done/$(length(entries)) done"
end

# ── Edit preview ──────────────────────────────────────────────────────────────
# Tiny inline diff shown above the lazy-loaded body so the user can skim
# the change without expanding. Renders the FIRST diff hunk's removed +
# added lines, capped at EDIT_PREVIEW_MAX_LINES. Multi-edit tools show a
# "+ N more files" footnote when there's more than one DiffContent.
const EDIT_PREVIEW_MAX_LINES = 8

# Minimal HTML escape — same shape as the JS escapeHTML so the snippet
# can be innerHTML'd directly without parse mismatches.
preview_escape(s) = replace(String(s),
    '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

function render_edit_preview(chat_dir::AbstractString, tool_id::AbstractString)
    content = load_tool_content(String(chat_dir), String(tool_id))
    isempty(content) && return nothing
    diffs = [c for c in content if c isa DiffContent]
    isempty(diffs) && return nothing

    d = first(diffs)
    old_lines = d.old_text === nothing ? String[] : split(String(d.old_text), '\n')
    new_lines = split(String(d.new_text), '\n')

    rows = String[]
    push!(rows, """<div class="bt-edit-preview-path">$(preview_escape(d.path))</div>""")

    # Trailing newline in old/new produces a phantom empty last element from
    # `split`; pop it so the preview doesn't show an awkward "- " or "+ "
    # blank row at the end of each side.
    trim_trailing_blank!(xs) =
        (!isempty(xs) && isempty(last(xs))) ? (pop!(xs); xs) : xs
    trim_trailing_blank!(old_lines)
    trim_trailing_blank!(new_lines)

    n_used = 0
    for line in old_lines
        n_used >= EDIT_PREVIEW_MAX_LINES && break
        push!(rows, """<div class="bt-edit-preview-line bt-edit-preview-del">- $(preview_escape(line))</div>""")
        n_used += 1
    end
    for line in new_lines
        n_used >= EDIT_PREVIEW_MAX_LINES && break
        push!(rows, """<div class="bt-edit-preview-line bt-edit-preview-add">+ $(preview_escape(line))</div>""")
        n_used += 1
    end

    if length(diffs) > 1
        extra = length(diffs) - 1
        push!(rows, """<div class="bt-edit-preview-more">+ $extra more file$(extra == 1 ? "" : "s") in this edit</div>""")
    end

    return join(rows)
end

# Tool-body rendering (Bonito DOM tree, includes BonitoBook MonacoEditor /
# DiffEditor instances). Called only when the user clicks expand; output is
# shipped to JS via Bonito.dom_in_js, which mounts the sub-DOM (Monaco etc.)
# inside the placeholder. Collapse on the JS side just empties the placeholder
# and lets the browser GC the editor instances.

function detect_language(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    ext == ".jl" && return "julia"
    ext in (".py", ".pyw") && return "python"
    ext in (".js", ".mjs", ".cjs") && return "javascript"
    ext in (".ts", ".tsx") && return "typescript"
    ext in (".md", ".markdown") && return "markdown"
    ext in (".html", ".htm") && return "html"
    ext == ".css" && return "css"
    ext == ".json" && return "json"
    ext in (".yml", ".yaml") && return "yaml"
    ext == ".toml" && return "toml"
    ext in (".sh", ".bash", ".zsh") && return "shell"
    ext in (".rs",) && return "rust"
    ext in (".go",) && return "go"
    return "plaintext"
end

# Read-only Monaco that sizes itself to content height exactly once.
# automaticLayout=false stops the polling loop that fights ResizeObserver.
# The js_init_func runs after the editor Promise resolves and sets an explicit
# pixel height so Monaco never gets a 0-height container.
const MONACO_RESIZE_INIT = js"""(monacoEditor) => {
    monacoEditor.editor.then(editor => {
        const div = monacoEditor.editor_div;
        const h = editor.getContentHeight();
        div.style.height = h + 'px';
        editor.layout({ width: div.offsetWidth || 600, height: h });
    });
}"""

function monaco_readonly(text::AbstractString, lang::AbstractString)
    BonitoBook.MonacoEditor(
        text;
        language=lang,
        readOnly=true,
        automaticLayout=false,
        scrollBeyondLastLine=false,
        lineNumbers="off",
        minimap=Dict(:enabled => false),
        js_init_func=MONACO_RESIZE_INIT,
    )
end

# Console output (captured stdout / stderr / error backtraces) → a
# `Bonito.RichText` terminal block: ANSI escape codes become styled spans
# instead of literal `\e[31m` garbage, and the `terminal-output` class gives
# monospace `pre-wrap`. Wrapped in `.bt-console` so the chat can size it.
console_block(body::AbstractString) = DOM.div(Bonito.RichText(body); class="bt-console")

# Render a single tool-content text block. Recognised shapes:
#  1. Fenced code (```lang\n...\n```)   → Monaco read-only with that language
#  2. Eval section (label:\n<body>)      → labeled card; `result` is a Julia
#     value repr → Monaco julia, the rest is console output → RichText.
#     Emitted by BonitoMCP's bt_julia_eval, which prefixes blocks with
#     "stdout" / "result" / "error".
#  3. ANSI-bearing prose                 → RichText (terminal block).
#  4. Mixed prose                        → Markdown.parse fallback.
const EVAL_SECTION_LABELS = ("stdout", "stderr", "result", "error")

function render_text_block(text::AbstractString)
    m = match(r"^\s*```(\w*)\r?\n(.*?)\r?\n```\s*$"s, text)
    if m !== nothing
        lang = isempty(m.captures[1]) ? "plaintext" : String(m.captures[1])
        return monaco_readonly(String(m.captures[2]), lang)
    end
    m = match(Regex("^(" * join(EVAL_SECTION_LABELS, "|") * "):\n(.*)\$", "s"), text)
    if m !== nothing
        label = String(m.captures[1])
        body = String(m.captures[2])
        # `result` is a Julia value's repr → julia syntax highlighting.
        # stdout / stderr / error are unstructured console output (captured
        # prints, stack traces) → RichText so ANSI colors survive and the
        # block stays a lightweight monospace pane, not a full editor.
        rendered = label == "result" ?
                   monaco_readonly(body, "julia") : console_block(body)
        return DOM.div(
            DOM.div(uppercase(label); class="bt-section-label"),
            rendered;
            class="bt-eval-section")
    end
    # Raw console dump that didn't match a section label but still carries
    # ANSI — render as a terminal block rather than letting Markdown.parse
    # mangle the escape codes.
    Bonito.has_ansi_codes(text) && return console_block(text)
    return DOM.div(Markdown.parse(text), class="bt-tool-md")
end

# A reusable collapsible section — the server-side (eager) counterpart of the
# JS `Collapsable` in bonitoteam.js. Renders a native <details>: the `body` is
# present from the start (no lazy fetch), used for eval Code/Output sub-sections
# inside an already-expanded tool card. `label` is the always-visible heading;
# `preview` (optional) is dim text next to it; `open` shows it expanded.
struct Collapsable
    label::String
    body::Any
    preview::String
    open::Bool
end
Collapsable(label::AbstractString, body; preview::AbstractString="", open::Bool=true) =
    Collapsable(String(label), body, String(preview), open)

function Bonito.jsrender(session::Session, c::Collapsable)
    summary_kids = Any[DOM.span(c.label; class="bt-subsection-label")]
    isempty(c.preview) || push!(summary_kids,
        DOM.span(c.preview; class="bt-subsection-preview"))
    Bonito.jsrender(session, DOM.details(
        DOM.summary(summary_kids...; class="bt-subsection-summary"),
        DOM.div(c.body; class="bt-subsection-body");
        class="bt-subsection",
        open=c.open ? true : nothing))
end

# Open by default — an already-expanded tool card should show everything without
# extra clicks; the collapsible just lets the user fold away a long code block
# or a noisy output to focus on the other.
tool_subsection(label::AbstractString, body; preview::AbstractString="", open::Bool=true) =
    Collapsable(label, body; preview, open)

# bt_julia_eval tool bodies: a ```julia code echo followed by stdout / result
# / error sections. Render as two collapsibles — "Code" (Monaco julia, same
# read-only editor the `read` file tool uses) and "Output" (the eval-section
# stack). Returns `nothing` if `content` isn't eval-shaped so the caller
# falls through to the generic renderer.
function render_eval_body(content)
    isempty(content) && return nothing
    code = nothing
    rest = []
    for c in content
        if c isa TextContent && code === nothing
            m = match(r"^\s*```julia\r?\n(.*?)\r?\n```\s*$"s, c.text)
            if m !== nothing
                code = String(m.captures[1])
                continue
            end
        end
        if c isa TextContent
            push!(rest, render_text_block(c.text))
        elseif c isa DiffContent
            push!(rest, render_diff_block(c))
        elseif c isa ImageContent
            push!(rest, DOM.img(src="data:$(c.mime_type);base64,$(c.data)",
                style=Styles("max-width" => "100%")))
        end
    end
    code === nothing && return nothing   # not eval-shaped — let caller handle it
    # `split` always yields ≥1 element (even for ""), so `first` is safe.
    first_line = strip(first(split(code, '\n')))
    code_preview = length(first_line) > 60 ?
                   SubString(first_line, 1, prevind(first_line, 60)) * "…" : first_line
    code_section = tool_subsection("Code", monaco_readonly(code, "julia");
        preview=code_preview)
    output_section = isempty(rest) ?
                     tool_subsection("Output", DOM.div("(no output)"; class="bt-tool-empty")) :
                     tool_subsection("Output", DOM.div(rest...))
    return DOM.div(code_section, output_section; class="bt-eval-body")
end

# Load the persisted ACP params for `tool_id` and parse the content array back
# into TextContent / DiffContent / ImageContent. Returns an empty vector if
# there's no saved snapshot (e.g. history loaded from chat.md but the tools/
# directory was never created on this server).
function load_tool_content(chat_dir::AbstractString, tool_id::AbstractString)
    params = load_tool_file(String(chat_dir), String(tool_id))
    params === nothing && return Any[]
    raw = get(params, "content", nothing)
    raw === nothing && return Any[]
    return Any[parse_tool_content_item(c) for c in raw if c isa AbstractDict]
end

# A single DiffContent rendered as path-header + inline DiffEditor. Used by
# both the dedicated 'edit' path (where multiple diffs are stacked) and the
# default fallback (where a diff appears in a mixed content array).
function render_diff_block(d::DiffContent)
    DOM.div(
        DOM.div(d.path; class="bt-diff-header"),
        BonitoBook.DiffEditor(something(d.old_text, ""), d.new_text;
            language=detect_language(d.path),
            renderSideBySide=false);
        class="bt-diff-block")
end

# Render search-tool output as one row per match. Recognises both `path:line:`
# (grep / rg default) and `path-line-` (grep -A/-B context). Lines that don't
# match either format are rendered as muted raw lines so we don't lose them.
function render_search_results(text::AbstractString)
    rows = []
    for line in split(text, '\n')
        isempty(strip(line)) && continue
        m = match(r"^([^:]+):(\d+):(.*)$", line)
        if m === nothing
            m = match(r"^([^-]+)-(\d+)-(.*)$", line)
        end
        if m !== nothing
            push!(rows, DOM.div(
                DOM.span(String(m.captures[1]); class="bt-search-path"),
                DOM.span(":" * String(m.captures[2]); class="bt-search-line"),
                DOM.code(strip(String(m.captures[3])); class="bt-search-snippet");
                class="bt-search-row"))
        else
            push!(rows, DOM.div(line; class="bt-search-raw"))
        end
    end
    DOM.div(rows...; class="bt-search-results")
end

function find_show_reference(content)
    for c in content
        c isa TextContent || continue
        startswith(c.text, "shown: ") && return c.text
    end
    return nothing
end

has_show_reference(content) = find_show_reference(content) !== nothing

# ── bt_show: render a worker file inline (ShowTool) ─────────────────────────
# A `shown: <path> …` text block (emitted by the `bt_show` MCP tool) becomes a
# `ShowTool`. Its `jsrender` fetches the file to the server (blocking the
# per-render task — the Collapsable's "loading…" placeholder shows meanwhile)
# and renders the right element. Video plays because Bonito's asset server
# honours HTTP Range requests, and we point `<video src>` at a served
# `Bonito.Asset` URL (not a multi-MB `data:` blob). No bytes pass through
# claude; the path is the only thing on the wire.

# Pull the path out of a `shown: <path>` header (tolerates a trailing
# ` (<mime>, <size>)` from older tool output). `nothing` if not a show ref.
function parse_show_path(text::AbstractString)
    nl = findfirst('\n', text)
    header = nl === nothing ? text : text[1:prevind(text, nl)]
    m = match(r"^shown:\s+(.+?)(?:\s+\([^)]*\))?\s*$", header)
    m === nothing ? nothing : String(m.captures[1])
end

# Pull the mime out of the `shown: <path> (<mime>, <size>)` reference. The
# wire ships it as `show_mime` so the client can decide how to depict the
# show (e.g. the "Native Images" toggle keys on image/*). `nothing` for
# refs without the parenthesized tail or a mime-shaped token.
function parse_show_mime(text::AbstractString)
    nl = findfirst('\n', text)
    header = nl === nothing ? text : text[1:prevind(text, nl)]
    m = match(r"\(([a-z0-9.+-]+/[a-z0-9.+-]+)\s*,", header)
    m === nothing ? nothing : String(m.captures[1])
end

# The displayable-media mime of a tool's content, if any: a bt_show
# reference's mime, or the mime of inline image content (e.g. the Read tool
# on a PNG ships an ACP ImageContent block). This is what the wire's
# `show_mime` field carries — the client's "Native Images" mode keys on it.
function tool_media_mime(content)
    ref = find_show_reference(content)
    ref === nothing || return parse_show_mime(ref)
    for c in content
        c isa ImageContent && return c.mime_type
    end
    return nothing
end

# A bt_show reference, rendered inline. Pure data — the fetch starts at render
# time (when the tool body is expanded), not at construction.
struct ShowTool
    state::ServerState
    project_id::String
    cwd::String
    path::String        # path as the WORKER sees it (absolute, or relative to its cwd)
end

# Always render synchronously: the fetch (minutes for a multi-GB video)
# blocks only the per-render @async task in `handle_command!(::ToolRender-
# Command)`, and the finished element ships through that handler's
# `dom_in_js` → `_btToolSlot` mount, which finds nodes the virtual scroll
# holds DETACHED. The earlier `@async` + `jsrender(::Task)` spinner path
# swapped the result in via Bonito's Observable machinery, whose
# document-scoped uuid lookup polls for 30s and then gives up — a video
# whose fetch outlived that window (or whose node was off-window at swap
# time) kept its spinner forever; only a manual re-render, by then on the
# isfile fast path, showed it.
Bonito.jsrender(session::Bonito.Session, st::ShowTool) =
    Bonito.jsrender(session, render_show_file(st))

# The server-side path a ShowTool's file resolves to — no IO. Files under the
# project tree map straight onto the server mirror (cwd ⟷ worker_path); an
# absolute path outside the project lands in a server-side cache.
function show_server_path(st::ShowTool)
    proj = get(st.state.projects[], st.project_id, nothing)
    if !isabspath(st.path)
        return joinpath(st.cwd, st.path)
    elseif proj !== nothing && startswith(st.path, proj.worker_path)
        return joinpath(st.cwd, relpath(st.path, proj.worker_path))
    else
        return joinpath(st.cwd, ".bt-show-cache", basename(st.path))
    end
end

# Single-flight per destination: concurrent `tool.render` calls for the same
# file (native-toggle spam, several tabs) would otherwise both stream into the
# same `<dst>.partial` and corrupt it. The loser blocks until the winner's
# fetch lands, re-checks isfile, and returns without a second transfer.
# Entries are kept (one small lock per distinct shown file) — dropping them
# would re-open the two-writers window for a fetch that errors and retries.
const SHOW_FETCH_LOCKS = ReentrantLock()
const SHOW_FETCH_INFLIGHT = Dict{String,ReentrantLock}()

# Resolve `st.path` to a file on the SERVER's disk, fetching it from the worker
# if we don't already have it. Blocks for the transfer (multi-GB videos take
# a while — receive_file streams into `<dst>.partial` and renames, so isfile
# never sees a torso). Throws if it can't be obtained.
function fetch_show_file(st::ShowTool)
    server_dst = show_server_path(st)
    isfile(server_dst) && return server_dst        # already mirrored or cached
    dst_lock = lock(SHOW_FETCH_LOCKS) do
        get!(ReentrantLock, SHOW_FETCH_INFLIGHT, server_dst)
    end
    lock(dst_lock) do
        isfile(server_dst) && return server_dst    # the racer fetched it
        proj = get(st.state.projects[], st.project_id, nothing)
        proj === nothing && error("bt_show: file not on server and no worker to fetch from: $(st.path)")
        worker_src = isabspath(st.path) ? st.path : joinpath(proj.worker_path, st.path)
        mkpath(dirname(server_dst))
        fetch_file_from_worker(st.state, proj.worker_id, worker_src, server_dst; handoff_timeout=60.0)
        return server_dst
    end
end

# MIME inferred from extension → the right element. Media point `src` at a
# served `Bonito.Asset` (range-capable); text goes through Monaco; anything
# else gets a caption. `<video>`/`<img>` get explicit `type`/element so we
# cover webp/bmp/mov and emit correct MIME types.
const SHOW_VIDEO_MIME = Dict(".mp4" => "video/mp4", ".webm" => "video/webm",
    ".ogg" => "video/ogg", ".mov" => "video/quicktime")
const SHOW_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg")
const SHOW_TEXT_EXTS = (".txt", ".log", ".md", ".json", ".csv", ".jl", ".py",
    ".js", ".ts", ".html", ".htm", ".toml", ".yaml", ".yml", ".css")

function render_show_file(st::ShowTool)
    path = fetch_show_file(st)
    ext = lowercase(splitext(path)[2])
    if ext in SHOW_IMAGE_EXTS
        return DOM.img(src=Bonito.Asset(path),
            style=Styles("max-width" => "100%", "display" => "block"))
    elseif haskey(SHOW_VIDEO_MIME, ext)
        return DOM.video(DOM.source(src=Bonito.Asset(path), type=SHOW_VIDEO_MIME[ext]);
            controls=true,
            style=Styles("max-width" => "100%", "display" => "block"))
    elseif ext in SHOW_TEXT_EXTS
        return monaco_readonly(read(path, String), detect_language(path))
    else
        return DOM.div("$(basename(path)) · $(filesize(path)) bytes"; class="bt-tool-empty")
    end
end

# A live worker app embeds against the per-tab Session via the placeholder's
# jsrender (not loaded from disk). The registered app id lives on the message
# (`app_id`, captured once on completion); empty ⇒ the app was registered under
# the message id (`show_remote_app!`). No content is read here.
render_tool_body(state::ServerState, m::BonitoAppMsg, cwd::AbstractString,
    chat_dir::AbstractString=cwd; project_id::AbstractString="") =
    wrap_for_detach(m.id, remote_app_placeholder(m.id, project_id,
                                                 isempty(m.app_id) ? m.id : m.app_id))

function render_tool_body(state::ServerState, m::ToolMsg, cwd::AbstractString,
    chat_dir::AbstractString=cwd;
    project_id::AbstractString="")
    content = load_tool_content(chat_dir, m.id)
    isempty(content) &&
        return DOM.div("(no body — tool details not persisted for this entry)",
            class="bt-tool-empty")

    # bt_show output: ANY text block starts with "shown: " (the bt_julia_eval
    # wrapper prepends a `\`\`\`julia` code-echo block before the formatter's
    # output, so we have to scan, not just look at the first block). The
    # rendered file lives on the worker; the chat fetches it lazily and
    # renders a collapsible preview without putting the bytes through claude.
    show_text = find_show_reference(content)
    if show_text !== nothing
        path = parse_show_path(show_text)
        path === nothing || return ShowTool(state, project_id, String(cwd), path)
    end

    # bt_julia_eval: `\`\`\`julia` code echo + stdout/result/error sections →
    # two collapsibles (Code / Output). Checked before the kind dispatch so
    # it works regardless of what `kind` claude-agent-acp tagged the MCP
    # tool with — the content shape is the reliable signal.
    eval_body = render_eval_body(content)
    eval_body === nothing || return eval_body

    if m.kind == "edit"
        # Render every diff (multi-edit calls used to silently drop all but
        # the first). Stack with file-path headers between each.
        diffs = [c for c in content if c isa DiffContent]
        if !isempty(diffs)
            return DOM.div((render_diff_block(d) for d in diffs)...;
                class=length(diffs) > 1 ? "bt-multi-diff" : "")
        end
    end

    if m.kind == "search"
        text = join((c.text for c in content if c isa TextContent), "\n")
        if !isempty(text)
            return render_search_results(text)
        end
    end

    if m.kind in ("execute", "read")
        text = join((c.text for c in content if c isa TextContent), "\n")
        if !isempty(text)
            lang = m.kind == "read" ? detect_language(m.title) : "shell"
            return monaco_readonly(text, lang)
        end
    end

    # Default / "think" / "other" / "fetch" / "move" / "delete" / mixed:
    # text blocks that ARE a fenced code block become Monaco; prose stays
    # markdown. Diff blocks (uncommon outside `edit`) render inline.
    parts = []
    for c in content
        if c isa TextContent
            push!(parts, render_text_block(c.text))
        elseif c isa DiffContent
            push!(parts, render_diff_block(c))
        elseif c isa ImageContent
            push!(parts, DOM.img(src="data:$(c.mime_type);base64,$(c.data)",
                style=Styles("max-width" => "100%")))
        end
    end
    isempty(parts) && return DOM.div("(empty)", class="bt-tool-empty")
    return DOM.div(parts...)
end

# ── The message is the streaming target ─────────────────────────────────────
# Each `ChatMsg` carries a `chat` back-ref (set when it goes live). The three
# sinks — in-memory store, browser (comm), disk (chat.md) — are each expressed
# ONCE here, as common verbs:
#
#   send!(chat, m)     store + emit the "new" wire event       (render a bubble)
#   append!(m, chunk)  grow the bubble's text + emit "chunk"   (stream into it)
#   close(m)           persist to chat.md + emit the "*_final"  (finalize)
#
# These are the ONLY things that touch `msgs_store` / `comm` / chat.md, and
# they all run on the single `run_chat!` consumer task — so the lock degenerates
# to a brief Vector guard around the `msgs_store` push (the read-only comm
# handlers read it concurrently), not a mutation funnel.

# Add a fresh message to the chat: push to the store, emit its "new" event.
function send!(model::ChatModel, m::ChatMsg)
    n = lock(model.lock) do
        push!(model.msgs_store, m)
        length(model.msgs_store)
    end
    d = wire_new(model, m)
    d["n"] = n            # JS bumps totalCount from `n`; no separate broadcast
    chat_emit(model, d)
    return m
end

# Grow a streaming text bubble in place and emit the delta. `m.chat` is the
# sink captured when the bubble was created. AgentMsg clears its cached html
# so a finalize-then-rerequest never serves the pre-streaming snapshot.
# Stream a text delta into the bubble. We still ACCUMULATE `m.text` (cheap), but
# once cancel is requested we stop shipping each chunk over the wire — under a
# heavy token stream that per-chunk `chat_emit` to a (possibly slow) browser is
# the one thing that keeps the turn "busy" after the user hit stop. The seal
# (`close` → `wire_final`) still ships the final partial, so the bubble is
# correct; we just don't stream the now-discarded tail.
function Base.append!(m::AgentMsg, t::AbstractString)
    m.text *= t
    m.html = ""
    c = m.chat === nothing ? nothing : m.chat.client[]
    (c !== nothing && (@atomic c.conn.cancelling)) || chat_emit(m.chat, wire_chunk(m, t))
    return m
end
Base.append!(m::UserMsg, t::AbstractString) = (m.text *= t; chat_emit(m.chat, wire_chunk(m, t)); m)
# Summaries arrive whole on replay; live they can stream through `process_update!`
# like a UserMessage. Append clears the HTML cache so the eventual close-time
# render reflects the full text.
Base.append!(m::SummaryMsg, t::AbstractString) = (m.text *= t; m.html = ""; m)

# Finalize a message: persist to chat.md (per-type writer) + emit its closing
# event. UserMsg / TodoListMsg have no `*_final` event; a ToolMsg only persists once
# it reaches a terminal status. AgentMsg builds its rendered html ONCE here so
# later `msgs.request` round-trips (scroll-back, re-mount) reuse the cache.
function Base.close(m::AgentMsg)
    # Idempotent: the orphan sweep can race with `process_update!`'s own
    # close-in-finally. Without this guard a second close would re-append to
    # chat.md (not idempotent on disk) and re-emit `agent_final` to JS.
    m.in_flight || return nothing
    m.in_flight = false
    ensure_html!(m)
    finalize_agent(m.chat.chat_session, m)
    chat_emit(m.chat, wire_final(m))
    return nothing
end
function Base.close(m::ThoughtMsg)
    m.in_flight || return nothing
    m.in_flight = false
    append_thought(m.chat.chat_session, m)
    chat_emit(m.chat, wire_final(m))
    return nothing
end
Base.close(m::UserMsg) = (append_user(m.chat.chat_session, m); nothing)
# Persist only. The previous version also stamped `finished_at = time()`,
# which made every just-created TodoListMsg immediately stop being "live"
# and broke cross-turn absorption (the next TodoWrite found the prior
# bubble as not-live and spawned a fresh one — visible in the chat
# history as a parallel stack of duplicate todo bubbles, each with its
# own timer ticking). Normal lifecycle: persist initial snapshot only —
# `try_absorb_todo!` is the path that flips `finished_at` once entries
# go all-done; mid-life updates keep landing through there. This close
# runs at INITIAL emit (a fresh `TodoListMsg` that couldn't absorb into
# a prior bubble), so it must NOT touch `finished_at` — otherwise a
# brand-new plan with pending entries lands non-live and the JS taskbar
# misses it. The orphan sweep on `restart_chat_session!` uses the
# `finalize_orphan!` verb below, NOT this close.
Base.close(m::TodoListMsg) =
    (append_plan(m.chat.chat_session, m); nothing)

# `finalize_orphan!` — what the restart orphan sweep calls. For most
# kinds it IS `close` (their normal finalize): AgentMsg / ThoughtMsg
# close is already idempotent + ships the trailing wire_final; ToolMsg
# close force-fails non-terminal status + emits the terminal
# tool_update. For TodoListMsg the two are distinct verbs: `close` is
# the initial-persist step the live-emit path uses, while
# `finalize_orphan!` is the "your driving agent went away — stop being
# live so a fresh one doesn't absorb into you" path. Splitting them
# avoids the trap where the initial-emit close accidentally drops
# liveness off a plan whose entries are still pending.
finalize_orphan!(m::AgentMsg)   = close(m)
finalize_orphan!(m::ThoughtMsg) = close(m)
finalize_orphan!(m::ToolMsg)    = close(m)
function finalize_orphan!(m::TodoListMsg)
    m.finished_at === nothing || return nothing
    m.finished_at = time()
    append_plan(m.chat.chat_session, m)
    chat_emit(m.chat, plan_update_dict(m))
    return nothing
end
# Default for kinds we don't sweep (UserMsg, SummaryMsg, BashToolMsg in
# background mode, …). Explicit no-op so dispatch never falls into a
# generic `close` for something we deliberately don't want finalised.
finalize_orphan!(::ChatMsg) = nothing
# Close is TOTAL: every reachable status finalizes. If the status isn't already
# terminal (cancel mid-tool, EOF, an upstream backstop that closed `updates`
# without a final snap), treat that as failure — flip to "failed", emit one
# trailing `tool_update` so the browser freezes the timer + stops the pulse,
# then persist. The old guarded form silently no-op'd on non-terminal status,
# which left the bubble pulsing forever AND skipped the chat.md append (so a
# reload couldn't show the tool either). Callers should not need to satisfy a
# precondition on `status` — that's exactly the "wrong-by-construction" shape
# we're trying to avoid here.
function Base.close(m::ToolMsg)
    if !(m.status in ("completed", "failed"))
        m.status = "failed"
        pretty_title, _ = pretty_tool_title(m.title)
        m.finished_at === nothing && (m.finished_at = time())
        chat_emit(m.chat, Dict{String,Any}("type" => "tool_update", "id" => m.id,
            "status" => "failed", "title" => pretty_title,
            "summary" => m.summary, "finished_at" => m.finished_at))
    end
    m.finished_at === nothing && (m.finished_at = time())
    append_tool(m.chat.chat_session, m)
    nothing
end
Base.close(m::SummaryMsg) = (ensure_html!(m); append_summary(m.chat.chat_session, m); chat_emit(m.chat, wire_final(m)); nothing)

# ── Wire-dict builders (the browser protocol; byte-identical to before) ─────
# CommonMark for rendering — `Bonito.bonito_parser()` already turns on the
# extensions we want (TableRule, FootnoteRule, DollarMath, Admonition,
# Strikethrough, RawContent, AttributeRule), so we share its config instead
# of maintaining a parallel `enable!` list here. The bare stdlib `Markdown`
# / `CM.Parser()` paths were both wrong: stdlib `Markdown` italicizes
# intraword `_` (`foo_bar_baz` → `foo<em>bar</em>baz`); a bare `CM.Parser()`
# fixes that but drops tables on the floor (they came out as literal `|`).
# The parser is reused across calls; CommonMark.Parser is mutating but the
# parse + write_html cycle leaves it in the same state each time.
const MARKDOWN_PARSER = Bonito.bonito_parser()
# Wrap the rendered html in `.markdown-body` so `Bonito.MarkdownCSS` (which
# is GitHub-style and already loaded into the shell) handles tables, code
# blocks, lists, etc. — we don't have to duplicate the styling.
markdown_html(text::AbstractString) =
    "<div class=\"markdown-body\">" *
    sprint(io -> CM.html(io, MARKDOWN_PARSER(String(text)))) *
    "</div>"

# "new message" event. Streaming-open shape for agent/thought (seeded with the
# first chunk); plain shape for user/tool/plan. `send!` adds the `n` count.
wire_new(::ChatModel, m::AgentMsg) =
    Dict{String,Any}("type" => "agent", "id" => m.id, "html" => "", "streaming" => true, "text" => m.text)
# A thought is committed whole (see `process!(::Thought)`): render it collapsed
# like a reloaded one (summary only, lazy body); `close` then ships the html.
wire_new(::ChatModel, m::ThoughtMsg) = msg_to_dict(m)
wire_new(::ChatModel, m::UserMsg) =
    Dict{String,Any}("type" => "user", "text" => m.text, "queued" => m.queued)
wire_new(model::ChatModel, m::ToolMsg) = tool_header_dict(m, model.chat_dir)
wire_new(model::ChatModel, m::TodoListMsg) = msg_to_dict(m, model.chat_dir)
# Summary opens as a centered placeholder; `close` ships the rendered html.
wire_new(::ChatModel, ::SummaryMsg) =
    Dict{String,Any}("type" => "summary", "html" => "", "streaming" => true)

# Stream the FULL rendered html of the message-so-far rather than the text
# delta — so a live agent message reads as proper markdown (lists, headings,
# code blocks, bold, links) instead of running together as one wall of text
# whose newlines also get lost. CommonMark is cheap per parse (~µs) and
# claude-agent-acp chunks are paragraph-sized, not per-character, so the
# O(N²) cumulative cost over a single message stays well under a millisecond
# for typical lengths. `append!` already invalidated the cache; `ensure_html!`
# rebuilds it from the new accumulated text.
wire_chunk(m::AgentMsg, _t) = Dict{String,Any}(
    "type" => "chunk", "id" => m.id, "html" => ensure_html!(m))
wire_chunk(m::UserMsg, t) = Dict{String,Any}("type" => "user_chunk", "text" => t)

wire_final(m::AgentMsg) = Dict{String,Any}("type" => "agent_final", "id" => m.id, "html" => ensure_html!(m))
wire_final(m::ThoughtMsg) = Dict{String,Any}("type" => "thought_final", "id" => m.id, "html" => markdown_html(m.text))
wire_final(m::SummaryMsg) = Dict{String,Any}("type" => "summary_final", "html" => ensure_html!(m))

# ── Rendering one ACP message into a bubble ─────────────────────────────────
# `process!` is the per-message renderer used by the `run_chat!` loop: turn the
# clean ACP message into a chat bubble, `send!` it, then stream its `updates`
# into that bubble via `process_update!`. Only tools/plan override
# `process_update!`; text messages use the default (drain the text deltas).
process!(chat::ChatModel, m::AgentClientProtocol.Message) =
    process_update!(send!(chat, to_message(chat, m)), m)

# Thoughts get special handling. This agent redacts the plaintext reasoning
# (the model returns thinking blocks with an empty `thinking` field and only an
# encrypted `signature`), so a thought is almost always EMPTY. We show a
# transient "reasoning…" indicator for the lifetime of the thought and only
# commit a real (collapsed, persisted) thought bubble if non-empty text
# actually arrives — empty redacted thoughts leave no trace in the store, while
# an agent that DOES expose plaintext still renders one.
function process!(chat::ChatModel, m::AgentClientProtocol.Thought)
    chat_emit(chat, Dict{String,Any}("type" => "thinking", "active" => true))
    text = m.text
    try
        for delta in m.updates
            text *= delta
        end
    finally
        # MUST fire even if the update iteration threw (session died mid-
        # thought / channel closed with InvalidStateException). Without
        # this, the JS `bt-thinking-active` class stays on forever — the
        # whole "reasoning…" indicator is stuck until another full thought
        # turn completes successfully. `run_turn!`'s finally has a second
        # defensive emit as a belt-and-suspenders backstop.
        chat_emit(chat, Dict{String,Any}("type" => "thinking", "active" => false))
    end
    isempty(strip(text)) || close(send!(chat, ThoughtMsg(chat, text)))
    return nothing
end

# Session-config changes mid-turn: pure header metadata — update the shared
# observable, no chat bubble, no persistence (config is ephemeral per
# connection; the next bring-up resets it from the session-setup result).
function process!(chat::ChatModel, m::AgentClientProtocol.ConfigUpdate)
    s = shared(chat)
    # The spec payload is the COMPLETE config state: replace the ConfigOption
    # items, preserve any other meta kinds a future parser may have added.
    rest = [x for x in s.session_meta[] if !(x isa AgentClientProtocol.ConfigOption)]
    s.session_meta[] = Any[m.options..., rest...]
    return nothing
end

function process!(chat::ChatModel, m::AgentClientProtocol.ModeUpdate)
    s = shared(chat)
    s.session_meta[] = Any[map(s.session_meta[]) do x
        x isa AgentClientProtocol.ConfigOption && x.id == "mode" ?
            AgentClientProtocol.ConfigOption(x.id, x.name, x.description,
                x.category, m.mode_id, x.choices) : x
    end...]
    return nothing
end

to_message(chat::ChatModel, m::AgentClientProtocol.AgentMessage) = AgentMsg(chat, m.text)
# Compact-summary "user" messages get their own centered kind. ACP doesn't carry
# Claude Code's `isCompactSummary` flag, so we route on the verbatim opening.
to_message(chat::ChatModel, m::AgentClientProtocol.UserMessage) =
    is_summary_text(m.text) ? SummaryMsg(chat, m.text) : UserMsg(chat, m.text)
# Typed dispatch on the ACP variant — one method per concrete `ToolCall`.
to_message(chat::ChatModel, tc::AgentClientProtocol.GenericTool)   = build_tool_msg(chat, tc)
to_message(chat::ChatModel, tc::AgentClientProtocol.BashCall)      = build_tool_msg(chat, tc)
to_message(chat::ChatModel, tc::AgentClientProtocol.TaskCall)      = build_tool_msg(chat, tc)
to_message(chat::ChatModel, tc::AgentClientProtocol.MCPCall)       = build_tool_msg(chat, tc)
to_message(chat::ChatModel, tc::AgentClientProtocol.TodoWriteCall) = TodoListMsg(chat, tc.entries)
to_message(chat::ChatModel, m::AgentClientProtocol.Plan)           = TodoListMsg(chat, m.entries)

# Concrete-typed builders for the four ToolMsg variants. Each one knows which
# tool-specific fields to lift out of its ACP source.
# `bt_show_app` (an MCP call) and any tool already tagged `bonito_app`
# (`show_remote_app!`) are live worker apps — route them to `BonitoAppMsg`,
# decided purely from the tool name / kind (no content sniffing).
is_bonito_app(tc::AgentClientProtocol.MCPCall)     = tc.tool_name == "bt_show_app"
is_bonito_app(tc::AgentClientProtocol.GenericTool) = tc.kind == "bonito_app"
is_bonito_app(::AgentClientProtocol.ToolCall)      = false

bonito_app_msg(tc, server, chat) =
    BonitoAppMsg(tc.id, "bonito_app", tc.title, tc.status,
                 content_summary("bonito_app", tc.content),
                 time(), nothing, server,
                 something(find_app_reference(tc.content), ""), chat)

build_tool_msg(chat::ChatModel, tc::AgentClientProtocol.GenericTool) =
    is_bonito_app(tc) ? bonito_app_msg(tc, "", chat) :
    GenericToolMsg(tc.id, tc.kind, tc.name, tc.title, tc.status,
                   content_summary(tc.kind, tc.content),
                   time(), nothing, chat)

build_tool_msg(chat::ChatModel, tc::AgentClientProtocol.BashCall) =
    BashToolMsg(tc.id, tc.kind, tc.title, tc.status,
                content_summary(tc.kind, tc.content),
                time(), nothing,
                tc.command, tc.run_in_background,
                "", 0, false, "", chat)

build_tool_msg(chat::ChatModel, tc::AgentClientProtocol.TaskCall) =
    TaskToolMsg(tc.id, tc.kind, tc.title, tc.status,
                content_summary(tc.kind, tc.content),
                time(), nothing,
                tc.description, tc.run_in_background, tc.task_name, chat)

build_tool_msg(chat::ChatModel, tc::AgentClientProtocol.MCPCall) =
    is_bonito_app(tc) ? bonito_app_msg(tc, tc.server, chat) :
    MCPToolMsg(tc.id, tc.kind, tc.title, tc.status,
               content_summary(tc.kind, tc.content),
               time(), nothing,
               tc.server, tc.tool_name, chat)

# Default: stream the message's text deltas into the bubble, then finalize.
function process_update!(b::ChatMsg, m::AgentClientProtocol.Message)
    try
        for delta in m.updates
            append!(b, delta)
        end
    finally
        # The `close(b)` MUST fire even when the update iteration threw
        # (session died mid-stream). `Base.close(::AgentMsg/::ThoughtMsg)`
        # is now idempotent + emits `agent_final`/`thought_final`, so the
        # browser sees a finalized bubble instead of one stuck in
        # `bt-stream-active`. If we somehow miss this path the orphan
        # sweep catches it via `is_turn_orphan(::AgentMsg) = m.in_flight`.
        close(b)
    end
    return nothing
end

# Tools: persist the content snapshot to disk (so the lazily-loaded body stays
# current), re-render the header on each change, finalize on terminal status.
# A tool's `updates` channel yields the (mutated) ToolCall after each change.
# `b::ToolMsg` covers every concrete variant — they all carry the same five
# header fields the update path touches.
function process_update!(b::ToolMsg, m::AgentClientProtocol.ToolCall)
    try
        persist_tool_content!(b.chat.chat_dir, m)
        ship_edit_preview!(b)
        for snap in m.updates
            prev_status = b.status
            b.status = snap.status
            b.title = snap.title
            b.summary = content_summary(snap.kind, snap.content)
            # Stamp `finished_at` on terminal-transition so the live timer freezes.
            prev_status in ("completed", "failed") || !(b.status in ("completed", "failed")) ||
                (b.finished_at = time())
            persist_tool_content!(b.chat.chat_dir, snap)
            pretty_title, _ = pretty_tool_title(b.title)
            d = Dict{String,Any}("type" => "tool_update", "id" => b.id,
                "status" => b.status, "title" => pretty_title, "summary" => b.summary)
            b.finished_at === nothing || (d["finished_at"] = b.finished_at)
            # Auto-expand the body: a live Bonito app always (it IS the point), or a
            # `bt_show` tool once its content carries a `shown:` ref. `auto_expand_body`
            # dispatches on the type — no content sniffing to decide.
            (auto_expand_body(b) || has_show_reference(snap.content)) &&
                (d["expand"] = true)
            # Displayable media (bt_show mime, or inline image content from
            # e.g. Read on a PNG) — the client's Native Images mode keys on
            # this; ship it with the update that carries the result.
            mime = tool_media_mime(snap.content)
            mime === nothing || (d["show_mime"] = mime)
            chat_emit(b.chat, d)
            ship_edit_preview!(b)
        end
    finally
        close(b)        # total: finalizes the bubble even if the loop body threw
    end
    return nothing
end

# Does this tool's body auto-open on render? Only a live Bonito app.
auto_expand_body(::ToolMsg) = false
auto_expand_body(::BonitoAppMsg) = true

# A live worker app: run the generic tool update, but first capture the worker's
# registered app id from the result content ONCE (bt_show_app returns it there),
# so render/header read `b.app_id` and never touch content again.
function process_update!(b::BonitoAppMsg, m::AgentClientProtocol.ToolCall)
    if isempty(b.app_id)
        for snap in m.updates
            ref = find_app_reference(snap.content)
            if ref !== nothing
                b.app_id = ref
                break
            end
        end
    end
    invoke(process_update!, Tuple{ToolMsg, AgentClientProtocol.ToolCall}, b, m)
end

# Background bash (`run_in_background`): the agent "completes" the tool_call the
# instant the command is LAUNCHED and hands back an output-file path; the shell
# keeps running. We do the normal persist + header updates but, instead of
# finalizing on "completed", capture the output path and go live (`bg_running`) —
# the background-task poller then streams the file and finalizes when the shell
# exits. Non-background bashes fall through to the generic ToolMsg handling.
function process_update!(b::BashToolMsg, m::AgentClientProtocol.ToolCall)
    try
        persist_tool_content!(b.chat.chat_dir, m)
        for snap in m.updates
            b.status  = snap.status
            b.title   = snap.title
            b.summary = content_summary(snap.kind, snap.content)
            persist_tool_content!(b.chat.chat_dir, snap)
            # Detect a background launch from the RESULT ("…running in background…
            # Output is being written to: <path>"), NOT from rawInput's
            # `run_in_background` — some agent builds don't forward it, so
            # `is_background` reads false even for a real background bash. The result
            # text is the reliable signal; flip `is_background` on so the taskbar +
            # `is_live` treat it as the live task it is.
            if isempty(b.bg_output_path)
                path = parse_bg_output_path(snap.content)
                if path !== nothing
                    @debug "background task detected from result" id = b.id path = basename(path)
                    b.is_background  = true
                    b.bg_output_path = path
                    b.bg_offset      = 0
                    b.bg_running     = true       # the poller now owns its lifecycle
                end
            end
            # Foreground bash (or a failed launch): stamp finished_at on terminal.
            # A live background task is left unstamped — the poller finalizes it.
            if !b.bg_running && b.status in ("completed", "failed")
                b.finished_at === nothing && (b.finished_at = time())
            end
            pretty_title, _ = pretty_tool_title(b.title)
            d = Dict{String,Any}("type" => "tool_update", "id" => b.id,
                "status" => b.bg_running ? "in_progress" : b.status,
                "title" => pretty_title, "summary" => b.summary)
            if b.bg_running
                d["background"] = true
                # `wire_new` shipped `taskbar=false` (is_background was still false —
                # rawInput omits run_in_background); now that we know it IS a
                # background task, flip the taskbar slot on so it joins the bar.
                d["taskbar"] = true
            elseif b.finished_at !== nothing
                d["finished_at"] = b.finished_at
            end
            chat_emit(b.chat, d)
        end
    finally
        # A live background task is finalized later (by `finalize_bg_task!` when the
        # shell exits); only persist-to-chat.md here if it already terminated. The
        # guard belongs inside `finally` so a thrown loop body doesn't accidentally
        # close (= mark "failed") a still-running background shell.
        b.bg_running || close(b)
    end
    return nothing
end

# Pull the output-file path from a background-launch result, e.g.
# "… Output is being written to: /tmp/…/<id>.output".
function parse_bg_output_path(content)
    for c in content
        txt = try
            hasproperty(c, :text) ? String(getproperty(c, :text)) :
                (c isa AbstractDict ? String(get(c, "text", "")) : "")
        catch
            ""
        end
        mm = match(r"written to:\s*(\S+)", txt)
        mm === nothing || return String(mm.captures[1])
    end
    return nothing
end

# ── Background-task output poller ───────────────────────────────────────────
# ONE server-wide loop streams every live background bash. The agent backgrounds
# the shell and only returns a file path (it does NOT stream), so we tail that
# file ourselves. Per task we back off 0.5s → 1 → 2 → 4 → 5s (responsive while
# fresh, cheap once settled). "Done" is the output file's fd closing — the shell
# exited (see the worker's `file_held_open`); a non-Linux worker falls back to
# output quiescence.
# Non-Linux fallback: if the worker can't report `open_known` on the
# output file's fd, we infer "the shell exited" from "no growth in 20 s".
const BG_QUIESCE_SECS = 20.0

# Per-chat background-output poller. Spawned on `start_chat_client!`,
# torn down when the chat closes. The task IS the taskbar's bookkeeping
# loop from the server's side: every second it walks THIS chat's live
# bg items (the same set the JS `_refreshTaskbar` paints) and tails
# their output. No global loop walking every model's msgs_store; no
# global cadence constant — the 1 s sleep is inline, the task's
# lifetime is the chat's, and a closed chat takes its poller with it.
#
# We use an IdDict keyed on the shared model rather than a field so the
# struct layout stays stable (= no precompile rebuild). Lookups are
# O(1) and the dict only ever has one entry per live chat.
const BG_POLLERS         = IdDict{ChatModel,Task}()
const BG_POLLERS_GC_LOCK = ReentrantLock()

function start_background_poller!(state::ServerState, model::ChatModel)
    s = shared(model)
    lock(BG_POLLERS_GC_LOCK) do
        existing = get(BG_POLLERS, s, nothing)
        existing === nothing || istaskdone(existing) || return  # already live
        BG_POLLERS[s] = Base.errormonitor(@async begin
            try
                background_poll_loop(state, s)
            finally
                lock(BG_POLLERS_GC_LOCK) do
                    delete!(BG_POLLERS, s)
                end
            end
        end)
        return nothing
    end
    return nothing
end

bg_worker_id(state::ServerState, model::ChatModel) =
    let pid = model.project_id
        (isempty(pid) || !haskey(state.projects[], pid)) ? nothing :
            state.projects[][pid].worker_id
    end

function write_bg_content!(chat_dir::AbstractString, m::BashToolMsg)
    body = isempty(strip(m.command)) ? m.bg_text : "\$ $(m.command)\n\n$(m.bg_text)"
    open(tool_file(chat_dir, m.id), "w") do io
        JSON.print(io, Dict("content" => [Dict("type" => "text", "text" => body)]))
    end
    return nothing
end

bg_line_count(m::BashToolMsg) = count(==('\n'), m.bg_text)

function stream_bg_update!(model::ChatModel, m::BashToolMsg)
    write_bg_content!(model.chat_dir, m)
    n = bg_line_count(m)
    m.summary = "running… $n line$(n == 1 ? "" : "s")"
    chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => m.id,
        "status" => "in_progress", "summary" => m.summary,
        "background" => true, "taskbar" => true))
    return nothing
end

function finalize_bg_task!(model::ChatModel, m::BashToolMsg)
    m.bg_running = false
    m.status = "completed"
    m.finished_at === nothing && (m.finished_at = time())
    write_bg_content!(model.chat_dir, m)
    try
        append_tool(model.chat_session, m)
    catch e
        @warn "append_tool for finished bg task failed" id = m.id exception = e
    end
    n = bg_line_count(m)
    chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => m.id,
        "status" => "completed", "summary" => "done · $n line$(n == 1 ? "" : "s")",
        "finished_at" => m.finished_at))
    return nothing
end

# Tail one task's output; stream new bytes to the bubble. Returns the worker's
# tail result (or `nothing` on a transient error → retry next tick).
function poll_background_task!(state::ServerState, model::ChatModel, m::BashToolMsg)
    wid = bg_worker_id(state, model)
    wid === nothing && return nothing
    r = try
        tail_worker_file(state, wid, m.bg_output_path; offset = m.bg_offset, timeout = 10.0)
    catch e
        @debug "tail_file failed (will retry)" id = m.id exception = e
        return nothing
    end
    if r.exists && !isempty(r.chunk)
        m.bg_text  *= r.chunk
        m.bg_offset = r.offset
        stream_bg_update!(model, m)
    end
    return r
end

function background_poll_loop(state::ServerState, model::ChatModel)
    # Per-tool state lives in the loop's closure: `last_grew` tracks the
    # last time each id's output file grew (only consulted for the non-
    # Linux quiesce fallback). When a tool finalizes we drop its entry.
    last_grew = Dict{String,Float64}()
    while true
        try
            for m in collect(model.msgs_store)
                (m isa BashToolMsg && m.is_background && m.bg_running &&
                    !isempty(m.bg_output_path)) || continue
                before = m.bg_offset
                r = poll_background_task!(state, model, m)
                if m.bg_offset > before
                    last_grew[m.id] = time()
                end
                lg = get(last_grew, m.id, time())
                done = r !== nothing &&
                    (r.open_known ? (r.exists && !r.open) :
                                    (time() - lg > BG_QUIESCE_SECS))
                if done
                    finalize_bg_task!(model, m)
                    delete!(last_grew, m.id)
                end
            end
            # GC `last_grew` for ids that are no longer live (finalized
            # on a previous tick or an orphan sweep cleared them).
            for id in collect(keys(last_grew))
                any(x -> x isa BashToolMsg && x.id == id && x.bg_running,
                    model.msgs_store) || delete!(last_grew, id)
            end
        catch e
            @warn "background task poll loop tick failed" exception = e
        end
        sleep(1.0)
    end
end

# Edit tools show an inline diff preview on the collapsed header. The diff is
# only on disk AFTER the persist above, but `wire_new` (which builds the header)
# already fired — so we ship the preview as a follow-up `tool_update`. No-op for
# non-edit tools, so the bt_show / generic tool flow is untouched.
function ship_edit_preview!(b::ToolMsg)
    b.kind == "edit" || return nothing
    prev = render_edit_preview(b.chat.chat_dir, b.id)
    prev === nothing && return nothing
    chat_emit(b.chat, Dict{String,Any}("type" => "tool_update", "id" => b.id, "preview" => prev))
    return nothing
end

# Todos are one-shot snapshots — nothing to stream, just finalize (persist).
process_update!(b::TodoListMsg, ::AgentClientProtocol.Plan) = (close(b); nothing)
process_update!(b::TodoListMsg, ::AgentClientProtocol.TodoWriteCall) = (close(b); nothing)

# ── TodoList absorption ────────────────────────────────────────────────────
# Both Claude tooling paths land here: a `tool_call/TodoWrite` (the SDK tool)
# AND a separate `plan` SessionUpdate (the older PlanUpdate channel). We
# *don't* push a fresh `TodoListMsg` if a live one already exists — instead
# the previous bubble absorbs the new entries and emits a `wire_update`. End
# result: ONE pill in the chat that animates as the todos move, plus one
# slot in the taskbar that mirrors it (see is_taskbar_item).
function process!(chat::ChatModel, m::AgentClientProtocol.TodoWriteCall)
    if !try_absorb_todo!(chat, m.entries)
        msg = TodoListMsg(chat, m.entries)
        close(send!(chat, msg))
    end
    for _ in m.updates; end                # drain any straggler updates (rare)
    return nothing
end

function process!(chat::ChatModel, m::AgentClientProtocol.Plan)
    try_absorb_todo!(chat, m.entries) ||
        close(send!(chat, TodoListMsg(chat, m.entries)))
    return nothing
end

# Find the last live `TodoListMsg` in the store and replace its entries with
# `new_entries`. Returns `true` if absorption happened; `false` means there's
# nothing live to update and the caller should push a fresh bubble.
function try_absorb_todo!(chat::ChatModel, new_entries)
    entries = collect(PlanEntry, new_entries)
    target = lock(chat.lock) do
        for i in length(chat.msgs_store):-1:1
            m = chat.msgs_store[i]
            m isa TodoListMsg || continue
            return is_live(m) ? m : nothing   # done lists stop absorbing — start fresh
        end
        return nothing
    end
    target === nothing && return false
    target.entries = entries
    is_live(target) || (target.finished_at = time())
    # Persist as a new chat.md plan section so a reload sees the latest state
    # (until we teach `load_history` to dedupe by `id`, this also keeps the
    # iteration trail visible on disk).
    target.chat === nothing || append_plan(target.chat.chat_session, target)
    # Emit a `plan_update` rather than a fresh `plan`: the JS dispatch keys
    # the existing bubble by id and patches its html / live class / timer,
    # instead of treating it as a new message arriving at the next index.
    chat_emit(chat, plan_update_dict(target))
    return true
end

plan_update_dict(m::TodoListMsg) = merge(msg_to_dict(m),
    Dict{String,Any}("type" => "plan_update"))

# ── The chat consumer loop ──────────────────────────────────────────────────
# ONE task per ChatModel drains `user_messages` and drives one prompt turn at a
# time. ALL chat-state mutation (`send!`/`append!`/`close`) happens on THIS
# task, so there is no funnel lock and the "user-submit lands mid agent-chunk"
# race cannot occur. Started in `start_chat_client!`; ends when `user_messages`
# is closed (chat teardown).
function run_chat!(chat::ChatModel)
    for user_msg in chat.user_messages
        try
            run_turn!(chat, user_msg)
        catch e
            @error "chat turn failed" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

# One user turn: drive the prompt and render each whole message of the agent's
# reply. The user bubble is ALREADY rendered + persisted — `send_message!` did
# that synchronously when the user hit send, so the message appears in the
# chat instantly (even when a prior turn is still running, where it shows up
# as a "queued" bubble). Here we just promote any queued bubble that's about
# to be processed, then prompt. `busy_active` is the single source of truth
# for the spinner (set here, cleared in `finally`).
function run_turn!(chat::ChatModel, user_msg::UserMessage)
    promote_queued_user_bubble!(chat)
    client = chat.client[]
    client === nothing && return nothing
    chat.busy_active[] = true
    try
        for m in AgentClientProtocol.prompt!(client, with_prelude(chat, user_msg.text);
            images=user_msg.images)
            process!(chat, m)
        end
    catch e
        # `prompt!` runs the turn's producer in a bound task, so a dead session
        # surfaces as a TaskFailedException wrapping the real cause — unwrap it
        # before classifying.
        e = e isa TaskFailedException ? e.task.result : e
        if is_session_dead_error(e)
            chat.session_alive[] = false
            chat.last_error[] = sprint(showerror, e)
        else
            close(send!(chat, AgentMsg(chat, "[error: $(sprint(showerror, e))]")))
        end
    finally
        chat.busy_active[] = false
        # Defensive thinking=off. `process!(::Thought)` already emits this
        # in its own finally, but in the multi-thought turn case the LAST
        # thought may not be reached if an exception unwinds through
        # `prompt!`'s consumer; this one-line backstop guarantees the JS
        # indicator is cleared regardless. Idempotent in the JS handler.
        chat_emit(chat, Dict{String,Any}("type" => "thinking", "active" => false))
        # Defense in depth: anything still in non-terminal status at end-of-turn is
        # an orphan — the `process_update!` per-tool drain SHOULD have finalized it
        # via `close(b)` once the ACP `close(::TurnState)` backstop force-failed
        # any tool the agent never resolved (see messages.jl). This sweep catches
        # the case where `process!` itself threw before reaching that close. Keyed
        # on `is_turn_orphan` — `ToolMsg` keys on status, `AgentMsg`/`ThoughtMsg`
        # on `in_flight`, so background bashes (status already "completed" at
        # launch) and live worker apps are correctly left alone, but a half-
        # streamed agent reply / thought lands properly finalized in JS.
        sweep_turn_orphans!(chat)
    end
    return nothing
end

function sweep_turn_orphans!(chat::ChatModel)
    orphans = lock(chat.lock) do
        ChatMsg[m for m in chat.msgs_store if is_turn_orphan(m)]
    end
    for m in orphans
        try
            # Dispatch to the kind-specific orphan verb (close for agent/
            # thought/tool, the dedicated final stamp for TodoListMsg).
            # Going through `close` directly would force a live plan into
            # its initial-persist path AGAIN instead of finalising it.
            finalize_orphan!(m)
        catch e
            @warn "turn-orphan sweep finalize failed" id = getfield(m, :id) exception = e
        end
    end
    return nothing
end

# Classify a turn exception. "Session dead" ⇒ the transport is torn down and the
# only path forward is a reconnect (banner shown, user clicks Restart).
# "Transient" ⇒ one bad turn, the session is still live (inline error bubble).
# We dispatch on the exception TYPE, never `showerror` text. ACP raises a typed
# `ConnectionClosed` for transport teardown; subprocess EOF / TCP errors surface
# as `EOFError` / `Base.IOError`; the WS transport as `WebSocketError`.
is_session_dead_error(::AgentClientProtocol.ConnectionClosed) = true
is_session_dead_error(::EOFError) = true
is_session_dead_error(::Base.IOError) = true
is_session_dead_error(::HTTP.WebSockets.WebSocketError) = true
is_session_dead_error(::Exception) = false

# ── Client lifecycle ───────────────────────────────────────────────────────
function start_chat_client!(model::ChatModel)
    # The agent→client fs/* RPCs are the only thing the handler does now —
    # session updates arrive as a message channel from `prompt!`, not via a
    # handler callback. `agent_cwd` is the path the agent sees (cwd locally,
    # worker_path remotely) so fs reads resolve against the right root.
    handler = AgentClientProtocol.FSRequestHandler(agent_cwd(model.transport))

    # Capture the recorded session id BEFORE start_session so we can detect
    # "fresh session, not a resume". A mismatch means claude has no memory of
    # `msgs_store` (e.g. project synced to a different worker), so we arm a
    # one-shot history prelude that the next prompt consumes (`with_prelude`).
    prev_session_id = model.chat_session.session_id
    # `on_frame` taps every raw ACP frame (both directions) into
    # chat_dir/acp.jsonl — inspectable live via GET /acp-log/<project_id>.
    client, replay = start_session(model.transport, handler;
                                   on_frame = acp_frame_logger(model.chat_dir))
    # Header metadata: typed views over the raw session-setup result. A future
    # agent kind extends this line with additional parsers over the same dict.
    # (What the header SHOWS is a separate, display-side decision — see
    # `show_in_header`.)
    shared(model).session_meta[] =
        Any[AgentClientProtocol.parse_config_options(client.session_result)...]
    model.client[] = client
    new_session_id = client.session_id
    if isempty(replay)
        # No replay (fresh session/new, or a transport without resume). If WE
        # have history but claude doesn't (the session changed under us), feed
        # ours forward as a one-shot text prelude on the next prompt.
        if !isempty(model.msgs_store) && prev_session_id != new_session_id
            arm_history_replay!(model)
        end
    else
        # claude resumed and re-streamed its history — reconcile into chat.md
        # (keep ours canonical, adopt only what we're missing). Mutually
        # exclusive with the prelude: claude HAS memory here, so we never
        # double-feed it ours.
        reconcile_replay!(model, replay)
    end
    update_session_id!(model.chat_session, new_session_id)

    # Start the single consumer loop ONCE (it survives restarts, which only
    # swap `client[]`). Runs on the shared parent so all per-session views and
    # producers feed the one queue / one consumer.
    s = shared(model)
    if s.consumer_task[] === nothing
        s.consumer_task[] = Base.errormonitor(@async run_chat!(s))
    end
    # And the per-chat background-output poller (one task that ticks every
    # second, walks THIS chat's live `BashToolMsg`s with `bg_running=true`).
    # Idempotent: re-calls on restart find the existing task still alive and
    # do nothing. The task ends when the chat closes.
    start_background_poller!(model.state, s)

    # Cache the live model so the sidebar can swap to this chat instantly and
    # test rigs can drive prompts via state.chat_models[pid] without the UI.
    if !isempty(model.project_id)
        @info "registering chat model" project_id = model.project_id session_id = model.client[].session_id
        lock(model.state.lock) do
            model.state.chat_models[model.project_id] = model
        end
        notify_chats!(model.state)   # surface in the active-chats sidebar
    end
    return nothing
end

# Serializer for `restart_chat_session!` — keyed on the SHARED parent
# ChatModel (so per-session views funnel to one gate). Two concurrent
# restart calls would otherwise both close(old_client), both wait, both
# call start_chat_client! — at best one of them losing its newly-spawned
# client into the wind, at worst deadlocking because each blocks the
# consumer task's `sweep_turn_orphans!` from acquiring `model.lock`. The
# module-level IdDict avoids adding a struct field — restart is rare
# (user click) so an IdDict lookup per call is fine; the entry lifetime
# is one restart so no GC pressure either. The companion `RESTART_LOCK`
# guards the dict itself across the read-test-set sequence.
const RESTART_LOCK   = ReentrantLock()
const RESTART_INFLIGHT = IdDict{ChatModel,Bool}()

function restart_chat_session!(model::ChatModel)
    s = shared(model)
    # Compare-and-swap the in-flight flag. If another restart is already
    # running for this shared model, wait for it to clear and then return:
    # whatever the user wanted to achieve (a fresh, alive session) is
    # what that restart is delivering — we don't need to redo it. The
    # bounded wait caps a misbehaving in-flight restart at 10 s so we
    # can't wedge the caller indefinitely.
    already = lock(RESTART_LOCK) do
        if get(RESTART_INFLIGHT, s, false)
            true
        else
            RESTART_INFLIGHT[s] = true
            false
        end
    end
    if already
        deadline = time() + 10.0
        while time() < deadline &&
              lock(RESTART_LOCK) do; get(RESTART_INFLIGHT, s, false); end
            sleep(0.02)
        end
        return nothing
    end
    try
        try
            old = model.client[]
            # close is idempotent + total: stdin EOF / WS peer close makes the
            # agent exit cleanly and cascades through the Connection teardown, so
            # any in-flight `prompt!` errors out (its turn loop ends) without stale
            # updates leaking into the new session.
            if old !== nothing
                close(old)
                # Wait for the in-flight turn (if any) to actually exit so its
                # try/catch/finally in `run_turn!` runs to completion BEFORE we
                # boot a fresh client. That finally is what:
                #   • emits the trailing `thinking=false`
                #   • runs `sweep_turn_orphans!` (finalises half-streamed
                #     AgentMsg / ThoughtMsg, fails open ToolMsg pills)
                #   • clears `busy_active`
                # If we raced past it the new client could start emitting
                # chunks against the same comm while the old finally was still
                # running — undefined ordering on the wire. Bounded wait so a
                # wedged consumer can't block us forever; the explicit cleanup
                # below covers any state that didn't settle in time.
                deadline = time() + 2.0
                while s.busy_active[] && time() < deadline
                    sleep(0.02)
                end
            end
            # Force-clean defensively even if the wait timed out / there was no
            # in-flight turn to begin with.
            s.busy_active[] = false
            chat_emit(s, Dict{String,Any}("type" => "thinking", "active" => false))
            sweep_turn_orphans!(s)
            # ── JS-side reset ───────────────────────────────────────────────
            # Single event the browser handler treats as "drop any UI state
            # attached to the dead session" — clears `bt-thinking-active`,
            # `bt-busy-active`, cancels any pending chase rAF, strips
            # `bt-stream-active` from leftover streaming nodes. Emitted BEFORE
            # the new client so a chunk from the fresh session can't be applied
            # to a node that hasn't been cleared yet. The followup `msgs.count`
            # below tells the virtual scroll the post-restart truth so any
            # bubble whose final-form HTML changed during the orphan sweep
            # gets re-fetched on next range request.
            chat_emit(s, Dict{String,Any}("type" => "session_reset"))

            start_chat_client!(model)      # brings up a fresh client[]; consumer keeps running
            # Broadcast recovery to every connected tab via the shared parent.
            s.session_alive[] = true
            s.last_error[] = ""
            chat_emit(s, Dict{String,Any}(
                "type" => "msgs.count", "n" => length(s.msgs_store)))
        catch e
            s.last_error[] = "restart failed: $(sprint(showerror, e))"
            @error "restart_chat_session! failed" exception=(e, catch_backtrace())
        end
    finally
        lock(RESTART_LOCK) do
            delete!(RESTART_INFLIGHT, s)
        end
    end
end

# Single-entry "user submitted a message" path. Every call site (input area,
# auto-prompt, scripted hooks) goes through here. We render + persist the user
# bubble synchronously so the message appears the instant the user hits send —
# previously the bubble was created inside `run_turn!`, which meant messages
# submitted while an earlier turn was still running stayed invisible (queued
# silently on the channel) until that turn finished. Now they show up as
# "queued" bubbles immediately; `promote_queued_user_bubble!` clears the
# `queued` flag when `run_turn!` actually picks them up.
#
# `images` are sent to the agent as multimodal content blocks; the caller is
# responsible for embedding any file-path reference into `msg.text` so display
# + replay see what claude does.
function send_message!(model::ChatModel, msg::UserMsg;
    images=AgentClientProtocol.ImageAttachment[])
    s = shared(model)
    # If there's a turn in flight, the bubble joins the queue (visually dim).
    bubble = UserMsg(model, msg.text)
    bubble.queued = s.busy_active[]
    close(send!(model, bubble))   # send! pushes + emits wire_new; close persists
    put!(s.user_messages,
        UserMessage(msg.text, collect(AgentClientProtocol.ImageAttachment, images)))
    backfill_project_title!(model, msg.text)
    return nothing
end

# Strip claude-agent-acp injected context blocks (`<ide_opened_file>…`,
# `<system-reminder>…`, `<local-command-*>…`, …) and the "Caveat" prefix.
# A duplicate of BonitoWorker's `strip_injected_context`/`meaningful_prompt`
# kept here so the server side doesn't depend on the deployed worker's
# version of those helpers (older workers pre-date them).
#
# Generic strategy: strip ANY leading `<tag>…</tag>` block (closer matches
# opener via backreference); after that, if the remainder still starts with a
# bare `<tag>` opener it's system commentary (e.g. `<ide_opened_file>The user
# opened …` with no closing tag) and contains no user prose, so we skip it.
const TITLE_LEADING_TAG_BLOCK  = r"\A\s*<\s*([A-Za-z][\w-]*)\s*>.*?<\s*/\s*\1\s*>"is
const TITLE_LEADING_TAG_OPENER = r"\A\s*<\s*[A-Za-z][\w-]*\s*>"

function meaningful_title(raw::AbstractString)
    s = String(raw)
    while occursin(TITLE_LEADING_TAG_BLOCK, s)
        s = replace(s, TITLE_LEADING_TAG_BLOCK => ""; count = 1)
    end
    s = strip(s)
    isempty(s) && return nothing
    occursin(TITLE_LEADING_TAG_OPENER, s) && return nothing
    startswith(s, "Caveat: The messages below were generated by the user") && return nothing
    # Collapse whitespace runs, then truncate to a sidebar-friendly length.
    s = strip(replace(s, r"\s+" => " "))
    isempty(s) && return nothing
    return length(s) > 80 ? String(first(s, 79)) * "…" : String(s)
end

# Set `p.title` from the user's first meaningful prompt — what makes the
# sidebar / project card read `[DT] resume the build refactor` instead of
# `[DT] ClaudeExperiments`. Idempotent: only fires while `title` is still
# `nothing` (a user edit pins it forever). No-op for projects whose
# state.projects[] entry is gone (project removed mid-send).
function backfill_project_title!(model::ChatModel, prompt::AbstractString)
    pid = model.project_id
    isempty(pid) && return
    haskey(model.state.projects[], pid) || return
    p = model.state.projects[][pid]
    p.title === nothing || return
    t = meaningful_title(prompt)
    t === nothing && return
    p.title = t
    try
        save_projects!(model.state)
    catch e
        @warn "backfill_project_title!: persist failed" exception=e
    end
    safe_notify!(model.state.projects)
    return nothing
end

# `run_turn!` calls this right before driving the agent prompt for a popped
# `UserMessage`. Finds the oldest UserMsg in `msgs_store` still marked queued
# (FIFO matches the channel order under `send_message!`) and emits a
# `user_unqueue` event so the browser drops the "queued" class. No-op when
# the chat was idle — the just-pushed bubble was never queued.
function promote_queued_user_bubble!(chat::ChatModel)
    target = lock(chat.lock) do
        for m in chat.msgs_store
            if m isa UserMsg && m.queued
                m.queued = false
                return m
            end
        end
        return nothing
    end
    target === nothing && return nothing
    chat_emit(chat, Dict{String,Any}("type" => "user_unqueue"))
    return nothing
end

# Auto-prompt: if the project carries an `auto_prompt` (set by the "From
# GitHub" template) and the chat is otherwise empty, fire it once as the
# first user message. Cleared + persisted right away so a server restart or
# session reconnect doesn't double-fire.
function fire_auto_prompt!(model::ChatModel)
    isempty(model.project_id) && return
    haskey(model.state.projects[], model.project_id) || return
    proj = model.state.projects[][model.project_id]
    ap = proj.auto_prompt
    (ap === nothing || isempty(ap) || !isempty(model.msgs_store)) && return
    proj.auto_prompt = nothing
    try
        save_projects!(model.state)
    catch e
        @warn "auto_prompt: persist clear failed" exception = e
    end
    send_message!(model, UserMsg(String(ap)))
    return nothing
end

# Build a transcript prelude from `msgs_store` to feed into claude's first
# prompt after a session change (project synced to a new worker, restart
# without a usable resume_id, etc.). User + agent turns only — tool calls
# and thoughts are claude-internal artifacts and don't belong in the
# conversation context. Capped at the last 60 turns to keep the prompt
# size sane on long histories.
function build_history_prelude(model::ChatModel)::String
    relevant = ChatMsg[]
    lock(model.lock) do
        for m in model.msgs_store
            (m isa UserMsg || m isa AgentMsg) && push!(relevant, m)
        end
    end
    if length(relevant) > 60
        relevant = relevant[end-59:end]
    end
    io = IOBuffer()
    println(io, "Below is a transcript of our previous conversation on this project. ",
        "I'm continuing where we left off — please read it for context, then respond ",
        "to my new message after the divider.")
    println(io)
    println(io, "--- PREVIOUS CONVERSATION ---")
    for m in relevant
        if m isa UserMsg
            println(io, "USER: ", m.text)
        elseif m isa AgentMsg
            println(io, "ASSISTANT: ", m.text)
        end
        println(io)
    end
    println(io, "--- END OF PREVIOUS CONVERSATION ---")
    println(io)
    println(io, "My new message:")
    println(io)
    return String(take!(io))
end

# Arm a one-shot history replay for the next prompt. Builds the prelude
# **now** (so any messages the user types between arming and sending are
# their own conversation, not part of the replay) and stashes it on the
# model. Idempotent — a second arm before consume replaces the prelude.
function arm_history_replay!(model::ChatModel)
    lock(model.lock) do
        model.pending_history_replay[] = build_history_prelude(model)
    end
    @info "chat history replay armed" project_id = model.project_id n_msgs = length(model.msgs_store)
    return nothing
end

# Prepend any armed one-shot history prelude to `text`, consuming it. Empty in
# steady state — only set right after a session change that lost claude's jsonl.
function with_prelude(model::ChatModel, text::AbstractString)
    p = model.pending_history_replay[]
    isempty(p) || (model.pending_history_replay[] = "")
    return p * text
end

# ── Reconcile claude's resumed history into chat.md (keep ours, fill gaps) ───
# On `session/load` claude re-streams the resumed session's full history (see
# `ACP.replay_history`). `chat.md` is canonical, so we adopt only what we're
# missing: the whole replay when chat.md is empty (importing a claude session),
# or the tail beyond our last recorded turn (e.g. the user used the Claude Code
# CLI directly). Our history is always an in-order prefix of claude's — every
# turn goes through claude — so we match the shared prefix and append the rest.

# Which replayed messages belong in persisted history. Redacted/empty thoughts
# and empty text turns leave no trace (consistent with `process!(::Thought)`).
keep_in_history(m::AgentClientProtocol.AgentMessage) = !isempty(strip(m.text))
keep_in_history(m::AgentClientProtocol.UserMessage)  = !isempty(strip(m.text))
keep_in_history(m::AgentClientProtocol.Thought)      = false
keep_in_history(m::AgentClientProtocol.ToolCall)     = true
keep_in_history(m::AgentClientProtocol.Plan)         = true

# Does an existing (chat.md) message correspond to a replayed one? Tools key on
# claude's tool_use id (the one id that survives the replay, stored as ToolMsg.id);
# user/agent turns on text; plans on entries. Different shapes never match.
msg_matches(a::ToolMsg,  b::AgentClientProtocol.ToolCall)     = a.id == b.id
msg_matches(a::UserMsg,  b::AgentClientProtocol.UserMessage)  =
    !is_summary_text(b.text) && strip(a.text) == strip(b.text)
msg_matches(a::SummaryMsg, b::AgentClientProtocol.UserMessage) =
    is_summary_text(b.text) && strip(a.text) == strip(b.text)
msg_matches(a::AgentMsg, b::AgentClientProtocol.AgentMessage) = strip(a.text) == strip(b.text)
msg_matches(a::TodoListMsg, b::AgentClientProtocol.Plan)         = plan_entries_equal(a.entries, b.entries)
msg_matches(a::TodoListMsg, b::AgentClientProtocol.TodoWriteCall) = plan_entries_equal(a.entries, b.entries)
msg_matches(::ChatMsg,   ::AgentClientProtocol.Message)       = false

plan_entries_equal(a, b) = length(a) == length(b) &&
    all(ea.content == eb.content && ea.status == eb.status for (ea, eb) in zip(a, b))

# Length of the leading run where our store and the replay candidates line up
# index-for-index (the shared prefix). Everything after is claude-only → adopt.
function longest_matched_prefix(existing, candidates)
    n = min(length(existing), length(candidates))
    i = 1
    while i <= n && msg_matches(existing[i], candidates[i])
        i += 1
    end
    return i - 1
end

# Persist + store one replayed message as history (chat === nothing; never emits
# live UI events — the single `msgs.count` from `reconcile_replay!` covers it).
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.AgentMessage)
    msg = AgentMsg(string(uuid4()), m.text)
    lock(model.lock) do; push!(model.msgs_store, msg); end
    finalize_agent(model.chat_session, msg)
end
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.UserMessage)
    if is_summary_text(m.text)
        msg = SummaryMsg(m.text)
        lock(model.lock) do; push!(model.msgs_store, msg); end
        append_summary(model.chat_session, msg)
    else
        msg = UserMsg(m.text)
        lock(model.lock) do; push!(model.msgs_store, msg); end
        append_user(model.chat_session, msg)
    end
end
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.ToolCall)
    isempty(m.content) || persist_tool_content!(model.chat_dir, m)
    # Pick the typed BonitoTeam variant per ACP subtype. Replay always lands
    # as a finished call (no live updates afterwards), so `finished_at = now`.
    msg = replayed_tool_msg(m)
    lock(model.lock) do; push!(model.msgs_store, msg); end
    msg.status in ("completed", "failed") && append_tool(model.chat_session, msg)
end
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.TodoWriteCall)
    msg = TodoListMsg(string(uuid4()), collect(PlanEntry, m.entries),
                      time(), time(), nothing)
    lock(model.lock) do; push!(model.msgs_store, msg); end
    append_plan(model.chat_session, msg)
end
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.Plan)
    msg = TodoListMsg(string(uuid4()), collect(PlanEntry, m.entries),
                      time(), time(), nothing)
    lock(model.lock) do; push!(model.msgs_store, msg); end
    append_plan(model.chat_session, msg)
end

# Mirror of `build_tool_msg` for the replay path: no `chat`, finished_at
# stamped now so the timer doesn't tick. The typed variants persist their
# subtype-specific fields too (so e.g. a replayed background bash still
# rendered the right way).
# Replayed live app — content is on disk (so the app id is available now); same
# type-driven recognition as the live path (`is_bonito_app`).
replayed_bonito_app_msg(tc, server) =
    BonitoAppMsg(tc.id, "bonito_app", tc.title, tc.status,
                 content_summary("bonito_app", tc.content),
                 time(), time(), server,
                 something(find_app_reference(tc.content), ""), nothing)

replayed_tool_msg(tc::AgentClientProtocol.GenericTool) =
    is_bonito_app(tc) ? replayed_bonito_app_msg(tc, "") :
    GenericToolMsg(tc.id, tc.kind, tc.name, tc.title, tc.status,
                   content_summary(tc.kind, tc.content),
                   time(), time(), nothing)
replayed_tool_msg(tc::AgentClientProtocol.BashCall) =
    BashToolMsg(tc.id, tc.kind, tc.title, tc.status,
                content_summary(tc.kind, tc.content),
                time(), time(),
                tc.command, tc.run_in_background,
                "", 0, false, "", nothing)   # bg fields: history → already done
replayed_tool_msg(tc::AgentClientProtocol.TaskCall) =
    TaskToolMsg(tc.id, tc.kind, tc.title, tc.status,
                content_summary(tc.kind, tc.content),
                time(), time(),
                tc.description, tc.run_in_background, tc.task_name, nothing)
replayed_tool_msg(tc::AgentClientProtocol.MCPCall) =
    is_bonito_app(tc) ? replayed_bonito_app_msg(tc, tc.server) :
    MCPToolMsg(tc.id, tc.kind, tc.title, tc.status,
               content_summary(tc.kind, tc.content),
               time(), time(),
               tc.server, tc.tool_name, nothing)

function reconcile_replay!(model::ChatModel, replay)
    candidates = filter(keep_in_history, replay)
    adopt = lock(model.lock) do
        existing = model.msgs_store
        isempty(existing) ? candidates :
            candidates[(longest_matched_prefix(existing, candidates) + 1):end]
    end
    isempty(adopt) && return nothing
    for m in adopt
        adopt_replayed!(model, m)
    end
    chat_emit(model, Dict{String,Any}(
        "type" => "msgs.count", "n" => length(model.msgs_store)))
    @info "reconciled claude history" project_id = model.project_id adopted = length(adopt)
    return nothing
end

# ── DOM building (split into header / messages / input / banner) ──────────
# ── Header metadata line ─────────────────────────────────────────────────────
# One `header_pill` method per metadata kind in `session_meta` — future agents
# add a struct + a method here, never touch the header skeleton. Display-only:
# plain text spans (tooltip carries the full description), joined with " · "
# on a second header line below the title/sync row.

function pill_tooltip(o::AgentClientProtocol.ConfigOption)
    c = AgentClientProtocol.current_choice(o)
    c === nothing && return "$(o.name): $(o.current_value)"
    isnothing(c.description) || isempty(c.description) ?
        "$(o.name): $(c.name)" : "$(o.name): $(c.name) — $(c.description)"
end

# The model label ("Opus 4.7 with 1M context") is self-explanatory; the other
# options need their name as a prefix to read well ("mode: Default").
header_pill(o::AgentClientProtocol.ConfigOption) =
    DOM.span(o.category == "model" ? AgentClientProtocol.pill_label(o) :
             "$(lowercase(o.name)): $(AgentClientProtocol.pill_label(o))";
        class = "bt-header-meta-item", title = pill_tooltip(o))
# Fallback so an unknown meta kind degrades to its string form, not an error.
header_pill(x) = DOM.span(string(x); class = "bt-header-meta-item")

# Display policy: which meta items make it into the header line. Of claude's
# config options only the MODEL is shown — the agent reports mode/effort as
# unhelpful "default"s (and we won't fire extra RPCs just to fix a label).
# All of them stay parsed on `session_meta` for future use; future meta kinds
# default to visible.
show_in_header(o::AgentClientProtocol.ConfigOption) = o.category == "model"
show_in_header(::Any) = true

# The most informative item (the model) leads the line.
meta_order(x) = x isa AgentClientProtocol.ConfigOption && x.category == "model" ? 0 : 1

function header_meta_line(items)
    shown = sort(filter(show_in_header, collect(Any, items)); by = meta_order)
    isempty(shown) && return DOM.span()
    parts = Any[]
    for (i, x) in enumerate(shown)
        i > 1 && push!(parts, " · ")
        push!(parts, header_pill(x))
    end
    DOM.div(parts...; class = "bt-header-meta")
end

function chat_header(session::Bonito.Session, model::ChatModel, sync_modal_state::Observable)
    state = model.state
    project_id = model.project_id
    cwd = model.cwd

    status_dot = map(model.session_alive) do alive
        DOM.span(""; class=alive ? "bt-dot bt-dot-online" : "bt-dot bt-dot-offline",
            title=alive ? "session live" : "session ended")
    end

    # Session config (model / mode / effort …) as a plain-text second header
    # line; re-renders whenever the agent reports a change (bring-up,
    # config_option_update).
    meta_line = map(header_meta_line, model.session_meta)

    sync_status = Observable("")
    sync_button = DOM.button(map(s -> isempty(s) ? "Sync" : s, sync_status);
        class="bt-header-sync",
        title="Pull this project from the worker to the server",
        onclick=js"event => $(sync_status).notify('__click__')")
    on(session, sync_status) do s
        s == "__click__" || return
        sync_status[] = ""
        isempty(project_id) && (sync_status[] = "no project bound"; return)
        handle_chat_sync_click(state, project_id, sync_status)
    end

    # Cross-worker sync: only present when this project has a same-named
    # sibling on another worker. Clicking inspects both sides and opens the
    # comparison modal (see `render_sync_modal`). Computed at header build
    # time — re-navigating refreshes it if siblings appear/disappear.
    sibs = isempty(project_id) ? ProjectInfo[] : same_name_siblings(state, project_id)
    xsync_control = if isempty(sibs)
        DOM.span()
    else
        other = first(sibs)
        other_label = haskey(state.workers[], other.worker_id) ?
            state.workers[][other.worker_id].name : other.worker_id
        xsync_status = Observable("")
        xsync_button = DOM.button(map(s -> isempty(s) ? "⇄ $other_label" : s, xsync_status);
            class="bt-header-sync",
            title="Compare and sync this project with $other_label",
            onclick=js"event => $(xsync_status).notify('__click__')")
        on(session, xsync_status) do s
            s == "__click__" || return
            xsync_status[] = "comparing…"
            cur = state.projects[][project_id]
            @async begin
                try
                    cmp = compare_projects(state, cur, other)
                    sync_modal_state[] = (current = cur, other = other, comparison = cmp)
                    safe_set!(xsync_status, "")
                catch e
                    @warn "cross-worker compare failed" exception=e
                    safe_set!(xsync_status, "compare failed")
                end
            end
        end
        xsync_button
    end

    # Header-level restart: the ONE affordance for restarting the ACP session.
    # Previously a banner showed only on session death + had its own button;
    # that banner used Bonito.Button inside a conditional `map(…)` output,
    # which re-rendered the DOM each `session_alive` toggle and on some
    # cycles left the click handler bound to an orphaned element — "click
    # does nothing". The permanent header button avoids that entirely:
    # plain `DOM.button` + Observable click (same pattern as the sync
    # buttons above), one DOM element for the lifetime of the chat.
    #
    # When the session dies, the button gains `bt-header-restart-dead` →
    # CSS pulses it red and the title flips to the error message, so a
    # failure is visible without a separate banner. Mid-restart the label
    # reads "Restarting…" so the click is acknowledged synchronously.
    restart_status = Observable("")
    restart_label  = map(s -> isempty(s) ? "Restart" : s, restart_status)
    restart_class  = map(model.session_alive) do alive
        alive ? "bt-header-restart" : "bt-header-restart bt-header-restart-dead"
    end
    restart_title  = map(model.session_alive, model.last_error) do alive, err
        alive  && return "Stop and respawn the agent process for this chat"
        isempty(err) ? "Session ended — click to reconnect" :
                       "Session ended: $err — click to reconnect"
    end
    restart_button = DOM.button(restart_label;
        class   = restart_class,
        title   = restart_title,
        onclick = js"event => $(restart_status).notify('__click__')")
    on(session, restart_status) do s
        s == "__click__" || return
        restart_status[] = "Restarting…"
        @async begin
            try
                restart_chat_session!(model)
            finally
                safe_set!(restart_status, "")
            end
        end
    end

    # No back arrow — the unified app's sidebar Home icon is the way home.
    # The session-config meta line renders as a second row BELOW the main one.
    DOM.div(
        DOM.div(
            status_dot,
            DOM.div(
                DOM.span(basename(rstrip(cwd, '/')); title=cwd),
                class="bt-header-title"),
            xsync_control,
            sync_button,
            restart_button;
            class="bt-header-row"),
        meta_line;
        class="bt-header")
end

# Icons live as standalone SVG files under assets/icons/ and ship as
# Bonito.Asset (hashed URL, served by the same machinery as bonitoteam.js).
# Colors are baked into the SVGs since <img> doesn't inherit currentColor.
const SEND_ICON = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "icons", "send.svg"))
const STOP_ICON = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "icons", "stop.svg"))
icon_img(asset, alt) = DOM.img(src=asset, alt=alt, draggable="false",
    style=Styles("pointer-events" => "none",
        "user-select" => "none"))

function chat_input_area(::Session, ::ChatModel)
    # Pure DOM. The input widgets are entirely JS-owned: `BonitoChat`
    # (assets/bonitoteam.js → `_setupInputs`) attaches capture-phase
    # click + Enter listeners, reads the textarea on submit, posts a
    # `{type: 'send', text, attachments}` event over `comm`, and clears
    # the textarea locally. The stop button posts `{type: 'cancel'}`.
    # On the Julia side, those land as `SendCommand` / `CancelCommand`
    # in `chat_dispatch!` — there's no Observable round-trip for the
    # textarea value or for clearing it, which removes a whole class of
    # echo-bug ("server-echoed stale value overwrites user keystroke").
    text_input = DOM.textarea(
        placeholder="Message…",
        title="Enter to send  ·  Shift+Enter for newline",
        class="bt-text-input", rows=1,
        oninput=js"""event => {
            event.target.style.height = 'auto';
            event.target.style.height = Math.min(event.target.scrollHeight, 120) + 'px';
        }""")
    send_btn = DOM.button(icon_img(SEND_ICON, "Send"); type="button",
        class="bt-send-btn", title="Send (Enter)")
    stop_btn = DOM.button(icon_img(STOP_ICON, "Stop"); type="button",
        class="bt-stop-btn", title="Stop generation")
    DOM.div(DOM.div(text_input, send_btn, stop_btn, class="bt-input-row");
        class="bt-input-area")
end

# JS counterpart. `connect(node, comm)` is called by the inline init JS in
# `jsrender(::ChatModel)` below — same pattern as BonitoBook's MonacoEditor.
const ChatLib = Bonito.ES6Module(joinpath(@__DIR__, "..", "assets", "bonitoteam.js"))

# ── Image attachments ─────────────────────────────────────────────────────
# The JS input area collects pasted / dropped images locally and ships them
# as a base64 + mime payload in the "send" comm event. This helper saves
# each one to `<cwd>/.bt-attachments/<ts>-<short>.<ext>` so:
#   1. The bubble's UserMsg text carries a `[attached: …]` reference that
#      survives chat.md replay (claude can `Read` the file on resume).
#   2. The worker mirror has the same file when send_file_to_worker! lands.
#   3. The multimodal blocks let claude see the image *right now* without
#      doing an extra Read tool call.
const ATTACHMENT_DIR_NAME = ".bt-attachments"

# Map mime types to the canonical file extension we save under. Anything
# not in this table is rejected (caller raises) — silently saving foreign
# blobs as `.bin` would surprise users on replay.
const ATTACHMENT_EXTENSIONS = Dict(
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/jpg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp",
    "image/svg+xml" => "svg",
)

# 5 MB per image. ACP / claude will balk much later than this, but we want
# a clear error path before we burn bandwidth sending bytes downstream.
const ATTACHMENT_MAX_BYTES = 5 * 1024 * 1024

function attachment_ext(mime::AbstractString)
    ext = get(ATTACHMENT_EXTENSIONS, lowercase(String(mime)), nothing)
    ext === nothing || return ext
    allowed = join(sort(collect(keys(ATTACHMENT_EXTENSIONS))), ", ")
    error("Unsupported attachment mime type: $mime (allowed: $allowed)")
end

# Save one attachment to disk under the project's `.bt-attachments/` dir.
# Returns the path RELATIVE to `model.cwd` so it round-trips into the
# UserMsg text as a portable reference. The absolute path is the second
# return value (used by the worker push).
function save_attachment(model::ChatModel,
    mime::AbstractString,
    bytes::AbstractVector{UInt8})
    length(bytes) <= ATTACHMENT_MAX_BYTES ||
        error("Attachment too large: $(length(bytes)) bytes > $(ATTACHMENT_MAX_BYTES)")
    ext = attachment_ext(mime)
    ts = Dates.format(now(UTC), "yyyy-mm-dd_HHMMSS")
    short = string(uuid4())[1:8]
    rel = joinpath(ATTACHMENT_DIR_NAME, "$(ts)_$(short).$(ext)")
    abs = joinpath(model.cwd, rel)
    mkpath(dirname(abs))
    write(abs, bytes)
    return rel, abs
end

# Best-effort push of an attachment from the server mirror to the worker
# mirror. Failure here doesn't abort the send — the file still exists on
# the server, so a subsequent full sync (or move) will replicate it. We
# only push when there's a project bound and the worker is connected.
function push_attachment_to_worker(model::ChatModel, rel_path::AbstractString)
    pid = model.project_id
    isempty(pid) && return
    proj = get(model.state.projects[], pid, nothing)
    proj === nothing && return
    haskey(model.state.worker_control_ws, proj.worker_id) || return
    src = joinpath(model.cwd, rel_path)
    dst = joinpath(proj.worker_path, rel_path)
    try
        send_file_to_worker!(model.state, proj.worker_id, src, dst;
            handoff_timeout=15.0)
    catch e
        @warn "attachment push to worker failed" worker = proj.worker_id rel_path exception = e
    end
    return
end

# Parse JS-side attachment payloads ({mime, data, filename?}) into a
# (display_text_suffix, [ImageAttachment]) pair. `attachments` may be
# empty (no-op). Each entry's base64 `data` field is decoded once.
function process_attachments!(model::ChatModel, attachments)
    attachments isa AbstractVector || return ("", AgentClientProtocol.ImageAttachment[])
    isempty(attachments) && return ("", AgentClientProtocol.ImageAttachment[])

    suffix_lines = String[]
    blocks = AgentClientProtocol.ImageAttachment[]
    for a in attachments
        a isa AbstractDict || continue
        mime = String(get(a, "mime", ""))
        b64 = String(get(a, "data", ""))
        (isempty(mime) || isempty(b64)) && continue
        bytes = Base64.base64decode(b64)
        rel, _ = save_attachment(model, mime, bytes)
        push_attachment_to_worker(model, rel)
        push!(blocks, AgentClientProtocol.ImageAttachment(bytes, mime))
        push!(suffix_lines, "  - $(rel)")
    end
    suffix = isempty(suffix_lines) ? "" :
             "\n\n[attached files in this message]\n" * join(suffix_lines, "\n")
    return suffix, blocks
end

# JS-originated commands sent over the `comm` Observable, modelled as a
# sum type so each command kind is parsed once and routed via dispatch.
# Adding a new JS command = add a struct + a `parse_chat_command` arm +
# a `handle_command!` method. No further branching in the entry point.
abstract type ChatCommand end

# Wire `{type: "init"}` — browser is fresh and asks for the current
# message count to bootstrap virtual scroll.
struct InitCommand <: ChatCommand end

# Wire `{type: "msgs.request", range: [s, e]}` — JS virtual-scroll wants
# messages [s..e] (zero-based, inclusive) for the visible window.
struct MsgsRequestCommand <: ChatCommand
    s::Int
    e::Int
end

# Wire `{type: "tool.render", id: <tool_id>}` — user expanded the tool
# row; Julia mounts the rich body (Monaco / DiffEditor) via `dom_in_js`.
struct ToolRenderCommand <: ChatCommand
    tool_id::String
end

# Wire `{type: "thought.render", id: <thought_id>}` — same shape for the
# lazy-loaded thought body.
struct ThoughtRenderCommand <: ChatCommand
    thought_id::String
end

# Wire `{type: "send", text, attachments: [...]}` — user submitted a
# message (possibly with image attachments). `attachments` is the raw
# list of `{mime, data, ...}` dicts shipped by JS.
struct SendCommand <: ChatCommand
    text::String
    attachments::Vector{Any}
end

# Wire `{type: "cancel"}` — user clicked stop. Cancels the active ACP
# turn (notification, non-blocking).
struct CancelCommand <: ChatCommand end

# Wire `{type: "stop_tool", id: "<tool_id>"}` — user clicked the ⊗ on a
# taskbar slot. Background bash / Task run on the worker outside of any
# ACP-defined cancel primitive (the SDK doesn't surface a KillShell tool;
# only `TaskStop` exists). The handler routes per concrete `ToolMsg`
# subtype — see `request_tool_stop!` below for the per-variant strategy.
struct StopToolCommand <: ChatCommand
    tool_id::String
end

# Used when `msg` doesn't match any known shape — handler is a no-op.
# Lets `chat_dispatch!` stay total without `return` plumbing.
struct UnknownCommand <: ChatCommand end

function parse_chat_command(msg::AbstractDict)::ChatCommand
    type = String(get(msg, "type", ""))
    if type == "init"
        return InitCommand()
    elseif type == "msgs.request"
        rng = get(msg, "range", nothing)
        rng isa AbstractVector && length(rng) == 2 || return UnknownCommand()
        return MsgsRequestCommand(Int(rng[1]), Int(rng[2]))
    elseif type == "tool.render"
        return ToolRenderCommand(String(get(msg, "id", "")))
    elseif type == "thought.render"
        return ThoughtRenderCommand(String(get(msg, "id", "")))
    elseif type == "send"
        atts = get(msg, "attachments", Any[])
        return SendCommand(String(get(msg, "text", "")),
            atts isa AbstractVector ? collect(atts) : Any[])
    elseif type == "cancel"
        return CancelCommand()
    elseif type == "stop_tool"
        id = String(get(msg, "id", ""))
        return isempty(id) ? UnknownCommand() : StopToolCommand(id)
    end
    return UnknownCommand()
end

# One `handle_command!` method per concrete `ChatCommand` subtype. The
# `session` argument is needed for `dom_in_js` (tool body rendering); the
# other handlers ignore it but take it uniformly so the dispatch shape
# stays predictable.

handle_command!(::ChatModel, ::Session, ::UnknownCommand) = nothing

handle_command!(model::ChatModel, ::Session, ::InitCommand) =
    chat_emit(model, Dict{String,Any}(
        "type" => "msgs.count", "n" => length(model.msgs_store)))

function handle_command!(model::ChatModel, ::Session, cmd::MsgsRequestCommand)
    store = model.msgs_store
    n = length(store)
    s = clamp(cmd.s, 0, n - 1)
    e = clamp(cmd.e, 0, n - 1)
    s > e && return nothing
    batch = [msg_to_dict(store[i], model.chat_dir) for i in (s+1):(e+1)]
    chat_emit(model, Dict{String,Any}(
        "type" => "msgs.range", "start" => s, "msgs" => batch))
    return nothing
end

function handle_command!(model::ChatModel, session::Session, cmd::ToolRenderCommand)
    isempty(cmd.tool_id) && return nothing
    idx = findfirst(m -> m isa ToolMsg && m.id == cmd.tool_id, model.msgs_store)
    idx === nothing && return nothing
    msg = model.msgs_store[idx]
    # Run the render OFF the comm task. `render_tool_body` for a `bonito_app`
    # ToolMsg mounts a `RemoteAppPlaceholder` whose `jsrender` calls
    # `embed_remote_app` → `call_ctrl(eb, "delegate")`, which blocks up to 30 s
    # on the worker bridge. If we ran it inline, that 30 s would stop EVERY
    # other chat event for this tab (scroll fetches, sends, tab switches) until
    # the timeout — multiple stuck tools compound to minutes of frozen UI.
    #
    # Each render is fire-and-forget — no return value the comm handler needs.
    # Concurrent renders are safe: `call_ctrl` uses per-request channels +
    # serial WS writes under `eb.wlock`, and `dom_in_js` opens its own
    # subsession per call. The catch keeps a stale tool id / dead bridge from
    # leaking out as an uncaught task error.
    Base.errormonitor(@async try
        body = render_tool_body(model.state, msg,
            model.cwd, model.chat_dir; project_id=model.project_id)
        # `_btToolSlot` (bonitoteam.js) also finds slots on nodes the virtual
        # scroll holds DETACHED (cache window / prefetch) — a plain
        # document.querySelector misses those and the body would be stuck on
        # "loading…". Fallback covers a not-yet-loaded chat module.
        Bonito.dom_in_js(
            session,
            body,
            js"""(elem) => {
    const slot = window._btToolSlot ? window._btToolSlot($(cmd.tool_id)) :
        document.querySelector(
            '.bt-tool-body[data-tool-id="' + $(cmd.tool_id) + '"]');
    if (slot) { slot.innerHTML = ''; slot.appendChild(elem); }
}"""
        )
    catch e
        @warn "tool render failed" tool_id = cmd.tool_id exception = e
        # Replace the stale "loading…" with a visible failure so the user knows
        # the body is gone (typically: the eval bridge was rebuilt since this
        # turn, so the `shown_app:` id is no longer registered on the worker).
        # We `dom_in_js` a tiny static node — no RemoteAppPlaceholder, no
        # control round-trip, can't repeat the failure.
        try
            Bonito.dom_in_js(
                session,
                DOM.div("tool body unavailable: $(sprint(showerror, e))";
                        class = "bt-tool-error"),
                js"""(elem) => {
    const slot = window._btToolSlot ? window._btToolSlot($(cmd.tool_id)) :
        document.querySelector(
            '.bt-tool-body[data-tool-id="' + $(cmd.tool_id) + '"]');
    if (slot) { slot.innerHTML = ''; slot.appendChild(elem); }
}""")
        catch
        end
    end)
    return nothing
end

function handle_command!(model::ChatModel, ::Session, cmd::ThoughtRenderCommand)
    isempty(cmd.thought_id) && return nothing
    idx = findfirst(m -> m isa ThoughtMsg && m.id == cmd.thought_id, model.msgs_store)
    idx === nothing && return nothing
    html = sprint(show, MIME("text/html"),
        Markdown.parse(model.msgs_store[idx].text))
    chat_emit(model, Dict{String,Any}("type" => "thought.body",
        "id" => cmd.thought_id, "html" => html))
    return nothing
end

function handle_command!(model::ChatModel, ::Session, cmd::SendCommand)
    # `process_attachments!` decodes user-supplied base64 and writes files
    # to disk. Any failure (bad mime, oversize image, IO error) becomes an
    # `attach_error` event the JS side shows inline — we deliberately
    # surface the showerror message rather than abort silently.
    suffix, blocks = try
        process_attachments!(model, cmd.attachments)
    catch e
        chat_emit(model, Dict{String,Any}(
            "type" => "attach_error", "error" => sprint(showerror, e)))
        return nothing
    end
    display_text = isempty(strip(cmd.text)) && !isempty(blocks) ?
                   "(image attached)" * suffix :
                   cmd.text * suffix
    # No server-side ack — JS already cleared the input optimistically on
    # submit. Errors (attachment-rejection above, or ACP send failures
    # surfaced by `send_message!`'s downstream code) flow back through
    # their own events.
    send_message!(model, UserMsg(display_text); images=blocks)
    return nothing
end

# A re-cancel only escalates to a force-close after the agent has had a real
# chance to honor the first one. Set well past the worst observed cold-start
# honor latency (warm ≈ 0.1s, cold-fresh ≈ 3.9s, cold-resumed ≈ 6–18s) so an
# impatient double-click never force-closes a turn that's about to honor.
const CANCEL_ESCALATE_WAIT = 20.0

function handle_command!(model::ChatModel, ::Any, ::CancelCommand)
    # Off-band, instant: cancel is a lone ACP notification, not a chat-state
    # mutation, so it never goes through the `run_chat!` consumer. Reading
    # `model.client[]` is a single-Ref read. (Session arg is unused here — typed
    # `::Any` so the cancel path is unit-testable without a live Bonito.Session.)
    c = model.client[]
    c === nothing && return nothing
    s = shared(model)

    # A graceful `session/cancel` makes ACP close the active turn's update
    # channel; the `prompt!` loop ends, `run_turn!`'s `finally` clears
    # `busy_active`, and the partial bubble is sealed. We do NOT force-close on a
    # timer: the agent's honor latency is large + unbounded on a cold/resumed turn,
    # so a timer races it, and a premature mid-turn teardown leaves an orphaned
    # tool_use that wedges every future resume (a doom loop). A clean cancel always
    # honors eventually.
    #
    # The hammer is reserved for a genuinely-wedged agent (resumed onto an
    # already-orphaned tool call, ignores cancel, connection still alive so no
    # `ConnectionClosed` fires) — and it's the USER's call: cancel AGAIN, after the
    # agent's had a real chance (≥ CANCEL_ESCALATE_WAIT) and it's STILL busy. That
    # distinguishes a deliberate "force it" from both an impatient double-click
    # (< the wait → graceful re-send) and a slow-but-honoring cold cancel.
    now      = time()
    first_at = (@atomic c.conn.cancel_at)              # 0.0 ⇒ first cancel this turn
    escalate = first_at > 0 && (now - first_at) ≥ CANCEL_ESCALATE_WAIT && s.busy_active[]
    first_at > 0 || (@atomic c.conn.cancel_at = now)   # stamp the first cancel
    AgentClientProtocol.cancel!(c)                      # graceful (idempotent re-send)
    if escalate
        @warn "deliberate re-cancel: agent not honoring — force-closing" project_id = model.project_id
        s.last_error[] = "The agent didn't respond to cancel; session stopped. Click Restart to reconnect."
        try
            close(c)
        catch e
            @warn "force-close after cancel failed" exception = e
        end
    end
    return nothing
end

# ── Stop background tool ───────────────────────────────────────────────────
# Find the tool by id, then dispatch on its concrete subtype so each tool
# family decides its own honest stop strategy. We deliberately don't fake
# anything: the SDK has no `KillShell`, only `TaskStop` for subagents and
# `BashOutput` polling for background bashes. So we route a synthetic user
# message asking Claude to stop the thing — visible in the chat history,
# honest about what the agent is being asked to do. The slot keeps pulsing
# until the actual tool transitions to terminal status (no fake "Stopping…"
# state that might never resolve).
function handle_command!(model::ChatModel, ::Any, cmd::StopToolCommand)
    isempty(cmd.tool_id) && return nothing
    target = lock(model.lock) do
        idx = findfirst(m -> m isa ToolMsg && m.id == cmd.tool_id, model.msgs_store)
        idx === nothing ? nothing : model.msgs_store[idx]
    end
    target === nothing && return nothing
    request_tool_stop!(model, target)
    return nothing
end

# Per-variant: each tool kind we surface in the taskbar gets its own arm.
# The default (`::ToolMsg`) is a no-op — we'd never have shown a slot for a
# one-shot tool, so a stop click on it is the user clicking a transient UI
# affordance after the tool already finished. Silent ignore is correct.
request_tool_stop!(::ChatModel, ::ToolMsg) = nothing

function request_tool_stop!(model::ChatModel, t::BashToolMsg)
    t.is_background || return
    cmd_snippet = isempty(t.command) ? t.title : t.command
    text = "Please stop the background bash command immediately. " *
           "Tool id: `$(t.id)`. Command: `$(cmd_snippet)`. " *
           "Use the most direct mechanism the SDK provides; if none does, " *
           "just acknowledge the cancellation so the chat reflects it."
    send_message!(model, UserMsg(text))
    return nothing
end

function request_tool_stop!(model::ChatModel, t::TaskToolMsg)
    t.is_background || return
    name_clause = t.task_name === nothing ? "" : " (name: `$(t.task_name)`)"
    text = "Please stop the background task immediately. " *
           "Tool id: `$(t.id)`$(name_clause). " *
           "Call `TaskStop` with that id."
    send_message!(model, UserMsg(text))
    return nothing
end

# Thin entry point for the per-session `comm` listener wired up in
# `jsrender(::ChatModel)`. Parses once, dispatches once. The
# `session::Session` closure binding flows through unchanged because
# `handle_command!(::Any, ::Any, ::ToolRenderCommand)` needs it for
# `dom_in_js`.
chat_dispatch!(model::ChatModel, session::Session, msg::AbstractDict) =
    handle_command!(model, session, parse_chat_command(msg))

# `ChatModel` is a Bonito component. Per the convention, the shared instance
# (the one in `state.chat_models[pid]`) should never be rendered directly —
# we make a per-session view via `copy(model)` and bind handlers to *that*
# session. The shared bits (msgs_store, ACP client, lock) are still shared
# (sessions cooperate); the Observable `comm` is a connected child so each
# tab's JS bridge GC's cleanly when the tab closes.
function Bonito.jsrender(session::Session, shared_model::ChatModel)
    # `model` is the per-session view: its `comm`, `session_alive`, and
    # `last_error` are connected children of `shared_model`'s, so the JS
    # bridge stays scoped to this tab. Rendering reads from `model`.
    # Handlers reach the shared parent via `shared(m)` so writes
    # broadcast to every connected tab — see the `parent` field doc on
    # ChatModel.
    model = copy(shared_model, session)

    # Single per-session dispatcher. `chat_dispatch!` itself does
    # `shared(m)` for any state-mutating writes, so passing `model` is
    # safe AND gives the handler access to `session` (for `dom_in_js`).
    on(session, model.comm) do msg
        chat_dispatch!(model, session, msg)
    end

    # Spinner class follows the shared busy_active observable so the
    # `bt-busy-active` class is set correctly on remount — the comm
    # `busy_start` / `busy_end` events only forward to FUTURE bridges,
    # so a tab that opens mid-prompt would otherwise miss the start.
    busy_class = map(b -> b ? "bt-busy bt-busy-active" : "bt-busy", model.busy_active)

    messages_container = DOM.div(
        DOM.div(class="bt-spacer-top"),
        DOM.div(class="bt-spacer-bottom"),
        # Busy dots + transient "reasoning…" indicator live INSIDE the
        # scroll content, after the bottom spacer (message nodes insert
        # before it) and before the overscroll tail — so they show up
        # directly under the last message, not below the tail's empty
        # space down by the composer. Like the tail, they're plain
        # content the virtual-scroll geometry never tracks.
        DOM.div(DOM.div(class="bt-busy-dot"),
            DOM.div(class="bt-busy-dot"),
            DOM.div(class="bt-busy-dot");
            class=busy_class),
        # Idle indicator — visible when the busy dots are NOT (CSS
        # adjacent-sibling rule on `.bt-busy`, so it MUST stay the dots'
        # immediate next sibling) AND the chat has agent replies on display
        # (`bt-waiting-on`, toggled by `_updateWaiting` in bonitoteam.js).
        # The slot under the last message thus says what the agent is
        # doing: dots/reasoning mid-turn, waiting between turns — and
        # nothing at all in a chat that hasn't been asked anything yet.
        DOM.div("Waiting for your next instruction"; class="bt-waiting"),
        # Transient "reasoning…" indicator (toggled by the `thinking` comm
        # event in bonitoteam.js). Hidden until an agent thought is in flight.
        DOM.div("💭 reasoning…"; class="bt-thinking"),
        # Overscroll tail: empty space the user can scroll into below the
        # last message (~30% of the pane; JS sizes it from clientHeight).
        DOM.div(class="bt-messages-tail");
        class="bt-messages")

    init_script = js"""
        $(ChatLib).then(lib => lib.connect($(messages_container), $(model.comm)))
    """

    # Cross-worker sync modal state + apply. `nothing` ⇒ hidden; otherwise
    # `(current, other, comparison)`. `on_apply(src, dst)` runs the
    # directional overwrite in a Task and closes the modal when done.
    sync_modal_state = Observable{Union{Nothing,NamedTuple}}(nothing)
    sync_modal = render_sync_modal(session, model.state, sync_modal_state,
        (src, dst) -> @async begin
            try
                sync_across_workers!(model.state, src, dst)
            catch e
                @warn "cross-worker sync failed" src=src.name dst=dst.name exception=e
            finally
                sync_modal_state[] = nothing
            end
        end)

    Bonito.jsrender(session, DOM.div(
        chat_header(session, model, sync_modal_state),
        sync_modal,
        messages_container,
        init_script,
        # Taskbar — floats over the messages area, top-left of the chat panel.
        # Populated entirely client-side by scanning live tool/todo pills (see
        # `setupTaskbar` in bonitoteam.js); the server never tracks slot state.
        DOM.div(class = "bt-taskbar"),
        chat_input_area(session, model),
        # Toolbar below the composer. Populated entirely client-side by
        # BonitoChat (`noteType`): one show/hide checkbox per message type the
        # first time that type occurs. Sized to host future controls too.
        DOM.div(class = "bt-chat-toolbar"),
        # NOTE: there is deliberately NO mount curtain here. The dashboard's
        # load overlay (`chat_waiting_view`, sidebar.jl) covers this pane
        # from the moment the user clicks until the chat module reports the
        # geometry settled (`bt-chat-settling` / `bt-chat-settled` events
        # from `_startSettle` in bonitoteam.js) — one continuous loading
        # surface instead of the old bring-up pane → bare gap → per-chat
        # curtain relay.
        class="bt-app"))
end
