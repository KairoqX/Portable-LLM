# Dev end-to-end test of the REAL launcher.ps1 on Linux/macOS with PowerShell 7 (NOT a Windows test).
# Stubs: cpu-detect.ps1 (host probe JSON) and llama-server.exe (a shell script that writes a marker file when it is spawned).
# Memory is injected through PORTABLE_LLM_TEST_MEMORY (test seam).  Usage: pwsh tests/dev/launcher_e2e.ps1
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'lib/PortableLlm.Core.ps1')
$fails = 0
function Check([string]$Name, [bool]$Ok, $Detail = '') { if ($Ok) { Write-Host "PASS  $Name" } else { Write-Host "FAIL  $Name  -> $Detail"; $script:fails++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pllm-e2e-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null

function New-Bundle([string]$Dir, [string[]]$Min, [int]$Pref) {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $marker = Join-Path $tmp 'spawned.txt'
    $files = @('llama-server.exe', 'ggml.dll', 'ggml-base.dll', 'llama.dll')
    $core = @()
    foreach ($f in $files) {
        $p = Join-Path $Dir $f
        if ($f -eq 'llama-server.exe') { "#!/bin/bash`necho `"spawned from $Dir`" >> '$marker'`necho 'srv  start: listening on http://127.0.0.1:18099'`necho 'srv  update_slots: all slots are idle'`nsleep 1`nexit 0`n" | Set-Content -LiteralPath $p -NoNewline; & chmod +x $p }
        else { "content of $f" | Set-Content -LiteralPath $p }
        $core += [pscustomobject]@{ file = $f; sha256 = (Get-PLlmFileSha256 $p) }
    }
    $m = [pscustomobject]@{ schema = 1; min_host_features = @($Min); preference = $Pref; core_modules = $core; cpu_variants = @(); supports_cli = @('--cors-origins') }
    $mp = Join-Path $Dir 'build-manifest.json'; ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $mp
    (Get-PLlmFileSha256 $mp) + '  build-manifest.json' | Set-Content -LiteralPath ($mp + '.sha256')
}
function New-Sandbox([bool]$Avx2) {
    $d = Join-Path $tmp ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
    Copy-Item (Join-Path $Root 'lib') $d -Recurse; foreach ($n in 'launcher.ps1', 'monitor.ps1', 'CONFIG.bat') { Copy-Item (Join-Path $Root $n) $d }
    $av = $(if ($Avx2) { 'true' } else { 'false' })
    "param([string]`$LlamaDir, [switch]`$Json)`n@{ cpu_name='Stub CPU'; cores=4; logical_cpus=8; pf=@{ SSE42=`$true; AVX=`$true; AVX2=`$$av; AVX512=`$false }; scorer=@{ available=`$false; reason='stub'; predicted=`$null; scores=@{} } } | ConvertTo-Json -Depth 5`n" | Set-Content (Join-Path $d 'cpu-detect.ps1')
    New-Item -ItemType Directory (Join-Path $d 'models') | Out-Null
    $g = Join-Path $d 'models/m.gguf'
    $fs = [IO.File]::Create($g); $bw = New-Object IO.BinaryWriter($fs)
    $kv = [ordered]@{ 'general.architecture' = 'llama'; 'llama.block_count' = 28; 'llama.embedding_length' = 3072; 'llama.attention.head_count' = 24; 'llama.attention.head_count_kv' = 8; 'llama.attention.key_length' = 128 }
    $bw.Write([uint32]0x46554747); $bw.Write([uint32]3); $bw.Write([uint64]0); $bw.Write([uint64]($kv.Count))
    foreach ($k in $kv.Keys) { $kb = [Text.Encoding]::UTF8.GetBytes($k); $bw.Write([uint64]$kb.Length); $bw.Write($kb); if ($kv[$k] -is [string]) { $bw.Write([uint32]8); $vb = [Text.Encoding]::UTF8.GetBytes($kv[$k]); $bw.Write([uint64]$vb.Length); $bw.Write($vb) } else { $bw.Write([uint32]4); $bw.Write([uint32]$kv[$k]) } }
    $bw.Write([byte[]](New-Object byte[] 1MB)); $bw.Flush(); $fs.Dispose()        # ~1 MB "model": the estimate uses the real file size
    return $d
}
function Run([string]$Dir, [string[]]$Extra, [string]$Memory) {
    Remove-Item (Join-Path $tmp 'spawned.txt') -ErrorAction SilentlyContinue
    $env:PORTABLE_LLM_TEST_MEMORY = $Memory; $env:PORTABLE_LLM_UI = 'log'; $env:PORTABLE_LLM_PORT = '18099'
    $out = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $Dir 'launcher.ps1') -Choice 1 -NoBrowser @Extra 2>&1 | Out-String
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; Out = $out; Spawned = (Test-Path (Join-Path $tmp 'spawned.txt')); Marker = $(if (Test-Path (Join-Path $tmp 'spawned.txt')) { Get-Content (Join-Path $tmp 'spawned.txt') -Raw } else { '' }) }
}
$ample = '17179869184,12884901888'; $tiny = '1000000,500000'
try {
    $s = New-Sandbox $true; New-Bundle (Join-Path $s 'llama') @('AVX2') 100
    $r = Run $s @('-DryRun') $ample
    Check 'e2e: ample memory, dry run -> exit 0, PASS printed once, selected build named' (($r.Code -eq 0) -and ($r.Out -match 'Memory preflight: PASS') -and (([regex]::Matches($r.Out, 'Memory preflight: ')).Count -eq 1) -and ($r.Out -match 'Selected\s+: llama') -and -not $r.Spawned) "$($r.Code)"
    $r = Run $s @() $tiny
    Check 'e2e: BLOCK -> exit 6, "No server process was created", and the fake server was NEVER spawned' (($r.Code -eq 6) -and ($r.Out -match 'No server process was created') -and ($r.Out -match 'Memory preflight: BLOCK') -and -not $r.Spawned) "code=$($r.Code) spawned=$($r.Spawned)"
    $r = Run $s @('-DryRun') $tiny
    Check 'e2e: BLOCK is reported in a dry run too (exit 6)' ($r.Code -eq 6)
    $r = Run $s @('-AllowLowMemory', '-DryRun') $tiny
    Check 'e2e: explicit -AllowLowMemory lets a BLOCK proceed and says so' (($r.Code -eq 0) -and ($r.Out -match 'Memory preflight: BLOCK') -and ($r.Out -match 'overridden')) "$($r.Code)"
    $r = Run $s @() $ample
    Check 'e2e: ample memory, real start -> the server IS spawned and the monitor ran to completion' (($r.Spawned) -and ($r.Out -match 'SERVER STOPPED') -and ($r.Code -eq 0)) "code=$($r.Code)"
    $r = Run $s @() $null
    Check 'e2e: memory unmeasurable -> WARN diagnostic printed, not a silent pass' ($r.Out -match 'Memory could not be measured')
    $r = Run $s @() 'garbage'
    Check 'e2e: malformed memory reading is also reported as unmeasured' ($r.Out -match 'Memory could not be measured')

    $s2 = New-Sandbox $false; New-Bundle (Join-Path $s2 'llama') @('AVX2') 100
    $r = Run $s2 @() $ample
    Check 'e2e: host without AVX2 and only an AVX2 build -> exit 4, nothing spawned, reason shown' (($r.Code -eq 4) -and -not $r.Spawned -and ($r.Out -match 'host CPU lacks AVX2')) "code=$($r.Code)"
    New-Bundle (Join-Path $s2 'llama/baseline') @() 50
    $r = Run $s2 @() $ample
    Check 'e2e: host without AVX2 + verified baseline build -> the baseline is selected and spawned' (($r.Code -eq 0) -and $r.Spawned -and ($r.Marker -match 'baseline') -and ($r.Out -match 'Selected\s+: llama.baseline')) "code=$($r.Code) marker=$($r.Marker)"
    [IO.File]::AppendAllText((Join-Path $s2 'llama/baseline/ggml.dll'), 'tamper')
    $r = Run $s2 @('-DryRun') $ample
    Check 'e2e: a tampered baseline (hash differs) is reported UNVERIFIED, not as matching the manifest' (($r.Out -match 'UNVERIFIED') -and ($r.Out -notmatch 'FILES MATCH THE LOCAL ANALYSIS MANIFEST') -and ($r.Out -match 'hash differs: ggml.dll'))
    [IO.File]::WriteAllText((Join-Path $s2 'llama/baseline/ggml-vulkan.dll'), 'x')
    $r = Run $s2 @('-DryRun') $ample
    Check 'e2e: an unexpected ggml-*.dll is reported and prevents any "match" wording' (($r.Out -match 'unlisted backend DLL: ggml-vulkan.dll') -and ($r.Out -notmatch 'FILES MATCH THE LOCAL ANALYSIS MANIFEST'))
    $r = Run $s2 @('-DryRun', '-AllowUnverified') $ample
    $s3 = New-Sandbox $false; New-Bundle (Join-Path $s3 'llama') @('AVX2') 100
    $r = Run $s3 @('-DryRun', '-AllowUnverified') $ample
    Check 'e2e: CPU override starts a rejected build with a prominent OVERRIDE banner, and never calls it verified' (($r.Code -eq 0) -and ($r.Out -match 'OVERRIDE: starting a build that was REJECTED') -and ($r.Out -match 'NOT verified as compatible') -and ($r.Out -match 'REJECTED FOR THIS CPU \(override in effect\)') -and ($r.Out -notmatch 'FILES MATCH THE LOCAL ANALYSIS MANIFEST')) "code=$($r.Code)"
} finally { Remove-Item Env:\PORTABLE_LLM_TEST_MEMORY, Env:\PORTABLE_LLM_UI, Env:\PORTABLE_LLM_PORT -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''; Write-Host ('{0} failure(s)' -f $fails); exit $(if ($fails) { 1 } else { 0 })
