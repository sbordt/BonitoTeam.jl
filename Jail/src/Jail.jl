"""
    Jail

Lightweight, cross-platform process sandboxing for Julia.

Wraps a command so it can only read/write an explicit set of folders, while
keeping GPU access intact. The public surface is a single cross-platform
function — [`jail`](@ref) — plus [`JailConfig`](@ref). All OS differences live
behind one backend file, selected at include time with `@static`:

  * Linux         -> bubblewrap (`bwrap`, default) or `landrun` (Landlock LSM)
  * Linux on WSL2 -> same, with the WSL GPU device (`/dev/dxg`) wired up
  * macOS         -> `sandbox-exec` (SBPL profile)   [implemented, untested]
  * Windows       -> Sandboxie-Plus (`Start.exe`)

Every backend implements the same contract so the high-level code stays
single-implementation:

    build_jail_cmd(exe::Vector{String}, whitelist::Vector{String},
                   readonly::Vector{String}, cfg::JailConfig) -> Cmd
    default_backend() -> Symbol

`build_jail_cmd` receives already-normalised (absolute, expanduser'd) paths from
[`jail`](@ref); it owns its entire command construction and returns a runnable,
composable `Cmd`:

    run(jail(`python train.py`; whitelist=["."]))
    success(jail(`julia --project=. run.jl`; whitelist=[".", "~/.julia"]))

`whitelist` folders get read+write host access; `readonly` folders are readable;
system/runtime paths stay readable so the program and GPU driver stack load;
everything else is denied.
"""
module Jail

export jail, JailConfig

# Cross-platform layer first: defines JailConfig + jail(). Its only dependency
# on the backend is at *call* time (default_backend / build_jail_cmd), so it can
# be parsed before the backend is included.
include("implementation.jl")

# Exactly one backend is compiled in. Each defines build_jail_cmd +
# default_backend, and may add its own exports (e.g. Windows install helpers).
@static if Sys.islinux()
    include("linux.jl")
elseif Sys.isapple()
    include("osx.jl")
elseif Sys.iswindows()
    include("windows.jl")
else
    error("Jail: unsupported OS $(Sys.KERNEL)")
end

end # module Jail
