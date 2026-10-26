# Portable-LLM host CPU probe.  ASCII only (Windows PowerShell 5.1 safe).
#
# Prints ONE JSON document to stdout.  It reports two independent kinds of evidence:
#   1. pf     : Windows IsProcessorFeaturePresent() results (OS-enabled support).  These say nothing about
#               how any executable was compiled.
#   2. scorer : the result of calling ggml_backend_score() exported by each bundled ggml-cpu-<variant>.dll.
#               This is the same function llama.cpp itself uses to choose a CPU kernel set:
#               score 0 = this host cannot run that variant, highest non-zero score = the variant llama.cpp loads.
#
# The launcher runs this script in a SEPARATE short-lived PowerShell process, so if loading a variant DLL
# were ever to crash, only this probe dies and the launcher reports "probe failed" instead of hanging.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File cpu-detect.ps1 -LlamaDir .\llama -Json
param(
    [string]$LlamaDir = '',
    [switch]$Json,
    [switch]$NoScorer
)

$ErrorActionPreference = 'Stop'

if (-not ('PLlmNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PLlmNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool IsProcessorFeaturePresent(uint feature);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectoryW(string path);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(string file, IntPtr hFile, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int ScoreFn();
    public static int CallScore(IntPtr fn) {
        ScoreFn d = (ScoreFn)Marshal.GetDelegateForFunctionPointer(fn, typeof(ScoreFn));
        return d();
    }
}
'@
}

function Get-PfFeature {
    param([int]$Id, [bool]$Trusted)
    # Feature ids 36-41 are only defined on Windows 10+; older Windows returns FALSE for unknown ids,
    # which would look like "CPU lacks AVX2".  On such systems report unknown ($null) instead of false.
    if (-not $Trusted) { return $null }
    try { return [bool][PLlmNative]::IsProcessorFeaturePresent([uint32]$Id) } catch { return $null }
}

$osVer = [Environment]::OSVersion.Version
$pfTrusted = ($osVer.Major -ge 10)

$cpuName = $null; $cores = $null; $logical = $null
try {
    $p = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $cpuName = $p.Name; $cores = $p.NumberOfCores; $logical = $p.NumberOfLogicalProcessors
} catch { }
if ([string]::IsNullOrWhiteSpace($cpuName)) { $cpuName = $env:PROCESSOR_IDENTIFIER }
if ($cpuName) { $cpuName = ($cpuName -replace '\s+', ' ').Trim() }

$result = [ordered]@{
    cpu_name        = $cpuName
    cores           = $cores
    logical_cpus    = $logical
    os_version      = $osVer.ToString()
    process_bits    = $(if ([IntPtr]::Size -eq 8) { 64 } else { 32 })
    pf_trusted      = $pfTrusted
    pf              = [ordered]@{
        SSE3   = Get-PfFeature 13 $pfTrusted
        SSE42  = Get-PfFeature 38 $pfTrusted
        AVX    = Get-PfFeature 39 $pfTrusted
        AVX2   = Get-PfFeature 40 $pfTrusted
        AVX512 = Get-PfFeature 41 $pfTrusted
    }
    scorer          = [ordered]@{ attempted = $false; available = $false; reason = ''; scores = [ordered]@{}; errors = [ordered]@{} }
}

if (-not $NoScorer -and $LlamaDir) {
    $result.scorer.attempted = $true
    try {
        if ([IntPtr]::Size -ne 8) { throw '32-bit PowerShell cannot load 64-bit ggml DLLs' }
        $dir = (Resolve-Path -LiteralPath $LlamaDir).Path
        $dlls = @(Get-ChildItem -LiteralPath $dir -Filter 'ggml-cpu-*.dll' -ErrorAction Stop | Sort-Object Name)
        if ($dlls.Count -eq 0) { throw 'no ggml-cpu-*.dll files in this build (monolithic build or incomplete folder)' }
        [void][PLlmNative]::SetDllDirectoryW($dir)
        $anyOk = $false
        foreach ($f in $dlls) {
            $name = $f.BaseName -replace '^ggml-cpu-', ''
            try {
                # 0x8 = LOAD_WITH_ALTERED_SEARCH_PATH: resolve ggml-base.dll / libomp from the DLL's own folder
                $h = [PLlmNative]::LoadLibraryExW($f.FullName, [IntPtr]::Zero, 0x8)
                if ($h -eq [IntPtr]::Zero) { $result.scorer.errors[$name] = ('LoadLibrary failed, Win32 error {0}' -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()); continue }
                $fn = [PLlmNative]::GetProcAddress($h, 'ggml_backend_score')
                if ($fn -eq [IntPtr]::Zero) { $result.scorer.errors[$name] = 'ggml_backend_score export not found'; continue }
                $result.scorer.scores[$name] = [int][PLlmNative]::CallScore($fn)
                $anyOk = $true
            } catch {
                $result.scorer.errors[$name] = $_.Exception.Message
            }
        }
        $result.scorer.available = $anyOk
        if (-not $anyOk) { $result.scorer.reason = 'no variant could be scored' }
    } catch {
        $result.scorer.available = $false
        $result.scorer.reason = $_.Exception.Message
    }
}

# Predicted variant = highest non-zero score (the rule ggml's loader applies)
$best = $null; $bestScore = 0
foreach ($k in @($result.scorer.scores.Keys)) {
    if ($result.scorer.scores[$k] -gt $bestScore) { $bestScore = $result.scorer.scores[$k]; $best = $k }
}
$result.scorer['predicted'] = $best

if ($Json) {
    Write-Output ($result | ConvertTo-Json -Depth 6 -Compress)
} else {
    Write-Output ('CPU: {0}' -f $result.cpu_name)
    foreach ($k in @($result.pf.Keys)) {
        $v = $result.pf[$k]; if ($null -eq $v) { $v = 'unknown' }
        Write-Output ('  Windows API {0}: {1}' -f $k, $v)
    }
    if ($result.scorer.available) {
        Write-Output ('  Bundled scorer: predicted variant = {0}' -f $result.scorer.predicted)
        foreach ($k in @($result.scorer.scores.Keys)) { Write-Output ('    {0,-15} score {1}' -f $k, $result.scorer.scores[$k]) }
    } else {
        Write-Output ('  Bundled scorer: unavailable ({0})' -f $result.scorer.reason)
    }
}
