# Stage 2: does a LOW-integrity process still get GPU access?
# Builds a tiny D3D11 device-creation probe, runs it at Medium (baseline) and at
# Low integrity, and compares. D3D11 hardware device creation is the universal
# "can I talk to the GPU" check (vendor-agnostic).
$ErrorActionPreference = "Stop"

# --- low-integrity launcher (same mechanism as lowbox_probe.ps1) ----------------
Add-Type -Language CSharp @"
using System; using System.IO; using System.Text; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class LowBox {
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFO { public int cb; public string r1,r2,r3; public int x,y,xs,ys,xc,yc,fill,flags; public short sw,r4; public IntPtr r5; public IntPtr hi,ho,he; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hP,hT; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int n; public IntPtr sd; public int inh; }
    [StructLayout(LayoutKind.Sequential)] struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attr; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_MANDATORY_LABEL { public SID_AND_ATTRIBUTES Label; }
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr t, uint a, IntPtr sa, int il, int tt, out IntPtr nt);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool ConvertStringSidToSid(string s, out IntPtr sid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetTokenInformation(IntPtr t, int c, ref TOKEN_MANDATORY_LABEL i, int l);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr t, string app, string cmd, IntPtr pa, IntPtr ta, bool inh, uint f, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CreatePipe(out IntPtr r, out IntPtr w, ref SECURITY_ATTRIBUTES sa, uint sz);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr h, uint m, uint f);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint c);
    const uint TOKEN_ALL=0xF01FF, MAX=0x02000000, SEG=0x20, NOWIN=0x08000000, INH=1, USESTD=0x100;
    const int IL=25, IMP=2, PRIM=1;
    public static string Run(string cmd, out uint code) {
        IntPtr tok,dup,sid;
        OpenProcessToken(GetCurrentProcess(), TOKEN_ALL, out tok);
        DuplicateTokenEx(tok, MAX, IntPtr.Zero, IMP, PRIM, out dup);
        ConvertStringSidToSid("S-1-16-4096", out sid);
        var tml=new TOKEN_MANDATORY_LABEL(); tml.Label.Sid=sid; tml.Label.Attr=SEG;
        if(!SetTokenInformation(dup, IL, ref tml, Marshal.SizeOf(tml)+8)) throw new Exception("SetTokenInformation "+Marshal.GetLastWin32Error());
        var sa=new SECURITY_ATTRIBUTES(); sa.n=Marshal.SizeOf(sa); sa.inh=1;
        IntPtr rd,wr; CreatePipe(out rd, out wr, ref sa, 0); SetHandleInformation(rd, INH, 0);
        var si=new STARTUPINFO(); si.cb=Marshal.SizeOf(si); si.flags=(int)USESTD; si.ho=wr; si.he=wr;
        PROCESS_INFORMATION pi;
        if(!CreateProcessAsUser(dup, null, cmd, IntPtr.Zero, IntPtr.Zero, true, NOWIN, IntPtr.Zero, null, ref si, out pi)) throw new Exception("CreateProcessAsUser "+Marshal.GetLastWin32Error());
        CloseHandle(wr);
        var sr=new StreamReader(new FileStream(new SafeFileHandle(rd,true), FileAccess.Read), Encoding.Default);
        string o=sr.ReadToEnd(); WaitForSingleObject(pi.hP, 30000);
        uint c; GetExitCodeProcess(pi.hP, out c); code=c; CloseHandle(pi.hP); CloseHandle(pi.hT); return o;
    }
}
"@

# --- build a tiny D3D11 device-creation probe exe -------------------------------
$base = "C:\Users\Public\gpuprobe"; Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $base -Force | Out-Null
$exe = Join-Path $base "d3dprobe.exe"
$src = @"
using System; using System.Runtime.InteropServices;
class P {
  [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(IntPtr a, int dt, IntPtr sw, uint fl, IntPtr pfl, uint nfl, uint sdk, out IntPtr dev, out int lvl, out IntPtr ctx);
  static int Main(){
    IntPtr dev, ctx; int lvl;
    int hr = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0, IntPtr.Zero, 0, 7, out dev, out lvl, out ctx);
    if(hr==0){ Console.WriteLine("D3D11 OK featureLevel=0x"+lvl.ToString("X")); return 0; }
    Console.WriteLine("D3D11 FAIL hr=0x"+((uint)hr).ToString("X8")); return 1;
  }
}
"@
Add-Type -TypeDefinition $src -OutputAssembly $exe -OutputType ConsoleApplication

Write-Host "=== baseline: D3D11 at MEDIUM integrity ==="
$m = & $exe; Write-Host ("   {0}" -f ($m -join ' '))

Write-Host "=== D3D11 at LOW integrity (jailed) ==="
$code = 0; $o = [LowBox]::Run($exe, [ref]$code)
Write-Host ("   {0}  (exit {1})" -f $o.Trim(), $code)
Write-Host ("   -> {0}" -f ($(if($o -match 'OK'){'PASS  (GPU usable at Low integrity)'}else{'FAIL  (GPU blocked at Low integrity)'})))

Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
