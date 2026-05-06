# Persistent-session Julia eval tool with output discipline.
# Multiple sessions keyed by env_path, lazily started.

import Pkg

# Per-session anonymous module + (optional) Pkg env
const SESSIONS = Dict{String,Module}()

function _session_for(env_path::Union{Nothing,AbstractString})
    key = something(env_path, "<temp>")
    if !haskey(SESSIONS, key)
        m = Module(Symbol("MCPSession_", replace(string(hash(key)), "-" => "_")))
        # Make Base + Core available in the session
        Core.eval(m, :(using Base))
        if env_path !== nothing && isdir(env_path)
            Pkg.activate(env_path; io = devnull)
        end
        SESSIONS[key] = m
    end
    return SESSIONS[key]
end

# redirect_stdout requires a Pipe / IOStream / DevNull (NOT IOBuffer). Capture
# both stdout and stderr from `f()` and return (val, error_text, captured_text).
function _eval_with_capture(sess::Module, code::AbstractString)
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
    old_stdout = stdout
    old_stderr = stderr
    val = nothing
    err_text = nothing

    # Reader runs concurrently so the pipe never fills up
    reader = @async read(pipe, String)

    redirect_stdout(pipe.in)
    redirect_stderr(pipe.in)
    try
        val = include_string(sess, code, "mcp_eval")
    catch e
        err_text = sprint() do io
            showerror(io, e)
            println(io)
            Base.show_backtrace(io, catch_backtrace())
        end
    finally
        redirect_stdout(old_stdout)
        redirect_stderr(old_stderr)
        close(pipe.in)
    end
    captured = fetch(reader)
    return (val, err_text, captured)
end

# Trim noisy frames from a Julia backtrace string. We keep the showerror line
# (which has the actual error) and drop everything past the first stdlib /
# REPL boundary — claude doesn't need to wade through 30 frames of `eval`,
# `include_string`, `client.jl`, etc., that's just our MCP plumbing.
const BACKTRACE_NOISE_FRAMES = (
    r"\bBase\.eval\b", r"\binclude_string\b", r"\beval_user_input\b",
    r"\bclient\.jl\b", r"\brun_main_repl\b", r"\brun_fallback_repl\b",
    r"\brepl_main\b",  r"\b_start\b",
)

function _trim_backtrace(text::AbstractString)
    lines = split(text, '\n')
    cut = something(findfirst(line -> any(p -> occursin(p, line), BACKTRACE_NOISE_FRAMES),
                              lines), length(lines) + 1)
    cut > length(lines) && return String(strip(text))
    kept = lines[1:cut-1]
    suppressed = length(lines) - length(kept)
    suppressed > 1 && push!(kept, "  [+ $suppressed internal frames]")
    return strip(join(kept, "\n"))
end

"""
Evaluate `code` in the per-env_path persistent session. Captures stdout, return
value, and errors. Output is formatted via output_discipline.jl rules.
"""
function julia_eval_handler(args::AbstractDict)
    code = String(get(args, "code", ""))
    env_path = get(args, "env_path", nothing)
    full_output = Bool(get(args, "full_output", false))
    max_bytes = Int(get(args, "max_response_bytes", DEFAULT_MAX_RESPONSE_BYTES))

    sess = _session_for(env_path)
    val, err_text, stdout_str = _eval_with_capture(sess, code)

    # Always include the executed code as the first content block — ACP doesn't
    # surface tool args, so this is how the chat UI shows what was run.
    code_block = Dict("type" => "text", "text" => "```julia\n$code\n```")

    blocks = if err_text !== nothing
        out_blocks = Dict{String,Any}[code_block]
        if !isempty(stdout_str)
            push!(out_blocks, Dict("type" => "text", "text" => "stdout:\n$stdout_str"))
        end
        push!(out_blocks, Dict("type" => "text",
                                "text" => "error:\n$(_trim_backtrace(err_text))"))
        out_blocks
    else
        result_blocks = format_for_mcp(val;
                                       full_output = full_output,
                                       max_response_bytes = max_bytes,
                                       stdout_text = stdout_str)
        prepend!(result_blocks, [code_block])
        result_blocks
    end

    return Dict{String,Any}(
        "content" => blocks,
        "isError" => err_text !== nothing,
    )
end

"""
Restart a session (drop the module + recreate on next call).
"""
function julia_restart_handler(args::AbstractDict)
    env_path = get(args, "env_path", nothing)
    key = something(env_path, "<temp>")
    if haskey(SESSIONS, key)
        delete!(SESSIONS, key)
        text = "Session for env_path=$(repr(env_path)) cleared. Next call rebuilds it."
    else
        text = "No active session for env_path=$(repr(env_path))."
    end
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => text)],
        "isError" => false,
    )
end

"""
List active sessions and their env paths.
"""
function julia_list_sessions_handler(::AbstractDict)
    keys_list = collect(keys(SESSIONS))
    text = isempty(keys_list) ?
        "no active sessions" :
        "active sessions:\n" * join(("  - $k" for k in keys_list), "\n")
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => text)],
        "isError" => false,
    )
end

# tool registration
register!(
    "bt_julia_eval",
    """
    Evaluate Julia code in a persistent per-`env_path` session. ALWAYS prefer
    this over `julia -e` via Bash for Julia work — running through Bash spawns
    a fresh process every time, so `using Foo` / loaded variables / compiled
    methods don't carry over and you pay full startup cost on each call.

    State (top-level bindings, loaded modules, function defs) carries over
    across calls with the same `env_path`. Use `bt_julia_restart` to drop the
    session if it's gotten into a bad state. `bt_julia_list_sessions` shows
    what's currently live.

    Output rules:
      - stdout, return value, and errors are returned as separate blocks.
      - Output is auto-truncated at `max_response_bytes` (default 10000).
        Large arrays / dicts are summarised; pass `full_output=true` to disable.
      - 2-D arrays of color types are rendered as images.
      - A return value of `nothing` is suppressed to keep responses tight —
        if you need to inspect a value, return it explicitly (last expression
        in the block).
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "code" => Dict("type" => "string",
                           "description" => "Julia code to evaluate"),
            "env_path" => Dict("type" => "string",
                               "description" => "Optional Julia project directory"),
            "full_output" => Dict("type" => "boolean", "default" => false,
                                  "description" => "Disable output truncation/summarization"),
            "max_response_bytes" => Dict("type" => "integer", "default" => 10_000,
                                          "description" => "Per-block byte cap"),
        ),
        "required" => ["code"],
    ),
    julia_eval_handler,
)

register!(
    "bt_julia_restart",
    "Drop the persistent session for env_path so the next eval starts fresh.",
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "env_path" => Dict("type" => "string",
                               "description" => "Project to restart"),
        ),
    ),
    julia_restart_handler,
)

register!(
    "bt_julia_list_sessions",
    "List currently active per-env_path Julia sessions.",
    Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
    julia_list_sessions_handler,
)
