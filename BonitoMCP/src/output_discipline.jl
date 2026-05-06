# Output-discipline rules enforced server-side rather than via prompt instructions.
# See CONVENTIONS.md ("Tools (MCP julia_eval) hygiene") for the user-facing contract.

const DEFAULT_MAX_RESPONSE_BYTES = 10_000
const LARGE_CONTAINER_THRESHOLD = 100   # elements

# Format a Julia value for MCP text output, with size + container heuristics.
# Returns a vector of MCP content blocks.
function format_for_mcp(value;
                       full_output::Bool = false,
                       max_response_bytes::Int = DEFAULT_MAX_RESPONSE_BYTES,
                       stdout_text::AbstractString = "")
    blocks = Vector{Dict{String,Any}}()

    # 1. stdout (if any)
    if !isempty(stdout_text)
        push!(blocks, _text_block(stdout_text, "stdout"; full_output, max_response_bytes))
    end

    # 2. Image-detection: if value is a Matrix of colorant-like elements, render as image
    if !full_output && _looks_like_image(value)
        try
            png_bytes = _value_to_png(value)
            if length(png_bytes) <= 4 * max_response_bytes  # cap image size too
                push!(blocks, Dict(
                    "type" => "image",
                    "data" => _base64encode(png_bytes),
                    "mimeType" => "image/png",
                ))
                return blocks
            end
        catch
            # fall through to text repr
        end
    end

    # 3. `nothing` return is the common case for statements with side effects
    # (println, push!, etc.). Skip emitting "result:\nnothing" — it's noise
    # that the chat doesn't benefit from and that costs claude tokens.
    if value === nothing
        return blocks
    end

    # 4. Large container: summarize instead of dumping
    if !full_output && _is_large_container(value)
        repr = _summarize_container(value)
    else
        repr = sprint(show, "text/plain", value)
    end
    push!(blocks, _text_block(repr, "result"; full_output, max_response_bytes))

    return blocks
end

function _text_block(text::AbstractString, label::AbstractString;
                     full_output::Bool, max_response_bytes::Int)
    n = length(text)
    if !full_output && n > max_response_bytes
        keep = max_response_bytes
        text = SubString(text, 1, prevind(text, keep + 1)) *
               "\n[truncated: $label was $n bytes; kept first $keep. " *
               "call with full_output=true to see all]"
    end
    return Dict("type" => "text", "text" => "$label:\n$text")
end

# Heuristic: a 2-D array of color-like elements is probably an image we should render.
function _looks_like_image(value)
    value isa AbstractArray || return false
    ndims(value) == 2 || return false
    elt = eltype(value)
    return _is_colorant_type(elt)
end

function _is_colorant_type(T)
    name = string(T)
    return occursin("RGB", name) || occursin("RGBA", name) || occursin("Gray", name) ||
           occursin("Colorant", name)
end

function _value_to_png(value)
    # Lazy: only used when ColorTypes/FileIO/PNGFiles available. For the v1 stub,
    # fall back to errpr; the tool wrapper catches and uses text repr instead.
    error("PNG encoding not implemented in v1 stub; install FileIO+PNGFiles to enable")
end

_base64encode(bytes::AbstractVector{UInt8}) = Base64.base64encode(bytes)

function _is_large_container(value)
    if value isa AbstractArray
        return length(value) > LARGE_CONTAINER_THRESHOLD
    elseif value isa AbstractDict
        return length(value) > LARGE_CONTAINER_THRESHOLD
    end
    return false
end

function _summarize_container(value)
    sz = value isa AbstractArray ? length(value) :
         value isa AbstractDict  ? length(value) : 0
    head_n = min(10, sz)
    head = if value isa AbstractArray
        first(value, head_n)
    else
        Dict(k => v for (k, v) in Iterators.take(value, head_n))
    end
    return string(typeof(value), " with $(sz) elements; first $(head_n):\n",
                  sprint(show, "text/plain", head))
end

# Bring base64 in scope without a hard dep on Base64 stdlib import at top level
import Base64
