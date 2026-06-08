# A drop-in replacement for the `claude-agent-acp` Node binary, written in
# Julia. Speaks the SAME JSON-RPC dialect over stdin/stdout: tests can point
# `BonitoTeam.LocalTransport`'s `agent_bin` at this script and exercise the
# full real-subprocess path — process spawn, stdin/stdout buffering, `kill`
# semantics, reader-loop EOF cascade — instead of an in-memory Channel
# mock. This is what `MockTransport` cannot do: it shorts the real
# transport teardown plumbing the restart pipeline depends on.
#
# Behaviour for `session/prompt` is selected by the `BT_MOCK_ACP_SCENARIO`
# env var, set by tests. `initialize`, `session/new`, `session/load`,
# `session/cancel` follow the real protocol so chat bring-up is identical.
#
# Scenarios (all chunks are short — tests assert on prefixes, not lengths):
#
#   normal              — N agent chunks, then end_turn response.
#   normal_with_thought — emit thought_chunk(empty) before each agent
#                         chunk, then end_turn (exercises the thinking
#                         indicator pair-emit guarantee).
#   hang_after_chunks   — N agent chunks, then NEVER respond. Used to
#                         simulate the "session got wedged mid-stream"
#                         case the restart UI exists to recover from.
#   hang_in_thought     — one thought_chunk then never respond. Tests that
#                         `thinking=false` is emitted on restart even
#                         though the agent never sent a closing thought.
#   hang_in_tool        — one tool_call (status=pending) then never
#                         respond. Tests that the orphan sweep flips the
#                         tool to "failed" on restart.
#   crash               — exit(1) immediately after `session/prompt`
#                         (simulates an agent that died mid-turn). The
#                         reader-loop's EOF surfaces as session_alive=false.
#   ignore_cancel       — stream forever, ignore `session/cancel`. Lets a
#                         test prove the cancel-then-restart escalation
#                         works against an uncooperative agent.
#
# Stdin EOF → exit(0). The `LocalTransport` close(); `kill` cycle relies on
# this: closing stdin makes us drop out of the dispatcher loop cleanly.

using JSON

const SCENARIO  = String(get(ENV, "BT_MOCK_ACP_SCENARIO", "normal"))
const N_CHUNKS  = parse(Int, String(get(ENV, "BT_MOCK_ACP_CHUNKS",  "3")))
const SESSION   = String(get(ENV, "BT_MOCK_ACP_SESSION", "s"))
const CHUNK_MS  = parse(Int, String(get(ENV, "BT_MOCK_ACP_CHUNK_MS", "0")))

# Flushing line writer: the real claude-agent-acp emits each frame as one
# line + flush; mirror it so the reader-loop in `ACP.Connection` sees
# frames promptly under tests. Default `stdout` write is line-buffered
# when wired to a terminal but block-buffered to a pipe; explicit flush
# avoids 8 kB delays.
emit(d::AbstractDict) = (println(stdout, JSON.json(d)); flush(stdout); nothing)

upd(kind::AbstractString, payload::AbstractDict) = emit(Dict(
    "jsonrpc" => "2.0", "method" => "session/update",
    "params"  => Dict("sessionId" => SESSION,
                      "update"    => merge(Dict("sessionUpdate" => kind), payload))))

agent_chunk(text)   = upd("agent_message_chunk",
    Dict("content" => Dict("type" => "text", "text" => text)))
thought_chunk(text) = upd("agent_thought_chunk",
    Dict("content" => Dict("type" => "text", "text" => text)))
tool_call(status; id = "tc1", kind = "execute", title = "mock tool",
          extra = Dict{String,Any}()) = upd("tool_call",
    merge(Dict{String,Any}(
        "toolCallId" => id, "kind" => kind,
        "title" => title, "status" => status), extra))

# `tool_call_update` is the partial-update variant the agent emits to flip
# an existing tool's status / content without restating its identity.
tool_call_update(id, fields::AbstractDict) = upd("tool_call_update",
    merge(Dict{String,Any}("toolCallId" => id), fields))

# TodoWrite tool emits content as a JSON-encoded list of `{content, status,
# activeForm}` entries. The chat side parses it into `TodoListMsg`.
todo_write_content(entries::Vector) = [Dict(
    "type" => "text",
    "text" => JSON.json(Dict("todos" => entries)))]

todo_write(entries::Vector; id = "todo1", status = "completed") = upd("tool_call",
    Dict("toolCallId" => id, "kind"   => "edit",
         "title"      => "TodoWrite", "status" => status,
         "content"    => todo_write_content(entries)))

resp(id, result) =
    emit(Dict("jsonrpc" => "2.0", "id" => id, "result" => result))

# Per-prompt sleep helper: zero-cost in normal scenarios, configurable for
# the "stress timing" tests that want pacing in the stream.
pause() = CHUNK_MS > 0 && sleep(CHUNK_MS / 1000)

# Track whether the agent is currently honoring cancel — toggled by the
# `session/cancel` handler (also drives "ignore_cancel" which clears it).
const cancelled = Ref(false)

# Drive ONE `session/prompt`. The dispatcher catches throws so a scenario
# can `exit(1)` to simulate a crash without crashing the dispatcher first.
function handle_prompt(prompt_id, scenario::AbstractString)
    if scenario == "normal"
        for i in 1:N_CHUNKS
            cancelled[] && break
            agent_chunk("chunk$i "); pause()
        end
        resp(prompt_id, Dict("stopReason" =>
                             cancelled[] ? "cancelled" : "end_turn"))
    elseif scenario == "normal_with_thought"
        for i in 1:N_CHUNKS
            cancelled[] && break
            thought_chunk("")   # redacted — exercises the thinking-on/off pair
            agent_chunk("chunk$i "); pause()
        end
        resp(prompt_id, Dict("stopReason" =>
                             cancelled[] ? "cancelled" : "end_turn"))
    elseif scenario == "hang_after_chunks"
        for i in 1:N_CHUNKS
            agent_chunk("chunk$i "); pause()
        end
        # Sit forever waiting for kill / stdin EOF.
        while true
            sleep(1.0)
        end
    elseif scenario == "hang_in_thought"
        thought_chunk("")
        while true
            sleep(1.0)
        end
    elseif scenario == "hang_in_tool"
        tool_call("pending")
        while true
            sleep(1.0)
        end
    elseif scenario == "todo_hang"
        # Emit a TodoWrite with one in-progress + one pending entry, then
        # hang. Exercises restart-while-live-plan: the plan stays in
        # msgs_store, the JS taskbar shows it (`bt-plan-live`), and the
        # orphan sweep on restart must close it (finished_at set) so a
        # fresh agent's first TodoWrite starts a new plan instead of
        # absorbing into the dead one.
        emit(Dict("jsonrpc" => "2.0", "method" => "session/update", "params" => Dict(
            "sessionId" => SESSION,
            "update" => Dict(
                "sessionUpdate" => "tool_call",
                "toolCallId" => "todo1", "kind" => "edit",
                "title"  => "TodoWrite", "status" => "completed",
                "_meta"  => Dict("claudeCode" => Dict("toolName" => "TodoWrite")),
                "rawInput" => Dict("todos" => [
                    Dict("content" => "Step 1", "priority" => "high", "status" => "in_progress"),
                    Dict("content" => "Step 2", "priority" => "high", "status" => "pending")])))))
        while true
            sleep(1.0)
        end
    elseif scenario == "bg_bash_hang"
        # Background bash via two frames: the initial `tool_call` opens
        # the bubble with status="pending" so the per-tool snap channel
        # stays open, then a `tool_call_update` ships the "completed"
        # status WITH the "Running in background, output written to: …"
        # content snap — that's what the chat-side update loop iterates
        # to flip `bg_running=true`. (One frame with status=completed
        # closes the channel synchronously with no snap delivered, so the
        # detection loop never runs.) Then hang without finishing the
        # prompt — restart must leave the bg bubble intact (worker owns
        # the shell, not the ACP session).
        emit(Dict("jsonrpc" => "2.0", "method" => "session/update", "params" => Dict(
            "sessionId" => SESSION,
            "update" => Dict(
                "sessionUpdate" => "tool_call",
                "toolCallId" => "bash1", "kind" => "execute",
                "title"  => "Bash", "status" => "pending",
                "_meta"  => Dict("claudeCode" => Dict("toolName" => "Bash")),
                "rawInput" => Dict(
                    "command" => "sleep 10; echo done",
                    "run_in_background" => true,
                    "description" => "mock background bash")))))
        # IMPORTANT: tool-call CONTENT items use the `{type:"content",
        # content:{type:"text", text:"…"}}` envelope, NOT `{type:"text",
        # text:"…"}`. `parse_tool_content_item` peels the inner block via
        # `parse_content_block`; a bare `type:"text"` falls through to a
        # placeholder string and the "written to:" detection misses.
        emit(Dict("jsonrpc" => "2.0", "method" => "session/update", "params" => Dict(
            "sessionId" => SESSION,
            "update" => Dict(
                "sessionUpdate" => "tool_call_update",
                "toolCallId" => "bash1",
                "status"  => "completed",
                "content" => [Dict("type"    => "content",
                                   "content" => Dict("type" => "text",
                                                     "text" => "Running in background, output written to: /tmp/mock-bg.log"))]))))
        while true
            sleep(1.0)
        end
    elseif scenario == "multi_tool"
        # Two tools, sequential. Exercises the multi-tool turn coalescer
        # AND the orphan sweep — if a restart lands here mid-stream we
        # want EVERY non-terminal pill failed, not just the last.
        tool_call("pending"; id = "tc-a", title = "tool A")
        tool_call_update("tc-a", Dict("status" => "completed"))
        tool_call("pending"; id = "tc-b", title = "tool B")
        # Don't close the second — let the test exercise both:
        # - if `n_chunks > 0`, the next iteration completes it
        # - if the test fires restart here, "tc-b" should land failed
        for i in 1:N_CHUNKS
            agent_chunk("a$i "); pause()
        end
        tool_call_update("tc-b", Dict("status" => "completed"))
        resp(prompt_id, Dict("stopReason" => "end_turn"))
    elseif scenario == "crash"
        # Mimic an agent that segfaulted mid-turn: no response, just exit.
        exit(1)
    elseif scenario == "ignore_cancel"
        i = 0
        # NOTE: deliberately doesn't observe `cancelled[]` — that's the
        # whole point of this scenario. Sits looping until killed.
        while true
            i += 1
            agent_chunk("loop$i ")
            pause()
        end
    else
        error("unknown BT_MOCK_ACP_SCENARIO: $(scenario)")
    end
end

# Dispatcher: read JSON-RPC frames from stdin, route by `method`. Returns
# when stdin EOFs (parent closed our stdin → time to die).
function dispatch_loop()
    while !eof(stdin)
        line = try readline(stdin) catch; break end
        isempty(line) && continue
        msg = try JSON.parse(line) catch; continue end
        method = String(get(msg, "method", ""))
        id     = get(msg, "id", nothing)
        if method == "initialize" && id !== nothing
            # Empty caps + agentCapabilities is what the real agent's
            # session/new reply leans on; the chat layer doesn't read
            # initialize's result beyond presence.
            resp(id, Dict())
        elseif method == "session/new" && id !== nothing
            resp(id, Dict("sessionId" => SESSION))
        elseif method == "session/load" && id !== nothing
            resp(id, Dict("sessionId" => SESSION))
        elseif method == "session/prompt" && id !== nothing
            cancelled[] = false
            try
                handle_prompt(id, SCENARIO)
            catch e
                # A scenario-side throw shouldn't kill the dispatcher; the
                # real agent would either respond or not. We respond with
                # a synthetic error so the chat side surfaces it.
                resp(id, Dict("stopReason" => "error",
                              "message"    => sprint(showerror, e)))
            end
        elseif method == "session/cancel"
            # Notification — no response. Flip the flag so the current
            # prompt's loop (if it's checking) exits and replies cancelled.
            cancelled[] = true
        end
        # Anything else: silently ignore. The real agent does the same
        # for unknown methods.
    end
end

dispatch_loop()
