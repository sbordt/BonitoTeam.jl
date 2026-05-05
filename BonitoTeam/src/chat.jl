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
    preview::String
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

# Serialise messages to JSON dicts for JS
function msg_to_dict(m::UserMsg)
    Dict{String,Any}("type" => "user", "text" => m.text)
end

function msg_to_dict(m::AgentMsg)
    html = sprint(show, MIME("text/html"), Markdown.parse(m.text))
    Dict{String,Any}("type" => "agent", "id" => m.id, "html" => html)
end

function msg_to_dict(m::ToolMsg)
    Dict{String,Any}(
        "type"    => "tool",
        "id"      => m.id,
        "kind"    => m.kind,
        "icon"    => tool_icon(m.kind),
        "title"   => m.title,
        "status"  => m.status,
        "preview" => m.preview,
    )
end

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

# Content preview (for tool calls)
function content_preview(items)
    for item in items
        item isa TextContent && return item.text[1:min(end, 120)]
        item isa DiffContent && return "+ $(item.path)"
    end
    return ""
end

# Chat app
function chat_app(cwd::String;
                  mcp_servers    = AgentClientProtocol.MCPServer[],
                  client_factory = nothing)   # (on_update::Function) → AgentClientProtocol.Client
    chat_session = load_session(cwd)
    msgs_store   = load_history(chat_session)
    agent_id     = Ref("")   # id of current streaming AgentMsg
    thought_id   = Ref("")   # id of current streaming ThoughtMsg
    client       = Ref{Union{AgentClientProtocol.Client,Nothing}}(nothing)

    # Observables
    # Julia → JS
    total_count    = Observable(length(msgs_store))
    new_msg_obs    = Observable("")   # JSON: typed event (see bonitoteam.js)
    range_response = Observable("")   # JSON: {start, messages}

    # JS → Julia
    request_range  = Observable(Any[])  # [start_idx, end_idx]  (0-based)

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
                      upd.status, content_preview(upd.content))
        push_msg!(msg)
        # Persist only when the notification itself is already terminal
        upd.status in ("completed", "failed") && append_tool(chat_session, msg)
    end

    function on_update(upd::ToolCallUpdateNotif)
        idx = findfirst(m -> m isa ToolMsg && m.id == upd.tool_call_id, msgs_store)
        idx === nothing && return
        m = msgs_store[idx]
        upd.status !== nothing && (m.status = upd.status)
        upd.title  !== nothing && (m.title  = upd.title)
        isempty(upd.content) || (m.preview = content_preview(upd.content))
        emit(Dict{String,Any}("type"    => "tool_update",
                              "id"      => m.id,
                              "status"  => m.status,
                              "title"   => m.title,
                              "preview" => m.preview))
        # Persist once the tool reaches a terminal state
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
        batch = [msg_to_dict(msgs_store[i]) for i in s+1:e+1]  # 0→1 indexed
        range_response[] = JSON.json(Dict{String,Any}("start" => s, "messages" => batch))
    end

    # Start ACP session
    client[] = if client_factory !== nothing
        client_factory(on_update)
    else
        AgentClientProtocol.Client(cwd; on_update, mcp_servers)
    end
    # Persist the session ID so we can display it; actual resume is via ACP protocol
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

        # Initialise BonitoChat; pass current count as plain number for immediate bootstrap
        n = length(msgs_store)
        evaljs(bonito_session, js"""
            window.initBonitoChat({
                totalCount:    $(total_count),
                requestRange:  $(request_range),
                rangeResponse: $(range_response),
                newMsg:        $(new_msg_obs),
                initialCount:  $n,
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
