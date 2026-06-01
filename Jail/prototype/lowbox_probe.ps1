# Prototype: launch a process at LOW integrity with redirected stdout, the way
# the planned native Windows backend will (CreateProcessAsUser + a Low-integrity
# restricted token + STARTF_USESTDHANDLES pipes). Validates, non-admin:
#   1. stdio capture works (no console-session dance, unlike Sandboxie)
#   2. a Low-integrity child CANNOT write a Medium dir (deny-by-default)
#   3. it CAN write a dir we've labelled Low (the "whitelist" mechanism)
# GPU is validated separately in stage 2.

$ErrorActionPreference = "Stop"

Add-Type -Language CSharp @"
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class LowBox {
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFO {
        public int cb; public string r1, r2, r3; public int x,y,xs,ys,xc,yc,fill,flags;
        public short showWindow, r4; public IntPtr r5; public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSD; public int bInherit; }
    [StructLayout(LayoutKind.Sequential)] struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_MANDATORY_LABEL { public SID_AND_ATTRIBUTES Label; }

    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr t, uint a, IntPtr sa, int il, int tt, out IntPtr nt);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool ConvertStringSidToSid(string s, out IntPtr sid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetTokenInformation(IntPtr t, int cls, ref TOKEN_MANDATORY_LABEL info, int len);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcessAsUser(
        IntPtr t, string app, string cmd, IntPtr pa, IntPtr ta, bool inh, uint flags, IntPtr env, string cwd,
        ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CreatePipe(out IntPtr r, out IntPtr w, ref SECURITY_ATTRIBUTES sa, uint sz);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);

    const uint TOKEN_ALL = 0xF01FF, MAXIMUM_ALLOWED = 0x02000000;
    const int  TokenIntegrityLevel = 25, SecurityImpersonation = 2, TokenPrimary = 1;
    const uint SE_GROUP_INTEGRITY = 0x20, CREATE_NO_WINDOW = 0x08000000, HANDLE_FLAG_INHERIT = 1, STARTF_USESTDHANDLES = 0x100;

    public static string Run(string cmdline, out uint exitCode) {
        IntPtr tok, dup, sid;
        if(!OpenProcessToken(GetCurrentProcess(), TOKEN_ALL, out tok)) throw new Exception("OpenProcessToken "+Marshal.GetLastWin32Error());
        if(!DuplicateTokenEx(tok, MAXIMUM_ALLOWED, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out dup)) throw new Exception("DuplicateTokenEx "+Marshal.GetLastWin32Error());
        if(!ConvertStringSidToSid("S-1-16-4096", out sid)) throw new Exception("ConvertStringSidToSid "+Marshal.GetLastWin32Error()); // Low
        var tml = new TOKEN_MANDATORY_LABEL();
        tml.Label.Sid = sid; tml.Label.Attributes = SE_GROUP_INTEGRITY;
        if(!SetTokenInformation(dup, TokenIntegrityLevel, ref tml, Marshal.SizeOf(tml)+8)) throw new Exception("SetTokenInformation "+Marshal.GetLastWin32Error());

        var sa = new SECURITY_ATTRIBUTES(); sa.nLength = Marshal.SizeOf(sa); sa.bInherit = 1;
        IntPtr rd, wr;
        if(!CreatePipe(out rd, out wr, ref sa, 0)) throw new Exception("CreatePipe "+Marshal.GetLastWin32Error());
        SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0); // parent read end not inherited

        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
        si.flags = (int)STARTF_USESTDHANDLES; si.hStdOutput = wr; si.hStdError = wr; si.hStdInput = IntPtr.Zero;
        PROCESS_INFORMATION pi;
        bool ok = CreateProcessAsUser(dup, null, cmdline, IntPtr.Zero, IntPtr.Zero, true, CREATE_NO_WINDOW, IntPtr.Zero, null, ref si, out pi);
        if(!ok) throw new Exception("CreateProcessAsUser "+Marshal.GetLastWin32Error());
        CloseHandle(wr); // parent closes write end so ReadToEnd terminates

        var sr = new StreamReader(new FileStream(new SafeFileHandle(rd, true), FileAccess.Read), Encoding.Default);
        string outp = sr.ReadToEnd();
        WaitForSingleObject(pi.hProcess, 30000);
        uint code; GetExitCodeProcess(pi.hProcess, out code); exitCode = code;
        CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
        return outp;
    }
}
"@

function Invoke-Low([string]$cmdline) {
    $code = 0
    $out = [LowBox]::Run($cmdline, [ref]$code)
    return [pscustomobject]@{ Out = $out.Trim(); Code = $code }
}

# --- Setup dirs: one Medium (default), one labelled Low -------------------------
$base = "C:\Users\Public\lowbox"; Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
$med = Join-Path $base "medium"; $low = Join-Path $base "low"
New-Item -ItemType Directory $med,$low -Force | Out-Null
icacls $low /setintegritylevel "(OI)(CI)L" | Out-Null   # label whitelist Low (writable by low-IL procs)

$medFile = Join-Path $med "evil.txt"; $lowFile = Join-Path $low "ok.txt"

Write-Host "=== 1. stdio capture (echo) ==="
$r = Invoke-Low 'cmd /c echo HELLO_FROM_LOW'
Write-Host ("   captured: '{0}'  (exit {1})  -> {2}" -f $r.Out, $r.Code, ($(if($r.Out -eq 'HELLO_FROM_LOW'){'PASS'}else{'FAIL'})))

Write-Host "=== 2. write to MEDIUM dir should be BLOCKED ==="
$r = Invoke-Low ('cmd /c echo x> "{0}"' -f $medFile)
$blocked = -not (Test-Path $medFile)
Write-Host ("   host file created? {0}  -> {1}" -f (Test-Path $medFile), ($(if($blocked){'PASS (blocked)'}else{'FAIL (leaked)'})))

Write-Host "=== 3. write to LOW-labelled dir should SUCCEED ==="
$r = Invoke-Low ('cmd /c echo x> "{0}"' -f $lowFile)
$ok = Test-Path $lowFile
Write-Host ("   host file created? {0}  -> {1}" -f $ok, ($(if($ok){'PASS (allowed)'}else{'FAIL (blocked)'})))

Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
