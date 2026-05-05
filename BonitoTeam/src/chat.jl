const BonitoTeamJS = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "bonitoteam.js"))

# Message types
abstract type ChatMsg end

struct UserMsg <: ChatMsg
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
    content::Vector{Any}      # raw ACP content blocks (TextContent / DiffContent / ImageContent)
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
function content_summary(kind::AbstractString, content::AbstractVector)
    isempty(content) && return ""
    if kind == "edit"
        for c in content
            if c isa DiffContent
                old_n = length(split(something(c.old_text, ""), '\n'))
                new_n = length(split(c.new_text, '\n'))
                d     = new_n - old_n
                noun  = abs(d) == 1 ? "line" : "lines"
                return "$(basename(c.path)) · $(d > 0 ? "+$d" : d) $noun"
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

# Header info shipped to JS at message-create time. The full content is NOT
# included — JS asks via requestToolRender(id) when the user expands.
function tool_header_dict(m::ToolMsg)
    Dict{String,Any}(
        "type"    => "tool",
        "id"      => m.id,
        "kind"    => m.kind,
        "icon"    => tool_icon(m.kind),
        "title"   => m.title,
        "status"  => m.status,
        "summary" => content_summary(m.kind, m.content),
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

function msg_to_dict(m::ThoughtMsg)
    html = sprint(show, MIME("text/html"), Markdown.parse(m.text))
    Dict{String,Any}("type" => "thought", "id" => m.id, "html" => html)
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

function render_tool_body(m::ToolMsg)
    if m.kind == "edit"
        # Find a DiffContent block; render Monaco DiffEditor.
        for c in m.content
            if c isa DiffContent
                lang = detect_language(c.path)
                return BonitoBook.DiffEditor(
                    something(c.old_text, ""),
                    c.new_text;
                    language = lang,
                    renderSideBySide = false,
                )
            end
        end
    end

    if m.kind in ("execute", "read")
        # Concatenate text blocks; render with MonacoEditor (read-only).
        text = join((c.text for c in m.content if c isa TextContent), "\n")
        if !isempty(text)
            lang = m.kind == "read" ? detect_language(m.title) : "shell"
            return BonitoBook.MonacoEditor(text; language = lang, options = Dict(:readOnly => true))
        end
    end

    # Default / "think" / "other" / "search" / "fetch" / mixed:
    # render text blocks as Markdown so agents that emit ```julia ... ``` etc.
    # get language-aware code blocks. Diff blocks render via DiffEditor inline.
    parts = []
    for c in m.content
        if c isa TextContent
            push!(parts, DOM.div(Markdown.parse(c.text), class = "bt-tool-md"))
        elseif c isa DiffContent
            lang = detect_language(c.path)
            push!(parts, BonitoBook.DiffEditor(something(c.old_text, ""), c.new_text;
                                                language = lang,
                                                renderSideBySide = false))
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
                  mcp_servers    = AgentClientProtocol.MCPServer[],
                  client_factory = nothing)
    chat_session = load_session(cwd)
    msgs_store   = load_history(chat_session)
    agent_id     = Ref("")
    thought_id   = Ref("")
    client       = Ref{Union{AgentClientProtocol.Client,Nothing}}(nothing)

    # Observables
    # Julia → JS
    total_count    = Observable(length(msgs_store))
    new_msg_obs    = Observable("")           # JSON: typed event
    range_response = Observable("")           # JSON: {start, messages}

    # JS → Julia
    request_range        = Observable(Any[])  # [start_idx, end_idx]
    request_tool_render  = Observable("")     # tool_id

    function push_msg!(msg::ChatMsg)
        push!(msgs_store, msg)
        total_count[] = length(msgs_store)
        new_msg_obs[] = JSON.json(msg_to_dict(msg))
    end

    function emit(event::Dict)
        new_msg_obs[] = JSON.json(event)
    end

    # ACP update handlers
    function on_update(upd::AgentMessageChunk)
        upd.content isa TextContent || return
        text = upd.content.text
        if isempty(agent_id[])
            id = string(uuid4())
            agent_id[] = id
            msg = AgentMsg(id, text)
            push!(msgs_store, msg)
            total_count[] = length(msgs_store)
            emit(Dict{String,Any}("type" => "agent", "id" => id,
                                  "html" => "", "streaming" => true))
        else
            msgs_store[end].text *= text
            emit(Dict{String,Any}("type" => "chunk", "id" => agent_id[], "text" => text))
        end
    end

    function finalize_streaming!()
        if !isempty(thought_id[])
            idx = findfirst(m -> m isa ThoughtMsg && m.id == thought_id[], msgs_store)
            if idx !== nothing
                m = msgs_store[idx]
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

    function on_update(upd::AgentThoughtChunk)
        upd.content isa TextContent || return
        text = upd.content.text
        if isempty(thought_id[])
            id = string(uuid4())
            thought_id[] = id
            msg = ThoughtMsg(id, text)
            push!(msgs_store, msg)
            total_count[] = length(msgs_store)
            emit(Dict{String,Any}("type" => "thought", "id" => id,
                                  "html" => "", "streaming" => true))
        else
            msgs_store[end].text *= text
            emit(Dict{String,Any}("type" => "thought_chunk", "id" => thought_id[], "text" => text))
        end
    end

    function on_update(upd::ToolCallNotif)
        finalize_streaming!()
        msg = ToolMsg(upd.tool_call_id, upd.kind, upd.title,
                      upd.status, collect(upd.content))
        push_msg!(msg)
        upd.status in ("completed", "failed") && append_tool(chat_session, msg)
    end

    function on_update(upd::ToolCallUpdateNotif)
        idx = findfirst(m -> m isa ToolMsg && m.id == upd.tool_call_id, msgs_store)
        idx === nothing && return
        m = msgs_store[idx]
        upd.status !== nothing && (m.status = upd.status)
        upd.title  !== nothing && (m.title  = upd.title)
        if !isempty(upd.content)
            # ACP tool-call updates often carry the COMPLETE current content,
            # not just an incremental delta. Replace, don't append.
            m.content = collect(upd.content)
        end
        emit(Dict{String,Any}("type"    => "tool_update",
                              "id"      => m.id,
                              "status"  => m.status,
                              "title"   => m.title,
                              "summary" => content_summary(m.kind, m.content)))
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

    # Bonito App
    App() do bonito_session
        text_val  = Observable("")
        send_btn  = Bonito.Button("▶"; style=nothing, class="bt-send-btn")
        stop_btn  = Bonito.Button("■"; style=nothing, class="bt-stop-btn")

        text_input = DOM.textarea(
            "";
            placeholder="Message (Shift+Enter for newline)",
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
                    id = string(uuid4())
                    err_msg = AgentMsg(id, "[error: $e]")
                    push_msg!(err_msg)
                    finalize_agent(chat_session, err_msg)
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
            body = render_tool_body(msgs_store[idx])
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

        n = length(msgs_store)
        evaljs(bonito_session, js"""
            window.initBonitoChat({
                totalCount:        $(total_count),
                requestRange:      $(request_range),
                rangeResponse:     $(range_response),
                newMsg:            $(new_msg_obs),
                requestToolRender: $(request_tool_render),
                initialCount:      $n,
            });
        """)

        DOM.div(
            ChatStyles,
            BonitoTeamJS,
            Bonito.MarkdownCSS,
            DOM.div("BonitoTeam — ", DOM.code(cwd), class="bt-header"),
            DOM.div(
                DOM.div(class="bt-spacer-top"),
                DOM.div(class="bt-spacer-bottom"),
                class="bt-messages"),
            DOM.div(
                DOM.div(class="bt-busy-dot"),
                DOM.div(class="bt-busy-dot"),
                DOM.div(class="bt-busy-dot"),
                class="bt-busy"),
            DOM.div(text_input, send_btn, stop_btn, class="bt-input-area"),
            class="bt-app")
    end
end
