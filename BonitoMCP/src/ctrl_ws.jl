# Control dial-back from THIS process (the stdio MCP server) to the
# BonitoTeam server — the lever that lets the chat's per-tool ⊗ button
# interrupt an in-flight bt_julia_eval WITHOUT cancelling the whole agent
# turn.
#
# Why a separate channel: the eval-ws bridge (RemoteProxy) lives in the Malt
# EVAL worker, the same process that runs the user's code — a busy eval can
# starve its event loop, so it can't be trusted to deliver an interrupt. THIS
# process never runs user code (evals are remote_eval'd into the Malt
# worker), so its tasks stay responsive, and it already owns the one reliable
# stop lever: `Malt.interrupt(worker)` — the same SIGINT `bt_julia_interrupt`
# and the MCP `notifications/cancelled` path use.
#
# Wire: one JSON object per WS message.
#   server → us:  {"op": "interrupt_eval", "request_id": id, "env_path"?: p}
#                 {"op": "ping", "request_id": id}
#   us → server:  {"type": "interrupt_result", "request_id": id, "interrupted": n}
#                 {"type": "pong", "request_id": id}
#
# The dial is configured by the same env the eval-ws dial-back uses
# (BONITOTEAM_SERVER_URL from the worker daemon, BONITOTEAM_SECRET /
# BONITOTEAM_PROJECT_ID injected by the server into the MCP launch env).
# Standalone BonitoMCP use (no BonitoTeam) has none of them set → no dial,
# zero overhead.

using HTTP.WebSockets: WebSockets

const CTRL_TASK = Ref{Union{Task,Nothing}}(nothing)
# Stop hook for tests/embedders: production never sets it — the control
# channel's lifetime is the MCP process's. Flipping it makes the dial loop
# exit at the next reconnect boundary instead of retrying forever.
const CTRL_STOP = Ref(false)

function start_ctrl_dialback!()
    server_url = get(ENV, "BONITOTEAM_SERVER_URL", "")
    secret     = get(ENV, "BONITOTEAM_SECRET", "")
    project_id = get(ENV, "BONITOTEAM_PROJECT_ID", "")
    (isempty(server_url) || isempty(secret) || isempty(project_id)) && return nothing
    CTRL_TASK[] === nothing || return nothing
    wsurl = replace(rstrip(server_url, '/'), r"^http" => "ws") * "/mcp-ws"
    CTRL_TASK[] = Base.errormonitor(@async ctrl_dial_loop(wsurl, "$secret $project_id"))
    log_info("control dial-back armed → $wsurl")
    return nothing
end

# Dial-and-serve until the process exits. A dropped socket (server restart,
# network blip) reconnects with exponential backoff — same shape as
# RemoteProxy.dial_loop.
function ctrl_dial_loop(wsurl::AbstractString, handshake::AbstractString;
                        min_backoff::Float64 = 0.5, max_backoff::Float64 = 8.0)
    backoff = min_backoff
    while !CTRL_STOP[]
        connected = false
        try
            WebSockets.open(wsurl) do ws
                WebSockets.send(ws, handshake)
                connected = true
                for msg in ws
                    # Per-frame guard: one malformed frame must not drop the
                    # whole control channel.
                    try
                        handle_ctrl_frame!(ws, JSON.parse(String(msg)))
                    catch e
                        log_info("ctrl frame failed: $(sprint(showerror, e))")
                    end
                end
            end
        catch e
            log_info("ctrl dial failed (will retry in $(backoff)s): $(sprint(showerror, e))")
        end
        backoff = connected ? min_backoff : min(backoff * 2, max_backoff)
        sleep(backoff)
    end
end

function handle_ctrl_frame!(ws, msg::AbstractDict)
    op  = get(msg, "op", "")
    rid = get(msg, "request_id", nothing)
    if op == "interrupt_eval"
        env_path = get(msg, "env_path", nothing)
        env_path isa AbstractString && isempty(env_path) && (env_path = nothing)
        n = interrupt_in_flight!(env_path isa AbstractString ? String(env_path) : nothing)
        log_info("ctrl interrupt_eval (env=$(env_path)) → interrupted $n in-flight eval(s)")
        WebSockets.send(ws, JSON.json(Dict(
            "type" => "interrupt_result", "request_id" => rid, "interrupted" => n)))
    elseif op == "ping"
        WebSockets.send(ws, JSON.json(Dict("type" => "pong", "request_id" => rid)))
    else
        log_info("ctrl: unknown op '$op'")
    end
    return nothing
end
