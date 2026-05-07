# JuliaSession + SessionManager — subprocess-per-env eval, ported from
# julia-mcp's design (https://github.com/SimonDanisch/julia-mcp/blob/main/server.py).
# Compared to the previous in-process Module-based session this gives us:
#   - hard timeout via process kill
#   - crash isolation between sessions
#   - julia_cmd flexibility (`julia +1.11`, custom flags, alt binary)
#   - auto-Revise, TestEnv, Pkg-aware timeout
#   - per-session log file for debugging
# Output discipline (truncation, structured blocks) lives in helper_payload.jl
# which is `include`d into each subprocess on startup.

using Base64
using Dates: format, now

const HELPER_PATH = abspath(joinpath(@__DIR__, "helper_payload.jl"))

# Pkg.* calls need indefinite time; matched by this regex on the user code.
const PKG_PATTERN = r"\bPkg\."

# Markers emitted by the helper payload around the structured-block stream.
const BLOCKS_BEGIN = "__MCP_BLOCKS_BEGIN__"
const BLOCKS_END   = "__MCP_BLOCKS_END__"

const DEFAULT_TIMEOUT = 60.0

# ── JuliaSession ────────────────────────────────────────────────────────────
"""
A persistent `julia -i --project=<env_dir>` subprocess. One per env_path.
Stdin/stdout pipes carry code + output; a per-session sentinel tells us when
each call's output is done. Output is the helper's structured-block stream,
not raw stdout.
"""
mutable struct JuliaSession
    env_dir::String
    sentinel::String                 # per-session UUID, used as response delimiter
    is_temp::Bool
    is_test::Bool                    # path ends in /test → run TestEnv.activate()
    julia_cmd::Union{String,Nothing} # nothing = default `julia`
    process::Union{Base.Process,Nothing}
    lock::ReentrantLock              # serialises execute() within a session
    log_path::Union{String,Nothing}
    log_io::Union{IOStream,Nothing}
end

function JuliaSession(env_dir::String;
                       is_temp::Bool   = false,
                       is_test::Bool   = false,
                       julia_cmd::Union{String,Nothing} = nothing,
                       log_path::Union{String,Nothing}  = nothing)
    sentinel = "__BT_MCP_$(string(Base.UUID(rand(UInt128))))__"
    log_io   = log_path === nothing ? nothing : open(log_path, "a")
    JuliaSession(env_dir, sentinel, is_temp, is_test, julia_cmd,
                 nothing, ReentrantLock(), log_path, log_io)
end

is_alive(s::JuliaSession) =
    s.process !== nothing && process_running(s.process)

# Build the command vector. Handles juliaup `+channel` syntax and custom flags
# in `julia_cmd`. The last arg is always `--project=<env_dir>` so the session
# resolves packages from the right env.
function build_cmd(s::JuliaSession)::Cmd
    parts::Vector{String} = if s.julia_cmd === nothing
        ["julia"]
    else
        split(s.julia_cmd)
    end
    exe = parts[1]
    rest = parts[2:end]

    # juliaup `+channel` must come right after the executable
    channel_args = String[]
    if !isempty(rest) && startswith(rest[1], "+")
        push!(channel_args, popfirst!(rest))
    end

    return Cmd(String[
        exe, channel_args...,
        "-i",                                          # interactive (no prompt when stdin isn't a TTY)
        "--threads=auto",
        "--banner=no",
        rest...,
        "--project=$(s.env_dir)",
    ])
end

function start!(s::JuliaSession)
    is_alive(s) && return s

    # Pipe subprocess stderr into the per-session log file so the parent's
    # stderr stays clean (GC warnings, the SIGTERM banner on hard-timeout
    # kill, etc.). Falls back to devnull if no log path is configured.
    err_target = s.log_path === nothing ? devnull : s.log_path
    cmd = pipeline(build_cmd(s); stderr = err_target, append = true)
    s.process = open(cmd, "r+")

    # Give the subprocess a moment to spin up before sending code. Without this
    # the very first include() can race the subprocess's banner-suppression.
    sleep(0.1)

    # 1. Load the helper module
    send_raw(s, "include(\"$HELPER_PATH\")\n")
    # 2. Bring Base64 into Main scope so the wrapped `Base64.base64decode(...)`
    #    eval calls resolve (Base64 is stdlib but not imported by default).
    send_raw(s, "using Base64\n")
    # 3. Auto-load Revise (best-effort; missing dep is fine)
    send_raw(s, "try; using Revise; catch; end\n")
    # 4. /test envs use TestEnv to activate the parent project's test deps
    if s.is_test
        send_raw(s, "try; using TestEnv; TestEnv.activate(); catch; end\n")
    end
    # 5. Sentinel ping to know when init is done
    send_raw(s, "println(\"$(s.sentinel)\")\n")

    # Wait for sentinel — generous timeout for first launch (precompile etc.)
    read_until_sentinel(s; timeout = 120.0, on_kill = "startup")
    return s
end

# Send a JSON-RPC-style `eval_and_emit` call, read the structured-block
# stream, parse it into MCP content blocks, return the content array.
"""
    execute(session, code; timeout, max_bytes, full_output)
        → Vector{Dict{String,Any}}, isError::Bool

`timeout` is in seconds; `nothing` means no timeout. On timeout the subprocess
is killed; the session is then dead and `manager.execute` will rebuild it on
the next call.
"""
function execute(s::JuliaSession, code::AbstractString;
                  timeout::Union{Real,Nothing} = DEFAULT_TIMEOUT,
                  max_bytes::Int               = 10_000,
                  full_output::Bool            = false)
    @lock s.lock begin
        is_alive(s) || error("Julia session has died")

        if s.log_io !== nothing
            ts = format(now(), "HH:MM:SS")
            println(s.log_io, "[$ts] julia> ", code)
            flush(s.log_io)
        end

        # Encode the user code so embedded quotes / newlines don't trip up
        # the line-based REPL parser.
        encoded = base64encode(code)
        wrapped = string(
            "BonitoMCPHelper.eval_and_emit(",
                "String(Base64.base64decode(\"", encoded, "\"));",
                "max_bytes=", max_bytes, ", full_output=", full_output, ")\n",
            "println(\"", s.sentinel, "\")\n",
        )
        send_raw(s, wrapped)

        raw = read_until_sentinel(s; timeout, on_kill = "eval")
        blocks, is_error = parse_block_stream(raw)

        if s.log_io !== nothing
            n_blocks = length(blocks)
            println(s.log_io, "    ", n_blocks, " block(s) returned")
            flush(s.log_io)
        end

        return blocks, is_error
    end
end

# Send a string verbatim to the subprocess's stdin (with newline-flush).
function send_raw(s::JuliaSession, payload::AbstractString)
    @assert s.process !== nothing
    write(s.process, payload)
    flush(s.process)
    return nothing
end

# Read lines until the per-session sentinel appears. With timeout, kill the
# process on expiry — the session is unrecoverable, but isolation kept the
# rest of BonitoMCP alive. Returns the buffered text (sentinel excluded).
function read_until_sentinel(s::JuliaSession; timeout::Union{Real,Nothing}, on_kill::String)
    proc = s.process
    @assert proc !== nothing
    buf = IOBuffer()

    reader = @async begin
        while !eof(proc)
            line = readline(proc; keep = false)
            line == s.sentinel && return :done
            println(buf, line)
        end
        return :eof
    end

    if timeout === nothing
        outcome = fetch(reader)
    else
        deadline = time() + timeout
        while !istaskdone(reader) && time() < deadline
            sleep(0.05)
        end
        if !istaskdone(reader)
            kill(proc)
            wait(proc)
            partial = String(take!(buf))
            error("$(on_kill) timed out after $(timeout)s; session killed.\n" *
                  (isempty(partial) ? "" : "Output before timeout:\n$partial"))
        end
        outcome = fetch(reader)
    end

    outcome == :eof && error("Julia subprocess died during $(on_kill).\n" *
                              "Output before death:\n$(String(take!(buf)))")
    return String(take!(buf))
end

# Parse the helper's `__MCP_BLOCKS_BEGIN__ ... __MCP_BLOCKS_END__` envelope.
# Each interior line is `<kind>:<base64>` (or `image:<base64>:<mime>`).
# Returns the MCP content vector + whether any block was an error.
function parse_block_stream(raw::AbstractString)
    blocks   = Vector{Dict{String,Any}}()
    in_block = false
    is_error = false
    for line in split(raw, '\n')
        if !in_block
            line == BLOCKS_BEGIN && (in_block = true)
            continue
        end
        line == BLOCKS_END && break
        # `kind:b64` or `image:b64:mime`
        sep = findfirst(==(':'), line)
        sep === nothing && continue
        kind  = SubString(line, 1, sep - 1)
        rest  = SubString(line, sep + 1, lastindex(line))
        if kind == "image"
            sep2 = findfirst(==(':'), rest)
            sep2 === nothing && continue
            data = String(rest[1:sep2 - 1])
            mime = String(rest[sep2 + 1:lastindex(rest)])
            push!(blocks, Dict{String,Any}(
                "type" => "image", "data" => data, "mimeType" => mime))
        else
            text = String(base64decode(String(rest)))
            push!(blocks, Dict{String,Any}("type" => "text", "text" => text))
            kind == "error" && (is_error = true)
        end
    end
    return blocks, is_error
end

function kill_session!(s::JuliaSession)
    if s.process !== nothing && process_running(s.process)
        kill(s.process)
        try wait(s.process) catch end
    end
    if s.log_io !== nothing
        try close(s.log_io) catch end
        s.log_io = nothing
    end
    if s.is_temp && isdir(s.env_dir)
        try rm(s.env_dir; recursive = true, force = true) catch end
    end
    return nothing
end

# ── SessionManager ──────────────────────────────────────────────────────────
"""
Holds JuliaSession instances keyed by canonical env_path. Per-key creation
locks prevent two concurrent get_or_create calls from racing to spawn two
subprocesses for the same env.
"""
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

function _key(env_path::Union{String,Nothing})
    env_path === nothing && return TEMP_KEY
    return abspath(env_path)
end

function _log_path(m::SessionManager, key::String)
    safe = replace(key, '/' => '_', '\\' => '_')
    safe = strip(safe, '_')
    isempty(safe) && (safe = "temp")
    return joinpath(m.log_dir, "$safe.log")
end

function get_or_create!(m::SessionManager, env_path::Union{String,Nothing};
                        julia_cmd::Union{String,Nothing} = nothing)
    key = _key(env_path)

    # Fast path: live session with matching julia_cmd
    if haskey(m.sessions, key) && is_alive(m.sessions[key]) &&
       m.sessions[key].julia_cmd == julia_cmd
        return m.sessions[key]
    end

    # Per-key creation lock so two concurrent calls don't race on spawn
    create_lock = @lock m.global_lock get!(m.create_locks, key, ReentrantLock())
    @lock create_lock begin
        # Re-check under the lock
        if haskey(m.sessions, key) && is_alive(m.sessions[key]) &&
           m.sessions[key].julia_cmd == julia_cmd
            return m.sessions[key]
        end
        # Tear down stale (dead or wrong-cmd) session
        if haskey(m.sessions, key)
            kill_session!(m.sessions[key])
            delete!(m.sessions, key)
        end
        # Build new session
        is_temp = env_path === nothing
        if is_temp
            env_dir = mktempdir(; prefix = "bonitoteam-mcp-")
            is_test = false
        else
            env_dir = abspath(env_path)
            is_test = basename(rstrip(env_dir, '/')) == "test"
        end
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
        if haskey(m.sessions, key)
            kill_session!(m.sessions[key])
            delete!(m.sessions, key)
        end
    end
    return nothing
end

function list_sessions(m::SessionManager)
    @lock m.global_lock begin
        return [(env_path = s.env_dir,
                 alive    = is_alive(s),
                 temp     = s.is_temp,
                 julia_cmd = s.julia_cmd,
                 log_path  = s.log_path)
                for s in values(m.sessions)]
    end
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

# Pick the right effective timeout: nothing for Pkg.*, otherwise honour the
# caller's value (or DEFAULT_TIMEOUT if nothing was passed).
function effective_timeout(code::AbstractString,
                            requested::Union{Real,Nothing})::Union{Real,Nothing}
    if requested === nothing
        return occursin(PKG_PATTERN, code) ? nothing : DEFAULT_TIMEOUT
    end
    return requested > 0 ? requested : nothing
end

# Module-level singleton, created lazily.
const MANAGER = Ref{Union{SessionManager,Nothing}}(nothing)
function manager()
    MANAGER[] === nothing && (MANAGER[] = SessionManager())
    return MANAGER[]
end
