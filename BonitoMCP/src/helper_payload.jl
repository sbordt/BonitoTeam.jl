# Helper payload — `include`d into every BonitoMCP Julia subprocess on startup.
# Provides BonitoMCPHelper.eval_and_emit, which runs user code, captures
# stdout/stderr/return value, applies output discipline (truncation, container
# summarisation, image detection, backtrace trim, suppress `nothing`), and
# writes the resulting structured-block stream back to stdout where the
# parent BonitoMCP process can parse it.
#
# Wire format (one line per block, between BEGIN/END markers):
#
#   __MCP_BLOCKS_BEGIN__
#   <kind>:<base64-of-utf8-text>
#   ...
#   __MCP_BLOCKS_END__
#
# `kind` is one of: code, stdout, stderr, result, error, image.
# Image blocks emit a third field for the mime type:
#   image:<base64-of-bytes>:<mime>

module BonitoMCPHelper

using Base64

const BLOCKS_BEGIN = "__MCP_BLOCKS_BEGIN__"
const BLOCKS_END   = "__MCP_BLOCKS_END__"

const DEFAULT_MAX_RESPONSE_BYTES = 10_000
const LARGE_CONTAINER_THRESHOLD  = 100      # array / dict elements

# Stack frames we strip from error backtraces — REPL / include_string / our
# own eval plumbing — so the user-visible trace is the actual call site.
const BACKTRACE_NOISE_FRAMES = (
    r"\bBase\.eval\b", r"\binclude_string\b", r"\beval_user_input\b",
    r"\bclient\.jl\b", r"\brun_main_repl\b", r"\brun_fallback_repl\b",
    r"\brepl_main\b",  r"\b_start\b",
    r"\beval_and_emit\b",                   # our own frame
)

# ── Public entry ─────────────────────────────────────────────────────────────
"""
    eval_and_emit(code; max_bytes, full_output)

Evaluate `code` in `Main`, capture all output, and write a sentinel-bracketed
structured-block stream to the (real, pre-redirect) stdout. Returns `nothing`.
"""
function eval_and_emit(code::AbstractString;
                       max_bytes::Int   = DEFAULT_MAX_RESPONSE_BYTES,
                       full_output::Bool = false)
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
    real_stdout = stdout
    real_stderr = stderr

    val      = nothing
    err_text = nothing

    reader = @async read(pipe, String)
    redirect_stdout(pipe.in)
    redirect_stderr(pipe.in)
    try
        val = include_string(Main, code, "mcp_eval")
    catch e
        err_text = sprint() do io
            showerror(io, e)
            println(io)
            Base.show_backtrace(io, catch_backtrace())
        end
        err_text = trim_backtrace(err_text)
    finally
        redirect_stdout(real_stdout)
        redirect_stderr(real_stderr)
        close(pipe.in)
    end
    captured = fetch(reader)

    println(real_stdout, BLOCKS_BEGIN)
    emit_text(real_stdout, "code", "```julia\n$(rstrip(code, '\n'))\n```")
    if !isempty(captured)
        emit_text(real_stdout, "stdout",
                   "stdout:\n$(truncate_text(captured, max_bytes, full_output, "stdout"))")
    end
    if err_text !== nothing
        emit_text(real_stdout, "error",
                   "error:\n$(truncate_text(err_text, max_bytes, full_output, "error"))")
    elseif val !== nothing
        emit_value(real_stdout, val, max_bytes, full_output)
    end
    println(real_stdout, BLOCKS_END)
    flush(real_stdout)
    return nothing
end

# ── Block emitters ───────────────────────────────────────────────────────────
emit_text(io, kind, text::AbstractString) =
    println(io, kind, ":", base64encode(text))

emit_image(io, bytes::AbstractVector{UInt8}, mime::AbstractString) =
    println(io, "image:", base64encode(bytes), ":", mime)

# Result branch: image vs container vs plain repr
function emit_value(io, val, max_bytes::Int, full_output::Bool)
    # Image-detection: 2-D array of colorants → try to render as PNG
    if !full_output && looks_like_image(val)
        try
            png = value_to_png(val)
            if length(png) <= 4 * max_bytes
                emit_image(io, png, "image/png")
                return
            end
        catch
            # fall through to text
        end
    end
    repr = !full_output && is_large_container(val) ?
        summarize_container(val) : sprint(show, "text/plain", val)
    emit_text(io, "result", "result:\n$(truncate_text(repr, max_bytes, full_output, "result"))")
end

# ── Truncation ──────────────────────────────────────────────────────────────
function truncate_text(text::AbstractString, max_bytes::Int, full_output::Bool,
                       label::AbstractString)
    full_output && return text
    n = length(text)
    n <= max_bytes && return text
    keep = max_bytes
    cut  = SubString(text, 1, prevind(text, keep + 1))
    return cut * "\n[truncated: $label was $n bytes; kept first $keep. " *
                  "call with full_output=true to see all]"
end

# ── Backtrace cleanup ───────────────────────────────────────────────────────
function trim_backtrace(text::AbstractString)
    lines = split(text, '\n')
    cut = something(findfirst(line -> any(p -> occursin(p, line), BACKTRACE_NOISE_FRAMES),
                              lines), length(lines) + 1)
    cut > length(lines) && return strip(text)
    kept       = lines[1:cut-1]
    suppressed = length(lines) - length(kept)
    suppressed > 1 && push!(kept, "  [+ $suppressed internal frames]")
    return strip(join(kept, "\n"))
end

# ── Large-container summary ─────────────────────────────────────────────────
function is_large_container(value)
    value isa AbstractArray && return length(value) > LARGE_CONTAINER_THRESHOLD
    value isa AbstractDict  && return length(value) > LARGE_CONTAINER_THRESHOLD
    return false
end

function summarize_container(value)
    sz     = value isa AbstractArray ? length(value) :
             value isa AbstractDict  ? length(value) : 0
    head_n = min(10, sz)
    head = value isa AbstractArray ? first(value, head_n) :
           Dict(k => v for (k, v) in Iterators.take(value, head_n))
    return string(typeof(value), " with $sz elements; first $head_n:\n",
                  sprint(show, "text/plain", head))
end

# ── Image detection ─────────────────────────────────────────────────────────
function looks_like_image(value)
    value isa AbstractArray || return false
    ndims(value) == 2       || return false
    name = string(eltype(value))
    return occursin("RGB", name) || occursin("RGBA", name) ||
           occursin("Gray", name) || occursin("Colorant", name)
end

# Stub: real PNG encoding requires FileIO+PNGFiles or similar in the user's
# env. The wrapping `try` in emit_value falls through to text repr when this
# raises, so absence of those packages just disables image rendering.
function value_to_png(value)
    if Base.isbindingresolved(Main, :PNGFiles) && isdefined(Main, :PNGFiles)
        io = IOBuffer()
        Base.invokelatest(Main.PNGFiles.save, io, value)
        return take!(io)
    end
    error("PNG encoding requires PNGFiles in the env; falling back to text repr")
end

end # module BonitoMCPHelper
