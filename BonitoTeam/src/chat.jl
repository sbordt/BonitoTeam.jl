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

function render_tool_body(m::ToolMsg, cwd::AbstractString)
    content = load_tool_content(cwd, m.id)
    isempty(content) &&
        return DOM.div("(no body — tool details not persisted for this entry)",
                       class = "bt-tool-empty")

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
function chat_app(cwd::String;
                  project_id::String = "",
                  mcp_servers    = AgentClientProtocol.MCPServer[],
                  client_factory = nothing)
    chat_session = load_session(cwd)
    msgs_store   = load_history(chat_session)
    agent_id     = Ref("")
    thought_id   = Ref("")
    # Tracks whether a user_message_chunk replay is currently in flight,
    # so consecutive chunks accumulate into one UserMsg bubble. Live user
    # input never goes through on_update, so this only matters during
    # session/load replay.
    user_streaming = Ref(false)
    client       = Ref{Union{AgentClientProtocol.Client,Nothing}}(nothing)

    # Observables
    # Julia → JS
    total_count    = Observable(length(msgs_store))
    new_msg_obs    = Observable("")           # JSON: typed event
    range_response = Observable("")           # JSON: {start, messages}

    # JS → Julia
    request_range          = Observable(Any[])  # [start_idx, end_idx]
    request_tool_render    = Observable("")     # tool_id
    request_thought_render = Observable("")     # thought_id

    function push_msg!(msg::ChatMsg)
        push!(msgs_store, msg)
        total_count[] = length(msgs_store)
        new_msg_obs[] = JSON.json(msg_to_dict(msg))
    end

    function emit(event::Dict)
        new_msg_obs[] = JSON.json(event)
    end

    # ACP update handlers
    #
    # All three streaming handlers (user/agent/thought) follow the same shape:
    #   1. If we're already streaming the same type → accumulate by ID lookup
    #      (NOT msgs_store[end] — interleaved events from session/load replay
    #      can put a different message there).
    #   2. Otherwise → finalize_streaming! to close any other in-flight stream,
    #      then push a fresh message and remember its ID.
    function finalize_streaming!()
        # User messages are persisted at creation (append_user runs in
        # on_update(::UserMessageChunk) the moment the first chunk arrives),
        # so closing the stream just clears the in-flight flag.
        user_streaming[] = false
        if !isempty(thought_id[])
            idx = findfirst(m -> m isa ThoughtMsg && m.id == thought_id[], msgs_store)
            if idx !== nothing
                m = msgs_store[idx]
                append_thought(chat_session, m)
                html = sprint(show, MIME("text/html"), Markdown.parse(m.text))
                emit(Dict{String,Any}("type" => "thought_final", "id" => m.id, "html" => html))
            end
            thought_id[] = ""
        end
        if !isempty(agent_id[])
            idx = findfirst(m -> m isa AgentMsg && m.id == agent_id[], msgs_store)
            if idx !== nothing
                m = msgs_store[idx]
                finalize_agent(chat_session, m)
                html = sprint(show, MIME("text/html"), Markdown.parse(m.text))
                emit(Dict{String,Any}("type" => "agent_final", "id" => m.id, "html" => html))
            end
            agent_id[] = ""
        end
    end

    function on_update(upd::UserMessageChunk)
        upd.content isa TextContent || return
        text = upd.content.text
        if !user_streaming[]
            finalize_streaming!()
            user_streaming[] = true
            msg = UserMsg(text)
            push!(msgs_store, msg)
            append_user(chat_session, msg)
            total_count[] = length(msgs_store)
            emit(Dict{String,Any}("type" => "user", "text" => text))
        else
            # Accumulate into the most-recent UserMsg (the in-flight one).
            idx = findlast(m -> m isa UserMsg, msgs_store)
            idx === nothing && return
            msgs_store[idx].text *= text
            emit(Dict{String,Any}("type" => "user_chunk", "text" => text))
        end
    end

    function on_update(upd::AgentMessageChunk)
        upd.content isa TextContent || return
        text = upd.content.text
        if isempty(agent_id[])
            finalize_streaming!()
            id = string(uuid4())
            agent_id[] = id
            msg = AgentMsg(id, text)
            push!(msgs_store, msg)
            total_count[] = length(msgs_store)
            emit(Dict{String,Any}("type" => "agent", "id" => id,
                                  "html" => "", "streaming" => true))
        else
            idx = findfirst(m -> m isa AgentMsg && m.id == agent_id[], msgs_store)
            idx === nothing && return
            msgs_store[idx].text *= text
            emit(Dict{String,Any}("type" => "chunk", "id" => agent_id[], "text" => text))
        end
    end

    function on_update(upd::AgentThoughtChunk)
        upd.content isa TextContent || return
        text = upd.content.text
        # claude-agent-acp's session/load replay emits placeholder thought
        # chunks with empty content — the underlying jsonl doesn't persist
        # thought text, so the agent fakes "there was thinking here" markers.
        # Live sessions deliver real text; this filters the placeholders out
        # so we don't spawn empty bubbles after a resume.
        isempty(text) && return
        if isempty(thought_id[])
            finalize_streaming!()
            id = string(uuid4())
            thought_id[] = id
            msg = ThoughtMsg(id, text)
            push!(msgs_store, msg)
            total_count[] = length(msgs_store)
            emit(Dict{String,Any}("type" => "thought", "id" => id,
                                  "html" => "", "streaming" => true))
        else
            idx = findfirst(m -> m isa ThoughtMsg && m.id == thought_id[], msgs_store)
            idx === nothing && return
            msgs_store[idx].text *= text
            emit(Dict{String,Any}("type" => "thought_chunk", "id" => thought_id[], "text" => text))
        end
    end

    function on_update(upd::ToolCallNotif)
        finalize_streaming!()
        update_tool_file!(cwd, upd.tool_call_id, upd.raw)
        summary = content_summary(upd.kind, upd.content)
        msg = ToolMsg(upd.tool_call_id, upd.kind, upd.title, upd.status, summary)
        push_msg!(msg)
        upd.status in ("completed", "failed") && append_tool(chat_session, msg)
    end

    function on_update(upd::ToolCallUpdateNotif)
        idx = findfirst(m -> m isa ToolMsg && m.id == upd.tool_call_id, msgs_store)
        idx === nothing && return
        m = msgs_store[idx]
        update_tool_file!(cwd, upd.tool_call_id, upd.raw)
        upd.status !== nothing && (m.status = upd.status)
        upd.title  !== nothing && (m.title  = upd.title)
        # Only refresh summary when this update actually carries content
        # (status-only updates leave the prior summary in place).
        if !isempty(upd.content)
            m.summary = content_summary(m.kind, upd.content)
        end
        emit(Dict{String,Any}("type"    => "tool_update",
                              "id"      => m.id,
                              "status"  => m.status,
                              "title"   => m.title,
                              "summary" => m.summary))
        m.status in ("completed", "failed") && append_tool(chat_session, m)
    end

    function on_update(upd::PlanUpdate)
        finalize_streaming!()
        msg = PlanMsg(upd.entries)
        push_msg!(msg)
        append_plan(chat_session, msg)
    end

    on_update(::SessionUpdate) = nothing

    # Range request handler (JS asks for a slice of msgs_store)
    on(request_range) do rng
        isempty(rng) && return
        s = Int(rng[1]);  e = Int(rng[2])
        n = length(msgs_store)
        s = clamp(s, 0, n - 1);  e = clamp(e, 0, n - 1)
        s > e && return
        batch = [msg_to_dict(msgs_store[i]) for i in s+1:e+1]
        range_response[] = JSON.json(Dict{String,Any}("start" => s, "messages" => batch))
    end

    # Start ACP session
    client[] = if client_factory !== nothing
        client_factory(on_update)
    else
        AgentClientProtocol.Client(cwd; on_update, mcp_servers)
    end
    update_session_id!(chat_session, client[].session_id)

    # Expose the live client to test harnesses + future programmatic
    # drivers so they can call AgentClientProtocol.prompt!() without
    # going through the UI's send-button observable. Keyed by project_id;
    # chat_app instances without a project_id (e.g. unit-test apps) skip.
    if !isempty(project_id)
        @info "registering CHAT_CLIENTS" project_id session_id=client[].session_id
        BonitoTeam.CHAT_CLIENTS[project_id] = client
    end

    # Session-health state surfaced in the UI. Flipped to false when prompt!
    # raises (worker WS dropped, ACP subprocess died, etc.); the chat banner
    # uses this to show "session ended — restart?" with a button.
    session_alive = Observable(true)
    last_error    = Observable("")

    function restart_session!()
        try
            old = client[]
            if old !== nothing
                # Best-effort close of the old conn so the worker stops sending.
                try AgentClientProtocol.send_request(old.conn, "session/cancel",
                                                      Dict("sessionId" => old.session_id)) catch end
            end
            client[] = if client_factory !== nothing
                client_factory(on_update)
            else
                AgentClientProtocol.Client(cwd; on_update, mcp_servers)
            end
            update_session_id!(chat_session, client[].session_id)
            session_alive[] = true
            last_error[]    = ""
        catch e
            last_error[] = "restart failed: $(sprint(showerror, e))"
        end
    end

    # Bonito App
    App() do bonito_session
        text_val  = Observable("")
        # Inline SVG icons render crisply at any size, independent of installed
        # fonts (Arial's ▶ glyph is tiny on Linux).
        send_icon = Bonito.HTML(
            """<svg viewBox="0 0 24 24" width="20" height="20" fill="none"
                    stroke="currentColor" stroke-width="2.2"
                    stroke-linecap="round" stroke-linejoin="round">
                 <line x1="12" y1="19" x2="12" y2="5"></line>
                 <polyline points="5 12 12 5 19 12"></polyline>
               </svg>""")
        stop_icon = Bonito.HTML(
            """<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                 <rect x="5" y="5" width="14" height="14" rx="2.5"></rect>
               </svg>""")
        send_btn  = Bonito.Button(send_icon; style=nothing, class="bt-send-btn",
                                  title="Send (Enter)")
        stop_btn  = Bonito.Button(stop_icon; style=nothing, class="bt-stop-btn",
                                  title="Stop generation")

        text_input = DOM.textarea(
            "";
            placeholder="Message…",
            title="Enter to send  ·  Shift+Enter for newline",
            class="bt-text-input",
            rows=1,
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
            }"""
        )

        on(send_btn.value) do clicked
            clicked || return
            text = strip(text_val[])
            isempty(text) && return
            text_val[] = ""
            evaljs(bonito_session, js"$(text_input).value = ''; $(text_input).style.height = 'auto';")

            user_msg = UserMsg(String(text))
            push_msg!(user_msg)
            append_user(chat_session, user_msg)
            agent_id[] = ""
            emit(Dict{String,Any}("type" => "busy_start"))

            @async begin
                try
                    AgentClientProtocol.prompt!(client[], String(text))
                    finalize_streaming!()
                catch e
                    # Distinguish transient errors from session death. If the
                    # underlying ACP connection is gone, the chat banner shows
                    # the restart affordance; otherwise we still log the error
                    # inline as a chat bubble so the user has context.
                    msg = sprint(showerror, e)
                    if occursin("connection closed", msg) ||
                       occursin("EOFError",          msg) ||
                       occursin("BrokenPipe",        msg)
                        session_alive[] = false
                        last_error[]    = msg
                    else
                        id = string(uuid4())
                        err_msg = AgentMsg(id, "[error: $msg]")
                        push_msg!(err_msg)
                        finalize_agent(chat_session, err_msg)
                    end
                finally
                    emit(Dict{String,Any}("type" => "busy_end"))
                end
            end
        end

        on(stop_btn.value) do clicked
            clicked || return
            c = client[]
            c !== nothing && AgentClientProtocol.cancel!(c)
        end

        # Lazy tool-body rendering: when the user clicks expand on a tool, JS
        # notifies request_tool_render with the tool_id; we look up the
        # ToolMsg, build its body (Monaco / DiffEditor / Markdown), and ship
        # it via Bonito.dom_in_js — which creates a sub-session, ships the
        # rendered HTML+init JS, and runs the supplied function on the JS
        # side to inject it into the right placeholder.
        on(request_tool_render) do tool_id
            isempty(tool_id) && return
            idx = findfirst(m -> m isa ToolMsg && m.id == tool_id, msgs_store)
            idx === nothing && return
            body = render_tool_body(msgs_store[idx], cwd)
            try
                Bonito.dom_in_js(bonito_session, body, js"""(elem) => {
                    const slot = document.querySelector(
                        '.bt-tool-body[data-tool-id="' + $(tool_id) + '"]');
                    if (slot) {
                        slot.innerHTML = '';
                        slot.appendChild(elem);
                    }
                }""")
            catch e
                @warn "tool render failed" tool_id exception=e
            end
        end

        # Lazy thought body rendering: msg_to_dict ships a header only; when
        # the user expands the <details>, JS notifies request_thought_render
        # with the thought id and we ship the rendered HTML back via emit.
        on(request_thought_render) do thought_id
            isempty(thought_id) && return
            idx = findfirst(m -> m isa ThoughtMsg && m.id == thought_id, msgs_store)
            idx === nothing && return
            html = sprint(show, MIME("text/html"), Markdown.parse(msgs_store[idx].text))
            emit(Dict{String,Any}("type" => "thought_body",
                                  "id"   => thought_id,
                                  "html" => html))
        end

        n = length(msgs_store)
        evaljs(bonito_session, js"""
            window.initBonitoChat({
                totalCount:           $(total_count),
                requestRange:         $(request_range),
                rangeResponse:        $(range_response),
                newMsg:               $(new_msg_obs),
                requestToolRender:    $(request_tool_render),
                requestThoughtRender: $(request_thought_render),
                initialCount:         $n,
            });
        """)

        # Status dot reflects ACP session health, not Bonito's WS — the WS
        # indicator is the floater in the corner, this is "is claude alive".
        status_dot = map(session_alive) do alive
            DOM.span(""; class = alive ? "bt-dot bt-dot-online" : "bt-dot bt-dot-offline",
                         title = alive ? "session live" : "session ended")
        end

        # Restart banner shown when the agent died. Hidden when alive=true.
        restart_btn_inner = Bonito.Button("Restart session"; style=nothing,
                                          class = "bt-btn bt-btn-secondary")
        on(restart_btn_inner.value) do clicked
            clicked && @async restart_session!()
        end
        banner = map(session_alive, last_error) do alive, err
            alive && return DOM.div()
            DOM.div(
                DOM.div(
                    DOM.span("⚠ Session ended"; style = "font-weight:600"),
                    DOM.div(isempty(err) ? "The agent connection was closed." : err;
                            class = "bt-banner-detail");
                    style = "flex:1 1 auto; min-width:0"),
                restart_btn_inner;
                class = "bt-banner-error")
        end

        # Top-left chat menu. JS-only popover so we don't burn an extra
        # observable trip just to toggle visibility. Items use observables
        # (sync_click, etc.) for the actual actions.
        sync_click  = Observable("")
        sync_status = Observable("")    # human-readable status line for the menu
        on(sync_click) do tag
            isempty(tag) && return
            sync_click[] = ""
            isempty(project_id) && (sync_status[] = "no project bound"; return)
            handle_chat_sync_click(project_id, sync_status)
        end

        menu_block = DOM.div(
            DOM.button("☰";
                class = "bt-header-back",
                title = "Project menu",
                onclick = js"""event => {
                    const m = event.currentTarget.nextElementSibling;
                    m.classList.toggle('bt-menu-open');
                    event.stopPropagation();
                }"""),
            DOM.div(
                DOM.div("Sync to server";
                    class = "bt-menu-item",
                    onclick = js"""event => {
                        event.currentTarget.closest('.bt-menu')
                                            .classList.remove('bt-menu-open');
                        $(sync_click).notify('sync');
                    }"""),
                DOM.a("Open dashboard"; href = Bonito.Link("/"),
                       class = "bt-menu-item",
                       target = "_blank"),
                map(sync_status) do msg
                    isempty(msg) ? DOM.div() :
                        DOM.div(msg;
                                class = "bt-menu-status",
                                style = "padding:6px 12px;font-size:12px;color:var(--bt-text-muted)")
                end;
                class = "bt-menu");
            class = "bt-header-menu",
            # Click-outside-to-close: a single document-level listener that
            # closes any open .bt-menu when the click isn't inside one.
            onclick = js"event => event.stopPropagation()")

        DOM.div(
            ChatStyles,
            BonitoTeamJS,
            Bonito.MarkdownCSS,
            DOM.style("""
                .bt-header-menu { position: relative; display: inline-block; }
                .bt-menu {
                    position: absolute; left: 0; top: calc(100% + 4px);
                    min-width: 200px;
                    background: var(--bt-surface, #fff);
                    border: 1px solid var(--bt-border, #e5e7eb);
                    border-radius: 8px;
                    box-shadow: 0 4px 16px rgba(0,0,0,0.08);
                    padding: 4px 0;
                    display: none;
                    z-index: 100;
                }
                .bt-menu.bt-menu-open { display: block; }
                .bt-menu-item {
                    display: block; padding: 8px 12px;
                    cursor: pointer; color: var(--bt-text, #111827);
                    text-decoration: none; font-size: 13px;
                }
                .bt-menu-item:hover { background: var(--bt-surface-2, #f3f4f6); }
            """),
            DOM.script(js"""
                // Click anywhere outside the menu closes it.
                document.addEventListener('click', () => {
                    document.querySelectorAll('.bt-menu.bt-menu-open')
                            .forEach(m => m.classList.remove('bt-menu-open'));
                });
            """),
            # Live WS-connection indicator (fixed top-right corner).
            Bonito.ConnectionIndicator(),
            DOM.div(
                DOM.div(
                    DOM.a("←"; href = Bonito.Link("/"), class = "bt-header-back",
                           title = "Back to dashboard"),
                    menu_block,
                    status_dot,
                    DOM.div(
                        DOM.span(basename(rstrip(cwd, '/'))),
                        DOM.span(cwd; class = "bt-header-cwd"),
                        class = "bt-header-title");
                    class = "bt-header-row");
                class = "bt-header"),
            banner,
            DOM.div(
                DOM.div(class="bt-spacer-top"),
                DOM.div(class="bt-spacer-bottom"),
                class="bt-messages"),
            DOM.div(
                DOM.div(class="bt-busy-dot"),
                DOM.div(class="bt-busy-dot"),
                DOM.div(class="bt-busy-dot"),
                class="bt-busy"),
            DOM.div(
                DOM.div(text_input, send_btn, stop_btn, class = "bt-input-row");
                class = "bt-input-area"),
            class="bt-app")
    end
end
