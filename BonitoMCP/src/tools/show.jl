# bt_show — evaluate a Julia expression and ship the rendered output to the
# chat UI WITHOUT putting the bytes into the agent's context. Wraps the
# normal eval machinery; the only difference vs bt_julia_eval is the
# format_show payload formatter (helper_payload.jl::format_show), which
# walks the MIME chain (PNG → SVG → HTML → text) and tags heavy content
# with annotations.audience = ["user"] per the MCP spec.

function julia_show_handler(args::AbstractDict)
    code             = String(get(args, "code", ""))
    env_path         = get(args, "env_path", nothing)
    julia_cmd        = get(args, "julia_cmd", nothing)
    user_to          = get(args, "timeout", nothing)
    max_image_bytes  = Int(get(args, "max_image_bytes", 4_000_000))
    max_text_bytes   = Int(get(args, "max_text_bytes", 4_000))

    isempty(strip(code)) && return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => "error: empty code")],
        "isError" => true,
    )

    s = try
        get_or_create!(manager(), env_path; julia_cmd)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type" => "text",
                                "text" => "error starting session: $(sprint(showerror, e))")],
            "isError" => true,
        )
    end

    timeout = effective_timeout(code, user_to)

    res = try
        execute_show(s, code; timeout, max_image_bytes, max_text_bytes)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type" => "text", "text" => sprint(showerror, e))],
            "isError" => true,
        )
    end

    return res.status === :completed ?
        completed_response(res.blocks, res.is_error, res.elapsed_s) :
        running_response(env_path, res.partial, res.elapsed_s)
end

# ── Registration ────────────────────────────────────────────────────────────
const SHOW_DESCRIPTION = """
Evaluate Julia code and present its return value RICHLY to the user (image,
SVG, HTML, or formatted text) WITHOUT putting the bytes into your context.

Use this when you want the user to see something — a Makie plot, a DataFrame,
an HTML widget, an image — but don't need to read the content yourself. The
heavy bytes are tagged with `annotations.audience = ["user"]` per the MCP
spec, so MCP-aware clients route them to the chat UI without forwarding to
the model. You'll see only a short "shown: <type> as <mime> (<size>)"
acknowledgement.

Use bt_julia_eval (not bt_show) if you actually need to inspect the value
yourself.

The eval runs in the same per-`env_path` session as bt_julia_eval — bindings,
loaded packages, and Revise state carry over between calls.

MIME chain (richest match wins):
  • image/png         — Makie scenes, Plots.jl figures, Colorant matrices
  • image/svg+xml     — vector graphics
  • text/html         — HTML widgets, DataFrames with HTML show methods
  • text/plain        — fallback for anything else

Limits:
  • `max_image_bytes` (default 4 MB) caps PNG/SVG/HTML payloads. Above the
    limit we fall through to the next MIME (or eventually plain text).
  • `max_text_bytes`  (default 4 KB) is the text-fallback cap.
"""

register!(
    "bt_show", SHOW_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "code"             => Dict("type"=>"string", "description"=>"Julia code to evaluate; the LAST expression's value is what gets shown"),
            "env_path"         => Dict("type"=>"string", "description"=>"Optional Julia project directory; omit for a temp env"),
            "timeout"          => Dict("type"=>"number", "description"=>"Soft checkpoint cadence in seconds (same semantics as bt_julia_eval)"),
            "julia_cmd"        => Dict("type"=>"string", "description"=>"Custom Julia invocation, e.g. `julia +1.11`. Use rarely."),
            "max_image_bytes"  => Dict("type"=>"integer", "default"=>4_000_000, "description"=>"PNG/SVG/HTML payload cap"),
            "max_text_bytes"   => Dict("type"=>"integer", "default"=>4_000,     "description"=>"text-fallback truncation cap"),
        ),
        "required" => ["code"],
    ),
    julia_show_handler,
)
