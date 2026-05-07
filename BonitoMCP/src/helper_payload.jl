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
    format_show(val, out_dir, max_bytes) → Vector{Dict{String,Any}}

`bt_show` formatter. Writes the value to a file under `out_dir` (typically
`<cwd>/.bonitoTeam/show/`) and returns ONLY a small text reference. The
file's bytes never enter the MCP tool result, so claude-agent-acp can't
forward them to the model — the agent only sees a path + size + mime.

The chat-side renderer parses the reference, fetches the file from the
worker if needed, and shows a collapsible preview (image / video / html /
text) inline in the chat.

MIME chain (richest match wins, all rasterised to file extensions
claude.ai's Messages API doesn't even need to handle since the bytes
never reach it):
  • image/png         — Makie/Plots figures, Colorant matrices via
                        `showable` or PNGFiles
  • image/svg+xml     — vector graphics (saved as `.svg`)
  • text/html         — HTML widgets (`.html`)
  • text/plain        — fallback
"""
function format_show(val, out_dir::AbstractString, max_bytes::Int)
    val === nothing && return [text_block("shown: nothing")]

    mkpath(out_dir)
    base = string(time_ns(), base = 16) * "-" * string(rand(UInt32), base = 16)

    # Image PNG via showable hook (preferred for plots + Makie scenes).
    if showable_safe(MIME"image/png"(), val)
        png = sprint_mime(val, MIME"image/png"())
        if !isempty(png) && length(png) <= max_bytes
            return write_show_file(out_dir, base, ".png", "image/png", png, val)
        end
    end

    # Direct PNG render for 2-D colorant arrays (when PNGFiles is available).
    if looks_like_image(val)
        try
            png = value_to_png(val)
            if length(png) <= max_bytes
                return write_show_file(out_dir, base, ".png", "image/png", png, val)
            end
        catch
        end
    end

    # SVG (vector graphics — fine here because the bytes go to a file, not
    # to claude). Browsers render image/svg+xml in <img> tags.
    if showable_safe(MIME"image/svg+xml"(), val)
        svg = sprint_mime(val, MIME"image/svg+xml"())
        if !isempty(svg) && length(svg) <= max_bytes
            return write_show_file(out_dir, base, ".svg", "image/svg+xml", svg, val)
        end
    end

    # HTML widgets / DataFrames. Same thing — chat will iframe-render.
    if showable_safe(MIME"text/html"(), val)
        html = sprint_mime(val, MIME"text/html"())
        if !isempty(html) && length(html) <= max_bytes
            return write_show_file(out_dir, base, ".html", "text/html", html, val)
        end
    end

    # Plain text fallback — write to file too so the chat can render it
    # in Monaco like other tool outputs.
    repr = sprint(show, "text/plain", val)
    bytes = codeunits(repr)
    return write_show_file(out_dir, base, ".txt", "text/plain", bytes, val)
end

# Write the rendered bytes to disk and produce the reference content block.
function write_show_file(out_dir::AbstractString, base::AbstractString,
                          ext::AbstractString, mime::AbstractString,
                          bytes, val)
    fname = base * ext
    path  = joinpath(out_dir, fname)
    open(io -> write(io, bytes), path, "w")
    # Relative path so the chat side can resolve under either cwd. Path is
    # stable across server restarts because it lives on disk.
    relpath_str = joinpath(".bonitoTeam", "show", fname)
    text = string("shown: ", relpath_str,
                  " (", mime, ", ", format_bytes_short(length(bytes)), ")",
                  "\ntype: ", typeof_short(val))
    return [text_block(text)]
end

text_block(text::AbstractString) = Dict{String,Any}(
    "type" => "text",
    "text" => text,
)

typeof_short(val) = string(typeof(val).name.name)

# `showable` can throw for some types (e.g. Makie pre-display lifecycle bugs);
# we don't want a failed probe to abort the whole render path, just to fall
# through to the next MIME.
function showable_safe(mime::MIME, val)
    try
        return showable(mime, val)
    catch
        return false
    end
end

function sprint_mime(val, mime::MIME)
    try
        # Some types' MIME shows write binary, others write text — reading
        # back as Vector{UInt8} via take! handles both, and base64encode +
        # codeunits work on either path uniformly.
        io = IOBuffer()
        show(io, mime, val)
        return take!(io)
    catch
        return UInt8[]
    end
end

function format_bytes_short(n::Integer)
    n < 1024     && return "$(n)B"
    n < 1024^2   && return string(round(n / 1024; digits=1), "KB")
    n < 1024^3   && return string(round(n / 1024^2; digits=1), "MB")
                    return string(round(n / 1024^3; digits=2), "GB")
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
