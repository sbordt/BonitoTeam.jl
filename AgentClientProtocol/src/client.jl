# High-level ACP client: manages one claude-agent-acp subprocess per instance.
#
# Usage:
#   handler = MyCustomHandler(...)   # subtype of Handler with on_update overloads
#   client  = AgentClientProtocol.Client(cwd, handler)
#   AgentClientProtocol.prompt!(client, "hello")   # blocks until end_turn/cancelled
#   AgentClientProtocol.cancel!(client)

struct MCPServer
    name::String
    command::String
    args::Vector{String}
    env::Dict{String,String}
end

MCPServer(name, command; args=String[], env=Dict{String,String}()) =
    MCPServer(name, command, args, env)

mutable struct Client
    conn::Connection
    session_id::String
    cwd::String
end

# Default request handler for the local-subprocess Client. Handles the
# fs/terminal/permission RPCs claude-agent-acp can fire. Holds the cwd so
# `fs/read_text_file` / `fs/write_text_file` can be sandboxed if needed
# later — for now it just uses the path the agent sends.
struct FSRequestHandler <: Handler
    cwd::String
end

# Custom handlers compose with FSRequestHandler by wrapping it: the chat
# layer's ChatHandler delegates its on_request to a FSRequestHandler
# instance. Update handling is per-subtype, see e.g. BonitoTeam.ChatHandler.
function on_request(h::FSRequestHandler, method::AbstractString, params)
    if method == "fs/read_text_file"
        path = get(params, "path", "")
        return Dict("content" => read(path, String))

    elseif method == "fs/write_text_file"
        path = get(params, "path", "")
        content = get(params, "content", "")
        mkpath(dirname(path))
        write(path, content)
        return nothing

    elseif method == "session/request_permission"
        # bypassPermissions should prevent this; auto-allow if it appears anyway.
        options = get(params, "options", [])
        idx = findfirst(o -> get(o, "kind", "") in ("allow_once", "allow_always"), options)
        if idx !== nothing
            return Dict("outcome" => Dict("outcome" => "selected",
                                          "optionId" => options[idx]["optionId"]))
        end
        return Dict("outcome" => Dict("outcome" => "cancelled"))

    elseif method == "terminal/create"
        return Dict("terminalId" => string(rand(UInt32), base=16))
    elseif method == "terminal/output"
        return Dict("output" => "", "exitStatus" => nothing)
    elseif method in ("terminal/release", "terminal/kill", "terminal/wait_for_exit")
        return nothing
    end

    @warn "ACP: unhandled client request" method
    return nothing
end

# Discover the agent binary: env var → PATH → node_modules search.
function find_agent_bin()
    explicit = get(ENV, "CLAUDE_AGENT_ACP", "")
    !isempty(explicit) && return explicit

    global_bin = Sys.which("claude-agent-acp")
    global_bin !== nothing && return global_bin

    # Walk up from this source file; check both direct node_modules and
    # sibling subdirectory node_modules (e.g. dev/Bonito/node_modules).
    dir = @__DIR__
    for _ in 1:8
        bin = joinpath(dir, "node_modules", ".bin", "claude-agent-acp")
        isfile(bin) && return bin
        # Check one level of subdirectories (covers dev/*/node_modules pattern)
        for sub in readdir(dir; join=true)
            isdir(sub) || continue
            bin = joinpath(sub, "node_modules", ".bin", "claude-agent-acp")
            isfile(bin) && return bin
        end
        dir = dirname(dir)
    end
    return "claude-agent-acp"  # let OS raise a clear error at spawn time
end

function Client(cwd::String, handler::Handler = FSRequestHandler(cwd);
                mcp_servers::Vector{MCPServer} = MCPServer[],
                agent_env::Dict{String,String} = Dict{String,String}(),
                agent_bin::String = find_agent_bin())

    isfile(agent_bin) || error("claude-agent-acp not found at: $agent_bin\n" *
                               "Set CLAUDE_AGENT_ACP env var or pass agent_bin=.")

    env = merge(Dict(k => v for (k,v) in ENV),
                Dict("CLAUDE_PERMISSION_MODE" => "bypassPermissions",
                     "CLAUDE_MAX_TURNS"        => "100"),
                agent_env)

    proc = open(Cmd(`$agent_bin`; env, dir=cwd), "r+")
    conn = Connection(proc, handler)

    send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict(
            "fs" => Dict("readTextFile" => true, "writeTextFile" => true)
        ),
        "clientInfo" => Dict("name" => "AgentClientProtocol.jl", "version" => "0.1.0")
    ))

    mcp_list = [Dict("name"    => s.name,
                     "command" => s.command,
                     "args"    => s.args,
                     "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
                for s in mcp_servers]

    result = send_request(conn, "session/new",
                          Dict("cwd" => cwd, "mcpServers" => mcp_list))
    session_id = result["sessionId"]

    return Client(conn, session_id, cwd)
end

# One attached image for a multimodal prompt.
#   data:     raw bytes (will be base64-encoded for transport)
#   mime:     e.g. "image/png", "image/jpeg"
struct ImageAttachment
    data::Vector{UInt8}
    mime::String
end

# Send a user message; blocks until the agent signals end_turn / cancelled.
# `images` are appended after the text as ACP image content blocks.
function prompt!(client::Client, text::String;
                 images::Vector{ImageAttachment} = ImageAttachment[])
    blocks = Any[Dict("type" => "text", "text" => text)]
    for img in images
        push!(blocks, Dict(
            "type"     => "image",
            "data"     => Base64.base64encode(img.data),
            "mimeType" => img.mime,
        ))
    end
    send_request(client.conn, "session/prompt", Dict(
        "sessionId" => client.session_id,
        "prompt"    => blocks,
    ))
    return nothing
end

# Cancel the active turn (notification, non-blocking).
function cancel!(client::Client)
    send_notification(client.conn, "session/cancel",
                      Dict("sessionId" => client.session_id))
end

Base.close(client::Client) = close(client.conn)
