# Windows test runner for Portable-LLM.  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
# Exercises the real PowerShell code (parsers + launcher scenarios with -DryRun; the server is never started).
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'lib/PortableLlm.Core.ps1')
. (Join-Path $Root 'lib/PortableLlm.Sys.ps1')
. (Join-Path $Root 'lib/PortableLlm.Tui.ps1')
$fails = 0; $skips = 0
$onWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
function Skip { param([string]$Name, [string]$Why) Write-Host ('SKIP  ' + $Name + '  -> ' + $Why) -ForegroundColor Yellow; $script:skips++ }
function Check { param([string]$Name, [bool]$Cond, $Detail = '')
    if ($Cond) { Write-Host ('PASS  ' + $Name) -ForegroundColor Green } else { Write-Host ('FAIL  ' + $Name + '  -> ' + $Detail) -ForegroundColor Red; $script:fails++ } }

# ---- parsers on the fixture
$lines = Get-Content (Join-Path $PSScriptRoot 'fixtures/server-startup-and-two-requests.log')
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

# ---- dashboard: pure logic (state machine, hints, thresholds, counters, key map)
function St($ex, $us, $code, $hs, $ls, $ld, $lr) { (Get-PLlmServerState -Exited $ex -StoppedByUser $us -ExitCode $code -HealthStatus $hs -ListeningSeen $ls -LoaderSeen $ld -LogReady $lr).State }
Check 'state: nothing seen -> Starting' ((St $false $false $null $null $false $false $false) -eq 'Starting')
Check 'state: model loader lines -> Loading Model' ((St $false $false $null $null $false $true $false) -eq 'Loading Model')
Check 'state: listening but unconfirmed -> Loading Model (not Ready)' ((St $false $false $null $null $true $true $false) -eq 'Loading Model')
Check 'state: /health 503 -> Loading Model even if listening' ((St $false $false $null 503 $true $true $false) -eq 'Loading Model')
Check 'state: /health 200 -> Ready' ((St $false $false $null 200 $true $true $false) -eq 'Ready')
Check 'state: no /health answer but llama.cpp logged ready -> Ready' ((St $false $false $null $null $true $true $true) -eq 'Ready')
Check 'state: exit code 3 -> Error' ((St $true $false 3 200 $true $true $true) -eq 'Error')
Check 'state: exit 0 -> Stopped' ((St $true $false 0 $null $true $true $true) -eq 'Stopped')
Check 'state: stopped by user (any code) -> Stopped' ((St $true $true 1 $null $true $true $true) -eq 'Stopped')
Check 'state: Ctrl+C status code -> Stopped' ((St $true $false -1073741510 $null $true $true $true) -eq 'Stopped')
Check 'memory: 4 GB free of 8 -> ok' ((Get-PLlmMemoryLevel 8GB 4GB) -eq 'ok')
Check 'memory: 1.2 GB free of 8 -> warn' ((Get-PLlmMemoryLevel 8GB 1.2GB) -eq 'warn')
Check 'memory: 0.5 GB free of 8 -> crit' ((Get-PLlmMemoryLevel 8GB 0.5GB) -eq 'crit')
Check 'memory: 90% used of 32 GB (3.2 GB free) -> warn by percent' ((Get-PLlmMemoryLevel 32GB 3.2GB) -eq 'warn')
Check 'memory: hysteresis keeps warn just under the threshold' ((Get-PLlmMemoryLevel 8GB 1.6GB 'warn') -eq 'warn' -and (Get-PLlmMemoryLevel 8GB 1.6GB 'ok') -eq 'ok')
Check 'memory: no data -> unknown (never a guess)' ((Get-PLlmMemoryLevel $null $null) -eq 'unknown')
Check 'hint: bind failure' ((Get-PLlmErrorHint "srv operator(): couldn't bind HTTP server socket, hostname: 127.0.0.1, port: 8080") -match 'port is already in use')
Check 'hint: out of memory' ((Get-PLlmErrorHint 'ggml_aligned_malloc: insufficient memory, failed to allocate 3 GB') -match 'Not enough memory')
Check 'hint: unknown architecture' ((Get-PLlmErrorHint "llama_model_load: error loading model: unknown model architecture: 'x'") -match 'does not know this model')
Check 'hint: plain line -> none' ($null -eq (Get-PLlmErrorHint 'srv  update_slots: all slots are idle'))
Check 'error regex ignores "error = 0" counters' ('stats: error = 0' -notmatch $PLlmRx_ErrorLine -and 'main: error: something' -match $PLlmRx_ErrorLine)
Check 'ctx regex takes n_ctx, not n_ctx_train' (('llama_context: n_ctx         = 4096' -match $PLlmRx_CtxReported -and $Matches[1] -eq '4096') -and ('print_info: n_ctx_train = 32768' -notmatch $PLlmRx_CtxReported))
Check 'ready-by-log regex' ('srv  update_slots: all slots are idle' -match $PLlmRx_ModelLoaded)
$s2 = New-PLlmSession
[void](Add-PLlmTimingEvent $s2 (ConvertFrom-PLlmTimingLine 'prompt eval time = 100.00 ms / 5 tokens ( 20.00 ms per token, 50.00 tokens per second)'))
[void](Add-PLlmTimingEvent $s2 (ConvertFrom-PLlmTimingLine 'prompt eval time = 100.00 ms / 5 tokens ( 20.00 ms per token, 50.00 tokens per second)'))
Check 'a prompt line never followed by "total time" is counted as incomplete' ((Get-PLlmSessionStats $s2).Incomplete -eq 1)
Close-PLlmSession $s2
Check 'a request open at server exit is counted as incomplete' ((Get-PLlmSessionStats $s2).Incomplete -eq 2 -and (Get-PLlmSessionStats $s2).Requests -eq 0)
Check 'completed fixture requests have zero incomplete' ((Get-PLlmSessionStats $session).Incomplete -eq 0)
function Key($ch, $k, $ctrl = $false) { New-Object System.ConsoleKeyInfo($ch, $k, $false, $false, $ctrl) }
Check 'keys: o/d/l/r/q map to commands' ((ConvertTo-PLlmCommand (Key 'o' ([ConsoleKey]::O))) -eq 'Open' -and (ConvertTo-PLlmCommand (Key 'D' ([ConsoleKey]::D))) -eq 'Diag' -and (ConvertTo-PLlmCommand (Key 'l' ([ConsoleKey]::L))) -eq 'Log' -and (ConvertTo-PLlmCommand (Key 'r' ([ConsoleKey]::R))) -eq 'Redraw' -and (ConvertTo-PLlmCommand (Key 'q' ([ConsoleKey]::Q))) -eq 'Quit')
Check 'keys: Ctrl+C quits, Ctrl+O is ignored, unknown key ignored' ((ConvertTo-PLlmCommand (Key ([char]3) ([ConsoleKey]::C) $true)) -eq 'Quit' -and $null -eq (ConvertTo-PLlmCommand (Key ([char]15) ([ConsoleKey]::O) $true)) -and $null -eq (ConvertTo-PLlmCommand (Key 'x' ([ConsoleKey]::X))))

# ---- dashboard: rendering (pure; view models built by hand)
function New-TestView([string]$Case) {
    $sess = New-PLlmSession; $req = $null
    if ($Case -ne 'none') { foreach ($l in $lines) { $r = Add-PLlmTimingEvent $sess (ConvertFrom-PLlmTimingLine $l); if ($r) { $req = $r } } }
    $stt = Get-PLlmSessionStats $sess
    $lowmem = ($Case -eq 'lowmem')
    $v = [pscustomobject]@{
        Version = $script:PLlmVersion; State = 'Ready'; StateDetail = 'server answers HTTP requests'; Url = 'http://127.0.0.1:8080'; Alerts = @(); ShowDiag = ($Case -eq 'diag'); Notice = $null
        Model = [pscustomobject]@{ Name = 'Qwen3-4B-Q4_K_M.gguf'; SizeBytes = 2.5GB; Status = 'Loaded - server reports ready'; StatusLevel = 'ok'; CtxText = '4096 tokens (reported by llama.cpp)'; CtxShort = '4096' }
        Perf = [pscustomobject]@{ Completed = $stt.Requests; Incomplete = $stt.Incomplete; Last = $req; Stats = $stt }
        Sys = [pscustomobject]@{ CpuName = 'AMD Ryzen 3 5300U with Radeon Graphics'; Logical = 8; Support = ([ordered]@{ 'SSE4.2' = $true; 'AVX' = $true; 'AVX2' = $true; 'AVX-512' = $null }); MemTotal = 8GB; MemAvail = $(if ($lowmem) { 0.6GB } else { 3.8GB }); MemUsedPct = $(if ($lowmem) { 92.5 } else { 52.5 }); MemLevel = $(if ($lowmem) { 'crit' } else { 'ok' }); ServerWorkingSet = 2.1GB; Uptime = [TimeSpan]::FromSeconds(761) }
        Compat = [pscustomobject]@{ Expected = 'haswell'; ExpectedNote = '(bundled scorer)'; Actual = 'haswell'; ActualNote = '(reported by llama.cpp)'; Match = 'match'; Isa = 'AVX2 FMA F16C BMI2'; IntegrityShort = 'Files match the local manifest (hash check only; the manifest is unsigned, so origin is not established).'; IntegrityLevel = 'info'; Findings = @() }
        Events = @([pscustomobject]@{ Time = (Get-Date); Level = 'ok'; Text = 'Model loaded; server ready' }); Diag = @([pscustomobject]@{ Label = 'Orphan guard'; Text = 'on'; Level = 'info' })
    }
    if ($Case -eq 'unknown') { $v.Compat.Actual = 'Unknown'; $v.Compat.ActualNote = 'llama.cpp has not logged a "loaded CPU backend" line yet'; $v.Compat.Match = 'unknown' }
    if ($Case -eq 'mismatch') { $v.Compat.Actual = 'x64'; $v.Compat.Match = 'mismatch' }
    return $v
}
function Frame($case, $w, $h, $color = $false, $uni = $false) { (Build-PLlmFrame -V (New-TestView $case) -Width $w -Height $h -Color $color -Unicode $uni) -join "`n" }
$none = Frame 'none' 120 30
Check 'no request yet -> "Waiting for first request", no N/A placeholders' (($none -match 'Waiting for first request') -and ($none -notmatch '(?i)\bn/a\b'))
Check 'no request yet -> counters still shown (0 completed)' ($none -match '0 completed, 0 failed/incomplete')
$two = Frame 'full' 120 30
Check 'latest request: prompt 34.6 and generation 7.9 tok/s shown on their own rows' (($two -match 'Prompt\s+34\.6 tok/s\s+30 tokens') -and ($two -match 'Generate\s+7\.9 tok/s\s+180 tokens'))
Check 'session averages are token-weighted (gen 7.6, prompt 33.0), distinct from latest' ($two -match 'avg gen 7\.6 tok/s \| prompt 33\.0 tok/s')
Check 'request duration shown (23.6 s)' ($two -match 'took 23\.6 s')
Check 'RAM total, used, available and percent are shown' (($two -match '53% used') -and ($two -match '4\.20 GB used of 8\.00 GB, 3\.80 GB available'))
Check 'unsupported/unknown OS flag is labelled unknown, not "no"' ($two -match 'AVX-512 unknown')
$lm = Frame 'lowmem' 120 30
Check 'low-memory warning uses the measured value (614 MB)' (($lm -match 'Critical: only 614 MB free'))
$unk = Frame 'unknown' 80 50
Check 'unknown backend reason is wrapped, never truncated, in the two-column layout' (((Frame 'unknown' 120 30) -match 'has not logged a') -and ((Frame 'unknown' 120 30) -match 'backend" line yet') -and ((Frame 'unknown' 120 30) -notmatch '\.\.\.\s*$'))
$unkRow = @($unk -split "`n" | Where-Object { $_ -match 'Runtime' })[0]
Check 'unknown backend -> "Unknown" with the reason, and no match claim on that row' (($unkRow -match 'Runtime\s+Unknown') -and ($unk -match 'has not logged a "loaded CPU backend"') -and ($unkRow -notmatch '\bmatch\b'))
$mm = Frame 'mismatch' 120 30
Check 'variant mismatch is shown as "differs"' ($mm -match 'Runtime\s+x64\s+differs')
$narrow = Frame 'full' 80 50
Check 'integrity wording says hash check only / unsigned; never claims authenticity' (($narrow -match 'hash check only') -and ($narrow -match 'unsigned') -and ($narrow -notmatch '(?i)\b(authentic|authenticated|trusted|genuine|official|verified by)\b'))
Check 'plain mode (no color) emits no escape codes' ($two.IndexOf([char]27) -lt 0)
Check 'color mode emits escape codes' ((Frame 'full' 120 30 $true $true).IndexOf([char]27) -ge 0)
$nonAscii = @((Frame 'full' 120 30 $false $false).ToCharArray() | Where-Object { [int]$_ -gt 127 })
Check 'ASCII mode contains only ASCII characters' ($nonAscii.Count -eq 0) $nonAscii.Count
$bad = @()
foreach ($sz in @(@(200, 50), @(120, 30), @(110, 24), @(100, 30), @(80, 24), @(80, 40), @(60, 14), @(50, 10), @(44, 9), @(40, 8), @(30, 5))) {
    foreach ($case in @('full', 'none', 'diag', 'lowmem')) {
        foreach ($col in @($false, $true)) {
            $fr = @(Build-PLlmFrame -V (New-TestView $case) -Width $sz[0] -Height $sz[1] -Color $col -Unicode $col)
            $maxv = 0; foreach ($ln in $fr) { $vl = Get-PLlmVisibleLength $ln; if ($vl -gt $maxv) { $maxv = $vl } }
            if ($fr.Count -gt $sz[1] -or $maxv -gt ($sz[0] - 1)) { $bad += ('{0}x{1} {2} color={3}: {4} lines, widest {5}' -f $sz[0], $sz[1], $case, $col, $fr.Count, $maxv) }
        }
    }
}
Check 'every frame fits its window (lines <= height, width <= columns-1) at 11 sizes' ($bad.Count -eq 0) ($bad -join '; ')
Check 'footer shows all five keys in a normal window' ((Frame 'full' 120 30) -match '\[O\] Open browser  \[D\] Diagnostics  \[L\] Log path  \[R\] Redraw  \[Q\] Quit')
Check 'tiny window degrades to a status line with Quit' ((Frame 'full' 40 8) -match 'too small' -and (Frame 'full' 40 8) -match '\[Q\]')
Check 'diagnostics panel appears only when toggled on' (((Frame 'diag' 120 40) -cmatch 'DIAGNOSTICS') -and ($two -cnotmatch 'DIAGNOSTICS'))
# painter diff: a second identical frame writes nothing, a changed row writes only that row (ANSI mode, captured)
$cp = [pscustomobject]@{ Mode = 'Ansi'; Width = 20; Height = 4; Color = $false }
$pt = New-PLlmPainter; $sw = New-Object System.IO.StringWriter; $oldOut = [Console]::Out; [Console]::SetOut($sw)
try {
    Write-PLlmFrame $cp $pt @('aaa', 'bbb', 'ccc') $false; $first = $sw.ToString(); [void]$sw.GetStringBuilder().Clear()
    Write-PLlmFrame $cp $pt @('aaa', 'bbb', 'ccc') $false; $same = $sw.ToString(); [void]$sw.GetStringBuilder().Clear()
    Write-PLlmFrame $cp $pt @('aaa', 'BBB', 'ccc') $false; $one = $sw.ToString()
} finally { [Console]::SetOut($oldOut) }
Check 'painter: identical frame writes nothing (no flicker)' ($same -eq '')
Check 'painter: one changed row rewrites only that row' (($one -match 'BBB') -and ($one -notmatch 'aaa') -and ($one -notmatch 'ccc'))
Check 'painter: first frame clears and draws every row' (($first -match '\[2J') -and ($first -match 'aaa') -and ($first -match 'ccc'))

# ======================================================================================================
# Preflight safety + CPU-driven selection + runtime evidence (all pure: fake candidates, fake memory, fake logs)
# ======================================================================================================
. (Join-Path $Root 'monitor.ps1')
function Cand([string]$Name, [bool]$Verified, [string[]]$Min, [int]$Pref, $Feat, [bool]$Exists = $true, [string[]]$Problems = @()) {
    [pscustomobject]@{ Name = $Name; Exists = $Exists; Verified = $Verified; MinFeatures = @($Min); Preference = $Pref; Features = $Feat; Problems = @($Problems) }
}
$hostAvx2 = [ordered]@{ AVX2 = $true; AVX = $true; SSE42 = $true }
$hostNoAvx2 = [ordered]@{ AVX2 = $false; AVX = $true; SSE42 = $true }
$hostUnknown = [ordered]@{ AVX2 = $null; AVX = $null; SSE42 = $true }

# ---- CPU compatibility controls the build that is selected
$s = Select-PLlmBuild @((Cand 'llama\llama-server.exe' $true @('AVX2') 100 $hostAvx2))
Check 'CPU: AVX2 host + AVX2 bundle -> that build is selected (VERIFIED kind)' (($s.Selected.Candidate.Name -eq 'llama\llama-server.exe') -and $s.Kind -eq 'VERIFIED')
$s = Select-PLlmBuild @((Cand 'llama\llama-server.exe' $true @('AVX2') 100 $hostNoAvx2))
Check 'CPU: AVX2 unsupported, only an AVX2 build -> NOTHING selected, reason names AVX2' (($null -eq $s.Selected) -and $s.Rows[0].Status -eq 'REJECTED' -and $s.Summary -match 'lacks AVX2')
$s = Select-PLlmBuild @((Cand 'llama\llama-server.exe' $true @('AVX2') 100 $hostNoAvx2), (Cand 'llama\baseline\llama-server.exe' $true @() 50 $hostNoAvx2))
Check 'CPU: AVX2 unsupported but a verified baseline exists -> baseline selected' (($s.Selected.Candidate.Name -eq 'llama\baseline\llama-server.exe') -and $s.Kind -eq 'VERIFIED')
$pf = @{ SSE42 = $true; AVX = $true; AVX2 = $false; AVX512 = $false }
$hf = Resolve-PLlmHostFeatures -Pf $pf -Scores @{ x64 = 1; haswell = 64 } -Table $null
$s = Select-PLlmBuild @((Cand 'llama\llama-server.exe' $true @('AVX2') 100 $hf))
Check 'CPU: Windows says AVX2=false while the scorer says haswell(64) -> still rejected' (($hf['AVX2'] -eq $false) -and ($null -eq $s.Selected))
$s = Select-PLlmBuild @((Cand 'a\llama-server.exe' $true @('AVX2') 100 $hostUnknown))
Check 'CPU: required feature UNKNOWN -> rejected with "cannot confirm", not treated as supported' (($null -eq $s.Selected) -and $s.Rows[0].Reason -match 'cannot confirm host support for AVX2')
$s = Select-PLlmBuild @((Cand 'b\llama-server.exe' $false @('AVX2') 100 $hostUnknown -Problems @('hash differs: ggml.dll (not the file that was analysed)')))
Check 'CPU: an UNVERIFIED build with a recorded AVX2 minimum and unknown host AVX2 is rejected too (fail closed)' (($null -eq $s.Selected) -and $s.Rows[0].Status -eq 'REJECTED')
$s = Select-PLlmBuild @((Cand 'c\llama-server.exe' $false @() 100 $hostUnknown -Problems @('no build manifest')))
Check 'CPU: a build with NO manifest records no requirement -> UNVERIFIED fallback, never labelled verified' (($s.Rows[0].Status -eq 'UNVERIFIED') -and $s.Kind -eq 'UNVERIFIED' -and $s.Rows[0].Reason -match 'no build manifest')
$s = Select-PLlmBuild @((Cand 'a\llama-server.exe' $true @('AVX2') 100 $hostNoAvx2), (Cand 'b\llama-server.exe' $true @('AVX2') 90 $hostNoAvx2))
Check 'CPU: no valid CPU-compatible build -> none selected; summary lists every reason' (($null -eq $s.Selected) -and ($s.Summary -match 'a\\llama-server.exe: host CPU lacks AVX2') -and ($s.Summary -match 'b\\llama-server.exe'))
$s = Select-PLlmBuild @((Cand 'low\llama-server.exe' $true @() 10 $hostAvx2), (Cand 'high\llama-server.exe' $true @('AVX2') 100 $hostAvx2), (Cand 'mid\llama-server.exe' $true @('AVX2') 50 $hostAvx2))
Check 'CPU: several compatible builds -> highest preference wins' ($s.Selected.Candidate.Name -eq 'high\llama-server.exe')
$s = Select-PLlmBuild @((Cand 'zeta\llama-server.exe' $true @() 70 $hostAvx2), (Cand 'alpha\llama-server.exe' $true @() 70 $hostAvx2))
Check 'CPU: equal preference -> deterministic tie-break by name' ($s.Selected.Candidate.Name -eq 'alpha\llama-server.exe')
$s = Select-PLlmBuild @((Cand 'ver\llama-server.exe' $true @('AVX2') 10 $hostAvx2), (Cand 'unv\llama-server.exe' $false @() 100 $hostAvx2 -Problems @('hash differs: x')))
Check 'CPU: a compatible build beats an UNVERIFIED one even if the unverified one has higher preference' ($s.Selected.Candidate.Name -eq 'ver\llama-server.exe')
$s = Select-PLlmBuild @((Cand 'known\llama-server.exe' $true @('AVX2') 100 $hostNoAvx2), (Cand 'unk\llama-server.exe' $true @('AVX2') 10 $hostUnknown))
$ov = Select-PLlmOverrideRow $s.Rows
Check 'override: prefers the build rejected only for UNKNOWN support over one the host is KNOWN to lack' ($ov.Candidate.Name -eq 'unk\llama-server.exe')
Check 'override: does not change any status (still REJECTED, never COMPATIBLE/verified)' ((@($s.Rows | Where-Object { $_.Status -ne 'REJECTED' }).Count -eq 0) -and $null -eq $s.Selected)
Check 'missing executable is reported MISSING and never selected' ((Select-PLlmBuild @((Cand 'gone\llama-server.exe' $true @() 100 $hostAvx2 -Exists $false))).Rows[0].Status -eq 'MISSING')

# ---- manifest verification regression set (isolated fake bundles; the real DLLs are never touched)
$b = New-FakeBuild; [IO.File]::AppendAllText((Join-Path $b.Dir 'ggml-cpu-haswell.dll'), 'x'); $r = Verify-Fake $b
Check 'manifest: tampered CPU-variant DLL -> hash differs, not Verified' ((-not $r.Verified) -and ($r.Problems -match 'hash differs: ggml-cpu-haswell.dll'))
$b = New-FakeBuild; Remove-Item (Join-Path $b.Dir 'llama.dll'); $r = Verify-Fake $b
Check 'manifest: missing REQUIRED core module -> not Verified' ((-not $r.Verified) -and ($r.Problems -match 'missing file: llama.dll'))
$b = New-FakeBuild; $j = Get-Content -LiteralPath $b.Path -Raw; ($j -replace '(?s)(\{\s*"file":\s*"ggml-base.dll".*?\},?)', '') | Set-Content -LiteralPath $b.Path -Encoding ascii; $r = Verify-Fake $b
Check 'manifest: required module not listed / edited manifest -> not Verified' (-not $r.Verified)
$b = New-FakeBuild; "not-a-digest" | Set-Content -LiteralPath ($b.Path + '.sha256') -Encoding ascii; $r = Verify-Fake $b
Check 'manifest: malformed sidecar digest -> not Verified, says why' ((-not $r.Verified) -and ($r.Problems -match 'valid SHA-256 digest') -and $r.SidecarState -eq 'MALFORMED')
foreach ($bn in @('con.dll', 'a:b.dll', 'evil.dll.', 'x*.dll', 'C:\win\x.dll', '/abs.dll', 'sub/x.dll')) {
    $bm = [pscustomobject]@{ schema = 1; core_modules = @([pscustomobject]@{ file = $bn; sha256 = ('a' * 64) }); cpu_variants = @() }
    Check ('manifest: unsafe file name "{0}" is a schema error' -f $bn) (@(Test-PLlmManifestSchema $bm | Where-Object { $_ -match 'unsafe file name' }).Count -eq 1)
}
$bm = [pscustomobject]@{ schema = 1; core_modules = @([pscustomobject]@{ file = 'ggml.dll'; sha256 = 'xyz' }); cpu_variants = @() }
Check 'manifest: malformed sha256 field is a schema error' (@(Test-PLlmManifestSchema $bm | Where-Object { $_ -match 'bad sha256' }).Count -eq 1)
$b = New-FakeBuild; $m2 = Get-Content -LiteralPath $b.Path -Raw | ConvertFrom-Json; $m2.core_modules = @(); ($m2 | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $b.Path -Encoding ascii
(Get-PLlmFileSha256 $b.Path) + '  x' | Set-Content -LiteralPath ($b.Path + '.sha256') -Encoding ascii; $r = Verify-Fake $b
Check 'manifest: empty core_modules (with a matching sidecar) can never be Verified' ((-not $r.Verified) -and ($r.Problems -match 'core_modules is missing or empty'))
$b = New-FakeBuild; [IO.File]::WriteAllText((Join-Path $b.Dir 'ggml-vulkan.dll'), 'x'); $r = Verify-Fake $b
$cand = Cand 'llama\llama-server.exe' $r.Verified @('AVX2') 100 $hostAvx2 -Problems @($r.Problems)
$s = Select-PLlmBuild @($cand)
Check 'manifest -> selection: an unexpected ggml-*.dll makes the build UNVERIFIED (never COMPATIBLE) and the reason is visible' (($s.Rows[0].Status -eq 'UNVERIFIED') -and ($s.Rows[0].Reason -match 'unlisted backend DLL: ggml-vulkan.dll') -and $s.Kind -eq 'UNVERIFIED')

# ---- GGUF header reader + estimate (synthetic GGUF files in a temp folder)
function New-TestGguf {
    param([string]$Path, [hashtable]$Kv, [string[]]$Order, [switch]$BadMagic, [int]$Version = 3)
    $fs = [IO.File]::Create($Path); $bw = New-Object IO.BinaryWriter($fs)
    $bw.Write([uint32]$(if ($BadMagic) { 0x12345678 } else { 0x46554747 })); $bw.Write([uint32]$Version); $bw.Write([uint64]0); $bw.Write([uint64]$Order.Count)
    foreach ($k in $Order) {
        $kb = [Text.Encoding]::UTF8.GetBytes($k); $bw.Write([uint64]$kb.Length); $bw.Write($kb); $v = $Kv[$k]
        if ($v -is [string]) { $bw.Write([uint32]8); $vb = [Text.Encoding]::UTF8.GetBytes($v); $bw.Write([uint64]$vb.Length); $bw.Write($vb) }
        elseif ($v -is [array]) { $bw.Write([uint32]9); $bw.Write([uint32]4); $bw.Write([uint64]$v.Count); foreach ($x in $v) { $bw.Write([uint32]$x) } }
        else { $bw.Write([uint32]4); $bw.Write([uint32]$v) }
    }
    $bw.Write([byte[]](New-Object byte[] 64)); $bw.Flush(); $fs.Dispose()
}
$gd = Join-Path ([IO.Path]::GetTempPath()) ('pllm-gguf-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $gd | Out-Null
$ord = @('general.architecture', 'llama.block_count', 'llama.embedding_length', 'llama.attention.head_count', 'llama.attention.head_count_kv', 'llama.attention.key_length', 'tokenizer.ggml.model')
$kv3b = @{ 'general.architecture' = 'llama'; 'llama.block_count' = 28; 'llama.embedding_length' = 3072; 'llama.attention.head_count' = 24; 'llama.attention.head_count_kv' = 8; 'llama.attention.key_length' = 128; 'tokenizer.ggml.model' = 'gpt2' }
$g1 = Join-Path $gd 'ok.gguf'; New-TestGguf $g1 $kv3b $ord
$meta = Read-PLlmGgufMetadata $g1
Check 'GGUF: header parsed (arch, layers, embedding, heads, kv heads, key length)' ($meta.Ok -and $meta.Arch -eq 'llama' -and $meta.BlockCount -eq 28 -and $meta.EmbeddingLength -eq 3072 -and $meta.HeadCount -eq 24 -and $meta.HeadCountKv -eq 8 -and $meta.KeyLength -eq 128)
$e4k = Get-PLlmMemoryEstimate 1.9GB $meta 4096
Check 'estimate: KV cache for a 28-layer / 8-kv-head / 128-dim model at 4096 ctx is 448 MiB (known llama.cpp figure)' ([math]::Abs($e4k.KvBytes / 1MB - 448) -lt 0.01) ($e4k.KvBytes / 1MB)
$e8k = Get-PLlmMemoryEstimate 1.9GB $meta 8192
Check 'estimate: doubling the context doubles the KV cache and leaves the weights unchanged' (([math]::Abs($e8k.KvBytes / $e4k.KvBytes - 2) -lt 1e-9) -and $e8k.WeightsBytes -eq $e4k.WeightsBytes)
Check 'estimate: confidence is "metadata" when computed from the header' ($e4k.Confidence -eq 'metadata' -and $e4k.Notes.Count -eq 0)
$g2 = Join-Path $gd 'bad.gguf'; New-TestGguf $g2 $kv3b $ord -BadMagic
Check 'GGUF: bad magic -> Ok=false with a reason (no exception)' ((-not (Read-PLlmGgufMetadata $g2).Ok) -and (Read-PLlmGgufMetadata $g2).Reason -match 'bad magic')
$g3 = Join-Path $gd 'tiny.gguf'; [IO.File]::WriteAllBytes($g3, [byte[]](1, 2, 3))
Check 'GGUF: truncated/tiny file -> Ok=false' (-not (Read-PLlmGgufMetadata $g3).Ok)
Check 'GGUF: missing file -> Ok=false with a reason' ((-not (Read-PLlmGgufMetadata (Join-Path $gd 'nope.gguf')).Ok) -and (Read-PLlmGgufMetadata (Join-Path $gd 'nope.gguf')).Reason -match 'could not read')
$g4 = Join-Path $gd 'noarch.gguf'; New-TestGguf $g4 @{ 'llama.block_count' = 4 } @('llama.block_count', 'tokenizer.ggml.model') 
Check 'GGUF: no general.architecture -> Ok=false' (-not (Read-PLlmGgufMetadata $g4).Ok)
$g5 = Join-Path $gd 'perlayer.gguf'; New-TestGguf $g5 @{ 'general.architecture' = 'llama'; 'llama.block_count' = 4; 'llama.embedding_length' = 1024; 'llama.attention.head_count' = 16; 'llama.attention.head_count_kv' = @(2, 8, 4, 2); 'tokenizer.ggml.model' = 'x' } @('general.architecture', 'llama.block_count', 'llama.embedding_length', 'llama.attention.head_count', 'llama.attention.head_count_kv', 'tokenizer.ggml.model')
$m5 = Read-PLlmGgufMetadata $g5
Check 'GGUF: per-layer kv-head arrays are accepted and the largest value is used (conservative)' ($m5.Ok -and $m5.HeadCountKv -eq 8)
$eLow = Get-PLlmMemoryEstimate 2GB (Read-PLlmGgufMetadata $g4) 4096
Check 'estimate: unusable metadata -> confidence "low", KV unknown, explicit note (no pretend precision)' (($eLow.Confidence -eq 'low') -and ($null -eq $eLow.KvBytes) -and ($eLow.Notes -join ' ') -match 'could not be computed')
Check 'estimate: expected need always exceeds the bare minimum (overhead is added)' (($e4k.ExpectedBytes -gt $e4k.MinBytes) -and ($eLow.ExpectedBytes -gt $eLow.MinBytes))

# ---- memory verdicts (deterministic fake readings; the real machine is never touched)
function Mem($t, $a, $c = $null) { [pscustomobject]@{ TotalBytes = [double]$t; AvailBytes = [double]$a; CommitAvailBytes = $c } }
$v = Get-PLlmMemoryVerdict $e4k (Mem 8GB 3.8GB)
Check 'memory: ample RAM -> PASS' ($v.Verdict -eq 'PASS' -and $v.Measured)
$v = Get-PLlmMemoryVerdict $e4k (Mem 8GB 2.6GB)
Check 'memory: free RAM close to the expected need -> WARN (tight) with remedies and no guarantee wording' (($v.Verdict -eq 'WARN') -and $v.Kind -eq 'tight' -and ($v.Remedies.Count -ge 2) -and (($v.Remedies -join ' ') -match 'not guaranteed|might fit|may help'))
$v = Get-PLlmMemoryVerdict $e4k (Mem 8GB 1.2GB)
Check 'memory: low available RAM -> BLOCK (dynamic) with an actionable explanation' (($v.Verdict -eq 'BLOCK') -and $v.Kind -eq 'dynamic' -and ($v.Reasons -join ' ') -match 'Only 1\.20 GB' -and ($v.Remedies -join ' ') -match 'Close memory-hungry')
$big = Get-PLlmMemoryEstimate 7.6GB $meta 4096
$v = Get-PLlmMemoryVerdict $big (Mem 8GB 7.5GB)
Check 'memory: model larger than the safe budget -> BLOCK (static) even with the whole PC free' (($v.Verdict -eq 'BLOCK') -and $v.Kind -eq 'static' -and ($v.Reasons -join ' ') -match 'even with every other program closed')
$v32 = Get-PLlmMemoryVerdict (Get-PLlmMemoryEstimate 1.9GB $meta 65536) (Mem 8GB 6GB)
Check 'memory: raising CONTEXT can turn a PASS into a WARN/BLOCK (KV cache is counted)' ((Get-PLlmMemoryVerdict $e4k (Mem 8GB 6GB)).Verdict -eq 'PASS' -and $v32.Verdict -ne 'PASS')
Check 'memory: a lower CONTEXT suggestion is offered only when it is smaller than the current one' (($null -eq $v32.SuggestedContext) -or ($v32.SuggestedContext -lt 65536))
$v = Get-PLlmMemoryVerdict $eLow (Mem 8GB 6GB)
Check 'memory: unknown metadata -> a clear note and never a BLOCK on a guess' (($v.Verdict -ne 'BLOCK') -and ($v.Confidence -eq 'low') -and (($v.Notes -join ' ') -match 'uncertain'))
Check 'memory: weights alone larger than the machine budget still BLOCK without metadata (reliable lower bound)' ((Get-PLlmMemoryVerdict (Get-PLlmMemoryEstimate 7.8GB $null 4096) (Mem 8GB 7GB)).Verdict -eq 'BLOCK')
$v = Get-PLlmMemoryVerdict $e4k $null
Check 'memory: measurement failure -> explicit WARN "could not be measured", never PASS' (($v.Verdict -eq 'WARN') -and (-not $v.Measured) -and ($v.Reasons -join ' ') -match 'could not be measured')
$v = Get-PLlmMemoryVerdict $e4k (Mem 8GB 3.8GB 0.3GB)
Check 'memory: tight Windows commit limit turns a PASS into a WARN with its own reason' (($v.Verdict -eq 'WARN') -and $v.Kind -eq 'commit' -and ($v.Reasons -join ' ') -match 'commit')
$env:PORTABLE_LLM_TEST_MEMORY = '8589934592,4294967296'; $mi = Get-PLlmMemoryInfo
Check 'memory provider: PORTABLE_LLM_TEST_MEMORY seam returns the injected numbers (test-only)' ($mi.TotalBytes -eq 8589934592 -and $mi.AvailBytes -eq 4294967296 -and [math]::Round($mi.UsedPct) -eq 50)
$env:PORTABLE_LLM_TEST_MEMORY = 'garbage'; Check 'memory provider: malformed seam value -> $null (unmeasured), not a made-up reading' ($null -eq (Get-PLlmMemoryInfo))
Remove-Item Env:\PORTABLE_LLM_TEST_MEMORY

# ---- launch gate: a BLOCK never reaches the server-start code
$script:startCalls = 0; $script:notes = @()
$startBlock = { param($vv) $script:startCalls++; return 0 }
$notify = { param($stage, $vv) $script:notes += ('{0}:{1}' -f $stage, $vv.Verdict) }
$readMeta = { param($p) Read-PLlmGgufMetadata $p }
function Gate($provider, [bool]$allow = $false, $confirm = $null, [double]$size = 1.9GB, [int]$ctx = 4096) {
    $script:startCalls = 0; $script:notes = @()
    Invoke-PLlmLaunchGate -ModelPath $g1 -FileBytes $size -Context $ctx -MemoryProvider $provider -MetadataReader $readMeta -AllowOverride $allow -Confirm $confirm -Notify $notify -Start $startBlock
}
$o = Gate { Mem 8GB 4GB }
Check 'gate: ample memory -> server start called exactly once' ($o.Outcome -eq 'Started' -and $script:startCalls -eq 1 -and $o.Final.Verdict -eq 'PASS')
Check 'gate: an unchanged result is reported ONCE (no duplicate warnings on the recheck)' (@($script:notes).Count -eq 1)
$o = Gate { Mem 8GB 1.0GB }
Check 'gate: BLOCK without override -> Outcome Blocked and the start code is NEVER invoked' ($o.Outcome -eq 'Blocked' -and $script:startCalls -eq 0 -and -not $o.Started)
$o = Gate { Mem 8GB 1.0GB } $true
Check 'gate: BLOCK with explicit override -> starts, and OverrideUsed is recorded' ($o.Outcome -eq 'Started' -and $script:startCalls -eq 1 -and $o.OverrideUsed -and $o.First.Verdict -eq 'BLOCK')
$o = Gate { Mem 8GB 1.0GB } $false { param($vv) $false }
Check 'gate: user declines the typed confirmation -> not started' ($o.Outcome -eq 'Blocked' -and $script:startCalls -eq 0)
$o = Gate { Mem 8GB 1.0GB } $false { param($vv) $true }
Check 'gate: user confirms -> started with OverrideUsed' ($o.Outcome -eq 'Started' -and $o.OverrideUsed -and $script:startCalls -eq 1)
$script:seq = 0; $changing = { $script:seq++; if ($script:seq -le 1) { Mem 8GB 4GB } else { Mem 8GB 0.8GB } }
$o = Gate $changing
Check 'gate: memory collapses between preflight and launch -> BlockedAtLaunch, server never started' ($o.Outcome -eq 'BlockedAtLaunch' -and $script:startCalls -eq 0 -and $o.First.Verdict -eq 'PASS' -and $o.Final.Verdict -eq 'BLOCK')
Check 'gate: the changed result is reported (preflight then recheck)' (($script:notes -join ',') -eq 'preflight:PASS,recheck:BLOCK')
$o = Gate { Mem 8GB 2.6GB }
Check 'gate: WARN does not block; the server starts and the warning was shown once' ($o.Outcome -eq 'Started' -and $o.Final.Verdict -eq 'WARN' -and @($script:notes).Count -eq 1)
$o = Gate { $null }
Check 'gate: memory check returns nothing -> explicit WARN diagnostic, start allowed, never a silent PASS' ($o.Outcome -eq 'Started' -and $o.Final.Verdict -eq 'WARN' -and (-not $o.Final.Measured))
$o = Gate { throw 'WMI exploded' }
Check 'gate: memory provider throws -> treated as unmeasured WARN, no crash' ($o.Outcome -eq 'Started' -and (-not $o.Final.Measured) -and $o.Final.Verdict -eq 'WARN')
$o = Gate { Mem 8GB 4GB } $false $null 7.9GB
Check 'gate: model larger than the PC can hold -> Blocked, start never invoked' ($o.Outcome -eq 'Blocked' -and $script:startCalls -eq 0 -and $o.First.Kind -eq 'static')
$o = Invoke-PLlmLaunchGate -ModelPath (Join-Path $gd 'nope.gguf') -FileBytes 1.9GB -Context 4096 -MemoryProvider { Mem 8GB 4GB } -MetadataReader $readMeta -Start $startBlock
Check 'gate: unreadable model header -> low-confidence estimate with an explanatory note, still decides' ($o.Estimate.Confidence -eq 'low' -and @($o.Final.Notes).Count -ge 1)

# ---- runtime evidence: feed llama.cpp-format lines through the real monitor code and read what the dashboard would show
$logFx = @(
 'load_backend: loaded CPU backend from C:\x\ggml-cpu-haswell.dll',
 'system_info: n_threads = 4 (n_threads_batch = 4) / 8 | CPU : SSE3 = 1 | SSSE3 = 1 | AVX = 1 | AVX2 = 1 | F16C = 1 | FMA = 1 | BMI2 = 1 |',
 'llama_context: n_ctx         = 4096',
 'srv  start: listening on http://127.0.0.1:8080',
 'srv  update_slots: all slots are idle',
 'slot launch_slot_: id  0 | task 0 | processing task, is_child = 0',
 'slot      release: id  0 | task 0 | stop processing: n_tokens = 223, truncated = 0')
function New-RtState($pred = 'haswell', $kind = 'VERIFIED') {
    $caps = [pscustomobject]@{ Mode = 'Ansi'; Color = $false; Unicode = $false; Palette256 = $true; Width = 120; Height = 40 }
    $w = New-Object IO.StringWriter
    New-PLlmMonitorState -writer $w -logPath 'logs/x/session.log' -SessionDir 'logs/x' -ModelName 'm.gguf' -Url 'http://127.0.0.1:8080' -HostFeatures $hostAvx2 -PredictedVariant $pred -HostText 'cpu' `
        -VerificationText 'v' -VerificationOk ($kind -eq 'VERIFIED') -VerificationKind $kind -VerificationProblems @() -OpenBrowser $false -Quiet $true -caps $caps -dash $true `
        -ModelBytes 2GB -ContextRequested 4096 -HostProbe $null -Preflight (Get-PLlmMemoryVerdict $e4k (Mem 8GB 3.8GB)) -SelectedBuild 'llama\llama-server.exe' -SelectionSummary 'Selected llama\llama-server.exe (VERIFIED)'
}
function Rt($st) { Update-PLlmServerState $st $null; New-PLlmViewModel $st }
$st = New-RtState
$vm = Rt $st
Check 'runtime: before any log line the backend is Unknown (the scorer prediction is only "Expected")' (($vm.Compat.Actual -eq 'Unknown') -and ($vm.Compat.Expected -eq 'haswell') -and ($vm.Compat.Match -eq 'unknown') -and $vm.State -eq 'Starting')
Check 'runtime: preflight result and selected build are visible from the first frame' (($vm.Sys.PreflightText -match '^PASS') -and ($vm.Compat.Selected -match 'llama\\llama-server.exe - verified against local manifest') -and (@($st.Events | Where-Object { $_.Text -match 'Memory preflight PASS' }).Count -eq 0 -or $true))
Invoke-PLlmLine $st $logFx[0]; $vm = Rt $st
Check 'runtime: after "loaded CPU backend" the actual backend is confirmed and compared with the prediction' (($vm.Compat.Actual -eq 'haswell') -and ($vm.Compat.Match -eq 'match') -and ($vm.Compat.ActualNote -match 'reported by llama.cpp'))
Invoke-PLlmLine $st 'load_backend: loaded CPU backend from C:\x\ggml-cpu-x64.dll'; $vm = Rt $st
Check 'runtime: conflicting backend paths -> Unknown/ambiguous, not either one' (($vm.Compat.Actual -eq 'Unknown') -and ($vm.Compat.ActualNote -match 'several different') -and ($vm.Compat.Match -eq 'unknown'))
$st = New-RtState 'haswell'; Invoke-PLlmLine $st 'load_backend: loaded CPU backend from C:\x\ggml-cpu-x64.dll'; $vm = Rt $st
Check 'runtime: actual backend (x64) differs from the predicted variant (haswell) -> "mismatch" and a WARN finding' (($vm.Compat.Match -eq 'mismatch') -and (@($vm.Compat.Findings | Where-Object { $_.Level -eq 'WARN' -and $_.Text -match 'x64.*haswell' }).Count -eq 1))
$st = New-RtState; Invoke-PLlmLine $st $logFx[3]; $vm = Rt $st
Check 'runtime: a listening socket is NOT readiness (state Loading Model, detail says so)' (($vm.State -eq 'Loading Model') -and ($vm.StateDetail -match 'waiting for readiness'))
Invoke-PLlmLine $st $logFx[4]; $vm = Rt $st
Check 'runtime: llama.cpp reports the model loaded -> Ready, "waiting for first request"' (($vm.State -eq 'Ready') -and ($vm.StateDetail -match 'waiting for first request'))
Invoke-PLlmLine $st $logFx[5]; $vm = Rt $st
Check 'runtime: a task start line -> "request in progress"' ($vm.StateDetail -match 'request in progress')
Invoke-PLlmLine $st $logFx[6]; $vm = Rt $st
Check 'runtime: the task end line clears "request in progress"' ($vm.StateDetail -notmatch 'request in progress')
Check 'runtime: task regexes match the real llama.cpp format strings' (($logFx[5] -match $PLlmRx_TaskStart -and $Matches[1] -eq '0') -and ($logFx[6] -match $PLlmRx_TaskEnd -and $Matches[1] -eq '0') -and ('srv  start: listening' -notmatch $PLlmRx_TaskStart))
$st = New-RtState; Invoke-PLlmLine $st 'slot launch_slot_: id  0 | task 7 | processing task, is_child = 0'; $st.ServerState = 'Ready'
foreach ($l in $lines) { Invoke-PLlmLine $st $l }; $vm = Rt $st
Check 'runtime: completed requests update the performance values from the real timing lines' (($vm.Perf.Completed -eq 2) -and ($vm.Perf.Last.GenTps -eq 7.93) -and ($vm.Perf.Stats.GenAvgTps -gt 7.5))
$st = New-RtState; $st.ServerState = 'Starting'; Invoke-PLlmLine $st 'srv  operator(): couldn''t bind HTTP server socket, hostname: 127.0.0.1, port: 8080'
Check 'runtime: a server error line produces ONE actionable event (and repeats are not duplicated)' ((@($st.Events | Where-Object { $_.Level -eq 'crit' -and $_.Text -match 'port is already in use' }).Count -eq 1))
Invoke-PLlmLine $st 'srv  operator(): couldn''t bind HTTP server socket, hostname: 127.0.0.1, port: 8080'
Check 'runtime: the identical error repeated does not add another event' ((@($st.Events | Where-Object { $_.Text -match 'port is already in use' }).Count -eq 1))
$st = New-RtState 'haswell' 'OVERRIDE'; $vm = Rt $st
Check 'override: dashboard shows a red OVERRIDE alert and never the verified wording' ((@($vm.Alerts | Where-Object { $_.Text -match 'OVERRIDE' }).Count -eq 1) -and ($vm.Compat.Selected -match 'OVERRIDE') -and ($vm.Compat.Selected -notmatch 'verified against'))
$fr = (Build-PLlmFrame -V $vm -Width 120 -Height 40 -Color $false -Unicode $false) -join "`n"
Check 'dashboard: SYSTEM shows the preflight result and COMPATIBILITY shows the selected build' (($fr -match 'Preflight\s+PASS') -and ($fr -match 'Selected\s+llama\\llama-server.exe'))
$stB = New-RtState; $stB.Preflight = Get-PLlmMemoryVerdict $e4k (Mem 8GB 1.0GB); $vmB = Rt $stB
$frB = (Build-PLlmFrame -V $vmB -Width 120 -Height 40 -Color $false -Unicode $false) -join "`n"
Check 'dashboard: a long preflight reason is wrapped over several rows, not truncated with an ellipsis' (($frB -match 'Preflight\s+BLOCK') -and ($frB -match 'paging') -and ($frB -notmatch '\.\.\.\s*$'))
Remove-Item -LiteralPath $gd -Recurse -Force -ErrorAction SilentlyContinue


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
if (-not $onWindows) { Skip 'launcher scenarios (12 checks: missing exe, no models, bad choice, dry run, CORS/host args, tampered DLL, memory BLOCK/override/PASS)' 'they need the Windows host probe (cpu-detect.ps1 / kernel32); run this file on Windows' }
else { try {
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
    # memory preflight through the REAL launcher (deterministic: memory is injected, the machine is not touched)
    $s = New-Sandbox $true 1
    $env:PORTABLE_LLM_TEST_MEMORY = '1000000,500000'; $r = Run-Launcher $s @('-Choice', '1', '-NoBrowser')
    Check 'launcher: memory BLOCK -> exit 6 and "No server process was created"' (($r.Code -eq 6) -and ($r.Out -match 'No server process was created') -and ($r.Out -match 'Memory preflight: BLOCK')) "code=$($r.Code)"
    $r = Run-Launcher $s @('-Choice', '1', '-NoBrowser', '-AllowLowMemory')
    Check 'launcher: -AllowLowMemory is an explicit override and is reported' (($r.Code -eq 0) -and ($r.Out -match 'overridden')) "code=$($r.Code)"
    $env:PORTABLE_LLM_TEST_MEMORY = '17179869184,12884901888'; $r = Run-Launcher $s @('-Choice', '1', '-NoBrowser')
    Check 'launcher: ample injected memory -> preflight PASS' (($r.Code -eq 0) -and ($r.Out -match 'Memory preflight: PASS')) "code=$($r.Code)"
    Remove-Item Env:\PORTABLE_LLM_TEST_MEMORY -ErrorAction SilentlyContinue
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Host ''; Write-Host ('{0} failure(s), {1} skipped' -f $fails, $skips); exit $(if ($fails) { 1 } else { 0 })
