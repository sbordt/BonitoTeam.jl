# Loaded into every Malt-managed Julia subprocess on startup. Provides two
# pure formatting functions called from the wrapper expression in
# session.jl::execute. Returns Vector{Dict{String,Any}} of MCP content
# blocks — base types only, so Malt's serialiser never sees user-defined
# types it can't reconstruct on the parent side.

module BonitoMCPHelper

using Base64

const DEFAULT_MAX_RESPONSE_BYTES = 10_000
const LARGE_CONTAINER_THRESHOLD  = 100      # array / dict elements

# Stack frames we strip from error backtraces so the user-visible trace ends
# at the actual call site (not REPL / include_string / Malt internals).
const BACKTRACE_NOISE_FRAMES = (
    r"\bBase\.eval\b", r"\binclude_string\b", r"\beval_user_input\b",
    r"\bclient\.jl\b", r"\brun_main_repl\b", r"\brun_fallback_repl\b",
    r"\brepl_main\b",  r"\b_start\b",
    r"\bMalt\b",                            # Malt's own remote_eval frames
)

# ── Public entries ──────────────────────────────────────────────────────────
"""
    format_value(val, max_bytes, full_output) → Vector{Dict{String,Any}}

Turn a Julia value into MCP content blocks. `nothing` returns are suppressed.
2-D color arrays render to PNG when PNGFiles is loaded in the env. Large
containers are summarised. Always-text blocks use the `result:\\n<body>` shape
so the chat-side renderer picks them up as labeled Monaco sections.
"""
function format_value(val, max_bytes::Int, full_output::Bool)
    val === nothing && return Dict{String,Any}[]   # suppress nothing-result

    # Image-detection: 2-D array of colorants → render as PNG (size-capped).
    if !full_output && looks_like_image(val)
        try
            png = value_to_png(val)
            if length(png) <= 4 * max_bytes
                return [Dict{String,Any}(
                    "type" => "image",
                    "data" => base64encode(png),
                    "mimeType" => "image/png",
                )]
            end
        catch
            # fall through to text repr
        end
    end

    repr = !full_output && is_large_container(val) ?
        summarize_container(val) : sprint(show, "text/plain", val)
    return [Dict{String,Any}(
        "type" => "text",
        "text" => "result:\n$(truncate_text(repr, max_bytes, full_output, "result"))",
    )]
end

"""
    format_error(err, bt, max_bytes, full_output) → Vector{Dict{String,Any}}

Render an exception + trimmed backtrace as a single error block.
"""
function format_error(err, bt, max_bytes::Int, full_output::Bool)
    text = sprint() do io
        showerror(io, err)
        println(io)
        Base.show_backtrace(io, bt)
    end
    text = trim_backtrace(text)
    return [Dict{String,Any}(
        "type" => "text",
        "text" => "error:\n$(truncate_text(text, max_bytes, full_output, "error"))",
    )]
end

# ── Output discipline ──────────────────────────────────────────────────────
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

function looks_like_image(value)
    value isa AbstractArray || return false
    ndims(value) == 2       || return false
    name = string(eltype(value))
    return occursin("RGB", name) || occursin("RGBA", name) ||
           occursin("Gray", name) || occursin("Colorant", name)
end

# Best-effort: only renders if the user has PNGFiles loaded in the env.
function value_to_png(value)
    if Base.isbindingresolved(Main, :PNGFiles) && isdefined(Main, :PNGFiles)
        io = IOBuffer()
        Base.invokelatest(Main.PNGFiles.save, io, value)
        return take!(io)
    end
    error("PNG encoding requires PNGFiles in the env")
end

end # module BonitoMCPHelper
