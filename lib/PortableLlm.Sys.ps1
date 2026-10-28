# Portable-LLM Windows facilities.  ASCII only (Windows PowerShell 5.1 safe).  Dot-source; defines functions only.
# Everything here is in-process (P/Invoke + .NET); nothing launches a helper process.  Every function degrades to
# $null / $false on non-Windows hosts or when a call fails, so the dashboard shows "unknown" instead of crashing.

$script:PLlmIsWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$script:PLlmSysReady = $false

function Initialize-PLlmSys {
    if ($script:PLlmSysReady) { return $true }
    if (-not $script:PLlmIsWindows) { return $false }
    try {
        if (-not ('PLlmSys' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PLlmSys {
    [StructLayout(LayoutKind.Sequential)]
    public class MEMORYSTATUSEX {
        public uint dwLength; public uint dwMemoryLoad;
        public ulong ullTotalPhys; public ulong ullAvailPhys;
        public ulong ullTotalPageFile; public ulong ullAvailPageFile;
        public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
        public MEMORYSTATUSEX() { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); }
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);
    public static bool GetMemory(out ulong total, out ulong avail) {
        total = 0; avail = 0;
        MEMORYSTATUSEX m = new MEMORYSTATUSEX();
        if (!GlobalMemoryStatusEx(m)) return false;
        total = m.ullTotalPhys; avail = m.ullAvailPhys; return true;
    }

    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint mode);
    public static bool GetOutMode(out uint mode) {
        mode = 0; IntPtr h = GetStdHandle(-11);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
        return GetConsoleMode(h, out mode);
    }
    public static bool SetOutMode(uint mode) {
        IntPtr h = GetStdHandle(-11);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
        return SetConsoleMode(h, mode);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BASIC { public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)]
    struct IOC { public ulong a; public ulong b; public ulong c; public ulong d; public ulong e; public ulong f; }
    [StructLayout(LayoutKind.Sequential)]
    struct EXT { public BASIC Basic; public IOC Io; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr attrs, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    // Job whose processes are killed by Windows when the last handle to the job closes (including when this
    // PowerShell process dies for any reason).  Returns IntPtr.Zero on failure.
    public static IntPtr CreateKillOnCloseJob() {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return IntPtr.Zero;
        EXT ext = new EXT(); ext.Basic.LimitFlags = 0x2000;   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        int size = Marshal.SizeOf(typeof(EXT));
        IntPtr p = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(ext, p, false);
            if (!SetInformationJobObject(job, 9, p, (uint)size)) { CloseHandle(job); return IntPtr.Zero; }
        } finally { Marshal.FreeHGlobal(p); }
        return job;
    }
    public static bool AssignProcess(IntPtr job, IntPtr process) { return AssignProcessToJobObject(job, process); }
}
'@
        }
        $script:PLlmSysReady = $true
    } catch { $script:PLlmSysReady = $false }
    return $script:PLlmSysReady
}

function Get-PLlmMemoryInfo {
    # Physical RAM from GlobalMemoryStatusEx.  Returns $null when unavailable (never a made-up number).
    if (-not (Initialize-PLlmSys)) { return $null }
    try {
        $t = [uint64]0; $a = [uint64]0
        if (-not [PLlmSys]::GetMemory([ref]$t, [ref]$a) -or $t -eq 0) { return $null }
        $used = [double]($t - $a) * 100.0 / [double]$t
        return [pscustomobject]@{ TotalBytes = [double]$t; AvailBytes = [double]$a; UsedPct = $used }
    } catch { return $null }
}

function Get-PLlmProcessMemory {
    # Working set and private bytes of the server process (the model file is memory-mapped, so working set includes it).
    param($Process)
    if ($null -eq $Process) { return $null }
    try {
        $Process.Refresh()
        if ($Process.HasExited) { return $null }
        return [pscustomobject]@{ WorkingSet = [double]$Process.WorkingSet64; Private = [double]$Process.PrivateMemorySize64 }
    } catch { return $null }
}

function Enable-PLlmVt {
    # Turns on ANSI/VT processing for the console output.  Returns the original console mode (to restore later), or
    # $null when the stdout handle is not a console or VT cannot be enabled.
    if (-not (Initialize-PLlmSys)) { return $null }
    try {
        $mode = [uint32]0
        if (-not [PLlmSys]::GetOutMode([ref]$mode)) { return $null }
        if (($mode -band 4) -ne 0) { return [pscustomobject]@{ Original = $mode; Changed = $false } }
        if ([PLlmSys]::SetOutMode([uint32]($mode -bor 5))) { return [pscustomobject]@{ Original = $mode; Changed = $true } }
        return $null
    } catch { return $null }
}

function Restore-PLlmConsoleMode {
    param($Info)
    if ($null -eq $Info -or -not $Info.Changed) { return }
    try { [void][PLlmSys]::SetOutMode([uint32]$Info.Original) } catch { }
}

function New-PLlmProcessGuard {
    # Kill-on-close job object.  Result.Ok = $false means the guard is unavailable (reported in diagnostics).
    if (-not (Initialize-PLlmSys)) { return [pscustomobject]@{ Ok = $false; Handle = [IntPtr]::Zero; Reason = 'not available on this host' } }
    try {
        $h = [PLlmSys]::CreateKillOnCloseJob()
        if ($h -eq [IntPtr]::Zero) { return [pscustomobject]@{ Ok = $false; Handle = $h; Reason = 'could not create a job object' } }
        return [pscustomobject]@{ Ok = $true; Handle = $h; Reason = '' }
    } catch { return [pscustomobject]@{ Ok = $false; Handle = [IntPtr]::Zero; Reason = $_.Exception.Message } }
}

function Add-PLlmProcessToGuard {
    param($Guard, $Process)
    if ($null -eq $Guard -or -not $Guard.Ok) { return $false }
    try { return [bool][PLlmSys]::AssignProcess($Guard.Handle, $Process.Handle) } catch { return $false }
}

function Close-PLlmProcessGuard {
    # Closing the handle makes Windows kill anything still in the job.
    param($Guard)
    if ($null -eq $Guard -or -not $Guard.Ok) { return }
    try { [void][PLlmSys]::CloseHandle($Guard.Handle) } catch { }
}
