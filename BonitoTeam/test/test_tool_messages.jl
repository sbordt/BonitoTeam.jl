# Headless coverage for the typed-tool family added in baf4fba + the TodoWrite
# consolidation fix in 5396e6c + the background-task / stop affordance in
# 0bcfdd2 / 97e2d61.
#
# Three concerns:
#
#   1. ACP wire → typed `ToolCall` subtype (`BashCall` / `TodoWriteCall` /
#      `TaskCall` / `MCPCall` / `GenericTool`) — `parse_session_update` reads
#      `_meta.claudeCode.toolName` + `rawInput` and dispatches.
#   2. BonitoTeam build dispatch (`build_tool_msg`) — typed ACP value ↦ typed
#      BonitoTeam `ToolMsg` subtype, carrying tool-specific fields
#      (`is_background`, `tool_name`, `task_name`).
#   3. `is_live` / `is_taskbar_item` + `tool_header_dict["taskbar"]` flag —
#      background bash & subagent Task get a taskbar slot; one-shot tools
#      don't.
#   4. TodoWrite absorption — single bubble per logical todo list, even
#      across turns, until the entries reach all-done.
#   5. `request_tool_stop!` dispatch — synthetic user message queued for
#      background bash/task, silent no-op for everything else.

using Test
using BonitoTeam
const BT  = BonitoTeam
const ACP = BonitoTeam.AgentClientProtocol

# ── Helpers ────────────────────────────────────────────────────────────────

# Build a `tool_call` SessionUpdate-shaped dict the way claude-agent-acp does
# (with the `_meta.claudeCode.toolName` envelope + `rawInput`).
function tool_call_params(id::String, name::String, raw_input::AbstractDict;
                          kind::String = "execute", title::String = name,
                          status::String = "pending",
                          content::AbstractVector = [])
    return Dict{String,Any}(
        "sessionUpdate" => "tool_call",
        "toolCallId"    => id,
        "title"         => title,
        "kind"          => kind,
        "status"        => status,
        "content"       => content,
        "_meta"         => Dict("claudeCode" => Dict("toolName" => name)),
        "rawInput"      => raw_input,
    )
end

# Build a chat model attached to a real ServerState + mock transport so the
# `Base.close(::TodoListMsg)` persist path runs against a real ChatSession.
function make_chat()
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    BT.ChatModel(state, mktempdir();
                  transport = BT.MockTransport((o, i) -> nothing))
end

# Convenience: build a PlanEntry vector.
mkentries(pairs::Vector) =
    [BT.PlanEntry(String(c), "", String(s)) for (c, s) in pairs]

# An *already-closed* updates channel — `process!(::TodoWriteCall)` drains
# `m.updates` for trailing tool_call_updates (rare, but the loop is there);
# a freshly-opened channel would block forever in a unit test.
function closed_chan()
    c = Channel{ACP.ToolCall}(1)
    close(c)
    return c
end

# Build a TodoWriteCall whose updates channel is already closed.
function mktodo(id, entries)
    ACP.TodoWriteCall(id, "think", "TodoWrite", "completed",
                       ACP.ToolContent[], closed_chan(), entries)
end

# ── 1. ACP wire → typed ToolCall ───────────────────────────────────────────

@testset "ACP parse_session_update → typed ToolCall" begin

    @testset "Bash with run_in_background=true → BashCall" begin
        p = tool_call_params("b1", "Bash",
            Dict("command" => "sleep 10; echo done", "run_in_background" => true);
            kind = "execute", title = "sleep 10; echo done")
        u = ACP.parse_session_update(p)
        @test u isa ACP.ToolCallNotif
        @test u.tool_name == "Bash"
        @test u.raw_input["command"] == "sleep 10; echo done"

        tc = ACP.build_tool_call(u)
        @test tc isa ACP.BashCall
        @test tc.id == "b1"
        @test tc.kind == "execute"
        @test tc.command == "sleep 10; echo done"
        @test tc.run_in_background == true
        @test tc.description === nothing
    end

    @testset "Bash without run_in_background → BashCall is_background=false" begin
        p = tool_call_params("b2", "Bash",
            Dict("command" => "ls -la", "description" => "list files"))
        tc = ACP.build_tool_call(ACP.parse_session_update(p))
        @test tc isa ACP.BashCall
        @test tc.run_in_background == false
        @test tc.description == "list files"
    end

    @testset "TodoWrite → TodoWriteCall with entries lifted from rawInput.todos" begin
        p = tool_call_params("t1", "TodoWrite",
            Dict("todos" => [
                Dict("content" => "Step one", "status" => "pending",     "priority" => "high"),
                Dict("content" => "Step two", "status" => "in_progress", "priority" => "medium"),
            ]); kind = "think", title = "TodoWrite")
        tc = ACP.build_tool_call(ACP.parse_session_update(p))
        @test tc isa ACP.TodoWriteCall
        @test length(tc.entries) == 2
        @test tc.entries[1].content == "Step one"
        @test tc.entries[1].status  == "pending"
        @test tc.entries[2].status  == "in_progress"
    end

    @testset "Task / Agent with run_in_background → TaskCall" begin
        p_task = tool_call_params("t2", "Task",
            Dict("description" => "research X",
                 "prompt" => "Investigate the API",
                 "run_in_background" => true,
                 "name" => "research-runner");
            kind = "other", title = "research X")
        tc = ACP.build_tool_call(ACP.parse_session_update(p_task))
        @test tc isa ACP.TaskCall
        @test tc.description == "research X"
        @test tc.prompt == "Investigate the API"
        @test tc.run_in_background == true
        @test tc.task_name == "research-runner"

        # `Agent` is the newer SDK name for the same shape — same routing.
        p_agent = tool_call_params("a1", "Agent",
            Dict("description" => "explore", "prompt" => "go"))
        tc2 = ACP.build_tool_call(ACP.parse_session_update(p_agent))
        @test tc2 isa ACP.TaskCall
        @test tc2.run_in_background == false
        @test tc2.task_name === nothing
    end

    @testset "mcp__server__tool → MCPCall with split name" begin
        p = tool_call_params("m1", "mcp__btworker__bt_julia_eval",
            Dict("code" => "1 + 1"); title = "mcp__btworker__bt_julia_eval")
        tc = ACP.build_tool_call(ACP.parse_session_update(p))
        @test tc isa ACP.MCPCall
        @test tc.server    == "btworker"
        @test tc.tool_name == "bt_julia_eval"
        @test tc.raw_input["code"] == "1 + 1"
    end

    @testset "Unknown tool name → GenericTool fallback" begin
        p = tool_call_params("u1", "SomeFutureTool", Dict("arg" => "x"))
        tc = ACP.build_tool_call(ACP.parse_session_update(p))
        @test tc isa ACP.GenericTool
        @test tc.name == "SomeFutureTool"
        @test tc.raw_input["arg"] == "x"
    end

    @testset "No meta envelope → empty tool_name, GenericTool fallback" begin
        # An ACP backend that doesn't fill the claudeCode envelope at all.
        p = Dict{String,Any}(
            "sessionUpdate" => "tool_call",
            "toolCallId"    => "g1",
            "title"         => "Read",
            "kind"          => "read",
            "status"        => "pending",
            "content"       => [],
        )
        u = ACP.parse_session_update(p)
        @test u.tool_name == ""
        tc = ACP.build_tool_call(u)
        @test tc isa ACP.GenericTool
        @test tc.name == ""
    end
end

# ── 2. BonitoTeam build_tool_msg dispatch ─────────────────────────────────

@testset "BonitoTeam build_tool_msg dispatch" begin
    chat = make_chat()

    # BashCall background → BashToolMsg(is_background=true)
    bash_bg = ACP.BashCall("b1", "execute", "sleep 10", "in_progress",
                           ACP.ToolContent[], Channel{ACP.ToolCall}(1),
                           "sleep 10", true, nothing)
    m_bash = BT.build_tool_msg(chat, bash_bg)
    @test m_bash isa BT.BashToolMsg
    @test m_bash.command == "sleep 10"
    @test m_bash.is_background == true

    # TaskCall → TaskToolMsg
    task = ACP.TaskCall("t1", "other", "research", "in_progress",
                        ACP.ToolContent[], Channel{ACP.ToolCall}(1),
                        "research", "Investigate", true, "researcher")
    m_task = BT.build_tool_msg(chat, task)
    @test m_task isa BT.TaskToolMsg
    @test m_task.is_background == true
    @test m_task.task_name == "researcher"

    # MCPCall → MCPToolMsg (server + bare tool_name)
    mcp = ACP.MCPCall("m1", "other", "mcp__btworker__bt_julia_eval", "completed",
                      ACP.ToolContent[], Channel{ACP.ToolCall}(1),
                      "btworker", "bt_julia_eval", Dict{String,Any}("code" => "1"))
    m_mcp = BT.build_tool_msg(chat, mcp)
    @test m_mcp isa BT.MCPToolMsg
    @test m_mcp.server == "btworker"
    @test m_mcp.tool_name == "bt_julia_eval"

    # GenericTool → GenericToolMsg
    gen = ACP.GenericTool("g1", "read", "cat foo.txt", "completed",
                          ACP.ToolContent[], Channel{ACP.ToolCall}(1),
                          "Read", Dict{String,Any}())
    m_gen = BT.build_tool_msg(chat, gen)
    @test m_gen isa BT.GenericToolMsg
end

# ── 3. is_live / is_taskbar_item + tool_header_dict["taskbar"] ────────────

@testset "is_live / is_taskbar_item + taskbar flag in header dict" begin
    now_t = time()

    # Background bash is taskbar + live until terminal.
    bash_bg = BT.BashToolMsg("b1", "execute", "sleep", "in_progress", "",
                              now_t, nothing, "sleep 10", true, "", 0, false, "", nothing)
    @test BT.is_live(bash_bg) == true
    @test BT.is_taskbar_item(bash_bg) == true
    h = BT.tool_header_dict(bash_bg)
    @test h["taskbar"] == true
    @test h["background"] == true        # subtype-specific flag

    # Same shape, foreground bash — neither taskbar nor (long-term) live UX.
    bash_fg = BT.BashToolMsg("b2", "execute", "ls", "in_progress", "",
                              now_t, nothing, "ls -la", false, "", 0, false, "", nothing)
    @test BT.is_live(bash_fg) == true             # status-based liveness still applies
    @test BT.is_taskbar_item(bash_fg) == false
    @test BT.tool_header_dict(bash_fg)["taskbar"] == false

    # Task subagent backgrounded → taskbar item.
    task_bg = BT.TaskToolMsg("t1", "other", "explore", "in_progress", "",
                              now_t, nothing, "explore X", true, "explorer", nothing)
    @test BT.is_taskbar_item(task_bg) == true

    # MCP / generic tools never land in the taskbar.
    mcp = BT.MCPToolMsg("m1", "other", "bt_julia_eval", "in_progress", "",
                        now_t, nothing, "btworker", "bt_julia_eval", nothing)
    @test BT.is_taskbar_item(mcp) == false
    gen = BT.GenericToolMsg("g1", "read", "cat", "in_progress", "",
                            now_t, nothing, nothing)
    @test BT.is_taskbar_item(gen) == false

    # Terminal status → not live.
    bash_done = BT.BashToolMsg("b3", "execute", "echo", "completed", "ok",
                                now_t, now_t, "echo hi", true, "", 0, false, "", nothing)
    @test BT.is_live(bash_done) == false

    # `finished_at` wins over status even when status is mid-flight (used by
    # absorbed TodoLists, but applies uniformly).
    bash_finished_early = BT.BashToolMsg("b4", "execute", "x", "in_progress", "",
                                          now_t, now_t, "x", true, "", 0, false, "", nothing)
    @test BT.is_live(bash_finished_early) == false
end

# ── 4. TodoWrite absorption ───────────────────────────────────────────────

@testset "TodoListMsg consolidation across calls" begin

    @testset "first call creates a single bubble" begin
        chat = make_chat()
        BT.process!(chat, mktodo("tw1",
            mkentries([("A", "pending"), ("B", "pending")])))
        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 1
        first_msg = chat.msgs_store[end]::BT.TodoListMsg
        @test BT.is_live(first_msg) == true        # any pending entry → live
        @test first_msg.finished_at === nothing     # NOT auto-stamped at create
    end

    @testset "second call ABSORBS into the existing bubble" begin
        chat = make_chat()
        BT.process!(chat, mktodo("tw1",
            mkentries([("A", "pending"), ("B", "pending")])))
        first_msg = chat.msgs_store[end]::BT.TodoListMsg
        first_id = first_msg.id

        BT.process!(chat, mktodo("tw2",
            mkentries([("A", "completed"), ("B", "in_progress")])))

        # Still ONE bubble, same identity, updated entries.
        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 1
        @test chat.msgs_store[end].id == first_id
        @test [e.status for e in chat.msgs_store[end].entries] ==
              ["completed", "in_progress"]
        @test BT.is_live(chat.msgs_store[end]) == true
    end

    @testset "absorption stamps finished_at when entries become all-done" begin
        chat = make_chat()
        BT.process!(chat, mktodo("tw1", mkentries([("A", "pending")])))
        @test chat.msgs_store[end].finished_at === nothing

        BT.process!(chat, mktodo("tw2", mkentries([("A", "completed")])))

        # One bubble; transitioned to done; finished_at stamped; is_live false.
        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 1
        @test chat.msgs_store[end].finished_at !== nothing
        @test BT.is_live(chat.msgs_store[end]) == false
    end

    @testset "after all-done, the NEXT call starts a fresh bubble" begin
        chat = make_chat()
        # Build a finished todo list.
        BT.process!(chat, mktodo("tw1", mkentries([("A", "completed")])))
        first_id = chat.msgs_store[end].id

        # A brand new TodoWrite — different items — should spawn a separate
        # bubble (NOT silently overwrite the just-finished list).
        BT.process!(chat, mktodo("tw2",
            mkentries([("X", "pending"), ("Y", "pending")])))

        todos = filter(m -> m isa BT.TodoListMsg, chat.msgs_store)
        @test length(todos) == 2
        @test todos[1].id == first_id
        @test todos[2].id != first_id
        @test BT.is_live(todos[2]) == true
        @test todos[2].finished_at === nothing
    end

    @testset "no premature finished_at on the initial close-persist" begin
        # Regression for 5396e6c: `Base.close(::TodoListMsg)` used to stamp
        # finished_at unconditionally, so the very first call's persist
        # already marked the bubble done — and every later TodoWrite found
        # `is_live=false` and spawned a parallel bubble. This guards against
        # that shape coming back.
        chat = make_chat()
        BT.process!(chat, mktodo("tw1", mkentries([("A", "in_progress")])))
        m = chat.msgs_store[end]::BT.TodoListMsg
        @test m.finished_at === nothing
        @test BT.is_live(m) == true
    end

    @testset "ACP Plan SessionUpdate routes the same absorption path" begin
        # claude-agent-acp ALSO emits a separate `plan` SessionUpdate parallel
        # to the `tool_call/TodoWrite`. Both should funnel into the same
        # bubble — this is what `process!(chat, ::ACP.Plan)` is for.
        chat = make_chat()
        BT.process!(chat, mktodo("tw1", mkentries([("A", "pending")])))
        first_id = chat.msgs_store[end].id

        BT.process!(chat, ACP.Plan(mkentries([("A", "in_progress")])))

        todos = filter(m -> m isa BT.TodoListMsg, chat.msgs_store)
        @test length(todos) == 1
        @test todos[1].id == first_id
        @test todos[1].entries[1].status == "in_progress"
    end
end

# ── 5. Stop-tool dispatch ─────────────────────────────────────────────────

@testset "request_tool_stop! per-variant" begin

    @testset "background BashToolMsg queues a synthetic user message" begin
        chat = make_chat()
        t = BT.BashToolMsg("b1", "execute", "sleep 100", "in_progress", "",
                            time(), nothing, "sleep 100", true, "", 0, false, "", chat)
        push!(chat.msgs_store, t)

        BT.handle_command!(chat, nothing, BT.StopToolCommand("b1"))

        # A new UserMsg landed in the store referencing the tool id.
        users = filter(m -> m isa BT.UserMsg, chat.msgs_store)
        @test length(users) == 1
        @test occursin("b1", users[1].text)
        @test occursin("background bash", lowercase(users[1].text))
    end

    @testset "non-background bash → silent no-op" begin
        chat = make_chat()
        t = BT.BashToolMsg("b2", "execute", "ls", "in_progress", "",
                            time(), nothing, "ls -la", false, "", 0, false, "", chat)
        push!(chat.msgs_store, t)
        BT.handle_command!(chat, nothing, BT.StopToolCommand("b2"))
        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
    end

    @testset "background TaskToolMsg asks Claude to call TaskStop" begin
        chat = make_chat()
        t = BT.TaskToolMsg("ta1", "other", "research", "in_progress", "",
                           time(), nothing, "research", true, "researcher", chat)
        push!(chat.msgs_store, t)
        BT.handle_command!(chat, nothing, BT.StopToolCommand("ta1"))

        users = filter(m -> m isa BT.UserMsg, chat.msgs_store)
        @test length(users) == 1
        @test occursin("TaskStop", users[1].text)
        @test occursin("ta1", users[1].text)
        @test occursin("researcher", users[1].text)
    end

    @testset "generic / MCP tools → silent no-op" begin
        chat = make_chat()
        m = BT.MCPToolMsg("m1", "other", "bt_julia_eval", "completed", "",
                          time(), time(), "btworker", "bt_julia_eval", chat)
        push!(chat.msgs_store, m)
        BT.handle_command!(chat, nothing, BT.StopToolCommand("m1"))
        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
    end

    @testset "unknown tool id → silent no-op" begin
        chat = make_chat()
        BT.handle_command!(chat, nothing, BT.StopToolCommand("nonexistent"))
        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
    end

    @testset "parse_chat_command extracts StopToolCommand" begin
        cmd = BT.parse_chat_command(Dict("type" => "stop_tool", "id" => "x1"))
        @test cmd isa BT.StopToolCommand
        @test cmd.tool_id == "x1"

        # Missing id → UnknownCommand (silent no-op).
        @test BT.parse_chat_command(Dict("type" => "stop_tool")) isa BT.UnknownCommand
    end
end
