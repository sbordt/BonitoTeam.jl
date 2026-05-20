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

# Load history from file.
#
# chat.md is hand-written by the `append_*` / `finalize_*` writers above in a
# fixed shape: a `+++` TOML front-matter block, then a sequence of admonition
# blocks — a `!!! <category> "<title>"` header followed by the body with every
# line indented 4 spaces. We parse it BY HAND rather than via CommonMark:
# CommonMark would re-parse each body as markdown, and reconstructing text
# from that AST is lossy (paragraph breaks, headings and tables all collapse —
# only inline `code` survives). The body is literally the message text + a
# 4-space indent, so the faithful inverse is just to strip the indent.
function load_history(session::ChatSession)::Vector{ChatMsg}
    isfile(session.path) || return ChatMsg[]
    lines = split(read(session.path, String), '\n')
    n = length(lines)

    i = 1
    # Skip the +++ front-matter block (parsed separately by parse_session_meta).
    if i <= n && strip(lines[i]) == "+++"
        i += 1
        while i <= n && strip(lines[i]) != "+++"
            i += 1
        end
        i <= n && (i += 1)   # step past the closing +++
    end

    msgs = ChatMsg[]
    # Admonition header: `!!! <category>` with an optional `"<title>"`.
    header = r"^!!! (\w+)(?:\s+\"(.*)\")?\s*$"
    while i <= n
        h = match(header, lines[i])
        if h === nothing
            i += 1
            continue
        end
        category = h.captures[1]
        title    = h.captures[2] === nothing ? "" : String(h.captures[2])
        i += 1
        # Body runs until the next admonition header (or EOF). Indented lines
        # are dedented by 4; blank lines are kept verbatim so paragraph breaks
        # survive. `strip` at the end drops the trailing separator blank.
        body_lines = String[]
        while i <= n && match(header, lines[i]) === nothing
            ln = lines[i]
            push!(body_lines, startswith(ln, "    ") ? chop(ln; head = 4, tail = 0) : ln)
            i += 1
        end
        body = strip(join(body_lines, '\n'))

        if category == "user"
            push!(msgs, UserMsg(String(body)))
        elseif category == "assistant"
            push!(msgs, AgentMsg(string(length(msgs)), String(body)))
        elseif category == "tool"
            # title encodes "kind · status · id"
            parts = split(title, " · "; limit = 3)
            kind, status, id = length(parts) == 3 ? parts : ("other", "completed", "")
            # body is `` `<tool title>` `` then an optional summary line.
            title_line = match(r"`([^`]*)`", body)
            tool_title = title_line !== nothing ? String(title_line.captures[1]) : ""
            summary = ""
            if title_line !== nothing
                tail = strip(body[nextind(body, title_line.offset + ncodeunits(title_line.match) - 1):end])
                summary = String(tail)
            end
            push!(msgs, ToolMsg(string(id), string(kind), tool_title,
                                string(status), summary))
        elseif category == "plan"
            entries = PlanEntry[]
            for line in split(body, '\n')
                m = match(r"\[( |x)\] (.+)", line)
                m === nothing && continue
                status = m.captures[1] == "x" ? "completed" : "pending"
                push!(entries, PlanEntry(String(m.captures[2]), "", status))
            end
            isempty(entries) || push!(msgs, PlanMsg(entries))
        end
        # `thought` admonitions are intentionally not reloaded (ephemeral).
    end
    return msgs
end
