# Typed transports for ChatModel. Replaces the old `client_factory :: Any`
# callback hell with concrete structs that hold the parameters needed to
# bring up an ACP session, plus dispatched I/O verbs underneath.
#
# Each concrete transport is an `AgentClientProtocol.Transport`, so the
# generic ACP `Connection` can drive it without knowing whether the
# bytes are going to a local subprocess, a worker WebSocket, or a pair
# of in-memory channels (tests).

const ACP = AgentClientProtocol

"""
    abstract type ChatTransport <: ACP.Transport

The means by which a `ChatModel` reaches its claude-agent-acp session.
Concrete subtypes:

  * `LocalTransport` — spawn `claude-agent-acp` on this server box.
  * `WorkerTransport` — ask a registered worker (over its control WS)
    to spawn `claude-agent-acp` and route ACP frames through the WS the
    worker dials back on `/worker-acp`.
  * `MockTransport` — in-memory loopback used by tests.

Each transport overloads `ACP.send(t, line)`, `ACP.recv(t)`, and
`Base.close(t)` for line-level I/O, and `start_session(t, handler)`
to drive the standard `initialize` + `session/new` (or `session/load`)
sequence and return `(client::ACP.Client, replay::Vector{ACP.Message})` —
`replay` is the resumed session's history captured during `session/load`
(empty for a fresh `session/new`). `handler` is an `ACP.Handler`
subtype — for the chat that's `ACP.FSRequestHandler`, which serves the
agent→client `fs/*` RPCs. Session updates are NOT handled here; they
arrive as the `Channel{Message}` returned by `ACP.prompt!` per turn.
"""
abstract type ChatTransport <: ACP.Transport end

# ── 1. Local subprocess ────────────────────────────────────────────────────

mutable struct LocalTransport <: ChatTransport
    cwd          :: String
    mcp_servers  :: Vector{ACP.MCPServer}
    agent_bin    :: String
    agent_env    :: Dict{String,String}
    # Lazily populated by start_session (set to the spawned process'
    # subprocess transport so send/recv/close can delegate).
    inner        :: Ref{Union{ACP.SubprocessTransport,Nothing}}
end

LocalTransport(cwd::AbstractString;
               mcp_servers = ACP.MCPServer[],
               agent_bin   = ACP.find_agent_bin(),
               agent_env   = Dict{String,String}()) =
    LocalTransport(String(cwd), collect(ACP.MCPServer, mcp_servers),
                    String(agent_bin), agent_env,
                    Ref{Union{ACP.SubprocessTransport,Nothing}}(nothing))

ACP.send(t::LocalTransport, line::AbstractString) = ACP.send(t.inner[], line)
ACP.recv(t::LocalTransport)                       = ACP.recv(t.inner[])
Base.close(t::LocalTransport) =
    (t.inner[] === nothing || close(t.inner[]); nothing)

# ── 2. Worker over WebSocket ────────────────────────────────────────────────

mutable struct WorkerTransport <: ChatTransport
    state              :: ServerState
    worker_id          :: String
    worker_path        :: String
    mcp_servers        :: Vector{ACP.MCPServer}
    resume_session_id  :: Union{String,Nothing}
    # Set by start_session once the worker dials back the ACP WS.
    ws                 :: Ref{Any}
end

WorkerTransport(state::ServerState, worker_id::AbstractString,
                worker_path::AbstractString;
                mcp_servers = ACP.MCPServer[],
                resume_session_id::Union{String,Nothing} = nothing) =
    WorkerTransport(state, String(worker_id), String(worker_path),
                     collect(ACP.MCPServer, mcp_servers),
                     resume_session_id, Ref{Any}(nothing))

function ACP.send(t::WorkerTransport, line::AbstractString)
    ws = t.ws[]
    ws === nothing && return nothing
    # The worker session can end (ws write-closed) between a line being queued
    # and delivered — e.g. a `session/cancel` notification arriving just after
    # the agent's connection dropped ("ACP session ended"). A closed transport
    # has nothing to deliver; the connection's death is detected on the recv
    # side (returns ""), which tears down the read loop and fails any pending
    # requests. So drop the write instead of throwing the bare HTTP
    # `send() requires !(ws.writeclosed)` ArgumentError up through chat_dispatch!.
    HTTP.WebSockets.isclosed(ws) && return nothing
    try
        HTTP.WebSockets.send(ws, rstrip(line, '\n'))
    catch e
        # Race: write side closed between the isclosed check and the send.
        if e isa ArgumentError || e isa Base.IOError || e isa HTTP.WebSockets.WebSocketError
            @debug "WorkerTransport.send: connection closed mid-write, dropping line" exception = e
            return nothing
        end
        rethrow(e)
    end
    return nothing
end

function ACP.recv(t::WorkerTransport)
    ws = t.ws[]
    HTTP.WebSockets.isclosed(ws) && return ""
    try
        return String(HTTP.WebSockets.receive(ws))
    catch e
        (e isa Base.IOError || e isa HTTP.WebSockets.WebSocketError) && return ""
        rethrow(e)
    end
end

function Base.close(t::WorkerTransport)
    ws = t.ws[]
    ws === nothing && return nothing
    HTTP.WebSockets.isclosed(ws) && return nothing
    try
        close(ws)
    catch e
        # Peer (worker) may have closed concurrently — that's the resource state
        # we want anyway. Only swallow the specific races; anything else is real.
        (e isa Base.IOError || e isa HTTP.WebSockets.WebSocketError) || rethrow()
    end
    return nothing
end

# ── 3. Mock loopback (tests) ────────────────────────────────────────────────
# A test sets up `incoming` (frames the agent is "sending" to us) and
# `outgoing` (frames we send back), plus an `on_setup` callback that the
# test uses to install its own JSON-RPC responder. start_session calls
# on_setup with the (outgoing, incoming) pair so the responder can read
# from outgoing and write to incoming.

mutable struct MockTransport <: ChatTransport
    # Mutable + Refs so `start_session` can swap in fresh channels on a
    # re-bring-up (after `restart_chat_session!` calls `close` on the
    # old client, the channels are closed and can't be put!/take!'d).
    incoming :: Channel{String}    # we read from this
    outgoing :: Channel{String}    # we write to this
    on_setup :: Function           # (outgoing, incoming) -> Nothing — install responder
    cwd      :: String             # cosmetic; passed to ACP.Client at the end
    capacity :: Int
end

MockTransport(on_setup::Function; cwd::AbstractString = "/tmp",
              capacity::Int = 64) =
    MockTransport(Channel{String}(capacity), Channel{String}(capacity),
                   on_setup, String(cwd), capacity)

ACP.send(t::MockTransport, line::AbstractString) = (put!(t.outgoing, String(line)); nothing)
ACP.recv(t::MockTransport)                       = take!(t.incoming)
# Channel.close is idempotent in Base, so no wrapper is needed.
Base.close(t::MockTransport) = (close(t.outgoing); close(t.incoming); nothing)

# The path the *agent* sees as its working directory. The chat layer uses
# this when constructing the ACP `FSRequestHandler` so server-side fs RPCs
# resolve paths against the right root (server cwd locally, worker path
# for remote sessions). Mock sessions report the cosmetic test cwd.
agent_cwd(t::LocalTransport)  = t.cwd
agent_cwd(t::WorkerTransport) = t.worker_path
agent_cwd(t::MockTransport)   = t.cwd

# ── ACP session bring-up, dispatched per transport ─────────────────────────

# Standard MCP-list serialisation used by both Local and Worker bring-up.
mcp_list_payload(mcp_servers) =
    [Dict("name"    => s.name,
          "command" => s.command,
          "args"    => s.args,
          "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
     for s in mcp_servers]

# Server-global system prompt (state_dir/AGENTS.md) as the `_meta` extension
# claude-agent-acp honors on `session/new` / `session/load`:
# `{_meta: {systemPrompt: {type: "preset", preset: "claude_code", append}}}` —
# the text is APPENDED to claude's stock system prompt, so it composes with
# (never replaces) the per-project CLAUDE.md hierarchy. Empty file ⇒ empty
# dict ⇒ the params stay byte-identical to before.
function system_prompt_meta(text::AbstractString)
    isempty(text) && return Dict{String,Any}()
    return Dict{String,Any}("_meta" => Dict{String,Any}(
        "systemPrompt" => Dict{String,Any}(
            "type"   => "preset",
            "preset" => "claude_code",
            "append" => String(text))))
end

# All three bring-ups accept `on_frame` — the optional ACP wire tap passed
# through to `ACP.Connection` (see `acp_frame_logger`). Threading it here
# (rather than per-transport state) keeps the tap per-session: a restart
# builds a fresh Connection and re-arms the tap with it.

# 1. Local: spawn claude-agent-acp, then drive initialize + session/new.
function start_session(t::LocalTransport, handler::ACP.Handler;
                       on_frame::Union{Function,Nothing} = nothing)
    isfile(t.agent_bin) || error("claude-agent-acp not found at: $(t.agent_bin)")
    env = merge(Dict(k => v for (k,v) in ENV),
                Dict("CLAUDE_PERMISSION_MODE" => "bypassPermissions",
                     "CLAUDE_MAX_TURNS"        => "100"),
                t.agent_env)
    proc = open(Cmd(`$(t.agent_bin)`; env, dir = t.cwd), "r+")
    t.inner[] = ACP.SubprocessTransport(proc)

    conn = ACP.Connection(t, handler; on_frame)
    ACP.send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict(
            "fs" => Dict("readTextFile" => true, "writeTextFile" => true),
            # Form elicitation: claude-agent-acp only ENABLES the
            # AskUserQuestion tool when the client can render a form
            # elicitation (otherwise it launches claude with
            # `--disallowedTools AskUserQuestion`). The chat renders these
            # as interactive question cards — see `handle_elicitation_request`.
            "elicitation" => Dict("form" => true)),
        "clientInfo"         => Dict("name"    => "BonitoAgents.LocalTransport",
                                      "version" => "0.1.0")))
    result = ACP.send_request(conn, "session/new",
                              Dict("cwd" => t.cwd,
                                   "mcpServers" => mcp_list_payload(t.mcp_servers)))
    # Local sessions are always fresh (`session/new`) — no resume, no replay.
    # The raw result rides on the Client (session config: models/modes/…).
    return ACP.Client(conn, result["sessionId"], t.cwd, ACP._result_dict(result)),
           ACP.Message[]
end

# 2. Worker: ask the worker to spawn claude-agent-acp and dial back, then
#    drive initialize + session/new (or session/load when resuming).
function start_session(t::WorkerTransport, handler::ACP.Handler;
                       on_frame::Union{Function,Nothing} = nothing)
    haskey(t.state.worker_control_ws, t.worker_id) ||
        error("Worker '$(t.worker_id)' is not connected")

    sid, ch = register_rpc!(t.state)
    mcp_list = mcp_list_payload(t.mcp_servers)

    # Find the project this session belongs to (cosmetic — used in the
    # worker-side log line).
    project_id = ""
    for p in values(t.state.projects[])
        p.worker_id == t.worker_id && p.worker_path == t.worker_path &&
            (project_id = p.id; break)
    end

    send_command(t.state, t.worker_id, Dict(
        "type"       => "open_session",
        "sid"        => sid,
        "project_id" => project_id,
        "cwd"        => t.worker_path,
        "env"        => Dict{String,String}(),
        "mcpServers" => mcp_list,
    ))

    # Bounded wait for the worker's /worker-acp upgrade.
    t.ws[] = take_pending!(t.state, ch, sid, 30.0,
                          "open_session on '$(t.worker_id)'")

    conn = ACP.Connection(t, handler; on_frame)
    ACP.send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict(
            "fs" => Dict("readTextFile" => true, "writeTextFile" => true),
            # Form elicitation: claude-agent-acp only ENABLES the
            # AskUserQuestion tool when the client can render a form
            # elicitation (otherwise it launches claude with
            # `--disallowedTools AskUserQuestion`). The chat renders these
            # as interactive question cards — see `handle_elicitation_request`.
            "elicitation" => Dict("form" => true)),
        "clientInfo"         => Dict("name"    => "BonitoAgents.WorkerTransport",
                                      "version" => "0.1.0")))

    # Resuming → `session/load`, during which the agent re-streams the session's
    # history as session/update notifications; `replay_history` captures them.
    # Fresh → `session/new`, no replay. Either way the response carries the
    # session-config blocks (models/modes/configOptions) — keep it raw on the
    # Client for typed views downstream. Both carry the server-global
    # AGENTS.md as an appended system prompt (see `system_prompt_meta`).
    prompt_meta = system_prompt_meta(global_agents_md(t.state))
    session_id, replay, result = if t.resume_session_id !== nothing
        @info "ACP: resuming session" cwd=t.worker_path resume=t.resume_session_id
        msgs, load_result = ACP.replay_history(conn, merge(Dict(
            "sessionId"  => t.resume_session_id,
            "cwd"        => t.worker_path,
            "mcpServers" => mcp_list,
        ), prompt_meta))
        t.resume_session_id, msgs, load_result
    else
        new_result = ACP.send_request(conn, "session/new",
                                  merge(Dict("cwd" => t.worker_path,
                                             "mcpServers" => mcp_list), prompt_meta))
        new_result["sessionId"], ACP.Message[], new_result
    end

    return ACP.Client(conn, session_id, t.worker_path, ACP._result_dict(result)), replay
end

# 3. Mock: (re-)open the loopback channels, hand them to the test
#    responder, then drive the standard initialize + session/new sequence.
#    Channels are recreated each call because `restart_chat_session!`
#    closes the old transport (killing the old responder) before bringing
#    up a new one.
function start_session(t::MockTransport, handler::ACP.Handler;
                       on_frame::Union{Function,Nothing} = nothing)
    if !isopen(t.outgoing); t.outgoing = Channel{String}(t.capacity); end
    if !isopen(t.incoming); t.incoming = Channel{String}(t.capacity); end
    t.on_setup(t.outgoing, t.incoming)
    conn = ACP.Connection(t, handler; on_frame)
    ACP.send_request(conn, "initialize", Dict("protocolVersion" => 1))
    result = ACP.send_request(conn, "session/new",
                              Dict("cwd" => t.cwd, "mcpServers" => []))
    return ACP.Client(conn, result["sessionId"], t.cwd, ACP._result_dict(result)),
           ACP.Message[]
end
