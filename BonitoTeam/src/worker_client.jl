# Server-side counterpart to BonitoWorker.serve: opens a WS to a remote worker
# and drives the ACP session. Lives here (not in BonitoWorker) because it depends
# on AgentClientProtocol.

using HTTP, HTTP.WebSockets, JSON, AgentClientProtocol

"""
    probe(url, secret; timeout=5.0) → Dict{String,Any}

Open a WS, authenticate, read the capability ACK, close. Used by the dashboard
to register a worker and learn its hostname / mcp_path / projects_root before
starting an ACP session. Throws on connection / auth failure.
"""
function probe(url::String, secret::String; timeout::Float64 = 5.0)
    result = Channel{Union{Dict{String,Any},Exception}}(1)

    @async WebSockets.open(url) do ws
        try
            WebSockets.send(ws, JSON.json(Dict("auth" => secret, "probe" => true)))
            ack_raw = WebSockets.receive(ws)
            ack     = JSON.parse(String(ack_raw))
            if haskey(ack, "error")
                put!(result, ErrorException("Worker probe failed: $(ack["error"])"))
            else
                put!(result, Dict{String,Any}(ack))
            end
        catch e
            isopen(result) && put!(result, e)
        finally
            try
                close(ws)
            catch e
                e isa Base.IOError || e isa WebSockets.WebSocketError ||
                    @warn "probe: close failed" exception=e
            end
        end
    end

    @async (sleep(timeout); isopen(result) && put!(result, ErrorException("probe timed out after $(timeout)s")))
    out = take!(result)
    close(result)
    out isa Exception && throw(out)
    return out
end

"""
    connect_worker(url, secret, cwd; on_update, mcp_servers, request_handler, agent_env) → AgentClientProtocol.Client

Open a WebSocket to a remote worker, authenticate, then establish an ACP session.
Returns a `Client` with the same interface as a local `AgentClientProtocol.Client`.

`url` should be a `ws://` or `wss://` URL, e.g. `"ws://192.168.1.42:8039"`.
"""
function connect_worker(url::String, secret::String, cwd::String;
                        on_update::Function       = identity,
                        mcp_servers               = [],
                        request_handler::Function = AgentClientProtocol.make_request_handler(cwd),
                        agent_env::Dict{String,String} = Dict{String,String}())

    ready = Channel{Union{AgentClientProtocol.Client, Exception}}(1)

    @async WebSockets.open(url) do ws
        try
            WebSockets.send(ws, JSON.json(Dict(
                "auth" => secret,
                "cwd"  => cwd,
                "env"  => agent_env,
            )))

            ack_raw = WebSockets.receive(ws)
            ack     = JSON.parse(String(ack_raw))
            if haskey(ack, "error")
                put!(ready, ErrorException("Worker auth failed: $(ack["error"])"))
                return
            end

            conn = ws_connection(ws; request_handler, update_handler=on_update)

            AgentClientProtocol.send_request(conn, "initialize", Dict(
                "protocolVersion"    => 1,
                "clientCapabilities" => Dict(
                    "fs" => Dict("readTextFile" => true, "writeTextFile" => true)
                ),
                "clientInfo" => Dict("name" => "BonitoTeam.WorkerClient", "version" => "0.1.0")
            ))

            mcp_list = [Dict("name"    => s.name,
                             "command" => s.command,
                             "args"    => s.args,
                             "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
                        for s in mcp_servers]

            result     = AgentClientProtocol.send_request(conn, "session/new",
                             Dict("cwd" => cwd, "mcpServers" => mcp_list))
            session_id = result["sessionId"]

            client = AgentClientProtocol.Client(conn, session_id, cwd)
            put!(ready, client)

            # Keep the WS alive until the connection closes from outside.
            while !WebSockets.isclosed(ws)
                sleep(1)
            end
        catch e
            isopen(ready) && put!(ready, e)
        end
    end

    out = take!(ready)
    out isa Exception && throw(out)
    return out
end

# Build an AgentClientProtocol.Connection backed by a WebSocket.
# Each ACP message is one WS frame (frame boundary replaces the newline delimiter).
function ws_connection(ws; request_handler, update_handler)
    send_line = line -> WebSockets.send(ws, rstrip(line, '\n'))
    read_line = ()   -> begin
        WebSockets.isclosed(ws) && return ""
        try
            String(WebSockets.receive(ws))
        catch e
            e isa Base.IOError && return ""
            e isa WebSockets.WebSocketError && return ""
            rethrow(e)
        end
    end
    on_close = () -> begin
        try
            close(ws)
        catch e
            e isa Base.IOError && return
            e isa WebSockets.WebSocketError && return
            @warn "ws_connection: close failed" exception=e
        end
    end

    return AgentClientProtocol.Connection(send_line, read_line, on_close;
                                          request_handler, update_handler)
end
