# bonitoteam.js is now an ES6 module — see `ChatLib` further down. It's
# loaded lazily by the `Bonito.ES6Module(...).then(...)` interpolation
# inside ChatModel's jsrender, NOT injected as a classic <script> tag.
# Loading it as a classic script would syntax-error on the `export`
# statements.

# Message types
abstract type ChatMsg end

mutable struct UserMsg <: ChatMsg
    text::String
end

mutable struct AgentMsg <: ChatMsg
    id::String
    text::String
end

mutable struct ToolMsg <: ChatMsg
    id::String
    kind::String
    title::String
    status::String
    summary::String           # cached header summary; full content lives on disk
end

mutable struct ThoughtMsg <: ChatMsg
    id::String
    text::String
end

struct PlanMsg <: ChatMsg
    entries::Vector{PlanEntry}
end

# Tool kind → icon
const TOOL_ICONS = Dict(
    "read"    => "📄",
    "edit"    => "✏️",
    "delete"  => "🗑️",
    "move"    => "📦",
    "search"  => "🔍",
    "execute" => "▶",
    "think"   => "💭",
    "fetch"   => "🌐",
    "other"   => "⚙",
)

tool_icon(kind) = get(TOOL_ICONS, kind, "⚙")

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
            sign_str  = total_delta > 0 ? "+$total_delta" : string(total_delta)
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
function tool_header_dict(m::ToolMsg, chat_dir::AbstractString = "")
    d = Dict{String,Any}(
        "type"    => "tool",
        "id"      => m.id,
        "kind"    => m.kind,
        "icon"    => tool_icon(m.kind),
        "title"   => m.title,
        "status"  => m.status,
        "summary" => m.summary,
    )
    if m.kind == "edit" && !isempty(chat_dir)
        prev = render_edit_preview(chat_dir, m.id)
        prev === nothing || (d["preview"] = prev)
    end
    return d
end

# Same shape used by msg_to_dict so the JS virtual-scroll renderer treats
# all messages uniformly. The `cwd` argument is only consulted for ToolMsg
# (to render the edit preview); other variants ignore it.
msg_to_dict(m::UserMsg, _chat_dir::AbstractString = "") =
    Dict{String,Any}("type" => "user", "text" => m.text)

function msg_to_dict(m::AgentMsg, _chat_dir::AbstractString = "")
    html = sprint(show, MIME("text/html"), Markdown.parse(m.text))
    Dict{String,Any}("type" => "agent", "id" => m.id, "html" => html)
end

msg_to_dict(m::ToolMsg, chat_dir::AbstractString = "") = tool_header_dict(m, chat_dir)

# Thoughts are lazy-loaded: header carries only id + a size hint. JS asks for
# the body via requestThoughtRender(id) when the user expands the <details>.
# Avoids shipping potentially huge thinking transcripts on every range fetch.
function msg_to_dict(m::ThoughtMsg, _chat_dir::AbstractString = "")
    n = count('\n', m.text) + 1
    Dict{String,Any}("type" => "thought", "id" => m.id,
                     "summary" => "$n $(n == 1 ? "line" : "lines")")
end

function msg_to_dict(m::PlanMsg, _chat_dir::AbstractString = "")
    rows = join(["""<div class="bt-plan-entry">
        <span class="bt-plan-status">$(e.status == "completed" ? "✓" : e.status == "in_progress" ? "▶" : "○")</span>
        <span>$(e.content)</span></div>""" for e in m.entries])
    Dict{String,Any}("type" => "plan", "html" => rows)
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

    d         = first(diffs)
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
    ext == ".jl"                       && return "julia"
    ext in (".py", ".pyw")             && return "python"
    ext in (".js", ".mjs", ".cjs")     && return "javascript"
    ext in (".ts", ".tsx")             && return "typescript"
    ext in (".md", ".markdown")        && return "markdown"
    ext in (".html", ".htm")           && return "html"
    ext == ".css"                      && return "css"
    ext == ".json"                     && return "json"
    ext in (".yml", ".yaml")           && return "yaml"
    ext == ".toml"                     && return "toml"
    ext in (".sh", ".bash", ".zsh")    && return "shell"
    ext in (".rs",)                    && return "rust"
    ext in (".go",)                    && return "go"
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
        language            = lang,
        readOnly            = true,
        automaticLayout     = false,
        scrollBeyondLastLine = false,
        lineNumbers         = "off",
        minimap             = Dict(:enabled => false),
        js_init_func        = MONACO_RESIZE_INIT,
    )
end

# Render a single tool-content text block. Three recognised shapes:
#  1. Fenced code (```lang\n...\n```)   → Monaco read-only with that language
#  2. Eval section (label:\n<body>)      → labeled card + Monaco; emitted by
#     BonitoMCP's bt_julia_eval which prefixes blocks with "stdout", "result",
#     "error" so the chat can show them as distinct sections instead of one
#     concatenated text dump.
#  3. Mixed prose                        → Markdown.parse fallback.
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
        body  = String(m.captures[2])
        # Result is a Julia value's repr → julia highlighting; everything else
        # is unstructured text (stack traces, captured stdout, etc).
        lang = label == "result" ? "julia" : "plaintext"
        return DOM.div(
            DOM.div(uppercase(label); class = "bt-section-label"),
            monaco_readonly(body, lang);
            class = "bt-eval-section")
    end
    return DOM.div(Markdown.parse(text), class = "bt-tool-md")
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
        DOM.div(d.path; class = "bt-diff-header"),
        BonitoBook.DiffEditor(something(d.old_text, ""), d.new_text;
                               language = detect_language(d.path),
                               renderSideBySide = false);
        class = "bt-diff-block")
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
                DOM.span(String(m.captures[1]); class = "bt-search-path"),
                DOM.span(":" * String(m.captures[2]); class = "bt-search-line"),
                DOM.code(strip(String(m.captures[3])); class = "bt-search-snippet");
                class = "bt-search-row"))
        else
            push!(rows, DOM.div(line; class = "bt-search-raw"))
        end
    end
    DOM.div(rows...; class = "bt-search-results")
end

function find_show_reference(content)
    for c in content
        c isa TextContent || continue
        startswith(c.text, "shown: ") && return c.text
    end
    return nothing
end

# Parse a `shown: <relpath> (<mime>, <size>)` reference and render a preview
# of the file. The file lives at <worker_path>/<relpath> on the worker. We
# try the server-side mirror first (RemoteSync may have already pulled it)
# and fall back to a single-file fetch over the worker control WS. Returns
# `nothing` if the reference can't be parsed (caller falls back to the
# default rendering).
function render_show_reference(state::ServerState, text::AbstractString,
                                cwd::AbstractString, project_id::AbstractString)
    # Header line is the first line; "type: ..." may follow.
    nl = findfirst('\n', text)
    header = nl === nothing ? text : text[1:prevind(text, nl)]
    m = match(r"^shown: (\S+)\s+\(([^,]+),\s*([^)]+)\)\s*$", header)
    m === nothing && return nothing
    relpath_str, mime, size_str = String(m.captures[1]),
                                    String(strip(m.captures[2])),
                                    String(strip(m.captures[3]))

    server_local_path = joinpath(cwd, relpath_str)

    # Already on the server (RemoteSync mirror or a previous fetch). Render
    # synchronously — no spinner needed.
    if isfile(server_local_path)
        return render_show_preview(read(server_local_path), mime, size_str, relpath_str)
    end

    # No project context → no worker to ask.
    if isempty(project_id) || !haskey(state.projects[], project_id)
        return DOM.div("(file not on server: $relpath_str)";
                       class = "bt-tool-empty")
    end

    # Stream from the worker via /transfer-ws + RemoteSync.send_file. Show a
    # spinner immediately and swap in the preview when the file lands on disk.
    p = state.projects[][project_id]
    worker_path = joinpath(p.worker_path, relpath_str)

    # NOTE: keep this Observable's binding distinct from the `state` parameter
    # — earlier this was named `state`, which shadowed the ServerState and
    # caused the @async branch to call fetch_file_from_worker with an
    # Observable instead of the ServerState.
    fetch_state = Observable{Any}(:loading)
    body = map(fetch_state) do s
        if s === :loading
            DOM.div(
                DOM.span(""; class = "bt-spinner"),
                DOM.span("Fetching $relpath_str from worker… ($size_str)";
                         style = Styles("margin-left" => "8px")),
                style = Styles("display" => "flex", "align-items" => "center",
                               "padding" => "8px", "color" => "var(--bt-text-muted)"))
        elseif s isa Tuple && s[1] === :ready
            render_show_preview(s[2], mime, size_str, relpath_str)
        elseif s isa Tuple && s[1] === :error
            DOM.div("(failed to fetch $relpath_str from worker: $(s[2]))";
                    class = "bt-tool-empty")
        else
            DOM.div("(unexpected state)"; class = "bt-tool-empty")
        end
    end

    Base.errormonitor(@async begin
        try
            mkpath(dirname(server_local_path))
            fetch_file_from_worker(state, p.worker_id, worker_path, server_local_path;
                                    handoff_timeout = 30.0)
            fetch_state[] = (:ready, read(server_local_path))
        catch e
            fetch_state[] = (:error, sprint(showerror, e))
        end
    end)

    return DOM.div(body)
end

# Render the actual preview based on MIME. Images / SVG → <img>, video/*
# → <video>, text/html → <iframe sandbox>, text/* → Monaco; everything else
# → a generic "binary" message + size.
function render_show_preview(bytes::AbstractVector{UInt8}, mime::AbstractString,
                              size_str::AbstractString, relpath_str::AbstractString)
    if startswith(mime, "image/")
        b64 = Base64.base64encode(bytes)
        return DOM.div(
            DOM.img(src = "data:$mime;base64,$b64",
                    style = Styles("max-width" => "100%", "display" => "block")),
            DOM.div("$relpath_str · $size_str";
                    style = Styles("font-size" => "11px",
                                   "color" => "var(--bt-text-faint)",
                                   "margin-top" => "4px")))
    elseif startswith(mime, "video/")
        b64 = Base64.base64encode(bytes)
        return DOM.div(
            # Bonito enforces strict booleans for HTML boolean attrs —
            # `controls = ""` (or any string) raises at render time.
            DOM.video(controls = true,
                       style = Styles("max-width" => "100%", "display" => "block"),
                       DOM.source(src = "data:$mime;base64,$b64", type = mime)),
            DOM.div("$relpath_str · $size_str";
                    style = Styles("font-size" => "11px",
                                   "color" => "var(--bt-text-faint)",
                                   "margin-top" => "4px")))
    # NOTE: text/html is intentionally NOT special-cased. Rendering arbitrary
    # HTML inline would clobber chat styles + JS; iframes have their own
    # downsides (Chromium opaque-origin churn for sandboxed data: URLs;
    # duplicated runtime cost for every WGLMakie/Bonito blob). The proper
    # fix is a serialize_bonito / deserialize_bonito pair that hooks into
    # the chat's existing Bonito session — tracked separately. Until then,
    # text/html falls through to the generic "binary" branch below.
    elseif startswith(mime, "text/")
        text = String(bytes)
        return monaco_readonly(text, mime == "text/julia" ? "julia" : "plaintext")
    else
        return DOM.div("$relpath_str · $size_str ($mime)";
                       class = "bt-tool-empty")
    end
end

function render_tool_body(state::ServerState, m::ToolMsg, cwd::AbstractString,
                           chat_dir::AbstractString = cwd;
                           project_id::AbstractString = "")
    content = load_tool_content(chat_dir, m.id)
    isempty(content) &&
        return DOM.div("(no body — tool details not persisted for this entry)",
                       class = "bt-tool-empty")

    # bt_show output: ANY text block starts with "shown: " (the bt_julia_eval
    # wrapper prepends a `\`\`\`julia` code-echo block before the formatter's
    # output, so we have to scan, not just look at the first block). The
    # rendered file lives on the worker; the chat fetches it lazily and
    # renders a collapsible preview without putting the bytes through claude.
    show_text = find_show_reference(content)
    if show_text !== nothing
        body = render_show_reference(state, show_text, cwd, project_id)
        body === nothing || return body
    end

    if m.kind == "edit"
        # Render every diff (multi-edit calls used to silently drop all but
        # the first). Stack with file-path headers between each.
        diffs = [c for c in content if c isa DiffContent]
        if !isempty(diffs)
            return DOM.div((render_diff_block(d) for d in diffs)...;
                            class = length(diffs) > 1 ? "bt-multi-diff" : "")
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
            push!(parts, DOM.img(src = "data:$(c.mime_type);base64,$(c.data)",
                                  style = Styles("max-width" => "100%")))
        end
    end
    isempty(parts) && return DOM.div("(empty)", class = "bt-tool-empty")
    return DOM.div(parts...)
end

# Chat app
# ── ChatModel ──────────────────────────────────────────────────────────────
# Shared per project, lifetime = project's lifetime. One instance lives in
# `state.chat_models[project_id]`; every browser tab viewing the project gets
# a per-session view via `Base.copy(::ChatModel)` (below). The shared bits —
# message store, ACP client, persistent chat session — are mutated under
# `lock` and broadcast via `comm`; the per-session copies share those refs
# but each get their own connected child of `comm` (and the small status
# Observables) so their JS bridges are GC'd cleanly when the tab closes.
mutable struct ChatModel
    # Convention: lock as the first field. Held by every mutator that touches
    # `msgs_store` together with `comm` or other multi-step state. See
    # .claude/skills/bonito/SKILL.md § "Thread-safe shared state".
    lock          :: ReentrantLock
    state         :: ServerState
    cwd           :: String
    project_id    :: String

    # Where chat.md + tools/<id>.json live. Resolved via `chat_storage_dir`
    # — for projects with an id, that's `state.state_dir/chats/<id>` (outside
    # the project tree, server-owned). Legacy fallback `<cwd>/.bonitoTeam`
    # only for orphan chats (project_id == "").
    chat_dir      :: String

    # Persistent state (loaded from disk on construction)
    chat_session  :: Any                    # ChatSession from persistence.jl
    msgs_store    :: Vector{ChatMsg}

    # ACP client + the typed Transport that knows how to (re)build it. Each
    # concrete transport (LocalTransport, WorkerTransport, MockTransport)
    # encapsulates everything needed to bring up a new session — no opaque
    # closure stored on the model.
    client      :: Ref{Union{AgentClientProtocol.Client,Nothing}}
    mcp_servers :: Vector{AgentClientProtocol.MCPServer}
    transport   :: ChatTransport

    # Streaming bookkeeping (which message id the next chunk extends)
    agent_id       :: Ref{String}
    thought_id     :: Ref{String}
    user_streaming :: Ref{Bool}

    # One-shot flag: when chat starts on a worker that doesn't have claude's
    # session jsonl (project moved, fresh sync, etc.), claude has no memory
    # of the prior conversation but `msgs_store` does. The next user prompt
    # gets a transcript prelude so claude can pick up where we left off.
    # See `start_chat_client!` (arms it) and `send_prompt_async!` (consumes).
    pending_history_replay :: Ref{Bool}

    # Single bidirectional channel between Julia and the browser-side BonitoChat.
    # Wire format is a tagged dict; see chat_emit / chat_dispatch! below for
    # the message types. Bonito's `update_nocycle!` prevents JS-originated
    # notifications from echoing back to JS, so one Observable serves both
    # directions cleanly.
    comm          :: Observable{Dict{String,Any}}

    # Status surface for the chat header (banner + reconnect state).
    session_alive :: Observable{Bool}
    last_error    :: Observable{String}

    # Backreference for per-session copies. `nothing` for the shared
    # parent (the one in `state.chat_models[pid]`); points back to that
    # parent for any `copy(model, session)` view. Handlers use
    # `shared(model)` to reach the parent so writes to `session_alive` /
    # `last_error` / `comm` broadcast to every connected tab instead of
    # silently flipping only the per-session view.
    parent :: Union{ChatModel, Nothing}
end

function ChatModel(state::ServerState, cwd::AbstractString;
                    project_id::AbstractString = "",
                    mcp_servers = AgentClientProtocol.MCPServer[],
                    transport::Union{ChatTransport,Nothing} = nothing)
    chat_dir     = chat_storage_dir(state, project_id, cwd)
    chat_session = load_session(chat_dir, cwd)
    msgs_store   = load_history(chat_session)
    # Default transport: spawn claude-agent-acp locally for `cwd`.
    actual_transport = transport === nothing ?
        LocalTransport(cwd; mcp_servers = collect(AgentClientProtocol.MCPServer, mcp_servers)) :
        transport
    return ChatModel(
        ReentrantLock(),
        state, String(cwd), String(project_id),
        chat_dir,
        chat_session, msgs_store,
        Ref{Union{AgentClientProtocol.Client,Nothing}}(nothing),
        collect(AgentClientProtocol.MCPServer, mcp_servers),
        actual_transport,
        Ref(""), Ref(""), Ref(false),
        Ref(false),                 # pending_history_replay
        Observable(Dict{String,Any}()),
        Observable(true),
        Observable(""),
        nothing,                    # parent: this is the shared instance itself
    )
end

# Per-session view. SHARES the lock, ACP client, msgs_store, chat_session,
# Refs etc. with the parent — sessions cooperate on the same chat history
# and the same lock. The Observable fields are bridged via
# `map(identity, session, obs)` so each session ends up with its own
# connected child Observable AND the parent→child callback is registered
# on `session.deregister_callbacks` (auto-GC'd on session close).
# `copy(obs)` would also produce a child but leak the callback forever.
function Base.copy(m::ChatModel, session::Bonito.Session)
    lock(m.lock) do
        ChatModel(
            m.lock,
            m.state, m.cwd, m.project_id,
            m.chat_dir,
            m.chat_session, m.msgs_store,
            m.client, m.mcp_servers, m.transport,
            m.agent_id, m.thought_id, m.user_streaming,
            m.pending_history_replay,
            map(identity, session, m.comm),
            map(identity, session, m.session_alive),
            map(identity, session, m.last_error),
            m,    # parent → the shared instance we copied from
        )
    end
end

# Resolve to the shared parent. Handlers invoked from per-session
# listeners use this so writes to broadcast observables (`comm`,
# `session_alive`, `last_error`) reach every connected tab via the
# parent→child `map(identity, session, ...)` bridges instead of
# silently flipping just this session's view.
shared(m::ChatModel) = m.parent === nothing ? m : m.parent

# ── Small helpers shared by every handler ─────────────────────────────────
# `chat_emit` writes to `comm`. Since Bonito propagates Julia-side writes to
# every JS subscriber on every per-session child of `m.comm`, all open tabs
# of this chat see the event. JS sends back via the same channel
# (`comm.notify({type, ...})`) — Julia's listener dispatches by `type`.
# Always writes to the SHARED comm so every connected tab sees the
# event via its own per-session bridge. Callers freely pass either the
# shared parent or a per-session view — `shared(model)` resolves the
# right target.
chat_emit(model::ChatModel, event::AbstractDict) =
    (shared(model).comm[] = Dict{String,Any}(event); nothing)

function chat_push_msg!(model::ChatModel, msg::ChatMsg)
    n = lock(model.lock) do
        push!(model.msgs_store, msg)
        length(model.msgs_store)
    end
    # Emit the typed dict directly (e.g. {type: "user", text, ...}) with the
    # new total count piggybacked. The JS `dispatch` routes by `type` and
    # bumps `totalCount` from the `n` field — no separate "msg.new" wrapper.
    payload = msg_to_dict(msg, model.chat_dir)
    payload["n"] = n
    chat_emit(model, payload)
end

# Close any in-flight thought/agent stream, persist + emit a "_final" event
# so the JS side swaps the streaming bubble for the rendered Markdown HTML.
# User messages are persisted at chunk-receive time, so closing them only
# clears the in-flight flag.
function chat_finalize_streaming!(model::ChatModel)
    model.user_streaming[] = false
    if !isempty(model.thought_id[])
        idx = findfirst(m -> m isa ThoughtMsg && m.id == model.thought_id[], model.msgs_store)
        if idx !== nothing
            m = model.msgs_store[idx]
            append_thought(model.chat_session, m)
            html = sprint(show, MIME("text/html"), Markdown.parse(m.text))
            chat_emit(model, Dict{String,Any}("type" => "thought_final", "id" => m.id, "html" => html))
        end
        model.thought_id[] = ""
    end
    if !isempty(model.agent_id[])
        idx = findfirst(m -> m isa AgentMsg && m.id == model.agent_id[], model.msgs_store)
        if idx !== nothing
            m = model.msgs_store[idx]
            finalize_agent(model.chat_session, m)
            html = sprint(show, MIME("text/html"), Markdown.parse(m.text))
            chat_emit(model, Dict{String,Any}("type" => "agent_final", "id" => m.id, "html" => html))
        end
        model.agent_id[] = ""
    end
    return nothing
end

# ── ACP update handlers (one per event type) ───────────────────────────────
# All three streaming handlers (user/agent/thought) follow the same shape:
#   1. If we're already streaming the same type → accumulate by ID lookup
#      (NOT msgs_store[end] — interleaved events from session/load replay
#      can put a different message there).
#   2. Otherwise → finalize_streaming! to close any other in-flight stream,
#      then push a fresh message and remember its ID.
function chat_on_user_chunk!(model::ChatModel, upd::UserMessageChunk)
    upd.content isa TextContent || return
    text = upd.content.text
    if !model.user_streaming[]
        chat_finalize_streaming!(model)
        model.user_streaming[] = true
        msg = UserMsg(text)
        n = lock(model.lock) do
            push!(model.msgs_store, msg)
            append_user(model.chat_session, msg)
            length(model.msgs_store)
        end
        chat_emit(model, Dict{String,Any}("type" => "user", "text" => text, "n" => n))
    else
        idx = findlast(m -> m isa UserMsg, model.msgs_store)
        idx === nothing && return
        model.msgs_store[idx].text *= text
        chat_emit(model, Dict{String,Any}("type" => "user_chunk", "text" => text))
    end
end

function chat_on_agent_chunk!(model::ChatModel, upd::AgentMessageChunk)
    upd.content isa TextContent || return
    text = upd.content.text
    if isempty(model.agent_id[])
        chat_finalize_streaming!(model)
        id = string(uuid4())
        model.agent_id[] = id
        msg = AgentMsg(id, text)
        n = lock(model.lock) do
            push!(model.msgs_store, msg)
            length(model.msgs_store)
        end
        # Seed the bubble's streaming accumulator with this first chunk's
        # text so a viewer that reconnected mid-stream sees content right
        # away (without waiting for the next chunk to arrive).
        chat_emit(model, Dict{String,Any}("type" => "agent", "id" => id, "n" => n,
                                            "html" => "", "streaming" => true,
                                            "text" => text))
    else
        idx = findfirst(m -> m isa AgentMsg && m.id == model.agent_id[], model.msgs_store)
        idx === nothing && return
        model.msgs_store[idx].text *= text
        chat_emit(model, Dict{String,Any}("type" => "chunk",
                                            "id"   => model.agent_id[], "text" => text))
    end
end

function chat_on_thought_chunk!(model::ChatModel, upd::AgentThoughtChunk)
    upd.content isa TextContent || return
    text = upd.content.text
    # claude-agent-acp's session/load replay emits placeholder thought chunks
    # with empty content — the underlying jsonl doesn't persist thought text.
    # Filter those so we don't spawn empty bubbles after a resume.
    isempty(text) && return
    if isempty(model.thought_id[])
        chat_finalize_streaming!(model)
        id = string(uuid4())
        model.thought_id[] = id
        msg = ThoughtMsg(id, text)
        n = lock(model.lock) do
            push!(model.msgs_store, msg)
            length(model.msgs_store)
        end
        chat_emit(model, Dict{String,Any}("type" => "thought", "id" => id, "n" => n,
                                            "html" => "", "streaming" => true,
                                            "text" => text))
    else
        idx = findfirst(m -> m isa ThoughtMsg && m.id == model.thought_id[], model.msgs_store)
        idx === nothing && return
        model.msgs_store[idx].text *= text
        chat_emit(model, Dict{String,Any}("type" => "thought_chunk",
                                            "id"   => model.thought_id[], "text" => text))
    end
end

function chat_on_tool!(model::ChatModel, upd::ToolCallNotif)
    chat_finalize_streaming!(model)
    update_tool_file!(model.chat_dir, upd.tool_call_id, upd.raw)
    summary = content_summary(upd.kind, upd.content)
    msg = ToolMsg(upd.tool_call_id, upd.kind, upd.title, upd.status, summary)
    chat_push_msg!(model, msg)
    upd.status in ("completed", "failed") && append_tool(model.chat_session, msg)
end

function chat_on_tool_update!(model::ChatModel, upd::ToolCallUpdateNotif)
    idx = findfirst(m -> m isa ToolMsg && m.id == upd.tool_call_id, model.msgs_store)
    idx === nothing && return
    m = model.msgs_store[idx]
    update_tool_file!(model.chat_dir, upd.tool_call_id, upd.raw)
    upd.status !== nothing && (m.status = upd.status)
    upd.title  !== nothing && (m.title  = upd.title)
    isempty(upd.content) || (m.summary = content_summary(m.kind, upd.content))
    chat_emit(model, Dict{String,Any}("type" => "tool_update",
        "id" => m.id, "status" => m.status, "title" => m.title, "summary" => m.summary))
    m.status in ("completed", "failed") && append_tool(model.chat_session, m)
end

function chat_on_plan!(model::ChatModel, upd::PlanUpdate)
    chat_finalize_streaming!(model)
    msg = PlanMsg(upd.entries)
    chat_push_msg!(model, msg)
    append_plan(model.chat_session, msg)
end

# Single dispatcher: ACP feeds us SessionUpdate-typed events; we route by
# concrete subtype to the matching handler. The closure captures `model`.
function make_on_update(model::ChatModel)
    return function (upd)
        if     upd isa UserMessageChunk    chat_on_user_chunk!(model, upd)
        elseif upd isa AgentMessageChunk   chat_on_agent_chunk!(model, upd)
        elseif upd isa AgentThoughtChunk   chat_on_thought_chunk!(model, upd)
        elseif upd isa ToolCallNotif       chat_on_tool!(model, upd)
        elseif upd isa ToolCallUpdateNotif chat_on_tool_update!(model, upd)
        elseif upd isa PlanUpdate          chat_on_plan!(model, upd)
        end
        return nothing
    end
end

# ── Client lifecycle ───────────────────────────────────────────────────────
function start_chat_client!(model::ChatModel)
    on_update = make_on_update(model)
    # All transport-specific bring-up (subprocess spawn / worker WS dial /
    # mock channel setup) lives in `start_session(::ChatTransport, on_update)`
    # — see src/transport.jl.
    #
    # Capture the recorded session id BEFORE start_session so we can detect
    # "fresh session, not a resume" afterwards. A mismatch means claude has
    # no memory of `msgs_store` (e.g. the project was just synced to a
    # different worker), so we arm a one-shot history prelude that
    # `send_prompt_async!` will fold into the next user prompt.
    prev_session_id = model.chat_session.session_id
    model.client[] = start_session(model.transport, on_update)
    new_session_id = model.client[].session_id
    if !isempty(model.msgs_store) && prev_session_id != new_session_id
        model.pending_history_replay[] = true
        @info "chat history replay armed" project_id=model.project_id n_msgs=length(model.msgs_store)
    end
    update_session_id!(model.chat_session, new_session_id)

    # Browser-side handlers (range requests + lazy tool/thought renders) are
    # wired in `Bonito.jsrender(::Session, ::ChatModel)` — once per mount,
    # session-scoped via `Observables.on(f, session, obs)` so they tear down
    # automatically when that tab closes. No more `bonito_session :: Ref`,
    # no more "wire once + dispatch via the latest session" shenanigans.

    # Cache the live model so the unified app's sidebar can swap to this chat
    # instantly on second visit, and test rigs can drive prompts via
    # state.chat_models[pid].client[] without going through the UI.
    if !isempty(model.project_id)
        @info "registering chat model" project_id=model.project_id session_id=model.client[].session_id
        lock(model.state.lock) do
            model.state.chat_models[model.project_id] = model
        end
    end
    return nothing
end

function restart_chat_session!(model::ChatModel)
    try
        old = model.client[]
        if old !== nothing
            try AgentClientProtocol.send_request(old.conn, "session/cancel",
                    Dict("sessionId" => old.session_id)) catch end
            # Tear down the old transport so a stale subprocess / WS / mock
            # responder doesn't keep running alongside the new one. Without
            # this, restart leaks resources and (for mocks) two responders
            # race on the same channels.
            try AgentClientProtocol.close!(old) catch end
        end
        start_chat_client!(model)
        # Broadcast the recovery to every connected tab via the shared
        # parent — never the per-session view, which would leave other
        # tabs (and external observers) seeing the stale `false`.
        s = shared(model)
        s.session_alive[] = true
        s.last_error[]    = ""
    catch e
        shared(model).last_error[] = "restart failed: $(sprint(showerror, e))"
    end
end

# Single-entry "user submitted a message" path. Every call site that wants
# to deliver a user message — typed in the input area, fired by the
# auto-prompt template, future scripted hooks — goes through here. That
# guarantees the same four steps happen in the same order: store push,
# MD persist, busy banner, async dispatch to the agent.
#
# `images` are sent to the agent as multimodal content blocks; the caller is
# responsible for already having embedded any file-path reference into
# `msg.text` so the display + replay see the same thing claude does.
function send_message!(model::ChatModel, msg::UserMsg;
                       images::Vector{AgentClientProtocol.ImageAttachment} =
                              AgentClientProtocol.ImageAttachment[])
    chat_push_msg!(model, msg)
    append_user(model.chat_session, msg)
    model.agent_id[] = ""    # any in-flight agent stream is over once the user sends
    chat_emit(model, Dict{String,Any}("type" => "busy_start"))
    Base.errormonitor(@async send_prompt_async!(model, msg.text; images))
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
    try save_projects!(model.state) catch e
        @warn "auto_prompt: persist clear failed" exception=e
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
        relevant = relevant[end - 59 : end]
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

# Common send-and-handle for both auto_prompt and user-typed prompts. Splits
# transient ACP errors (which we surface inline as a chat bubble) from
# session-death errors (which flip the banner so the user can restart).
function send_prompt_async!(model::ChatModel, text::AbstractString;
                            images::Vector{AgentClientProtocol.ImageAttachment} =
                                   AgentClientProtocol.ImageAttachment[])
    full_text = String(text)
    # One-shot: if `start_chat_client!` armed the replay flag (fresh claude
    # session that has no memory of prior chat.md content), prepend the
    # transcript so claude picks up where we left off. The user-visible
    # bubble already shows their actual question — only what goes to claude
    # over ACP includes the prelude.
    if model.pending_history_replay[]
        full_text = build_history_prelude(model) * full_text
        model.pending_history_replay[] = false
    end
    try
        AgentClientProtocol.prompt!(model.client[], full_text; images)
        chat_finalize_streaming!(model)
    catch e
        msg = sprint(showerror, e)
        if occursin("connection closed", msg) || occursin("EOFError", msg) ||
           occursin("BrokenPipe", msg)
            s = shared(model)
            s.session_alive[] = false
            s.last_error[]    = msg
        else
            id = string(uuid4())
            err_msg = AgentMsg(id, "[error: $msg]")
            chat_push_msg!(model, err_msg)
            finalize_agent(model.chat_session, err_msg)
        end
    finally
        chat_emit(model, Dict{String,Any}("type" => "busy_end"))
    end
end

# ── DOM building (split into header / messages / input / banner) ──────────
function chat_header(model::ChatModel)
    state    = model.state
    project_id = model.project_id
    cwd      = model.cwd

    status_dot = map(model.session_alive) do alive
        DOM.span(""; class = alive ? "bt-dot bt-dot-online" : "bt-dot bt-dot-offline",
                     title = alive ? "session live" : "session ended")
    end

    sync_status = Observable("")
    sync_button = DOM.button(map(s -> isempty(s) ? "Sync" : s, sync_status);
        class   = "bt-header-sync",
        title   = "Pull this project from the worker to the server",
        onclick = js"event => $(sync_status).notify('__click__')")
    on(sync_status) do s
        s == "__click__" || return
        sync_status[] = ""
        isempty(project_id) && (sync_status[] = "no project bound"; return)
        handle_chat_sync_click(state, project_id, sync_status)
    end

    # No back arrow — the unified app's sidebar Home icon is the way home.
    DOM.div(
        DOM.div(
            status_dot,
            DOM.div(
                DOM.span(basename(rstrip(cwd, '/')); title = cwd),
                class = "bt-header-title"),
            sync_button;
            class = "bt-header-row");
        class = "bt-header")
end

function chat_session_banner(model::ChatModel)
    restart_btn = Bonito.Button("Restart session"; style=nothing,
                                class = "bt-btn bt-btn-secondary")
    on(restart_btn.value) do clicked
        clicked && @async restart_chat_session!(model)
    end
    map(model.session_alive, model.last_error) do alive, err
        alive && return DOM.div()
        DOM.div(
            DOM.div(
                DOM.span("⚠ Session ended"; style = Styles("font-weight" => "600")),
                DOM.div(isempty(err) ? "The agent connection was closed." : err;
                        class = "bt-banner-detail");
                style = Styles("flex" => "1 1 auto", "min-width" => "0")),
            restart_btn;
            class = "bt-banner-error")
    end
end

# Icons live as standalone SVG files under assets/icons/ and ship as
# Bonito.Asset (hashed URL, served by the same machinery as bonitoteam.js).
# Colors are baked into the SVGs since <img> doesn't inherit currentColor.
const SEND_ICON = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "icons", "send.svg"))
const STOP_ICON = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "icons", "stop.svg"))
icon_img(asset, alt) = DOM.img(src = asset, alt = alt, draggable = "false",
                                style = Styles("pointer-events" => "none",
                                               "user-select" => "none"))

function chat_input_area(model::ChatModel)
    text_val = Observable("")
    send_btn = Bonito.Button(icon_img(SEND_ICON, "Send"); style=nothing,
                             class="bt-send-btn", title="Send (Enter)")
    stop_btn = Bonito.Button(icon_img(STOP_ICON, "Stop"); style=nothing,
                             class="bt-stop-btn", title="Stop generation")

    # `value = text_val` is a two-way bind: oninput pushes JS → Julia
    # below, and any Julia-side write to text_val[] propagates back to
    # the DOM (so clearing text_val[] = "" after send empties the box,
    # no separate evaljs needed). The JS height-adjust still rides on
    # the same oninput event since CSS auto-grow on textareas needs JS.
    text_input = DOM.textarea(value = text_val,
        placeholder = "Message…",
        title = "Enter to send  ·  Shift+Enter for newline",
        class = "bt-text-input", rows = 1,
        oninput = js"""event => {
            $(text_val).notify(event.target.value);
            event.target.style.height = 'auto';
            event.target.style.height = Math.min(event.target.scrollHeight, 120) + 'px';
        }""",
        onkeydown = js"""event => {
            if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                $(send_btn.value).notify(true);
            }
        }""")

    on(send_btn.value) do clicked
        clicked || return
        send_user_text!(model, text_val)
    end
    on(stop_btn.value) do clicked
        clicked || return
        c = model.client[]
        c !== nothing && AgentClientProtocol.cancel!(c)
    end
    DOM.div(DOM.div(text_input, send_btn, stop_btn, class = "bt-input-row");
            class = "bt-input-area")
end

function send_user_text!(model::ChatModel, text_val)
    text = strip(text_val[])
    isempty(text) && return
    # `value=text_val` on the textarea (chat_input_area) is a two-way bind,
    # so this single assignment empties the input on the JS side too. The
    # height-reset is folded into the existing `oninput` handler — when
    # value flips to "", oninput fires once and the auto-grow recomputes.
    text_val[] = ""
    send_message!(model, UserMsg(String(text)))
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
    "image/png"     => "png",
    "image/jpeg"    => "jpg",
    "image/jpg"     => "jpg",
    "image/gif"     => "gif",
    "image/webp"    => "webp",
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
    ext       = attachment_ext(mime)
    ts        = Dates.format(now(UTC), "yyyy-mm-dd_HHMMSS")
    short     = string(uuid4())[1:8]
    rel       = joinpath(ATTACHMENT_DIR_NAME, "$(ts)_$(short).$(ext)")
    abs       = joinpath(model.cwd, rel)
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
                              handoff_timeout = 15.0)
    catch e
        @warn "attachment push to worker failed" worker=proj.worker_id rel_path exception=e
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
        mime  = String(get(a, "mime",  ""))
        b64   = String(get(a, "data",  ""))
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

# Single dispatcher for all JS-originated commands. Reads `msg["type"]` and
# routes to the appropriate Julia handler. Called from `jsrender(::ChatModel)`
# on each session's `comm` Observable; session-scoped `Observables.on(f, session, …)`
# means the handler dies with its session — no manual deregistration.
#
# `session` is the *closure* binding for `Bonito.dom_in_js` (lazy tool body
# rendering needs a live session to mount sub-DOM with embedded MonacoEditors).
# No more `model.bonito_session :: Ref{Any}`.
function chat_dispatch!(model::ChatModel, session::Session, msg::AbstractDict)
    type = String(get(msg, "type", ""))
    if type == "init"
        # Browser just connected; tell it how many messages exist so it can
        # bootstrap virtual-scroll + request the visible range.
        chat_emit(model, Dict{String,Any}(
            "type" => "msgs.count", "n" => length(model.msgs_store)))
    elseif type == "msgs.request"
        # JS asked for messages [s, e]; reply via comm with msgs.range.
        rng = get(msg, "range", nothing)
        rng isa AbstractVector && length(rng) == 2 || return
        s, e = Int(rng[1]), Int(rng[2])
        store = model.msgs_store
        n = length(store)
        s = clamp(s, 0, n - 1);  e = clamp(e, 0, n - 1)
        s > e && return
        batch = [msg_to_dict(store[i], model.chat_dir) for i in (s+1):(e+1)]
        chat_emit(model, Dict{String,Any}(
            "type" => "msgs.range", "start" => s, "msgs" => batch))
    elseif type == "tool.render"
        tool_id = String(get(msg, "id", ""))
        isempty(tool_id) && return
        idx = findfirst(m -> m isa ToolMsg && m.id == tool_id, model.msgs_store)
        idx === nothing && return
        body = render_tool_body(model.state, model.msgs_store[idx],
                                 model.cwd, model.chat_dir;
                                 project_id = model.project_id)
        try
            Bonito.dom_in_js(session, body, js"""(elem) => {
                const slot = document.querySelector(
                    '.bt-tool-body[data-tool-id="' + $(tool_id) + '"]');
                if (slot) { slot.innerHTML = ''; slot.appendChild(elem); }
            }""")
        catch e
            @warn "tool render failed" tool_id exception=e
        end
    elseif type == "thought.render"
        thought_id = String(get(msg, "id", ""))
        isempty(thought_id) && return
        idx = findfirst(m -> m isa ThoughtMsg && m.id == thought_id, model.msgs_store)
        idx === nothing && return
        html = sprint(show, MIME("text/html"),
                      Markdown.parse(model.msgs_store[idx].text))
        chat_emit(model, Dict{String,Any}("type" => "thought.body",
                                            "id" => thought_id, "html" => html))
    elseif type == "send"
        # Multimodal send path. JS uses this whenever there are attached
        # images; pure-text sends still go through the Bonito.Button →
        # `send_user_text!` chain so the existing electron tests stay green.
        text  = String(get(msg, "text", ""))
        attachments = get(msg, "attachments", [])
        local suffix, blocks
        try
            suffix, blocks = process_attachments!(model, attachments)
        catch e
            chat_emit(model, Dict{String,Any}(
                "type" => "attach_error", "error" => sprint(showerror, e)))
            return
        end
        display_text = isempty(strip(text)) && !isempty(blocks) ?
            "(image attached)" * suffix :
            text * suffix
        # Tell JS the attachments have been accepted so it can clear the
        # thumbnail strip + textarea.
        chat_emit(model, Dict{String,Any}("type" => "send_ack"))
        send_message!(model, UserMsg(display_text); images = blocks)
    end
    return
end

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

    messages_container = DOM.div(
        DOM.div(class="bt-spacer-top"),
        DOM.div(class="bt-spacer-bottom");
        class="bt-messages")

    init_script = js"""
        $(ChatLib).then(lib => lib.connect($(messages_container), $(model.comm)))
    """

    Bonito.jsrender(session, DOM.div(
        chat_header(model),
        chat_session_banner(model),
        messages_container,
        init_script,
        DOM.div(DOM.div(class="bt-busy-dot"),
                DOM.div(class="bt-busy-dot"),
                DOM.div(class="bt-busy-dot");
                class="bt-busy"),
        chat_input_area(model),
        class = "bt-app"))
end

