# Standalone, dependency-free launcher for Jail's Windows backend.
#
# Invoked as:  julia --startup-file=no _lowbox_launcher.jl <grant dir>... -- <exe> <args>...
#
# It runs <exe args> at LOW integrity (S-1-16-4096) as the same user, passing
# THIS process's std handles straight to the child — so when the caller does
# `run`/`open`/`pipeline` on the outer julia, Base's pipes flow transparently to
# the jailed child. Each <grant dir> is labelled Low so the low-integrity child
# can write it (the whitelist); everything else stays writable only by Medium+,
# i.e. deny-by-default for writes. This loads no packages so it starts in a bare
# julia. Mechanism validated in Jail/prototype/lowbox_probe.ps1.

const HANDLE = Ptr{Cvoid}

# Win32 structs (x64 layout).
struct SID_AND_ATTRIBUTES
    Sid::Ptr{Cvoid}
    Attributes::UInt32
end

struct STARTUPINFOW
    cb::UInt32
    lpReserved::Ptr{UInt16}
    lpDesktop::Ptr{UInt16}
    lpTitle::Ptr{UInt16}
    dwX::UInt32; dwY::UInt32; dwXSize::UInt32; dwYSize::UInt32
    dwXCountChars::UInt32; dwYCountChars::UInt32; dwFillAttribute::UInt32
    dwFlags::UInt32
    wShowWindow::UInt16; cbReserved2::UInt16
    lpReserved2::Ptr{UInt8}
    hStdInput::HANDLE; hStdOutput::HANDLE; hStdError::HANDLE
end

struct PROCESS_INFORMATION
    hProcess::HANDLE
    hThread::HANDLE
    dwProcessId::UInt32
    dwThreadId::UInt32
end

const TOKEN_ALL_ACCESS    = UInt32(0xF01FF)
const MAXIMUM_ALLOWED     = UInt32(0x02000000)
const SecurityImpersonation = Cint(2)
const TokenPrimary        = Cint(1)
const TokenIntegrityLevel = Cint(25)
const SE_GROUP_INTEGRITY  = UInt32(0x20)
const STARTF_USESTDHANDLES = UInt32(0x100)
const CREATE_NO_WINDOW    = UInt32(0x08000000)
const INFINITE            = UInt32(0xFFFFFFFF)

_lasterr() = ccall((:GetLastError, "kernel32"), UInt32, ())
_fail(msg) = error("lowbox: $msg failed (GetLastError=$(_lasterr()))")

# Windows command-line quoting (CommandLineToArgvW rules).
function _winquote(arg::AbstractString)
    isempty(arg) && return "\"\""
    occursin(r"[\s\"]", arg) || return String(arg)
    io = IOBuffer(); print(io, '"'); bs = 0
    for c in arg
        if c == '\\'
            bs += 1
        elseif c == '"'
            print(io, '\\'^(2bs + 1), '"'); bs = 0
        else
            print(io, '\\'^bs, c); bs = 0
        end
    end
    print(io, '\\'^(2bs), '"')
    return String(take!(io))
end

function lowbox_run(argv::Vector{String})::Int
    # 1. duplicate our own token into a primary token
    proc = ccall((:GetCurrentProcess, "kernel32"), HANDLE, ())
    tok = Ref{HANDLE}(C_NULL)
    ccall((:OpenProcessToken, "advapi32"), Cint, (HANDLE, UInt32, Ptr{HANDLE}),
          proc, TOKEN_ALL_ACCESS, tok) == 0 && _fail("OpenProcessToken")
    dup = Ref{HANDLE}(C_NULL)
    ccall((:DuplicateTokenEx, "advapi32"), Cint,
          (HANDLE, UInt32, Ptr{Cvoid}, Cint, Cint, Ptr{HANDLE}),
          tok[], MAXIMUM_ALLOWED, C_NULL, SecurityImpersonation, TokenPrimary, dup) == 0 &&
        _fail("DuplicateTokenEx")

    # 2. lower the duplicate to Low integrity
    psid = Ref{Ptr{Cvoid}}(C_NULL)
    ccall((:ConvertStringSidToSidW, "advapi32"), Cint, (Cwstring, Ptr{Ptr{Cvoid}}),
          "S-1-16-4096", psid) == 0 && _fail("ConvertStringSidToSid")
    label = Ref(SID_AND_ATTRIBUTES(psid[], SE_GROUP_INTEGRITY))
    ccall((:SetTokenInformation, "advapi32"), Cint,
          (HANDLE, Cint, Ptr{Cvoid}, UInt32),
          dup[], TokenIntegrityLevel, label, UInt32(sizeof(SID_AND_ATTRIBUTES))) == 0 &&
        _fail("SetTokenInformation")

    # 3. launch the child with OUR std handles (so Base's pipes pass through)
    GetStdHandle(n) = ccall((:GetStdHandle, "kernel32"), HANDLE, (UInt32,), n % UInt32)
    si = Ref(STARTUPINFOW(
        UInt32(sizeof(STARTUPINFOW)), C_NULL, C_NULL, C_NULL,
        0,0,0,0, 0,0,0,
        STARTF_USESTDHANDLES, 0, 0, C_NULL,
        GetStdHandle(-10), GetStdHandle(-11), GetStdHandle(-12)))
    pinfo = Ref(PROCESS_INFORMATION(C_NULL, C_NULL, 0, 0))

    cmdline = join((_winquote(a) for a in argv), ' ')
    wbuf = transcode(UInt16, cmdline); push!(wbuf, UInt16(0))
    code = GC.@preserve wbuf begin
        ok = ccall((:CreateProcessAsUserW, "advapi32"), Cint,
            (HANDLE, Ptr{UInt16}, Ptr{UInt16}, Ptr{Cvoid}, Ptr{Cvoid}, Cint,
             UInt32, Ptr{Cvoid}, Ptr{UInt16}, Ptr{STARTUPINFOW}, Ptr{PROCESS_INFORMATION}),
            dup[], C_NULL, pointer(wbuf), C_NULL, C_NULL, Cint(1),
            CREATE_NO_WINDOW, C_NULL, C_NULL, si, pinfo)
        ok == 0 && _fail("CreateProcessAsUser")
        ccall((:WaitForSingleObject, "kernel32"), UInt32, (HANDLE, UInt32),
              pinfo[].hProcess, INFINITE)
        ec = Ref{UInt32}(0)
        ccall((:GetExitCodeProcess, "kernel32"), Cint, (HANDLE, Ptr{UInt32}),
              pinfo[].hProcess, ec)
        Int(ec[])
    end
    ccall((:CloseHandle, "kernel32"), Cint, (HANDLE,), pinfo[].hThread)
    ccall((:CloseHandle, "kernel32"), Cint, (HANDLE,), pinfo[].hProcess)
    return code
end

function main()
    args = copy(ARGS)
    sep = findfirst(==("--"), args)
    sep === nothing && error("lowbox: missing `--` separator")
    grants = args[1:sep-1]
    cmd    = args[sep+1:end]
    isempty(cmd) && error("lowbox: no command after `--`")

    # Label each whitelist dir Low so the low-integrity child can write it.
    # If labelling fails we MUST abort (R2): otherwise the child launches into a
    # silently mislabeled sandbox where the whitelist isn't actually writable,
    # and the failure surfaces much later as an opaque permission error deep in
    # the user's program instead of here at the boundary.
    for d in grants
        try
            run(pipeline(`icacls $d /setintegritylevel "(OI)(CI)L"`;
                         stdout = devnull, stderr = devnull))
        catch e
            error("lowbox: failed to label $d as Low integrity (the sandbox " *
                  "whitelist would not be writable); aborting launch: $e")
        end
    end

    exit(lowbox_run(cmd))
end

main()
