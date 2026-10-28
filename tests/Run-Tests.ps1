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
if (-not $onWindows) { Skip 'launcher scenarios (9 checks: missing exe, no models, bad choice, dry run, CORS/host args, tampered DLL)' 'they need the Windows host probe (cpu-detect.ps1 / kernel32); run this file on Windows' }
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
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Host ''; Write-Host ('{0} failure(s), {1} skipped' -f $fails, $skips); exit $(if ($fails) { 1 } else { 0 })
