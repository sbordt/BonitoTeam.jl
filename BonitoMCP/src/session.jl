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
import Pkg

const HELPER_PATH = abspath(joinpath(@__DIR__, "helper_payload.jl"))
const PKG_PATTERN = r"\bPkg\."
const DEFAULT_TIMEOUT = 30.0
const BONITO_UUID = Base.UUID("824d6782-a2ef-11e9-3a09-e5662e0c26f8")

# Locate Bonito's source directory in BonitoMCP's own active project, so a
# temp eval env can path-dep on the *same* Bonito BonitoMCP itself runs
# against. Returns `nothing` if Bonito isn't in the active project (e.g.
# BonitoMCP installed standalone) — caller falls back gracefully.
function _find_bonito_path()
    try
        deps = Pkg.dependencies()
        haskey(deps, BONITO_UUID) || return nothing
        src = deps[BONITO_UUID].source
        src isa AbstractString && isdir(src) ? String(src) : nothing
    catch e
        @debug "_find_bonito_path failed" exception = e
        nothing
    end
end

# Seed a fresh temp project so `using Bonito` on the Malt worker resolves to
# the proxy-aware dev Bonito (`id_prefix` & friends) rather than the
# registered version. Writes Project.toml + resolves it in a side julia
# subprocess so the worker can `using Bonito` immediately. Best-effort — a
# failure here just leaves the temp env empty, same as before.
function seed_temp_env_with_bonito!(env_dir::AbstractString)
    bonito_path = _find_bonito_path()
    bonito_path === nothing && return false
    proj_toml = joinpath(env_dir, "Project.toml")
    try
        open(proj_toml, "w") do io
            print(io, """
                [deps]
                Bonito = "$(BONITO_UUID)"

                [sources]
                Bonito = {path = $(repr(bonito_path))}
                """)
        end
        # Resolve in a side julia process (so the parent's project state isn't
        # disturbed and the Malt worker can `using Bonito` without doing its
        # own Pkg.resolve at first call).
        julia = joinpath(Sys.BINDIR::String, Base.julia_exename())
        run(pipeline(`$julia --project=$env_dir --startup-file=no -e "using Pkg; Pkg.resolve()"`;
                     stdout = devnull, stderr = devnull))
        true
    catch e
        @warn "seed_temp_env_with_bonito!: Pkg.resolve failed; bt_show_app may fail until env_path is given explicitly" env_dir exception = e
        false
    end
end

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
    dialed_back::Bool                   # `ensure_eval_dialed!` dedupes against this; flipped under `lock`
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
                        ReentrantLock(), log_path, false)
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

"""
    ensure_eval_dialed!(s::JuliaSession)

If the server injected WebSocket dial-back coordinates (via the MCP `env`),
bootstrap the worker-side proxy bridge and have the worker dial the server. This
one Malt call (over BonitoMCP's OWN link to the worker) includes `RemoteProxy` +
builds the bridge; the worker then opens the dial-back WebSocket and runs
`RemoteProxy.serve_bridge`, which pipes the Bonito protocol over it RAW (no Malt
on that socket — see RemoteProxy.jl). Lets the server drive this worker to render
interactive Bonito apps into the chat. Idempotent + lazy (call when Bonito is
loaded, e.g. from `bt_show_app`).
"""
function ensure_eval_dialed!(s::JuliaSession)
    # `BONITOTEAM_SERVER_URL` is set by the BonitoWorker daemon (the install
    # URL it dialed in on) and inherited down through claude-agent-acp → MCP
    # child. Single source of truth for "where the server is", shared with the
    # worker-control WS so the two dial-backs can't disagree.
    server_url = get(ENV, "BONITOTEAM_SERVER_URL", "")
    isempty(server_url) && return s
    wsurl = replace(rstrip(server_url, '/'), r"^http" => "ws") * "/eval-ws"
    is_alive(s) || start!(s)
    secret     = get(ENV, "BONITOTEAM_SECRET", "")
    project_id = get(ENV, "BONITOTEAM_PROJECT_ID", "")
    # Dedupe against this session's own state — avoids a Main-global
    # idempotency flag on the worker (Julia 1.12 strict-globals would force
    # a `Core.eval`/world-age dance, and we'd be inventing the dedupe twice).
    # Once we've dialed back, the worker's `dial_loop` task self-reconnects
    # on WS drop — we do NOT want to spawn a duplicate dial_loop. Just verify
    # the connection IS currently up; if it's between reconnect attempts
    # (backoff sleep), wait briefly for it to come back before failing. This
    # is the path that fires when bt_show_app runs against a worker whose WS
    # was lost (e.g. after a BonitoTeam server restart).
    if s.dialed_back
        worker_ws_live() = try
            Malt.remote_eval_fetch(s.worker,
                :(isdefined(Main, :RemoteProxy) &&
                  Main.RemoteProxy.BRIDGE[] !== nothing &&
                  Main.RemoteProxy.BRIDGE[].driver.ws[] !== nothing))
        catch
            false
        end
        worker_ws_live() && return s
        @info "BonitoMCP: eval-ws bridge currently disconnected — waiting for dial_loop to reconnect"
        for _ in 1:40   # ~10s budget, covers max_backoff (8s) plus reconnect
            worker_ws_live() && return s
            sleep(0.25)
        end
        @warn "BonitoMCP: eval-ws bridge stayed disconnected; will not double-dial. Use bt_julia_restart to rebuild the worker if the issue persists."
        return s
    end
    try
        # Bootstrap over BonitoMCP's OWN Malt link: include RemoteProxy + build the
        # bridge, get its namespace prefix. The dial-back socket itself carries NO
        # Malt — it's a raw Bonito frame pipe (see RemoteProxy.serve_bridge); Malt
        # is only this one-time setup call.
        prefix = Malt.remote_eval_fetch(s.worker, quote
            using Bonito
            # Re-include if RemoteProxy is absent OR only PARTIALLY loaded. A failed
            # include (e.g. the resolved Bonito lacks the remote-app proxy API the
            # module touches at load time) leaves a PARTIAL module registered in
            # Main — early defs present, late ones (`register_app!`, `render_embed`)
            # missing — and the include THREW. The old bare `isdefined(Main,
            # :RemoteProxy)` guard then skipped re-include forever, so the next call
            # built a bridge on the broken module and the missing def surfaced later
            # as a cryptic `register_app! not defined`. `render_embed` is the
            # module's last def ⇒ its presence means a complete load; otherwise
            # re-include, which re-throws the REAL load error if the env is wrong.
            if !(isdefined(Main, :RemoteProxy) && isdefined(Main.RemoteProxy, :render_embed))
                include($(REMOTE_PROXY_PATH))
            end
            Main.RemoteProxy.ensure_bridge!()
        end)
        # Drive a self-reconnecting dial loop on the worker. Handshake carries
        # the prefix so the host knows the namespace before any frame flows.
        # `dial_loop` survives transient WS drops by reconnecting with backoff —
        # `BRIDGE[].routes` is preserved across drops, so already-registered
        # apps keep working without re-running their code.
        Malt.remote_eval_fetch(s.worker, quote
            @async try
                Main.RemoteProxy.dial_loop(
                    $wsurl,
                    $(secret * " " * project_id * " " * prefix))
            catch e
                @warn "BonitoMCP eval-ws dial loop crashed" exception = (e, catch_backtrace())
            end
            nothing
        end)
        # Wait until the dial actually connects (serve_bridge sets the socket) so
        # callers can immediately reach the bridge over the raw transport.
        ready = false
        for _ in 1:120   # ~30s budget — covers cold include + first dial
            if Malt.remote_eval_fetch(s.worker,
                    :(isdefined(Main, :RemoteProxy) && Main.RemoteProxy.BRIDGE[] !== nothing &&
                      Main.RemoteProxy.BRIDGE[].driver.ws[] !== nothing))
                ready = true; break
            end
            sleep(0.25)
        end
        ready || @warn "BonitoMCP: bridge dial not connected 30s after setup" wsurl
        s.dialed_back = true
    catch e
        s.dialed_back = false   # allow retry on the next call
        @warn "BonitoMCP: eval dial-back setup failed" exception = (e, catch_backtrace())
    end
    return s
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

    # Interactive-app dial-back is lazy (ensure_eval_dialed! from bt_show_app),
    # so non-Bonito eval sessions don't pay for it.

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
  (status = :running,   partial::String, elapsed_s::Float64, code::String)

The `code` field on the running variant carries the in-flight code so the chat
renderer can show the ```julia code echo + partial stdout as eval-shaped
content (same render as the completed case), instead of a raw status blob.

Soft timeout — `:running` means the eval is still in flight; the caller can
`continue_eval!` to wait more, `interrupt!` to SIGINT, or restart the session.
"""
function execute(s::JuliaSession, code::AbstractString;
                  timeout::Union{Real,Nothing} = DEFAULT_TIMEOUT,
                  max_bytes::Int               = 10_000,
                  full_output::Bool            = false)
    @lock s.lock begin
        s.in_flight === nothing ||
            error("An eval is already in flight on this session — call " *
                  "bt_julia_continue, bt_julia_interrupt, or bt_julia_restart first.")
        is_alive(s) || start!(s)
        drain_output!(s)

        expr = try
            Meta.parseall(String(code))
        catch e
            return (status   = :completed,
                    blocks   = [Dict{String,Any}("type"=>"text",
                                                  "text"=>"error:\nparse error: $(sprint(showerror, e))")],
                    is_error = true,
                    elapsed_s = 0.0)
        end

        # Anchor the .bonitoTeam/show/ dir in env_path so rich-output files
        # written by format_value travel with the project. RemoteSync
        # already covers .bonitoTeam/, so show files persist alongside the
        # chat history. For temp envs we fall back to a tmp dir.
        out_dir = s.env_path === nothing ?
            mktempdir(prefix = "bt-show-") :
            joinpath(s.env_path, ".bonitoTeam", "show")

        s.in_flight_code    = String(code)
        s.in_flight_started = time()
        # Wrap in the helper so the worker returns pre-formatted block dicts
        # (base types only, never user-defined types Malt's serialiser
        # wouldn't recognise on the parent side).
        wrapped = quote
            try
                Main.BonitoMCPHelper.format_value($(expr), $out_dir, $max_bytes, $full_output)
            catch __mcp_err__
                Main.BonitoMCPHelper.format_error(__mcp_err__, catch_backtrace(),
                                                   $max_bytes, $full_output)
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
    # The loop also exits promptly when the eval task dies — e.g. an MCP
    # `notifications/cancelled` SIGINTs it via `handle_cancelled!`, which makes
    # `istaskdone` true and falls through to the completed (interrupted) result.
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
    return (status = :running, partial = partial, elapsed_s = elapsed,
            code = s.in_flight_code)
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
        # Temp envs are otherwise empty, so `using Bonito` on the Malt worker
        # falls back to the user depot and resolves the REGISTERED Bonito —
        # which doesn't have the remote-app proxy API (`id_prefix`, …) that
        # RemoteProxy.jl needs. Pre-populate the temp env with a Bonito
        # path-dep on whatever Bonito BonitoMCP's own active project uses, so
        # the worker resolves to the *same* Bonito. Best-effort: if we can't
        # locate Bonito (BonitoMCP installed standalone), bt_show_app will
        # still fail loudly, but bt_julia_eval keeps working in the bare env.
        is_temp && seed_temp_env_with_bonito!(env_dir)
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
