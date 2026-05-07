# JuliaSession + SessionManager backed by Malt.jl. One Malt.Worker per env_path.
#
# Key design points:
#   - Soft timeout, never a hard kill. Code keeps running across checkpoints.
#     The agent calls `bt_julia_eval` with `timeout=N`; if the eval doesn't
#     finish in N seconds, the result has `status: "running"` + the partial
#     stdout captured so far. The agent can `bt_julia_continue` to wait
#     longer, `bt_julia_interrupt` to SIGINT (state preserved), or
#     `bt_julia_restart` to SIGKILL (state lost).
#
#   - Streaming via stdout pipe. Worker is spawned with monitor_stdout=false
#     so its stdout/stderr are real Pipes back to us. Background reader
#     tasks pump bytes into a per-session buffer; each checkpoint drains
#     whatever has accumulated. No special framing needed.
#
#   - Output discipline (truncation, container summary, image detection,
#     trimmed backtrace, suppress-nothing) runs inside the worker via the
#     BonitoMCPHelper module (helper_payload.jl). The eval returns
#     pre-formatted block dicts — base types only, so Malt's serialiser
#     never sees user-defined types it doesn't know about.

using Malt
using Dates: format, now

const HELPER_PATH = abspath(joinpath(@__DIR__, "helper_payload.jl"))
const PKG_PATTERN = r"\bPkg\."
const DEFAULT_TIMEOUT = 30.0

# ── JuliaSession ────────────────────────────────────────────────────────────
mutable struct JuliaSession
    env_path::Union{String,Nothing}
    is_temp::Bool
    is_test::Bool
    julia_cmd::Union{String,Nothing}
    worker::Union{Malt.Worker,Nothing}
    output_buffer::IOBuffer
    output_lock::ReentrantLock          # protects output_buffer
    stdout_pump::Union{Task,Nothing}
    stderr_pump::Union{Task,Nothing}
    in_flight::Union{Task,Nothing}      # Malt.remote_eval task
    in_flight_code::String
    in_flight_started::Float64
    lock::ReentrantLock                 # serialises eval/continue/interrupt
    log_path::Union{String,Nothing}
end

function JuliaSession(env_path;
                       is_temp::Bool   = false,
                       is_test::Bool   = false,
                       julia_cmd::Union{String,Nothing} = nothing,
                       log_path::Union{String,Nothing}  = nothing)
    return JuliaSession(env_path, is_temp, is_test, julia_cmd,
                        nothing, IOBuffer(), ReentrantLock(),
                        nothing, nothing,
                        nothing, "", 0.0,
                        ReentrantLock(), log_path)
end

is_alive(s::JuliaSession) = s.worker !== nothing && Malt.isrunning(s.worker)

# Build the exeflags vector. Handles juliaup `+channel` syntax + custom flags.
function build_exeflags(env_path, julia_cmd)::Vector{String}
    base = String["--threads=auto"]
    env_path === nothing || push!(base, "--project=$(abspath(env_path))")
    if julia_cmd !== nothing
        # julia_cmd is something like "julia +1.11" or "julia --check-bounds=yes"
        # The exename is `julia` by default; we strip that and pull in the rest.
        parts = split(julia_cmd)
        @assert !isempty(parts)
        # Drop the `julia` token if present (Malt provides the executable)
        rest = parts[1] == "julia" ? parts[2:end] : parts
        prepend!(base, rest)
    end
    return base
end

function start!(s::JuliaSession)
    is_alive(s) && return s
    s.worker = Malt.Worker(
        monitor_stdout = false,
        monitor_stderr = false,
        exeflags       = build_exeflags(s.env_path, s.julia_cmd),
    )
    # Background pumps drain worker stdout/stderr into our buffer (and tee
    # into the log file if one is configured). Both streams merge into the
    # same buffer — same UX as a normal REPL.
    s.stdout_pump = Threads.@spawn pump_pipe!(s, s.worker.stdout)
    s.stderr_pump = Threads.@spawn pump_pipe!(s, s.worker.stderr)

    # Auto-Revise (best-effort) + load our format helper. The trailing
    # `; nothing` is load-bearing: include() returns the module object and
    # Malt can't serialise a `Module` reference back to the parent.
    Malt.remote_eval_fetch(s.worker, :(try; using Revise; catch; end; nothing))
    Malt.remote_eval_fetch(s.worker, :(include($HELPER_PATH); nothing))

    if s.is_test
        Malt.remote_eval_fetch(s.worker,
            :(try; using TestEnv; TestEnv.activate(); catch; end; nothing))
    end
    return s
end

function pump_pipe!(s::JuliaSession, pipe)
    log_io = s.log_path === nothing ? nothing : open(s.log_path, "a")
    try
        while !eof(pipe)
            data = readavailable(pipe)
            isempty(data) && continue
            @lock s.output_lock write(s.output_buffer, data)
            log_io === nothing || (write(log_io, data); flush(log_io))
        end
    catch e
        e isa EOFError && return
        e isa Base.IOError && return
        @warn "pipe pump error" exception=e
    finally
        log_io === nothing || try close(log_io) catch end
    end
end

drain_output!(s::JuliaSession) = @lock s.output_lock String(take!(s.output_buffer))

# ── Eval ────────────────────────────────────────────────────────────────────
"""
    execute(session, code; timeout, max_bytes, full_output)
        → NamedTuple

Returns one of:
  (status = :completed, blocks::Vector{Dict}, is_error::Bool, elapsed_s::Float64)
  (status = :running,   partial::String, elapsed_s::Float64)

Soft timeout — `:running` means the eval is still in flight; the caller can
`continue_eval!` to wait more, `interrupt!` to SIGINT, or restart the session.
"""
function execute(s::JuliaSession, code::AbstractString;
                  timeout::Union{Real,Nothing} = DEFAULT_TIMEOUT,
                  max_bytes::Int               = 10_000,
                  full_output::Bool            = false)
    return execute_with(s, code, :format_value, timeout,
                         (max_bytes, full_output))
end

# bt_show counterpart: uses the BonitoMCPHelper.format_show formatter, which
# RENDERS the result to a file under <env>/.bonitoTeam/show/ on the worker
# side and returns a small text reference. The chat UI on the server side
# fetches the file (lazily) and renders a collapsible preview — bytes never
# enter the MCP tool result, so claude-agent-acp can't forward them to the
# model. Keeps the agent's context small while still showing the user
# images / SVGs / HTML / text inline.
function execute_show(s::JuliaSession, code::AbstractString;
                       timeout::Union{Real,Nothing} = DEFAULT_TIMEOUT,
                       max_bytes::Int               = 4_000_000)
    # Anchor the show/ dir in the env_path so it travels with the project
    # (RemoteSync covers .bonitoTeam/ already; show files persist alongside
    # the chat history).
    out_dir = s.env_path === nothing ?
        mktempdir(prefix = "bt-show-") :
        joinpath(s.env_path, ".bonitoTeam", "show")
    return execute_with(s, code, :format_show, timeout,
                         (out_dir, max_bytes))
end

# Shared body — the formatter symbol picks which BonitoMCPHelper function the
# worker calls; `args_tuple` is splatted into that call.
function execute_with(s::JuliaSession, code::AbstractString,
                       formatter::Symbol,
                       timeout::Union{Real,Nothing},
                       args_tuple::Tuple)
    @lock s.lock begin
        s.in_flight === nothing ||
            error("An eval is already in flight on this session — call " *
                  "bt_julia_continue, bt_julia_interrupt, or bt_julia_restart first.")
        is_alive(s) || start!(s)
        # Reset the buffer so the agent's `partial` reflects only this call's output.
        drain_output!(s)

        # Parse the code parent-side so we can return a clean error before spawning.
        # Use `parseall` so multi-statement code blocks work.
        expr = try
            Meta.parseall(String(code))
        catch e
            return (status   = :completed,
                    blocks   = [Dict{String,Any}("type"=>"text",
                                                  "text"=>"error:\nparse error: $(sprint(showerror, e))")],
                    is_error = true,
                    elapsed_s = 0.0)
        end

        s.in_flight_code    = String(code)
        s.in_flight_started = time()
        # Wrap in the helper so the worker returns pre-formatted block dicts
        # (base types only, never user-defined types Malt's serialiser
        # wouldn't recognise on the parent side). The error path always uses
        # format_error regardless of which value-formatter is picked.
        max_err_bytes = formatter === :format_value ? args_tuple[1] : 4_000
        wrapped = quote
            try
                Main.BonitoMCPHelper.$(formatter)($(expr), $(args_tuple...))
            catch __mcp_err__
                Main.BonitoMCPHelper.format_error(__mcp_err__, catch_backtrace(),
                                                   $max_err_bytes, false)
            end
        end
        s.in_flight = Malt.remote_eval(s.worker, wrapped)
        return await_or_yield(s, timeout)
    end
end

function continue_eval!(s::JuliaSession;
                        timeout::Union{Real,Nothing} = DEFAULT_TIMEOUT)
    @lock s.lock begin
        s.in_flight === nothing && error("No eval in flight on this session.")
        return await_or_yield(s, timeout)
    end
end

function interrupt!(s::JuliaSession)
    @lock s.lock begin
        s.in_flight === nothing && error("No eval in flight on this session.")
        Malt.interrupt(s.worker)
        # Generous timeout: the user's code might be in a try/catch that swallows
        # InterruptException briefly, but should yield within 30s.
        return await_or_yield(s, 30.0)
    end
end

# Poll the in-flight task for up to `timeout` seconds. Returns either
# completed (drained partial → stdout block + the value blocks) or running.
function await_or_yield(s::JuliaSession, timeout::Union{Real,Nothing})
    deadline = timeout === nothing ? Inf : time() + timeout
    while !istaskdone(s.in_flight) && time() < deadline
        sleep(0.05)
    end
    elapsed = round(time() - s.in_flight_started; digits = 2)
    partial = drain_output!(s)

    if istaskdone(s.in_flight)
        value_blocks, fetch_failed = try
            (fetch(s.in_flight), false)
        catch e
            (interrupt_blocks(e), true)
        end
        s.in_flight = nothing
        # Worker's try/catch wraps user errors as `error:` blocks (returned
        # normally), so a successful fetch can still represent a user error.
        # Inspect the blocks to set is_error correctly.
        is_error = fetch_failed || any(b -> startswith(get(b, "text", ""), "error:"),
                                         value_blocks)
        # Stitch: code echo + stdout (if any) + value/error blocks
        blocks = Dict{String,Any}[]
        push!(blocks, Dict("type" => "text",
                            "text" => "```julia\n$(rstrip(s.in_flight_code, '\n'))\n```"))
        if !isempty(partial)
            push!(blocks, Dict("type" => "text",
                                "text" => "stdout:\n$partial"))
        end
        append!(blocks, value_blocks)
        return (status = :completed, blocks = blocks,
                is_error = is_error, elapsed_s = elapsed)
    end
    return (status = :running, partial = partial, elapsed_s = elapsed)
end

# Build a one-block error array from a Malt task failure. Drills through the
# wrapper layers (TaskFailedException → RemoteException → InterruptException
# or whatever the user's code actually threw).
function interrupt_blocks(e)
    msg = sprint(showerror, e)
    return [Dict{String,Any}("type" => "text", "text" => "error:\n$msg")]
end

# ── Lifecycle ───────────────────────────────────────────────────────────────
function kill_session!(s::JuliaSession)
    if is_alive(s)
        try Malt.stop(s.worker) catch end
    end
    s.worker = nothing
    s.in_flight = nothing
    s.is_temp && s.env_path !== nothing && isdir(s.env_path) &&
        try rm(s.env_path; recursive = true, force = true) catch end
    return nothing
end

# ── SessionManager ──────────────────────────────────────────────────────────
mutable struct SessionManager
    sessions::Dict{String,JuliaSession}
    create_locks::Dict{String,ReentrantLock}
    global_lock::ReentrantLock
    log_dir::String
end

function SessionManager()
    log_dir = mktempdir(; prefix = "bonitoteam-mcp-logs-")
    SessionManager(Dict{String,JuliaSession}(),
                   Dict{String,ReentrantLock}(),
                   ReentrantLock(), log_dir)
end

const TEMP_KEY = "__temp__"

_key(env_path::Union{String,Nothing}) = env_path === nothing ? TEMP_KEY : abspath(env_path)

function _log_path(m::SessionManager, key::String)
    safe = replace(key, '/' => '_', '\\' => '_')
    safe = strip(safe, '_')
    isempty(safe) && (safe = "temp")
    return joinpath(m.log_dir, "$safe.log")
end

function get_or_create!(m::SessionManager, env_path::Union{String,Nothing};
                        julia_cmd::Union{String,Nothing} = nothing)
    key = _key(env_path)
    if haskey(m.sessions, key) && is_alive(m.sessions[key]) &&
       m.sessions[key].julia_cmd == julia_cmd
        return m.sessions[key]
    end
    create_lock = @lock m.global_lock get!(m.create_locks, key, ReentrantLock())
    @lock create_lock begin
        if haskey(m.sessions, key) && is_alive(m.sessions[key]) &&
           m.sessions[key].julia_cmd == julia_cmd
            return m.sessions[key]
        end
        haskey(m.sessions, key) && (kill_session!(m.sessions[key]); delete!(m.sessions, key))

        is_temp = env_path === nothing
        env_dir = is_temp ? mktempdir(; prefix = "bonitoteam-mcp-") : abspath(env_path)
        is_test = !is_temp && basename(rstrip(env_dir, '/')) == "test"

        s = JuliaSession(env_dir;
                         is_temp, is_test, julia_cmd,
                         log_path = _log_path(m, key))
        start!(s)
        m.sessions[key] = s
        return s
    end
end

function restart!(m::SessionManager, env_path::Union{String,Nothing})
    key = _key(env_path)
    @lock m.global_lock begin
        haskey(m.sessions, key) || return nothing
        kill_session!(m.sessions[key])
        delete!(m.sessions, key)
    end
    return nothing
end

list_sessions(m::SessionManager) = @lock m.global_lock begin
    [(env_path = s.env_path,
      alive    = is_alive(s),
      temp     = s.is_temp,
      julia_cmd = s.julia_cmd,
      log_path  = s.log_path,
      in_flight = s.in_flight !== nothing)
     for s in values(m.sessions)]
end

function shutdown!(m::SessionManager)
    @lock m.global_lock begin
        for s in values(m.sessions)
            try kill_session!(s) catch end
        end
        empty!(m.sessions)
    end
    try rm(m.log_dir; recursive = true, force = true) catch end
    return nothing
end

# Pkg-aware: when no explicit timeout was passed and the code uses `Pkg.*`,
# disable the soft-timeout — Pkg installs are routinely multi-minute and the
# default 30s checkpoint cadence would be noise. Explicit user timeout always
# wins. Pass `timeout = 0` (or anything ≤ 0) to disable.
function effective_timeout(code::AbstractString,
                            requested::Union{Real,Nothing})::Union{Real,Nothing}
    if requested === nothing
        return occursin(PKG_PATTERN, code) ? nothing : DEFAULT_TIMEOUT
    end
    return requested > 0 ? requested : nothing
end

const MANAGER = Ref{Union{SessionManager,Nothing}}(nothing)
function manager()
    MANAGER[] === nothing && (MANAGER[] = SessionManager())
    return MANAGER[]
end
