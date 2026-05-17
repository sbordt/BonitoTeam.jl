import CommonMark as CM

# Session metadata + file path
struct ChatSession
    session_id::String      # ACP session ID (for --resume)
    cwd::String             # project working dir (for claude --cwd / display)
    created::DateTime
    path::String            # absolute path to chat.md (server-state-managed)
end

"""
    chat_storage_dir(state, project_id, cwd) -> String

Resolve the directory holding chat.md + tools/ for a project. Server-owned
state, lives alongside `workers.json` / `projects.json` under
`state.state_dir/chats/<project_id>/`. This deliberately sits OUTSIDE the
project tree so:

- Project sync never has to ignore it (the project tree is "code only")
- Project rename / move / re-sync to another worker can't lose chat history
- A worker without `.bonitoTeam` (which is every worker — chat is generated
  server-side from ACP events) can't accidentally clobber the server's
  chat by being the sync source

Legacy fallback `<cwd>/.bonitoTeam/` is kept for project_id-less callers
(tests, ad-hoc chats outside the project registry). A one-shot migration
`mv`s any pre-existing `<cwd>/.bonitoTeam/` into the new home the first
time a project loads under the new layout.
"""
function chat_storage_dir(state, project_id::AbstractString, cwd::AbstractString)
    if !isempty(project_id)
        new_dir = joinpath(state.state_dir, "chats", String(project_id))
        old_dir = joinpath(cwd, ".bonitoTeam")
        if isdir(old_dir) && !isdir(new_dir)
            mkpath(dirname(new_dir))
            try
                mv(old_dir, new_dir)
                @info "migrated chat storage to state_dir" project_id from=old_dir to=new_dir
            catch e
                # Cross-device mv fails on some setups; fall back to copy+rm.
                @warn "mv failed during chat-storage migration, copying" exception=e
                mkpath(new_dir)
                cp(old_dir, new_dir; force=true)
                rm(old_dir; recursive=true, force=true)
            end
        end
        mkpath(new_dir)
        return new_dir
    end
    # No project id: orphan chat, keep legacy in-tree storage.
    d = joinpath(cwd, ".bonitoTeam")
    mkpath(d)
    return d
end

session_file(chat_dir::AbstractString) = joinpath(String(chat_dir), "chat.md")

# Per-tool JSON snapshot of the latest ACP params (the wire format itself), so
# tool bodies survive restarts and don't have to live in process memory.
function tools_dir(chat_dir::AbstractString)
    d = joinpath(String(chat_dir), "tools")
    mkpath(d)
    return d
end

tool_file(chat_dir::AbstractString, tool_id::AbstractString) =
    joinpath(tools_dir(chat_dir), String(tool_id) * ".json")

# ACP sends either a full snapshot (initial notif + final update with content)
# or status-only updates with `content: []`. We only persist when there's real
# content; status/title transitions live in memory on ToolMsg.
function update_tool_file!(chat_dir::AbstractString, tool_id::AbstractString, params::AbstractDict)
    content = get(params, "content", nothing)
    (content === nothing || isempty(content)) && return nothing
    path = tool_file(chat_dir, tool_id)
    open(io -> JSON.print(io, params), path, "w")
    return params
end

function load_tool_file(chat_dir::AbstractString, tool_id::AbstractString)::Union{AbstractDict,Nothing}
    path = tool_file(chat_dir, tool_id)
    isfile(path) || return nothing
    return open(JSON.parse, path)
end

# Load or create a session. `chat_dir` is where chat.md lives (resolved via
# `chat_storage_dir`); `cwd` is the project's working dir (recorded on the
# ChatSession for display + claude resume).
function load_session(chat_dir::AbstractString, cwd::AbstractString)::ChatSession
    path = session_file(chat_dir)
    if isfile(path)
        session = parse_session_meta(path, String(cwd))
        session !== nothing && return session
    end
    # Create fresh session
    session = ChatSession("", String(cwd), now(UTC), path)
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

# Appended on stream-finalize (a tool call / next message arrives after
# thought chunks). Persisted so a chat reload or agent restart keeps the
# thinking trail visible. Empty thoughts (zero-byte chunks observed during
# replay edge cases) are skipped to keep chat.md clean.
function append_thought(session::ChatSession, msg::ThoughtMsg)
    isempty(strip(msg.text)) && return
    open(session.path, "a") do io
        println(io, "!!! thought \"$(msg.id)\"")
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
        # the chat-storage `tools/<id>.json` (see update_tool_file!).
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
