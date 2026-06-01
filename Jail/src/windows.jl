# Windows backend: native restricted-token / integrity-level sandbox.
#
# Sandboxie was abandoned here — it's a GUI/desktop-app sandbox whose Start.exe
# can't relay a boxed *console* process's stdin/stdout to pipes, which is exactly
# what an agent (ACP over stdio) needs. Instead we use Windows' own mechanism,
# the same one Chromium uses: launch the child with a token dropped to LOW
# integrity. That gives, natively and non-admin:
#   * working piped stdio (plain CreateProcessAsUser, no console session)
#   * GPU access (Low integrity is enough — Chromium's GPU process runs there)
#   * deny-by-default *writes* (a Low process can't write Medium+ objects)
# The whitelist is granted by labelling those dirs Low (the launcher does this).
#
# Julia's own `run` uses a Medium-integrity CreateProcess, so we can't drop
# integrity by returning a bare Cmd. Like Linux's `bwrap`, we need a launcher
# binary — here that binary is *julia itself*, re-invoked on a tiny standalone
# script (`_lowbox_launcher.jl`) that performs the token drop. This keeps the
# cross-platform contract (`jail(cmd) -> Cmd`) and full Base composability.
#
# Reads are NOT restricted in this model (Low integrity can read up): the
# guarantee is write-isolation, matching the worker-only-write usage. `readonly`
# grants are therefore a no-op on Windows.

default_backend() = :integrity

const _LAUNCHER = joinpath(@__DIR__, "_lowbox_launcher.jl")

_julia_exe() = joinpath(Sys.BINDIR::String, Base.julia_exename())

function build_jail_cmd(exe::Vector{String}, whitelist::Vector{String},
                        readonly::Vector{String}, cfg::JailConfig)
    cfg.backend === :integrity ||
        error("Jail: unknown Windows backend $(cfg.backend) (use :integrity)")
    isempty(readonly) ||
        @warn "Jail(Windows): `readonly` is ignored — the integrity model restricts writes, not reads."

    # julia --startup-file=no --compile=min <launcher> <grant>... -- <exe>...
    a = String[_julia_exe(), "--startup-file=no", "--compile=min", _LAUNCHER]
    append!(a, whitelist)   # dirs to label Low (writable by the jailed child)
    push!(a, "--")
    append!(a, exe)
    return Cmd(a)
end
