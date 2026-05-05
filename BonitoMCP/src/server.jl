# JSON-RPC 2.0 over stdio. Each line on stdin is one request / notification;
# each response is one line on stdout. stderr is free for logging.

# Structured logger (stderr) — never write non-MCP content to stdout
log_info(msg) = println(stderr, "[$SERVER_NAME] ", msg)

function send!(out::IO, payload::AbstractDict)
    println(out, JSON.json(payload))
    flush(out)
    return nothing
end

function send_response!(out, id, result)
    send!(out, Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
end

function send_error!(out, id, code::Integer, message::AbstractString)
    send!(out, Dict(
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => Dict("code" => code, "message" => message),
    ))
end

# Dispatch one parsed JSON-RPC request. id may be missing (notification).
function dispatch!(out, req::AbstractDict)
    method = get(req, "method", nothing)
    id = get(req, "id", nothing)
    params = get(req, "params", Dict{String,Any}())

    if method == "initialize"
        send_response!(out, id, Dict(
            "protocolVersion" => PROTOCOL_VERSION,
            "capabilities" => Dict("tools" => Dict("listChanged" => false)),
            "serverInfo" => Dict("name" => SERVER_NAME, "version" => SERVER_VERSION),
        ))
    elseif method == "notifications/initialized"
        # Notification, no response
    elseif method == "tools/list"
        tools = [Dict(
            "name" => t.name,
            "description" => t.description,
            "inputSchema" => t.input_schema,
        ) for t in TOOLS]
        send_response!(out, id, Dict("tools" => tools))
    elseif method == "tools/call"
        tool_name = get(params, "name", "")
        args = get(params, "arguments", Dict{String,Any}())
        idx = findfirst(t -> t.name == tool_name, TOOLS)
        if idx === nothing
            send_error!(out, id, -32602, "Unknown tool: $tool_name")
        else
            try
                result = TOOLS[idx].handler(args)
                send_response!(out, id, result)
            catch e
                bt = sprint(showerror, e, catch_backtrace())
                # Tool execution errors come back as a successful response with
                # isError=true so the agent can react to it (per MCP spec).
                send_response!(out, id, Dict(
                    "content" => [Dict("type" => "text",
                                       "text" => "tool handler threw:\n$bt")],
                    "isError" => true,
                ))
            end
        end
    elseif method === nothing
        # Malformed; ignore
    else
        if id !== nothing
            send_error!(out, id, -32601, "Method not found: $method")
        end
    end
    return nothing
end

"""
    run_stdio(; in=stdin, out=stdout)

Run the stdio MCP loop. Blocks until stdin closes.
"""
function run_stdio(; in::IO = stdin, out::IO = stdout)
    log_info("$(SERVER_NAME) v$(SERVER_VERSION) listening on stdio (protocol $(PROTOCOL_VERSION))")
    log_info("Registered $(length(TOOLS)) tool(s): " *
             join((t.name for t in TOOLS), ", "))
    for line in eachline(in)
        s = strip(line)
        isempty(s) && continue
        local req
        try
            req = JSON.parse(String(s))
        catch e
            log_info("parse error: $(string(e)) ; line: $s")
            send_error!(out, nothing, -32700, "Parse error")
            continue
        end
        try
            dispatch!(out, req)
        catch e
            bt = sprint(showerror, e, catch_backtrace())
            log_info("dispatch error: $bt")
            id = get(req, "id", nothing)
            id !== nothing && send_error!(out, id, -32603, "Internal error: $(string(e))")
        end
    end
    log_info("stdin closed; exiting")
    return nothing
end
