# MCP tool registrations: bt_julia_eval, bt_julia_restart, bt_julia_list_sessions.
# Architecture: each env_path gets a `julia -i` subprocess managed by
# SessionManager (see session.jl). Output discipline (truncation, structured
# blocks, container summarisation, image detection, backtrace trim,
# nothing-suppression) lives in helper_payload.jl which is `include`d into
# every subprocess on startup.

# ── Handlers ────────────────────────────────────────────────────────────────
function julia_eval_handler(args::AbstractDict)
    code        = String(get(args, "code", ""))
    env_path    = get(args, "env_path", nothing)
    julia_cmd   = get(args, "julia_cmd", nothing)
    user_to     = get(args, "timeout", nothing)
    full_output = Bool(get(args, "full_output", false))
    max_bytes   = Int(get(args, "max_response_bytes", 10_000))

    isempty(strip(code)) && return Dict{String,Any}(
        "content" => [Dict("type"=>"text", "text"=>"error: empty code")],
        "isError" => true,
    )

    # Tear down a stale dead session before creating a new one. SessionManager
    # already does this in get_or_create!, but doing it explicitly here lets
    # the next call after a hard-timeout-kill recover transparently.
    s = try
        get_or_create!(manager(), env_path; julia_cmd)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type"=>"text", "text"=>"error starting session: $(sprint(showerror, e))")],
            "isError" => true,
        )
    end

    timeout = effective_timeout(code, user_to)

    blocks, is_error = try
        execute(s, code; timeout, max_bytes, full_output)
    catch e
        # On timeout / subprocess death, clean the dict so the next call
        # builds a fresh subprocess.
        msg = sprint(showerror, e)
        return Dict{String,Any}(
            "content" => [Dict("type"=>"text", "text"=>msg)],
            "isError" => true,
        )
    end

    return Dict{String,Any}(
        "content" => blocks,
        "isError" => is_error,
    )
end

function julia_restart_handler(args::AbstractDict)
    env_path = get(args, "env_path", nothing)
    restart!(manager(), env_path)
    label = env_path === nothing ? "<temp>" : env_path
    return Dict{String,Any}(
        "content" => [Dict("type" => "text",
                            "text" => "Session for $label cleared. Next call rebuilds it.")],
        "isError" => false,
    )
end

function julia_list_sessions_handler(::AbstractDict)
    sessions = list_sessions(manager())
    text = if isempty(sessions)
        "no active sessions"
    else
        lines = String["active sessions:"]
        for s in sessions
            extras = String[]
            s.julia_cmd === nothing || push!(extras, "julia_cmd=$(s.julia_cmd)")
            s.temp                  && push!(extras, "temp")
            s.alive                 || push!(extras, "DEAD")
            tail = isempty(extras) ? "" : "  [" * join(extras, ", ") * "]"
            push!(lines, "  - $(s.env_path)$tail")
            s.log_path === nothing  || push!(lines, "      log: $(s.log_path)")
        end
        join(lines, "\n")
    end
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => text)],
        "isError" => false,
    )
end

# ── Registration ────────────────────────────────────────────────────────────
register!(
    "bt_julia_eval",
    """
    Evaluate Julia code in a persistent per-`env_path` session. ALWAYS prefer
    this over `julia -e` via Bash for Julia work — running through Bash spawns
    a fresh process every time, so `using Foo` / loaded variables / compiled
    methods don't carry over and you pay full startup cost on each call.

    Each `env_path` runs in its own `julia -i` subprocess; state (top-level
    bindings, loaded modules, function defs) carries over across calls with
    the same env. Use `bt_julia_restart` to drop the session if it's gotten
    into a bad state. `bt_julia_list_sessions` shows what's currently live.
    Revise.jl is auto-loaded so source edits to packages are picked up
    without restart. If the env path ends in `/test`, TestEnv is activated
    automatically so the parent project's test deps are visible.

    Output:
      - Echoed code, captured stdout, return value, and errors are returned
        as separate blocks.
      - Output is auto-truncated at `max_response_bytes` (default 10000).
        Large arrays / dicts are summarised; pass `full_output=true` to disable.
      - 2-D arrays of color types are rendered as PNG images when PNGFiles is
        available in the env.
      - A return value of `nothing` is suppressed to keep responses tight —
        if you need to inspect a value, return it explicitly (last expression
        in the block).
      - Backtraces are trimmed to user-relevant frames.

    Timeout (`timeout` seconds) defaults to 60s but is auto-disabled when the
    code matches `Pkg.*` so installs / precompiles aren't killed mid-flight.
    A hard timeout `kill`s the subprocess; the session is restarted on the
    next call.
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "code" => Dict("type" => "string",
                           "description" => "Julia code to evaluate"),
            "env_path" => Dict("type" => "string",
                               "description" => "Optional Julia project directory; omit for a temp env"),
            "timeout" => Dict("type" => "number",
                              "description" => "Hard timeout in seconds. Default 60s; auto-disabled for `Pkg.*`. Pass 0 to disable."),
            "julia_cmd" => Dict("type" => "string",
                                "description" => "Custom Julia invocation, e.g. `julia +1.11` (juliaup channel) or `/path/to/julia --check-bounds=yes`. Use rarely."),
            "full_output" => Dict("type" => "boolean", "default" => false,
                                  "description" => "Disable output truncation/summarisation"),
            "max_response_bytes" => Dict("type" => "integer", "default" => 10_000,
                                          "description" => "Per-block byte cap"),
        ),
        "required" => ["code"],
    ),
    julia_eval_handler,
)

register!(
    "bt_julia_restart",
    """
    Restart a Julia session, clearing all state. IMPORTANT: restarting is slow
    and loses everything. Revise.jl is loaded automatically so code changes to
    loaded packages are picked up without restarting — only restart as a last
    resort when the session is truly broken or for changes Revise can't fix
    (e.g. struct field changes).
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "env_path" => Dict("type" => "string",
                               "description" => "Project to restart; omit for the temp session"),
        ),
    ),
    julia_restart_handler,
)

register!(
    "bt_julia_list_sessions",
    "List currently active per-`env_path` Julia sessions and their log files.",
    Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
    julia_list_sessions_handler,
)
