# macOS backend: sandbox-exec with an inline SBPL profile.
#
# NOTE: sandbox-exec is deprecated by Apple (the underlying Seatbelt/App
# Sandbox is not), but it still ships and works on current macOS. This backend
# is implemented for API parity but is UNTESTED — it was authored on Windows.
# GPU access under the sandbox is best-effort (Metal needs IOKit user clients +
# WindowServer lookup, which vary by hardware).

default_backend() = :sandbox_exec

# Read-only system paths macOS needs so the binary + dyld + frameworks load.
const _MACOS_SYSTEM_RO = String[
    "/usr", "/bin", "/sbin", "/System", "/Library",
    "/private/var/db/dyld", "/private/var/db/timezone",
    "/dev", "/etc", "/opt", "/Applications",
]

# SBPL string literals are double-quoted; escape backslash and quote.
_sbpl_str(s::AbstractString) = '"' * replace(replace(s, "\\" => "\\\\"), "\"" => "\\\"") * '"'

_subpaths(key, dirs) = isempty(dirs) ? "" :
    "(allow $key\n" * join(("    (subpath $(_sbpl_str(d)))" for d in dirs), "\n") * ")\n"

function build_jail_cmd(exe::Vector{String}, whitelist::Vector{String},
                        readonly::Vector{String}, cfg::JailConfig)
    cfg.backend === :sandbox_exec ||
        error("Jail: unknown macOS backend $(cfg.backend) (use :sandbox_exec)")
    Sys.which("sandbox-exec") === nothing &&
        error("Jail: `sandbox-exec` not found on PATH.")

    profile = _build_sbpl(whitelist, readonly, cfg)
    return Cmd(String[ "sandbox-exec", "-p", profile, exe... ])
end

function _build_sbpl(whitelist, readonly, cfg::JailConfig)
    # System read paths: macOS defaults plus any caller-provided system_ro that
    # actually exists (filters out the cross-platform Linux defaults).
    sys_ro = unique(vcat(_MACOS_SYSTEM_RO, filter(ispath, cfg.system_ro)))

    io = IOBuffer()
    println(io, "(version 1)")
    println(io, "(deny default)")
    println(io, "(allow process-fork)")
    println(io, "(allow process-exec*)")
    println(io, "(allow sysctl-read)")
    println(io, "(allow mach-lookup)")
    println(io, "(allow file-read-metadata)")
    # Read system trees (binary, dyld, frameworks).
    print(io, _subpaths("file-read*", sys_ro))
    # Read-only extras.
    print(io, _subpaths("file-read*", readonly))
    # Whitelist: full read+write.
    print(io, _subpaths("file*", whitelist))
    # Scratch + the bit bucket.
    println(io, "(allow file* (subpath \"/private/tmp\") (subpath \"/private/var/folders\") (literal \"/dev/null\"))")
    if cfg.gpu
        # Best-effort GPU: IOKit user clients + WindowServer.
        println(io, "(allow iokit-open)")
        println(io, "(allow mach-lookup (global-name \"com.apple.windowserver.active\"))")
    end
    if cfg.network
        println(io, "(allow network*)")
    end
    return String(take!(io))
end
