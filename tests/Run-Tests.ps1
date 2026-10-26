# Windows test runner for Portable-LLM.  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
# Exercises the real PowerShell code (parsers + launcher scenarios with -DryRun; the server is never started).
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'lib\PortableLlm.Core.ps1')
$fails = 0
function Check { param([string]$Name, [bool]$Cond, $Detail = '')
    if ($Cond) { Write-Host ('PASS  ' + $Name) -ForegroundColor Green } else { Write-Host ('FAIL  ' + $Name + '  -> ' + $Detail) -ForegroundColor Red; $script:fails++ } }

# ---- parsers on the fixture
$lines = Get-Content (Join-Path $PSScriptRoot 'fixtures\server-startup-and-two-requests.log')
$session = New-PLlmSession; $done = @(); $sys = $null; $be = $null
foreach ($l in $lines) {
    if ($null -eq $sys -and $l -match $PLlmRx_SystemInfo) { $sys = ConvertFrom-PLlmSystemInfo $l }
    $b = ConvertFrom-PLlmLoadBackendLine $l; if ($b -and $b.Backend -eq 'CPU') { $be = $b }
    $r = Add-PLlmTimingEvent -Session $session -TimingEvent (ConvertFrom-PLlmTimingLine $l); if ($r) { $done += $r }
}
Check 'two requests completed' ($done.Count -eq 2) $done.Count
Check 'req1 prompt 26 tok @ 31.37' ($done[0].PromptTokens -eq 26 -and $done[0].PromptTps -eq 31.37)
Check 'req1 generation 197 tok @ 7.34 (not the prompt rate)' ($done[0].GenTokens -eq 197 -and $done[0].GenTps -eq 7.34)
Check 'req1 total 27683.85 ms / 223' ($done[0].TotalMs -eq 27683.85 -and $done[0].TotalTokens -eq 223)
Check 'req2 is a separate record, generation 7.93' ($done[1].Index -eq 2 -and $done[1].GenTps -eq 7.93)
$st = Get-PLlmSessionStats $session
Check 'session generation avg weighted ~7.61' ([math]::Abs($st.GenAvgTps - 7.608) -lt 0.01) $st.GenAvgTps
Check 'backend variant haswell' ($be.Variant -eq 'haswell')
Check 'ISA flags include AVX2 FMA F16C BMI2' (($sys.Enabled -join ' ') -match 'AVX2 F16C FMA BMI2') ($sys.Enabled -join ' ')
Check 'inf/nan rate -> null' ($null -eq (ConvertFrom-PLlmTimingLine 'prompt eval time = 0.00 ms / 0 tokens ( -nan ms per token, inf tokens per second)').TpsReported)
Write-Host (Format-PLlmRequestLine $done[0] (Format-PLlmTag $be $sys 'Llama-3.2-3B-Instruct-Q4_K_M.gguf')) -ForegroundColor Cyan

# ---- fail-loud cross-check
$hf = Resolve-PLlmHostFeatures -Pf @{ AVX2 = $true } -Scores @{ haswell = 10; x64 = 1; zen4 = 0 }
$noAvx2 = [pscustomobject]@{ Flags = ([ordered]@{ AVX2 = 0 }); Enabled = @() }
$f = Test-PLlmBackendAgainstHost -HostFeatures $hf -PredictedVariant 'haswell' -BackendInfo ([pscustomobject]@{ Backend = 'CPU'; Variant = 'x64'; Path = 'x' }) -SysInfo $noAvx2
Check 'AVX2 host + non-AVX2 backend raises FAIL' (@($f | Where-Object Level -eq 'FAIL').Count -eq 1)
Check 'variant mismatch raises WARN' (@($f | Where-Object Level -eq 'WARN').Count -eq 1)


# ---- audit scenarios: manifest verification on a tiny fake build folder (fast; real functions, fake files)
function New-FakeBuild {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('pllm-fake-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $d | Out-Null
    $files = @('llama-server.exe','ggml.dll','ggml-base.dll','llama.dll','llama-server-impl.dll','ggml-cpu-haswell.dll')
    $core = @(); $var = @()
    foreach ($f in $files) {
        [IO.File]::WriteAllText((Join-Path $d $f), ('content of ' + $f)); $h = Get-PLlmFileSha256 (Join-Path $d $f)
        if ($f -like 'ggml-cpu-*') { $var += [pscustomobject]@{ file = $f; sha256 = $h; variant = 'haswell'; declared_requires = @('AVX2') } } else { $core += [pscustomobject]@{ file = $f; sha256 = $h } }
    }
    $m = [pscustomobject]@{ schema = 1; min_host_features = @('AVX2'); core_modules = $core; cpu_variants = $var }
    $mp = Join-Path $d 'build-manifest.json'; ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $mp -Encoding ascii
    (Get-PLlmFileSha256 $mp) + '  build-manifest.json' | Set-Content -LiteralPath ($mp + '.sha256') -Encoding ascii
    return [pscustomobject]@{ Dir = $d; Manifest = $m; Path = $mp }
}
function Verify-Fake($b) { Test-PLlmManifest -Dir $b.Dir -Manifest (Get-Content -LiteralPath $b.Path -Raw | ConvertFrom-Json) -ManifestPath $b.Path }
$b = New-FakeBuild;  Check 'fake build: untouched -> Verified (integrity only)' ((Verify-Fake $b).Verified) ((Verify-Fake $b).Problems -join '; ')
$b = New-FakeBuild; [IO.File]::AppendAllText((Join-Path $b.Dir 'llama-server-impl.dll'), 'x'); $r = Verify-Fake $b
Check 'hash mismatch -> not Verified' ((-not $r.Verified) -and ($r.Problems -match 'hash differs: llama-server-impl.dll'))
$b = New-FakeBuild; Remove-Item (Join-Path $b.Dir 'ggml-cpu-haswell.dll'); $r = Verify-Fake $b
Check 'missing DLL -> not Verified' ((-not $r.Verified) -and ($r.Problems -match 'missing file: ggml-cpu-haswell.dll'))
$b = New-FakeBuild; [IO.File]::WriteAllText((Join-Path $b.Dir 'ggml-vulkan.dll'), 'x'); $r = Verify-Fake $b
Check 'unexpected ggml-*.dll -> not Verified' ((-not $r.Verified) -and ($r.Problems -match 'unlisted backend DLL: ggml-vulkan.dll'))
$b = New-FakeBuild; '{}' | Set-Content -LiteralPath $b.Path -Encoding ascii; $r = Verify-Fake $b
Check 'empty manifest {} -> not Verified' (-not $r.Verified)
$b = New-FakeBuild; $j = Get-Content -LiteralPath $b.Path -Raw; ($j -replace '"schema":\s*1', '"schema": 7') | Set-Content -LiteralPath $b.Path -Encoding ascii; $r = Verify-Fake $b
Check 'wrong schema / edited manifest -> not Verified (schema + sidecar)' (-not $r.Verified)
$b = New-FakeBuild; Remove-Item ($b.Path + '.sha256'); $r = Verify-Fake $b
Check 'missing sidecar -> not Verified' (-not $r.Verified)
$bad = [pscustomobject]@{ schema = 1; core_modules = @([pscustomobject]@{ file = '..\evil.dll'; sha256 = ('a' * 64) }); cpu_variants = @() }
Check 'path traversal in manifest -> schema errors' (@(Test-PLlmManifestSchema $bad).Count -gt 0)

# ---- prediction / unsupported CPU / unknown runtime backend
Check 'predicted variant comes from scores (haswell)' ((Get-PLlmPredictedVariant @{ x64 = 1; haswell = 64; zen4 = 0 }) -eq 'haswell')
Check 'all-zero scores -> no prediction' ($null -eq (Get-PLlmPredictedVariant @{ x64 = 0; haswell = 0 }))
Check 'tied top score -> no prediction' ($null -eq (Get-PLlmPredictedVariant @{ a = 5; b = 5 }))
Check 'no scores -> no prediction' ($null -eq (Get-PLlmPredictedVariant $null))
$hf = Resolve-PLlmHostFeatures -Pf @{ AVX2 = $false } -Scores @{ haswell = 64 }
Check 'Windows AVX2=false overrides scorer' ($hf['AVX2'] -eq $false)
$hf = Resolve-PLlmHostFeatures -Pf @{} -Scores $null
Check 'no data -> AVX2 unknown (null)' ($null -eq $hf['AVX2'])
$c = [pscustomobject]@{ Path = 'x'; Exists = $true; Verified = $true; Problems = @(); MinFeatures = @('AVX2'); Preference = 100 }
Check 'host without AVX2 -> bundle REJECTED, nothing selected' ((Select-PLlmBuild @($c) ([ordered]@{ AVX2 = $false })).Selected -eq $null)
Check 'unknown AVX2 -> REJECTED' ((Select-PLlmBuild @($c) ([ordered]@{ AVX2 = $null })).Rows[0].Status -eq 'REJECTED')
Check 'no runtime line -> backend UNKNOWN' ($null -eq (Get-PLlmResolvedBackend @()))
$one = ConvertFrom-PLlmLoadBackendLine 'load_backend: loaded CPU backend from C:\x\ggml-cpu-haswell.dll'; $two = ConvertFrom-PLlmLoadBackendLine 'load_backend: loaded CPU backend from C:\x\ggml-cpu-x64.dll'
Check 'one logged path -> identified' ((Get-PLlmResolvedBackend @($one)).Variant -eq 'haswell')
Check 'two different logged paths -> UNKNOWN (ambiguous)' ($null -eq (Get-PLlmResolvedBackend @($one, $two)))
$f = Test-PLlmBackendAgainstHost -HostFeatures $hf -PredictedVariant 'haswell' -BackendInfo $null -SysInfo $null
Check 'unknown backend never yields an OK finding' (@($f | Where-Object Level -eq 'OK').Count -eq 0 -and (@($f | Where-Object Text -match 'UNKNOWN').Count -ge 1))
Check 'listening line without http:// is detected' ('srv  start: listening on 127.0.0.1:8080' -match $PLlmRx_Listening)

# ---- launcher scenarios (temp copy; real llama\ folder only where needed)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pllm-test-' + [guid]::NewGuid().ToString('N'))
function New-Sandbox([bool]$WithLlama, [int]$Models) {
    $d = Join-Path $tmp ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $d | Out-Null
    Copy-Item (Join-Path $Root 'lib') $d -Recurse; foreach ($n in 'launcher.ps1','monitor.ps1','cpu-detect.ps1','CONFIG.bat') { Copy-Item (Join-Path $Root $n) $d }
    New-Item -ItemType Directory -Path (Join-Path $d 'models') | Out-Null
    for ($i = 1; $i -le $Models; $i++) { Set-Content -LiteralPath (Join-Path $d ("m$i.gguf")) 'x' ; Move-Item (Join-Path $d "m$i.gguf") (Join-Path $d 'models') }
    if ($WithLlama) { Copy-Item (Join-Path $Root 'llama') (Join-Path $d 'llama') -Recurse }
    return $d
}
function Run-Launcher($dir, [string[]]$extra) {
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $dir 'launcher.ps1')),'-DryRun') + $extra) -NoNewWindow -PassThru -Wait `
         -RedirectStandardOutput (Join-Path $dir 'out.txt') -RedirectStandardError (Join-Path $dir 'err.txt')
    return [pscustomobject]@{ Code = $p.ExitCode; Out = (Get-Content (Join-Path $dir 'out.txt') -Raw) }
}
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $s = New-Sandbox $false 1; New-Item -ItemType Directory (Join-Path $s 'llama') | Out-Null
    $r = Run-Launcher $s @('-Choice','1'); Check 'missing llama-server.exe -> exit 2' ($r.Code -eq 2) $r.Code
    $s = New-Sandbox $true 0; $r = Run-Launcher $s @(); Check 'no models -> exit 2' ($r.Code -eq 2) $r.Code
    $s = New-Sandbox $true 2; $r = Run-Launcher $s @('-Choice','9'); Check 'invalid model number -> exit 3' ($r.Code -eq 3) $r.Code
    $s = New-Sandbox $true 2; $r = Run-Launcher $s @('-Choice','2')
    Check 'valid run (dry) -> exit 0' ($r.Code -eq 0) $r.Code
    Check 'reports FILES MATCH THE LOCAL ANALYSIS MANIFEST for the untouched bundle' ($r.Out -match 'FILES MATCH THE LOCAL ANALYSIS MANIFEST') 
    Check 'command restricts CORS and binds 127.0.0.1' (($r.Out -match '--cors-origins localhost') -and ($r.Out -match '--host 127\.0\.0\.1'))
    [IO.File]::AppendAllText((Join-Path $s 'llama\ggml-cpu-haswell.dll'), 'tamper')
    $r = Run-Launcher $s @('-Choice','1')
    Check 'tampered DLL is NOT reported as verified' (($r.Out -notmatch 'FILES MATCH THE LOCAL ANALYSIS MANIFEST') -and ($r.Out -match 'UNVERIFIED|REJECTED')) 
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''; Write-Host ('{0} failure(s)' -f $fails); exit $(if ($fails) { 1 } else { 0 })
