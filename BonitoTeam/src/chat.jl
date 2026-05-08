const BonitoTeamJS = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "bonitoteam.js"))

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
function tool_header_dict(m::ToolMsg)
    Dict{String,Any}(
        "type"    => "tool",
        "id"      => m.id,
        "kind"    => m.kind,
        "icon"    => tool_icon(m.kind),
        "title"   => m.title,
        "status"  => m.status,
        "summary" => m.summary,
    )
end

# Same shape used by msg_to_dict so the JS virtual-scroll renderer treats
# all messages uniformly.
function msg_to_dict(m::UserMsg)
    Dict{String,Any}("type" => "user", "text" => m.text)
end

function msg_to_dict(m::AgentMsg)
    html = sprint(show, MIME("text/html"), Markdown.parse(m.text))
    Dict{String,Any}("type" => "agent", "id" => m.id, "html" => html)
end

msg_to_dict(m::ToolMsg) = tool_header_dict(m)

# Thoughts are lazy-loaded: header carries only id + a size hint. JS asks for
# the body via requestThoughtRender(id) when the user expands the <details>.
# Avoids shipping potentially huge thinking transcripts on every range fetch.
function msg_to_dict(m::ThoughtMsg)
    n = count('\n', m.text) + 1
    Dict{String,Any}("type" => "thought", "id" => m.id,
                     "summary" => "$n $(n == 1 ? "line" : "lines")")
end

function msg_to_dict(m::PlanMsg)
    rows = join(["""<div class="bt-plan-entry">
        <span class="bt-plan-status">$(e.status == "completed" ? "✓" : e.status == "in_progress" ? "▶" : "○")</span>
        <span>$(e.content)</span></div>""" for e in m.entries])
    Dict{String,Any}("type" => "plan", "html" => rows)
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
function load_tool_content(cwd::AbstractString, tool_id::AbstractString)
    params = load_tool_file(String(cwd), String(tool_id))
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
    if isempty(project_id) || !haskey(state.projects, project_id)
        return DOM.div("(file not on server: $relpath_str)";
                       class = "bt-tool-empty")
    end

    # Stream from the worker via /transfer-ws + RemoteSync.send_file. Show a
    # spinner immediately and swap in the preview when the file lands on disk.
    p = state.projects[project_id]
    worker_path = joinpath(p.worker_path, relpath_str)

    state = Observable{Any}(:loading)
    body  = map(state) do s
        if s === :loading
            DOM.div(
                DOM.span(""; class = "bt-spinner"),
                DOM.span("Fetching $relpath_str from worker… ($size_str)";
                         style = "margin-left:8px"),
                style = "display:flex; align-items:center; padding:8px; color:var(--bt-text-muted)")
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
            fetch_file_from_worker(state, p.worker_name, worker_path, server_local_path;
                                    handoff_timeout = 30.0)
            state[] = (:ready, read(server_local_path))
        catch e
            state[] = (:error, sprint(showerror, e))
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
                    style = "max-width:100%; display:block"),
            DOM.div("$relpath_str · $size_str";
                    style = "font-size:11px;color:var(--bt-text-faint);margin-top:4px"))
    elseif startswith(mime, "video/")
        b64 = Base64.base64encode(bytes)
        return DOM.div(
            DOM.video(controls = "", style = "max-width:100%; display:block",
                       DOM.source(src = "data:$mime;base64,$b64", type = mime)),
            DOM.div("$relpath_str · $size_str";
                    style = "font-size:11px;color:var(--bt-text-faint);margin-top:4px"))
    elseif mime == "text/html"
        # Sandbox the iframe so embedded scripts can't reach the chat
        # session. Same-origin disabled; allow scripts so HTML widgets
        # (DataFrames, Plots HTML output, simple SPAs) still render.
        b64 = Base64.base64encode(bytes)
        return DOM.div(
            DOM.iframe(src = "data:text/html;base64,$b64",
                        sandbox = "allow-scripts",
                        style = "width:100%; min-height:400px; border:1px solid var(--bt-border); border-radius:6px"),
            DOM.div("$relpath_str · $size_str";
                    style = "font-size:11px;color:var(--bt-text-faint);margin-top:4px"))
    elseif startswith(mime, "text/")
        text = String(bytes)
        return monaco_readonly(text, mime == "text/julia" ? "julia" : "plaintext")
    else
        return DOM.div("$relpath_str · $size_str ($mime)";
                       class = "bt-tool-empty")
    end
end

function render_tool_body(state::ServerState, m::ToolMsg, cwd::AbstractString;
                           project_id::AbstractString = "")
    content = load_tool_content(cwd, m.id)
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
                                  style = "max-width:100%"))
        end
    end
    isempty(parts) && return DOM.div("(empty)", class = "bt-tool-empty")
    return DOM.div(parts...)
end

# Chat app
# ── ChatModel ──────────────────────────────────────────────────────────────
# Single bag holding everything one chat session needs. Every helper below
# takes `model::ChatModel` so functions can be small and focused.
mutable struct ChatModel
    state         :: ServerState
    cwd           :: String
    project_id    :: String

    # Persistent state (loaded from disk on construction)
    chat_session  :: Any                    # ChatSession from persistence.jl
    msgs_store    :: Vector{ChatMsg}

    # ACP client + factory (factory captured so restart_session! can rebuild)
    client         :: Ref{Union{AgentClientProtocol.Client,Nothing}}
    mcp_servers    :: Vector{AgentClientProtocol.MCPServer}
    client_factory :: Any                   # nothing OR (on_update -> Client)

    # Streaming bookkeeping (which message id the next chunk extends)
    agent_id       :: Ref{String}
    thought_id     :: Ref{String}
    user_streaming :: Ref{Bool}

    # Server↔browser observables
    total_count            :: Observable{Int}
    new_msg_obs            :: Observable{String}      # JSON: typed event
    range_response         :: Observable{String}      # JSON: {start, messages}
    request_range          :: Observable{Vector{Any}} # [start, end] from JS
    request_tool_render    :: Observable{String}
    request_thought_render :: Observable{String}
    session_alive          :: Observable{Bool}
    last_error             :: Observable{String}
end

function ChatModel(state::ServerState, cwd::AbstractString;
                    project_id::AbstractString = "",
                    mcp_servers = AgentClientProtocol.MCPServer[],
                    client_factory = nothing)
    chat_session = load_session(cwd)
    msgs_store   = load_history(chat_session)
    return ChatModel(state, String(cwd), String(project_id),
        chat_session, msgs_store,
        Ref{Union{AgentClientProtocol.Client,Nothing}}(nothing),
        collect(AgentClientProtocol.MCPServer, mcp_servers),
        client_factory,
        Ref(""), Ref(""), Ref(false),
        Observable(length(msgs_store)),
        Observable(""),
        Observable(""),
        Observable(Any[]),
        Observable(""),
        Observable(""),
        Observable(true),
        Observable(""))
end

# ── Small helpers shared by every handler ─────────────────────────────────
chat_emit(model::ChatModel, event::AbstractDict) =
    (model.new_msg_obs[] = JSON.json(event); nothing)

function chat_push_msg!(model::ChatModel, msg::ChatMsg)
    push!(model.msgs_store, msg)
    model.total_count[] = length(model.msgs_store)
    model.new_msg_obs[] = JSON.json(msg_to_dict(msg))
    return nothing
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
        push!(model.msgs_store, msg)
        append_user(model.chat_session, msg)
        model.total_count[] = length(model.msgs_store)
        chat_emit(model, Dict{String,Any}("type" => "user", "text" => text))
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
        push!(model.msgs_store, msg)
        model.total_count[] = length(model.msgs_store)
        chat_emit(model, Dict{String,Any}("type" => "agent", "id" => id,
                                            "html" => "", "streaming" => true))
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
        push!(model.msgs_store, msg)
        model.total_count[] = length(model.msgs_store)
        chat_emit(model, Dict{String,Any}("type" => "thought", "id" => id,
                                            "html" => "", "streaming" => true))
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
    update_tool_file!(model.cwd, upd.tool_call_id, upd.raw)
    summary = content_summary(upd.kind, upd.content)
    msg = ToolMsg(upd.tool_call_id, upd.kind, upd.title, upd.status, summary)
    chat_push_msg!(model, msg)
    upd.status in ("completed", "failed") && append_tool(model.chat_session, msg)
end

function chat_on_tool_update!(model::ChatModel, upd::ToolCallUpdateNotif)
    idx = findfirst(m -> m isa ToolMsg && m.id == upd.tool_call_id, model.msgs_store)
    idx === nothing && return
    m = model.msgs_store[idx]
    update_tool_file!(model.cwd, upd.tool_call_id, upd.raw)
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
    model.client[] = if model.client_factory !== nothing
        model.client_factory(on_update)
    else
        AgentClientProtocol.Client(model.cwd; on_update, mcp_servers = model.mcp_servers)
    end
    update_session_id!(model.chat_session, model.client[].session_id)

    # Expose live client to test harnesses + programmatic drivers (test rigs
    # call AgentClientProtocol.prompt!() directly without synthesising a click).
    if !isempty(model.project_id)
        @info "registering chat client" project_id=model.project_id session_id=model.client[].session_id
        model.state.chat_clients[model.project_id] = model.client
    end
    return nothing
end

function restart_chat_session!(model::ChatModel)
    try
        old = model.client[]
        if old !== nothing
            try AgentClientProtocol.send_request(old.conn, "session/cancel",
                    Dict("sessionId" => old.session_id)) catch end
        end
        start_chat_client!(model)
        model.session_alive[] = true
        model.last_error[]    = ""
    catch e
        model.last_error[] = "restart failed: $(sprint(showerror, e))"
    end
end

# Auto-prompt: if the project carries an `auto_prompt` (set by the "From
# GitHub" template) and the chat is otherwise empty, fire it once as the
# first user message. Cleared + persisted right away so a server restart or
# session reconnect doesn't double-fire.
function fire_auto_prompt!(model::ChatModel)
    isempty(model.project_id) && return
    haskey(model.state.projects, model.project_id) || return
    proj = model.state.projects[model.project_id]
    ap = proj.auto_prompt
    (ap === nothing || isempty(ap) || !isempty(model.msgs_store)) && return
    proj.auto_prompt = nothing
    try save_projects!(model.state) catch e
        @warn "auto_prompt: persist clear failed" exception=e
    end
    user_msg = UserMsg(String(ap))
    chat_push_msg!(model, user_msg)
    append_user(model.chat_session, user_msg)
    chat_emit(model, Dict{String,Any}("type" => "busy_start"))
    Base.errormonitor(@async send_prompt_async!(model, String(ap)))
    return nothing
end

# Common send-and-handle for both auto_prompt and user-typed prompts. Splits
# transient ACP errors (which we surface inline as a chat bubble) from
# session-death errors (which flip the banner so the user can restart).
function send_prompt_async!(model::ChatModel, text::AbstractString)
    try
        AgentClientProtocol.prompt!(model.client[], String(text))
        chat_finalize_streaming!(model)
    catch e
        msg = sprint(showerror, e)
        if occursin("connection closed", msg) || occursin("EOFError", msg) ||
           occursin("BrokenPipe", msg)
            model.session_alive[] = false
            model.last_error[]    = msg
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
        onclick = js"event => Bonito.notify_observable($(sync_status), '__click__')")
    on(sync_status) do s
        s == "__click__" || return
        sync_status[] = ""
        isempty(project_id) && (sync_status[] = "no project bound"; return)
        handle_chat_sync_click(state, project_id, sync_status)
    end

    DOM.div(
        DOM.div(
            DOM.a("←"; href = Bonito.Link("/"), class = "bt-header-back",
                   title = "Back to dashboard"),
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
                DOM.span("⚠ Session ended"; style = "font-weight:600"),
                DOM.div(isempty(err) ? "The agent connection was closed." : err;
                        class = "bt-banner-detail");
                style = "flex:1 1 auto; min-width:0"),
            restart_btn;
            class = "bt-banner-error")
    end
end

# Inline SVG icons render crisply at any size, independent of installed
# fonts (Arial's ▶ glyph is tiny on Linux).
const SEND_SVG = Bonito.HTML(
    """<svg viewBox="0 0 24 24" width="20" height="20" fill="none"
            stroke="currentColor" stroke-width="2.2"
            stroke-linecap="round" stroke-linejoin="round">
         <line x1="12" y1="19" x2="12" y2="5"></line>
         <polyline points="5 12 12 5 19 12"></polyline>
       </svg>""")
const STOP_SVG = Bonito.HTML(
    """<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
         <rect x="5" y="5" width="14" height="14" rx="2.5"></rect>
       </svg>""")

function chat_input_area(model::ChatModel, bonito_session)
    text_val = Observable("")
    send_btn = Bonito.Button(SEND_SVG; style=nothing, class="bt-send-btn",
                             title="Send (Enter)")
    stop_btn = Bonito.Button(STOP_SVG; style=nothing, class="bt-stop-btn",
                             title="Stop generation")

    text_input = DOM.textarea(""; placeholder="Message…",
        title="Enter to send  ·  Shift+Enter for newline",
        class="bt-text-input", rows=1,
        oninput=js"""event => {
            $(text_val).notify(event.target.value);
            event.target.style.height = 'auto';
            event.target.style.height = Math.min(event.target.scrollHeight, 120) + 'px';
        }""",
        onkeydown=js"""event => {
            if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                $(send_btn.value).notify(true);
            }
        }""")

    on(send_btn.value) do clicked
        clicked || return
        send_user_text!(model, bonito_session, text_input, text_val)
    end
    on(stop_btn.value) do clicked
        clicked || return
        c = model.client[]
        c !== nothing && AgentClientProtocol.cancel!(c)
    end
    DOM.div(DOM.div(text_input, send_btn, stop_btn, class = "bt-input-row");
            class = "bt-input-area")
end

function send_user_text!(model::ChatModel, bonito_session, text_input, text_val)
    text = strip(text_val[])
    isempty(text) && return
    text_val[] = ""
    evaljs(bonito_session, js"$(text_input).value = ''; $(text_input).style.height = 'auto';")
    user_msg = UserMsg(String(text))
    chat_push_msg!(model, user_msg)
    append_user(model.chat_session, user_msg)
    model.agent_id[] = ""
    chat_emit(model, Dict{String,Any}("type" => "busy_start"))
    @async send_prompt_async!(model, String(text))
end

# Lazy tool/thought body rendering. JS notifies *_render Observable with the
# msg id when the user expands a placeholder; we look the message up, build
# its body, and ship it back via dom_in_js (tool) or emit (thought).
function wire_lazy_render!(model::ChatModel, bonito_session)
    on(model.request_tool_render) do tool_id
        isempty(tool_id) && return
        idx = findfirst(m -> m isa ToolMsg && m.id == tool_id, model.msgs_store)
        idx === nothing && return
        body = render_tool_body(model.state, model.msgs_store[idx], model.cwd;
                                 project_id = model.project_id)
        try
            Bonito.dom_in_js(bonito_session, body, js"""(elem) => {
                const slot = document.querySelector(
                    '.bt-tool-body[data-tool-id="' + $(tool_id) + '"]');
                if (slot) { slot.innerHTML = ''; slot.appendChild(elem); }
            }""")
        catch e
            @warn "tool render failed" tool_id exception=e
        end
    end
    on(model.request_thought_render) do thought_id
        isempty(thought_id) && return
        idx = findfirst(m -> m isa ThoughtMsg && m.id == thought_id, model.msgs_store)
        idx === nothing && return
        html = sprint(show, MIME("text/html"),
                      Markdown.parse(model.msgs_store[idx].text))
        chat_emit(model, Dict{String,Any}("type" => "thought_body",
                                            "id"   => thought_id, "html" => html))
    end
    return nothing
end

function wire_range_request!(model::ChatModel)
    on(model.request_range) do rng
        isempty(rng) && return
        s, e = Int(rng[1]), Int(rng[2])
        n = length(model.msgs_store)
        s = clamp(s, 0, n - 1);  e = clamp(e, 0, n - 1)
        s > e && return
        batch = [msg_to_dict(model.msgs_store[i]) for i in (s+1):(e+1)]
        model.range_response[] = JSON.json(Dict{String,Any}(
            "start" => s, "messages" => batch))
    end
end

# Compose the chat's full DOM. Returns a DOM block (no App wrapping) so the
# unified single-page App can drop it into its main panel directly.
function chat_dom(model::ChatModel, bonito_session)
    wire_range_request!(model)
    wire_lazy_render!(model, bonito_session)
    n = length(model.msgs_store)
    evaljs(bonito_session, js"""
        window.initBonitoChat({
            totalCount:           $(model.total_count),
            requestRange:         $(model.request_range),
            rangeResponse:        $(model.range_response),
            newMsg:               $(model.new_msg_obs),
            requestToolRender:    $(model.request_tool_render),
            requestThoughtRender: $(model.request_thought_render),
            initialCount:         $n,
        });
    """)
    DOM.div(
        chat_header(model),
        chat_session_banner(model),
        DOM.div(DOM.div(class="bt-spacer-top"),
                DOM.div(class="bt-spacer-bottom");
                class="bt-messages"),
        DOM.div(DOM.div(class="bt-busy-dot"),
                DOM.div(class="bt-busy-dot"),
                DOM.div(class="bt-busy-dot");
                class="bt-busy"),
        chat_input_area(model, bonito_session);
        class = "bt-app")
end

# Top-level: build the model, start the ACP client, fire any auto_prompt,
# then return an App that renders the chat DOM. <50 LOC because every step
# delegates.
function chat_app(state::ServerState, cwd::String;
                  project_id::String = "",
                  mcp_servers    = AgentClientProtocol.MCPServer[],
                  client_factory = nothing)
    model = ChatModel(state, cwd;
                       project_id    = project_id,
                       mcp_servers   = mcp_servers,
                       client_factory = client_factory)
    start_chat_client!(model)
    fire_auto_prompt!(model)
    App() do bonito_session
        DOM.div(
            ChatStyles, BonitoTeamJS, Bonito.MarkdownCSS,
            Bonito.ConnectionIndicator(),
            chat_dom(model, bonito_session))
    end
end
