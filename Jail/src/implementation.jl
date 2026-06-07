# Cross-platform layer. Knows nothing OS-specific itself — it normalises the
# caller's inputs and hands them to the backend's `build_jail_cmd`. The only
# names it borrows from the backend (`default_backend`, `build_jail_cmd`) are
# resolved at call time, so this file can be included before the backend.

"""
    JailConfig(; kwargs...)

Configuration for a single [`jail`](@ref) call. Cross-platform fields apply
everywhere; the OS-specific fields are consumed only by their own backend and
ignored elsewhere. OS-specific *defaults* that need to probe the system (e.g. a
Sandboxie install path) are left empty here and resolved lazily inside the
backend, so constructing a `JailConfig` never touches another OS's tooling.

Cross-platform:
  * `backend`  — which sandbox tool to use (defaults to the OS's best available).
  * `gpu`      — expose the GPU device/driver stack (default `true`).
  * `network`  — allow network access (default `true`).

Linux:
  * `env`        — env vars forwarded into the sandbox (matters for landrun,
                   which clears the environment; bwrap inherits it).
  * `system_ro`  — host paths exposed read-only so the program + linker + GPU
                   userspace load.

Windows uses a native integrity-level sandbox (see `windows.jl`); it has no
extra config — the whitelist is granted by labelling dirs Low, writes are
denied by default, and reads are unrestricted.
"""
Base.@kwdef struct JailConfig
    backend::Symbol            = default_backend()
    gpu::Bool                  = true
    network::Bool              = true
    # Linux
    env::Vector{String}        = ["PATH", "HOME", "TERM", "LANG", "LC_ALL"]
    system_ro::Vector{String}  = ["/usr", "/bin", "/lib", "/lib64", "/sbin", "/etc"]
end

"""
    jail(cmd::Cmd; whitelist=[], readonly=[], kwargs...) -> Cmd

Return a sandboxed version of `cmd`. `whitelist` dirs are read-write, `readonly`
dirs are read-only, everything else is denied. Paths are made absolute and
`expanduser`'d. Extra `kwargs` are forwarded to [`JailConfig`](@ref) (e.g.
`gpu=false`, `network=false`, `backend=:landrun`).

The returned `Cmd` is composable with `run`, `success`, `pipeline`, etc.
"""
function jail(cmd::Cmd;
              whitelist::AbstractVector{<:AbstractString} = String[],
              readonly::AbstractVector{<:AbstractString}  = String[],
              kwargs...)
    cfg = JailConfig(; kwargs...)
    exe = collect(String, cmd.exec)
    wl  = String[abspath(expanduser(d)) for d in whitelist]
    ro  = String[abspath(expanduser(d)) for d in readonly]
    return build_jail_cmd(exe, wl, ro, cfg)
end
