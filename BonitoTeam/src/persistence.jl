import CommonMark as CM

# Session metadata + file path
struct ChatSession
    session_id::String      # ACP session ID (for --resume)
    cwd::String
    created::DateTime
    path::String            # absolute path to chat.md
end

function session_dir(cwd::String)
    d = joinpath(cwd, ".bonitoTeam")
    mkpath(d)
    return d
end

function session_file(cwd::String)
    joinpath(session_dir(cwd), "chat.md")
end

# Per-tool JSON snapshot of the latest ACP params (the wire format itself), so
# tool bodies survive restarts and don't have to live in process memory.
function tools_dir(cwd::String)
    d = joinpath(session_dir(cwd), "tools")
    mkpath(d)
    return d
end

function tool_file(cwd::String, tool_id::String)
    joinpath(tools_dir(cwd), tool_id * ".json")
end

# ACP sends either a full snapshot (initial notif + final update with content)
# or status-only updates with `content: []`. We only persist when there's real
# content; status/title transitions live in memory on ToolMsg.
function update_tool_file!(cwd::String, tool_id::String, params::AbstractDict)
    content = get(params, "content", nothing)
    (content === nothing || isempty(content)) && return nothing
    path = tool_file(cwd, tool_id)
    open(io -> JSON.print(io, params), path, "w")
    return params
end

function load_tool_file(cwd::String, tool_id::String)::Union{AbstractDict,Nothing}
    path = tool_file(cwd, tool_id)
    isfile(path) || return nothing
    return open(JSON.parse, path)
end

# Load or create a session
function load_session(cwd::String)::ChatSession
    path = session_file(cwd)
    if isfile(path)
        session = parse_session_meta(path, cwd)
        session !== nothing && return session
    end
    # Create fresh session
    session = ChatSession("", cwd, now(UTC), path)
    write_session_header(session)
    return session
end

function parse_session_meta(path::String, cwd::String)::Union{ChatSession,Nothing}
    src = read(path, String)
    parser = CM.Parser()
    CM.enable!(parser, CM.FrontMatterRule(toml=TOML.parse))
    ast = parser(src)
    for (node, entering) in ast
        node.t isa CM.FrontMatter && entering || continue
        data = node.t.data
        sid  = get(data, "session_id", "")
        ts   = get(data, "created", string(now(UTC)))
        created = try DateTime(ts) catch; now(UTC) end
        return ChatSession(sid, cwd, created, path)
    end
    return nothing
end

function write_session_header(session::ChatSession)
    open(session.path, "w") do io
        println(io, "+++")
        println(io, "session_id = $(repr(session.session_id))")
        println(io, "cwd = $(repr(session.cwd))")
        println(io, "created = $(repr(string(session.created)))")
        println(io, "+++")
        println(io)
    end
end

function update_session_id!(session::ChatSession, new_id::String)
    # Rewrite only the header, preserving the rest of the file
    path = session.path
    content = isfile(path) ? read(path, String) : "\n"
    # Strip existing +++ block
    body = replace(content, r"^\+\+\+.*?\+\+\+\n"s => ""; count=1)
    new_session = ChatSession(new_id, session.cwd, session.created, path)
    open(path, "w") do io
        println(io, "+++")
        println(io, "session_id = $(repr(new_session.session_id))")
        println(io, "cwd = $(repr(new_session.cwd))")
        println(io, "created = $(repr(string(new_session.created)))")
        println(io, "+++")
        print(io, body)
    end
end

# Append messages
function append_user(session::ChatSession, msg::UserMsg)
    open(session.path, "a") do io
        println(io, "!!! user \"$(now(UTC))\"")
        for line in split(msg.text, '\n')
            println(io, "    ", line)
        end
        println(io)
    end
end

function finalize_agent(session::ChatSession, msg::AgentMsg)
    isempty(msg.text) && return
    open(session.path, "a") do io
        println(io, "!!! assistant \"$(now(UTC))\"")
        for line in split(msg.text, '\n')
            println(io, "    ", line)
        end
        println(io)
    end
end

function append_tool(session::ChatSession, msg::ToolMsg)
    open(session.path, "a") do io
        meta = "$(msg.kind) · $(msg.status) · $(msg.id)"
        println(io, "!!! tool \"$meta\"")
        println(io, "    `$(msg.title)`")
        # Brief summary on the collapsed header; full ACP body lives in
        # .bonitoTeam/tools/<id>.json (see update_tool_file!).
        if !isempty(msg.summary)
            println(io, "")
            println(io, "    $(msg.summary)")
        end
        println(io)
    end
end

function append_plan(session::ChatSession, msg::PlanMsg)
    open(session.path, "a") do io
        println(io, "!!! plan")
        # Write as plain lines (not markdown list) so admonition_text can round-trip them
        for e in msg.entries
            mark = e.status == "completed" ? "x" : " "
            println(io, "    [$mark] $(e.content)")
        end
        println(io)
    end
end

# Load history from file
function load_history(session::ChatSession)::Vector{ChatMsg}
    isfile(session.path) || return ChatMsg[]
    src = read(session.path, String)

    parser = CM.Parser()
    CM.enable!(parser, CM.FrontMatterRule(toml=TOML.parse))
    CM.enable!(parser, CM.AdmonitionRule())
    ast = parser(src)

    msgs = ChatMsg[]
    for (node, entering) in ast
        (node.t isa CM.Admonition && entering) || continue
        cat  = node.t.category   # "user", "assistant", "tool", "plan"
        body = admonition_text(node)

        if cat == "user"
            push!(msgs, UserMsg(body))
        elseif cat == "assistant"
            push!(msgs, AgentMsg(string(length(msgs)), body))
        elseif cat == "tool"
            # title encodes "kind · status · id"
            parts = split(node.t.title, " · "; limit=3)
            kind, status, id = length(parts) == 3 ? parts : ("other", "completed", "")
            # body is `<tool title>`\n\n<summary>; first backticked run is the
            # title, anything after is the cached summary line.
            title_line = match(r"`([^`]*)`", body)
            title = title_line !== nothing ? title_line.captures[1] : ""
            summary = ""
            if title_line !== nothing
                tail = strip(body[nextind(body, title_line.offset + length(title_line.match) - 1):end])
                summary = String(tail)
            end
            push!(msgs, ToolMsg(string(id), string(kind), string(title),
                                string(status), summary))
        elseif cat == "plan"
            entries = PlanEntry[]
            for line in split(body, '\n')
                m = match(r"\[( |x)\] (.+)", line)
                m === nothing && continue
                status = m.captures[1] == "x" ? "completed" : "pending"
                push!(entries, PlanEntry(string(m.captures[2]), "", status))
            end
            isempty(entries) || push!(msgs, PlanMsg(entries))
        end
    end
    return msgs
end

function admonition_text(admonition_node)::String
    lines = String[]
    for (n, entering) in admonition_node
        n === admonition_node && continue   # skip the root itself
        if n.t isa CM.Text && entering
            push!(lines, n.literal)
        elseif n.t isa CM.SoftBreak && entering
            push!(lines, "\n")
        elseif n.t isa CM.LineBreak && entering
            push!(lines, "\n")
        elseif n.t isa CM.CodeBlock && entering
            push!(lines, "\n```$(n.t.info)\n$(n.literal)```\n")
        elseif n.t isa CM.Code && entering
            push!(lines, "`$(n.literal)`")
        end
    end
    strip(join(lines))
end
