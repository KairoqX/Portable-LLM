# Dev harness: runs the REAL Invoke-PLlmServerMonitor against tests/dev/fakeserver.sh (PowerShell 7 on Linux/macOS).
# Not a Windows test: the Windows-only parts (VT mode, job object, GlobalMemoryStatusEx) are skipped there.
param([string]$Session = (Join-Path ([IO.Path]::GetTempPath()) 'pllm-dev-session'), [int]$Port = 18080)
$R = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $R 'lib/PortableLlm.Core.ps1'); . (Join-Path $R 'lib/PortableLlm.Sys.ps1'); . (Join-Path $R 'lib/PortableLlm.Tui.ps1'); . (Join-Path $R 'monitor.ps1')
$probe = [pscustomobject]@{ Ok = $true; Reason = ''; Data = ([pscustomobject]@{ cpu_name = 'Test CPU'; logical_cpus = 8; pf = [pscustomobject]@{ SSE42 = $true; AVX = $true; AVX2 = $true; AVX512 = $false }; scorer = [pscustomobject]@{ available = $true; reason = ''; scores = [pscustomobject]@{ haswell = 64; x64 = 1 } } }) }
Remove-Item -Recurse -Force $Session -ErrorAction SilentlyContinue
$code = Invoke-PLlmServerMonitor -ServerExe (Join-Path $PSScriptRoot 'fakeserver.sh') -ArgumentString '' -WorkDir $PSScriptRoot -SessionDir $Session -ModelName 'm.gguf' `
    -Url ('http://127.0.0.1:{0}' -f $Port) -Port $Port -HostFeatures ([ordered]@{ AVX2 = $true }) -PredictedVariant 'haswell' -HostText 'Test CPU' `
    -VerificationText 'FILES MATCH THE LOCAL ANALYSIS MANIFEST (integrity only)' -VerificationOk $true -HeaderLines @('dev harness') -OpenBrowser $false -Quiet $false `
    -HostProbe $probe -ModelBytes 2.5GB -ContextRequested 4096 -VerificationKind 'VERIFIED'
"EXIT CODE: $code"
