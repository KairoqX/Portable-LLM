# Portable-LLM live server monitor.  ASCII only.  Dot-sourced by launcher.ps1
# (requires lib\PortableLlm.Core.ps1, PortableLlm.Sys.ps1, PortableLlm.Tui.ps1).
#
# Starts llama-server with stdout/stderr redirected to files, then tails those files while the server runs:
#   - every server line is saved to the session log; llama.cpp's timing lines are parsed per request
#   - parsed facts update ONE state object; the dashboard (lib\PortableLlm.Tui.ps1) only renders a view of it
#   - when the console cannot host a dashboard (output redirected, PORTABLE_LLM_UI=log) the original line-by-line
#     output is used instead
# It never invents numbers: every figure shown comes from a line llama.cpp wrote, a Windows API, or is marked "(computed)".

function New-PLlmTail {
    param([string]$Path)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Stream = $fs; Reader = $sr; Partial = '' }
}

function Read-PLlmTailLines {
    # Returns complete new lines; a trailing partial line is held back until its newline arrives (or -Flush).
    param($Tail, [switch]$Flush)
    $text = $Tail.Reader.ReadToEnd()
    if ($text.Length -eq 0 -and $Tail.Partial.Length -eq 0) { return @() }
    $parts = ($Tail.Partial + $text) -split "`n"
    $lines = @()
    if ($Flush) {
        $Tail.Partial = ''
        $lines = $parts
    } else {
        $Tail.Partial = $parts[$parts.Count - 1]
        if ($parts.Count -gt 1) { $lines = $parts[0..($parts.Count - 2)] }
    }
    $clean = @()
    foreach ($l in $lines) { $clean += $l.TrimEnd("`r") }
    return $clean
}

function Write-PLlmOut {
    # Console + session log in one place.
    param($State, [string]$Text, [string]$Color = 'Gray', [switch]$LogOnly)
    if ($State.Log) { try { $State.Log.WriteLine($Text) } catch { } }
    if (-not $LogOnly -and $State.Echo) { Write-Host $Text -ForegroundColor $Color }
}

function Get-PLlmLevelColor {
    param([string]$Level)
    switch ($Level) { 'OK' { return 'Green' } 'INFO' { return 'Cyan' } 'WARN' { return 'Yellow' } 'FAIL' { return 'Red' } default { return 'Gray' } }
}

function Write-PLlmFindings {
    param($State)
    $findings = Test-PLlmBackendAgainstHost -HostFeatures $State.HostFeatures -PredictedVariant $State.Predicted -BackendInfo $State.Backend -SysInfo $State.SysInfo -BackendAmbiguous $State.BackendAmbiguous
    foreach ($f in $findings) {
        Write-PLlmOut $State ('   [{0}] {1}' -f $f.Level, $f.Text) (Get-PLlmLevelColor $f.Level)
    }
}

function Write-PLlmReadyBanner {
    param($State)
    $secs = [int]((Get-Date) - $State.StartedAt).TotalSeconds
    $line = '=' * 78
    Write-PLlmOut $State ''
    Write-PLlmOut $State $line 'Green'
    Write-PLlmOut $State (' HTTP SERVER LISTENING  {0}   (after {1} s; the model may still be loading - wait for the first answer)' -f $State.Url, $secs) 'Green'
    Write-PLlmOut $State $line 'Green'
    $b = 'UNKNOWN (llama.cpp has not logged a single "loaded CPU backend" line yet)'
    if ($State.BackendAmbiguous) { $b = 'UNKNOWN (llama.cpp logged several different CPU backend paths)' }
    if ($State.Backend) { $b = ('{0}{1}  <-  {2}' -f $State.Backend.Backend, $(if ($State.Backend.Variant) { ' / ' + $State.Backend.Variant } else { '' }), $State.Backend.Path) }
    $isa = 'UNKNOWN (no system_info line seen yet)'
    if ($State.SysInfo) {
        $isa = ($State.SysInfo.Enabled -join ' ')
        if ([string]::IsNullOrEmpty($isa)) { $isa = '(no SIMD flags enabled in the loaded backend)' }
    }
    Write-PLlmOut $State (' Build   : {0}' -f $(if ($State.BuildLine) { $State.BuildLine } else { 'UNKNOWN (no build line seen yet)' })) 'White'
    Write-PLlmOut $State (' Backend : {0}' -f $b) 'White'
    Write-PLlmOut $State (' ISA used: {0}' -f $isa) 'White'
    Write-PLlmOut $State '           (compile-time flags of the loaded backend as printed by llama.cpp; not a test of this CPU)' 'DarkGray'
    if ($State.SysInfo -and $null -ne $State.SysInfo.Threads) { Write-PLlmOut $State (' Threads : {0}' -f $State.SysInfo.Threads) 'White' }
    Write-PLlmOut $State (' Host    : {0}' -f $State.HostText) 'White'
    Write-PLlmOut $State (' Build ISA verification: {0}' -f $State.VerificationText) $(if ($State.VerificationOk) { 'Cyan' } else { 'Yellow' })
    Write-PLlmOut $State (' Model   : {0}' -f $State.ModelName) 'White'
    Write-PLlmOut $State (' Log     : {0}' -f $State.LogPath) 'White'
    Write-PLlmFindings $State
    $State.FindingsShown = $true
    Write-PLlmOut $State $line 'Green'
    Write-PLlmOut $State ' Speeds are printed after every request. Press Ctrl+C in this window (or run STOP.bat) to stop.' 'Green'
    Write-PLlmOut $State ''
}

function Write-PLlmLatestSummaryFile {
    param($State)
    try {
        $stats = Get-PLlmSessionStats $State.Session
        $lines = @()
        $lines += ('Portable-LLM latest summary  ({0})' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $lines += ('Model   : {0}' -f $State.ModelName)
        $lines += ('Host    : {0}' -f $State.HostText)
        $lines += ('Verified: {0}' -f $State.VerificationText)
        $lines += ('Tag     : {0}' -f (Format-PLlmTag $State.Backend $State.SysInfo $State.ModelName))
        if ($State.LastRequest) { $lines += (Format-PLlmRequestLine $State.LastRequest '') }
        $lines += (Format-PLlmSessionLine $stats)
        $lines += ('Full log: {0}' -f $State.LogPath)
        [System.IO.File]::WriteAllLines($State.LatestPath, $lines)
    } catch { }
}

function Add-PLlmCsvRow {
    param($State, $Req)
    try {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        if (-not (Test-Path -LiteralPath $State.CsvPath)) {
            'request,time,model,backend,variant,isa_flags,prompt_tokens,prompt_ms,prompt_tok_per_s,gen_tokens,gen_ms,gen_tok_per_s_reported_or_computed,gen_tok_per_s_from_ms_and_tokens,total_ms,total_tokens' |
                Out-File -LiteralPath $State.CsvPath -Encoding ascii
        }
        $be = ''; $va = ''; if ($State.Backend) { $be = $State.Backend.Backend; $va = $State.Backend.Variant }
        $isa = ''; if ($State.SysInfo) { $isa = ($State.SysInfo.Enabled -join ' ') }
        $f = { param($x) if ($null -eq $x) { '' } else { ([double]$x).ToString('0.###', $inv) } }
        $row = @($Req.Index, $Req.Time.ToString('s'), ('"' + $State.ModelName.Replace('"', '""') + '"'), $be, $va, ('"' + $isa + '"'),
                 $Req.PromptTokens, (& $f $Req.PromptMs), (& $f $Req.PromptTps), $Req.GenTokens, (& $f $Req.GenMs), (& $f $Req.GenTps), (& $f $Req.GenTpsComputed),
                 (& $f $Req.TotalMs), $Req.TotalTokens) -join ','
        Add-Content -LiteralPath $State.CsvPath -Value $row -Encoding ascii
    } catch { }
}

# ------------------------------------------------------------------------------------------------ events
function Add-PLlmEvent {
    # Short, meaningful events for the "Recent activity" panel.  Raw llama.cpp lines never go here (they stay in the log).
    param($State, [string]$Level, [string]$Text)
    [void]$State.Events.Add([pscustomobject]@{ Time = (Get-Date); Level = $Level; Text = $Text })
    if ($State.Events.Count -gt 100) { $State.Events.RemoveAt(0) }
    $State.Dirty = $true
    if ($State.Log) { try { $State.Log.WriteLine(('[event {0}] {1}' -f $Level, $Text)) } catch { } }
}

function Update-PLlmFindings {
    # Re-evaluates backend-vs-host findings; each new WARN/FAIL text becomes one event.
    param($State)
    $State.Findings = @(Test-PLlmBackendAgainstHost -HostFeatures $State.HostFeatures -PredictedVariant $State.Predicted -BackendInfo $State.Backend -SysInfo $State.SysInfo -BackendAmbiguous $State.BackendAmbiguous)
    foreach ($f in $State.Findings) {
        if (($f.Level -eq 'WARN' -or $f.Level -eq 'FAIL') -and -not $State.FindingSeen.ContainsKey($f.Text)) {
            $State.FindingSeen[$f.Text] = $true
            Add-PLlmEvent $State $(if ($f.Level -eq 'FAIL') { 'crit' } else { 'warn' }) ('Compatibility: ' + $f.Text)
        }
    }
}

function Invoke-PLlmLine {
    # Handles ONE line of server output: log it, parse it, update state, record events.
    param($State, [string]$Line)
    [void]$State.LastLines.Add($Line)
    if ($State.LastLines.Count -gt 40) { $State.LastLines.RemoveAt(0) }

    $isErr = ($Line -match $PLlmRx_ErrorLine)
    $color = 'Gray'
    if ($isErr) { $color = 'Red' } elseif ($Line -match $PLlmRx_WarnLine) { $color = 'Yellow' }
    $shown = $true
    if ($State.Quiet -and $color -eq 'Gray') { $shown = $false }
    Write-PLlmOut $State $Line $color -LogOnly:(-not $shown)

    if ($isErr) {
        $State.LastErrorLine = $Line.Trim()
        $State.LastErrorHint = Get-PLlmErrorHint $Line
        $key = (($Line.ToLowerInvariant() -replace '\d+', '#') -replace '\s+', ' ')
        if ($key.Length -gt 80) { $key = $key.Substring(0, 80) }
        if (-not $State.ErrorSeen.ContainsKey($key) -and $State.ErrorSeen.Count -lt 20) {
            $State.ErrorSeen[$key] = $true
            $txt = $Line.Trim(); if ($txt.Length -gt 110) { $txt = $txt.Substring(0, 110) }
            if ($State.LastErrorHint) { $txt = $State.LastErrorHint }
            Add-PLlmEvent $State 'crit' $txt
        }
    }
    elseif ($Line -match $PLlmRx_WarnLine -and $State.Warnings.Count -lt 8 -and -not $State.Warnings.Contains($Line.Trim())) { [void]$State.Warnings.Add($Line.Trim()) }

    if ($Line -match $PLlmRx_CorsWarning -and -not $State.CorsWarned) {
        $State.CorsWarned = $true
        Write-PLlmOut $State '   [WARN] The server still reports permissive CORS (any website could script this local server). Check the --cors-origins setting.' 'Yellow'
        Add-PLlmEvent $State 'warn' 'Server reports permissive CORS; check --cors-origins'
    }

    if ($null -eq $State.BuildLine -and $Line -match $PLlmRx_BuildInfo) { $State.BuildLine = $Matches[1].Trim() }
    if ($null -eq $State.CtxReported -and $Line -match $PLlmRx_CtxReported) { $State.CtxReported = [int]$Matches[1] }
    if (-not $State.LoaderSeen -and $Line -match $PLlmRx_ModelLoadStart) { $State.LoaderSeen = $true; Add-PLlmEvent $State 'info' 'Loading model file' }
    if (-not $State.LogReady -and $Line -match $PLlmRx_ModelLoaded) { $State.LogReady = $true }

    $be = ConvertFrom-PLlmLoadBackendLine $Line
    $hadBackend = ($null -ne $State.Backend)
    if ($be -and $be.Backend -eq 'CPU') {
        [void]$State.CpuBackendsSeen.Add($be)
        $State.Backend = Get-PLlmResolvedBackend $State.CpuBackendsSeen
        $State.BackendAmbiguous = ($null -eq $State.Backend)
        if ($State.Backend -and -not $hadBackend) { Add-PLlmEvent $State 'info' ('llama.cpp loaded CPU backend: ' + $(if ($State.Backend.Variant) { $State.Backend.Variant } else { 'CPU' })) }
    }
    elseif ($be) { $State.OtherBackends += $be.Backend }

    $newFacts = $false
    if ($null -eq $State.SysInfo -and $Line -match $PLlmRx_SystemInfo) { $State.SysInfo = ConvertFrom-PLlmSystemInfo $Line; $newFacts = $true }
    if ($newFacts -or $be) {
        Update-PLlmFindings $State
        if ($State.Ready -and $State.FindingsShown) {
            Write-PLlmOut $State ' Update from llama.cpp output received after the banner:' 'Cyan'
            Write-PLlmFindings $State
        }
    }

    if (-not $State.Ready -and $Line -match $PLlmRx_Listening) {
        $State.Ready = $true            # "HTTP server listening" (existing meaning); the model may still be loading
        $State.ListeningSeen = $true
        Write-PLlmReadyBanner $State
        Add-PLlmEvent $State 'info' ('Server listening on ' + $State.Url + ' (model may still be loading)')
    }

    $ev = ConvertFrom-PLlmTimingLine $Line
    if ($ev -and $ev.Kind -eq 'Total' -and $State.Ready -and -not $State.FirstRequestChecked) {
        $State.FirstRequestChecked = $true
        Update-PLlmFindings $State
        Write-PLlmOut $State ' Backend/ISA status at the first completed request:' 'Cyan'
        Write-PLlmFindings $State
    }
    if ($ev) {
        $req = Add-PLlmTimingEvent -Session $State.Session -TimingEvent $ev
        if ($req) {
            $State.LastRequest = $req
            $tag = Format-PLlmTag $State.Backend $State.SysInfo $State.ModelName
            Write-PLlmOut $State ''
            Write-PLlmOut $State (Format-PLlmRequestLine $req $tag) 'Cyan'
            Write-PLlmOut $State (Format-PLlmSessionLine (Get-PLlmSessionStats $State.Session)) 'DarkCyan'
            Write-PLlmOut $State ''
            Add-PLlmCsvRow $State $req
            Write-PLlmLatestSummaryFile $State
            $txt = ('Request #{0} complete: {1} generation' -f $req.Index, (Get-PLlmRate $req.GenTps))
            if ($null -ne $req.GenTokens) { $txt += (' ({0} tokens, {1} s)' -f $req.GenTokens, (Format-PLlmNumber ($req.TotalMs / 1000.0) '0.0')) }
            Add-PLlmEvent $State 'ok' $txt
        }
    }
}

# ------------------------------------------------------------------------------------------------ readiness (HTTP, in-process, non-blocking)
function Step-PLlmHealth {
    # Asks llama.cpp's GET /health whether the model is loaded (503 = still loading).  Never blocks the loop:
    # one request is started, and its result is collected on a later tick.  Never throws.
    param($State)
    $h = $State.Health
    try {
        if ($null -ne $h.Async) {
            if ($h.Async.IsCompleted) {
                $code = $null
                try { $resp = $h.Req.EndGetResponse($h.Async); $code = [int]$resp.StatusCode; $resp.Close() }
                catch [System.Net.WebException] {
                    $resp = $_.Exception.Response
                    if ($resp) { $code = [int]$resp.StatusCode; $resp.Close() } else { $h.LastError = [string]$_.Exception.Status }
                }
                if ($null -ne $code) { if ($h.Status -ne $code) { $State.Dirty = $true }; $h.Status = $code; $h.At = Get-Date; $h.LastError = '' }
                $h.Async = $null; $h.Req = $null
            }
            elseif (((Get-Date) - $h.Started).TotalSeconds -gt 3) { try { $h.Req.Abort() } catch { } }
            return
        }
        $every = 1.0; if ($State.HealthReady) { $every = 5.0 }
        if ($h.Started -and ((Get-Date) - $h.Started).TotalSeconds -lt $every) { return }
        $req = [System.Net.HttpWebRequest]::Create($State.Url + '/health')
        $req.Method = 'GET'; $req.Proxy = $null; $req.KeepAlive = $false; $req.Timeout = 2000
        $h.Req = $req; $h.Started = Get-Date; $h.Async = $req.BeginGetResponse($null, $null)
    } catch { $h.Async = $null; $h.Req = $null; $h.LastError = $_.Exception.Message }
}

function Update-PLlmServerState {
    param($State, $Proc)
    $exited = $false; $code = $null
    if ($Proc) { try { $exited = $Proc.HasExited; if ($exited) { $code = [int]$Proc.ExitCode } } catch { } }
    $s = Get-PLlmServerState -Exited $exited -StoppedByUser $State.StoppedByUser -ExitCode $code -HealthStatus $State.Health.Status `
            -ListeningSeen $State.ListeningSeen -LoaderSeen $State.LoaderSeen -LogReady $State.LogReady
    if ($exited -and $null -eq $State.ExitedAt) { $State.ExitedAt = Get-Date }
    if ($s.State -ne $State.ServerState) {
        $old = $State.ServerState
        $State.ServerState = $s.State; $State.StateDetail = $s.Detail; $State.Dirty = $true
        if ($s.State -eq 'Ready') {
            $State.HealthReady = $true
            Add-PLlmEvent $State 'ok' 'Model loaded; server ready'
            if ($State.OpenBrowser -and -not $State.BrowserOpened) {
                $State.BrowserOpened = $true
                try { Start-Process $State.Url } catch { Add-PLlmEvent $State 'info' ('Could not open the browser automatically; open ' + $State.Url + ' yourself.') }
            }
        }
        elseif ($s.State -eq 'Loading Model' -and $old -eq 'Starting') { }
        elseif ($s.State -eq 'Error') { Add-PLlmEvent $State 'crit' ('Server stopped unexpectedly (exit code {0}): {1}' -f $code, (Get-PLlmExitHint $code)) }
        elseif ($s.State -eq 'Stopped') { Add-PLlmEvent $State 'info' 'Server stopped' }
    } else { $State.StateDetail = $s.Detail }
}

# ------------------------------------------------------------------------------------------------ system sampling (about once per second)
function Update-PLlmSystem {
    param($State, $Proc)
    $m = Get-PLlmMemoryInfo
    if ($m) {
        $prev = $State.MemLevel
        $lvl = Get-PLlmMemoryLevel -TotalBytes $m.TotalBytes -AvailBytes $m.AvailBytes -Previous $prev
        $State.Mem = $m
        if ($lvl -ne $prev) {
            $State.MemLevel = $lvl
            $txt = ('{0} free, {1}% of RAM in use' -f (Format-PLlmBytes $m.AvailBytes), (Format-PLlmNumber $m.UsedPct '0'))
            if ($lvl -eq 'crit') { Add-PLlmEvent $State 'crit' ('Memory critically low: ' + $txt) }
            elseif ($lvl -eq 'warn') { Add-PLlmEvent $State 'warn' ('Memory low: ' + $txt) }
            elseif ($prev -ne 'unknown') { Add-PLlmEvent $State 'ok' 'Memory pressure cleared' }
        }
    }
    $State.ProcMem = Get-PLlmProcessMemory $Proc
    $State.Dirty = $true
}

# ------------------------------------------------------------------------------------------------ view model
function New-PLlmViewModel {
    param($State)
    $d = $null; if ($State.HostProbe -and $State.HostProbe.Ok) { $d = $State.HostProbe.Data }
    $cpuName = 'Unknown'; $logical = $null
    $sup = [ordered]@{ 'SSE4.2' = $null; 'AVX' = $null; 'AVX2' = $null; 'AVX-512' = $null }
    if ($d) {
        if ($d.cpu_name) { $cpuName = [string]$d.cpu_name }
        if ($d.logical_cpus) { $logical = $d.logical_cpus }
        if ($d.pf) { $sup['SSE4.2'] = $d.pf.SSE42; $sup['AVX'] = $d.pf.AVX; $sup['AVX2'] = $d.pf.AVX2; $sup['AVX-512'] = $d.pf.AVX512 }
    }
    $end = Get-Date; if ($State.ExitedAt) { $end = $State.ExitedAt }
    $mem = $State.Mem
    $sys = [pscustomobject]@{
        CpuName = $cpuName; Logical = $logical; Support = $sup
        MemTotal = $(if ($mem) { $mem.TotalBytes } else { $null }); MemAvail = $(if ($mem) { $mem.AvailBytes } else { $null })
        MemUsedPct = $(if ($mem) { $mem.UsedPct } else { 0 }); MemLevel = $State.MemLevel
        ServerWorkingSet = $(if ($State.ProcMem) { $State.ProcMem.WorkingSet } else { $null })
        Uptime = ($end - $State.StartedAt)
    }

    $stLevel = 'info'; $stText = 'Starting'
    switch ($State.ServerState) {
        'Starting'      { $stText = 'Starting server' }
        'Loading Model' { $stText = 'Loading model...' }
        'Ready'         { $stLevel = 'ok'; $stText = $(if ($State.Health.Status -ne $null) { 'Loaded - server reports ready' } else { 'Loaded - per llama.cpp log' }) }
        'Error'         { $stLevel = 'crit'; $stText = 'Not loaded - server exited with an error' }
        'Stopped'       { $stLevel = 'unknown'; $stText = 'Server stopped' }
    }
    $ctxText = ('{0} tokens requested (llama.cpp has not reported it yet)' -f $State.CtxRequested); $ctxShort = [string]$State.CtxRequested
    if ($null -ne $State.CtxReported) {
        $ctxText = ('{0} tokens (reported by llama.cpp)' -f $State.CtxReported); $ctxShort = [string]$State.CtxReported
        if ($State.CtxRequested -and $State.CtxRequested -ne $State.CtxReported) { $ctxText += (', {0} requested' -f $State.CtxRequested) }
    }
    $model = [pscustomobject]@{ Name = $State.ModelName; SizeBytes = $State.ModelBytes; Status = $stText; StatusLevel = $stLevel; CtxText = $ctxText; CtxShort = $ctxShort }

    $stats = Get-PLlmSessionStats $State.Session
    $perf = [pscustomobject]@{ Completed = $stats.Requests; Incomplete = $stats.Incomplete; Last = $State.LastRequest; Stats = $stats }

    # compatibility: expected (scorer) vs actual (llama.cpp's own output); unknown stays unknown, with the reason
    $exp = 'Unknown'; $expNote = ''
    if ($State.Predicted) { $exp = $State.Predicted; $expNote = '(bundled scorer, run on this CPU)' }
    elseif ($State.HostProbe -and -not $State.HostProbe.Ok) { $expNote = ('host probe failed: ' + $State.HostProbe.Reason) }
    elseif ($d -and -not $d.scorer.available) { $expNote = ('bundled scorer unavailable: ' + $d.scorer.reason) }
    else { $expNote = 'bundled scorer gave no single best variant' }
    $act = 'Unknown'; $actNote = ''
    if ($State.Backend) {
        $act = $(if ($State.Backend.Variant) { [string]$State.Backend.Variant } else { [string]$State.Backend.Backend })
        $actNote = '(reported by llama.cpp)'
    }
    elseif ($State.BackendAmbiguous) { $actNote = 'llama.cpp logged several different CPU backend paths' }
    else { $actNote = 'llama.cpp has not logged a "loaded CPU backend" line yet' }
    $match = 'unknown'
    if ($State.Backend -and $State.Backend.Variant -and $State.Predicted) { $match = $(if ($State.Backend.Variant -eq $State.Predicted) { 'match' } else { 'mismatch' }) }
    $isa = 'Unknown (no system_info line from llama.cpp yet)'
    if ($State.SysInfo) { $isa = $(if ($State.SysInfo.Enabled.Count -gt 0) { ($State.SysInfo.Enabled -join ' ') } else { 'no SIMD flags enabled in the loaded backend' }) }
    $intShort = ''; $intLevel = 'info'
    switch ($State.VerificationKind) {
        'VERIFIED' { $intShort = 'Files match the local manifest (hash check only; the manifest is unsigned, so origin is not established).' }
        'OVERRIDE' { $intShort = 'Build was rejected for this CPU and is running because of an override; compatibility is NOT established.'; $intLevel = 'warn' }
        default    { $p1 = 'no build manifest'; if ($State.VerificationProblems -and @($State.VerificationProblems).Count -gt 0) { $p1 = @($State.VerificationProblems)[0] }
                     $intShort = ('UNVERIFIED: ' + $p1 + '. Nothing was checked against a manifest.'); $intLevel = 'warn' }
    }
    $find = @($State.Findings | Where-Object { $_.Level -eq 'WARN' -or $_.Level -eq 'FAIL' })
    $compat = [pscustomobject]@{ Expected = $exp; ExpectedNote = $expNote; Actual = $act; ActualNote = $actNote; Match = $match; Isa = $isa; IntegrityShort = $intShort; IntegrityLevel = $intLevel; Findings = $find }

    $alerts = @()
    if ($State.ServerState -eq 'Error') {
        $a = 'Server exited with an error.'; if ($State.LastErrorHint) { $a = $State.LastErrorHint }
        $alerts += [pscustomobject]@{ Level = 'crit'; Text = $a }
    }
    if ($State.MemLevel -eq 'crit' -and $mem) { $alerts += [pscustomobject]@{ Level = 'crit'; Text = ('Memory critically low: ' + (Format-PLlmBytes $mem.AvailBytes) + ' free.') } }
    elseif ($State.MemLevel -eq 'warn' -and $mem) { $alerts += [pscustomobject]@{ Level = 'warn'; Text = ('Memory low: ' + (Format-PLlmBytes $mem.AvailBytes) + ' free.') } }

    $notice = $null
    if ($State.Notice) {
        if ((Get-Date) -lt $State.NoticeUntil) { $notice = $State.Notice } else { $State.Notice = $null; $State.Dirty = $true }   # expired: clear once, redraw once
    }

    $diag = @()
    if ($State.ShowDiag) { $diag = @(Get-PLlmDiagRows $State) }
    $nShow = 5
    $evAll = @($State.Events)
    return [pscustomobject]@{
        Version = $script:PLlmVersion; State = $State.ServerState; StateDetail = $State.StateDetail; Url = $State.Url
        Alerts = $alerts; Model = $model; Perf = $perf; Sys = $sys; Compat = $compat
        Events = $evAll; Notice = $notice; ShowDiag = $State.ShowDiag; Diag = $diag
    }
}

function Get-PLlmDiagRows {
    param($State)
    $rows = New-Object System.Collections.ArrayList
    function Add-D([string]$Label, [string]$Text, [string]$Level = 'info') { [void]$rows.Add([pscustomobject]@{ Label = $Label; Text = $Text; Level = $Level }) }
    Add-D 'Build' $(if ($State.BuildLine) { $State.BuildLine } else { 'Unknown (no build line from llama.cpp yet)' })
    Add-D 'Backend' $(if ($State.Backend) { $State.Backend.Path } elseif ($State.BackendAmbiguous) { 'Unknown: several different CPU backend paths were logged' } else { 'Unknown: no "loaded CPU backend" line seen' })
    if ($State.SysInfo -and $null -ne $State.SysInfo.Threads) { Add-D 'Threads' ([string]$State.SysInfo.Threads) }
    Add-D 'Integrity' $State.VerificationText $(if ($State.VerificationOk) { 'info' } else { 'warn' })
    foreach ($p in @($State.VerificationProblems | Select-Object -First 6)) { Add-D 'Problem' $p 'warn' }
    Add-D 'Host' $State.HostText
    if ($State.HostProbe -and $State.HostProbe.Ok -and $State.HostProbe.Data.scorer.available) {
        $sc = @(); foreach ($pp in $State.HostProbe.Data.scorer.scores.PSObject.Properties) { $sc += ('{0}={1}' -f $pp.Name, $pp.Value) }
        Add-D 'Scorer' ($sc -join ' ')
    }
    foreach ($f in @($State.Findings)) { Add-D 'Finding' ('[{0}] {1}' -f $f.Level, $f.Text) $(if ($f.Level -eq 'FAIL') { 'crit' } elseif ($f.Level -eq 'WARN') { 'warn' } else { 'info' }) }
    $h = $State.Health
    if ($null -ne $h.Status) { Add-D 'Health' ('GET /health -> {0}, {1} s ago' -f $h.Status, [int]((Get-Date) - $h.At).TotalSeconds) }
    else { Add-D 'Health' $(if ($h.LastError) { 'no answer from /health yet (' + $h.LastError + '); relying on llama.cpp log lines' } else { 'no answer from /health yet; relying on llama.cpp log lines' }) 'warn' }
    Add-D 'Process' $(if ($State.Pid) { 'PID ' + $State.Pid } else { 'not started' })
    Add-D 'Orphan guard' $(if ($State.GuardOk) { 'on: Windows ends the server if this window is closed' } else { 'off (' + $State.GuardReason + '); if the window is closed, run STOP.bat' }) $(if ($State.GuardOk) { 'info' } else { 'warn' })
    foreach ($w in @($State.Warnings | Select-Object -Last 3)) { Add-D 'llama warn' $w 'warn' }
    if ($State.LastErrorLine) { Add-D 'Last error' $State.LastErrorLine 'crit' }
    Add-D 'Counting' 'Incomplete = requests whose timing lines stopped early. A request that prints no timing line is not visible here.'
    Add-D 'Display' ('mode {0}; color {1}; unicode {2}' -f $State.Caps.Mode, $State.Caps.Color, $State.Caps.Unicode)
    Add-D 'Log' $State.LogPath
    return @($rows)
}

# ------------------------------------------------------------------------------------------------ commands
function Set-PLlmNotice {
    param($State, [string]$Level, [string]$Text, [int]$Seconds = 8)
    $State.Notice = [pscustomobject]@{ Level = $Level; Text = $Text }; $State.NoticeUntil = (Get-Date).AddSeconds($Seconds); $State.Dirty = $true
}

function Invoke-PLlmCommand {
    # Returns $true when the dashboard should force a full redraw.  'Quit' is handled by the caller.
    param($State, [string]$Cmd, $Proc)
    switch ($Cmd) {
        'Open' {
            if ($Proc -and $Proc.HasExited) { Set-PLlmNotice $State 'warn' 'The server is not running, so there is nothing to open.'; return $false }
            if ($State.LastOpen -and ((Get-Date) - $State.LastOpen).TotalSeconds -lt 1.5) { return $false }
            $State.LastOpen = Get-Date
            try { Start-Process $State.Url; Set-PLlmNotice $State 'ok' ('Opened ' + $State.Url + ' in your browser (the server was not restarted).') }
            catch { Set-PLlmNotice $State 'warn' ('Could not open the browser. Open ' + $State.Url + ' yourself.') }
        }
        'Diag' { $State.ShowDiag = -not $State.ShowDiag; $State.Dirty = $true; return $true }
        'Log' {
            if ($State.LogArmedUntil -and (Get-Date) -lt $State.LogArmedUntil) {
                $State.LogArmedUntil = $null
                try { Start-Process -FilePath (Split-Path -Parent $State.LogPath); Set-PLlmNotice $State 'ok' 'Opened the log folder.' }
                catch { Set-PLlmNotice $State 'warn' ('Could not open the folder. Log: ' + $State.LogPath) 15 }
            } else {
                $State.LogArmedUntil = (Get-Date).AddSeconds(10)
                Set-PLlmNotice $State 'info' ('Log: ' + $State.LogPath + '   (press L again within 10 s to open its folder)') 12
            }
        }
        'Redraw' { $State.Dirty = $true; return $true }
    }
    return $false
}

function Stop-PLlmServerProcess {
    # Ends the server and its children, then confirms it is gone.  Returns $true when the process has exited.
    param($State, $Proc)
    if ($null -eq $Proc) { return $true }
    try { if ($Proc.HasExited) { return $true } } catch { return $true }
    $State.StoppedByUser = $true
    try { $Proc.Kill() } catch { }
    try { [void]$Proc.WaitForExit(5000) } catch { }
    $gone = $false; try { $gone = $Proc.HasExited } catch { $gone = $true }
    if (-not $gone -and $script:PLlmIsWindows) {
        try { & taskkill.exe /PID $Proc.Id /T /F 2>&1 | Out-Null; [void]$Proc.WaitForExit(3000) } catch { }
        try { $gone = $Proc.HasExited } catch { $gone = $true }
    }
    return $gone
}

function Test-PLlmTcpPort {
    param([int]$Port)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(200)
        if ($ok -and $c.Connected) { return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}

function Invoke-PLlmServerMonitor {
    # Returns the server's exit code (or -1 if it could not be started).  0 when the user quit with Q / Ctrl+C in the dashboard.
    param(
        [string]$ServerExe, [string]$ArgumentString, [string]$WorkDir,
        [string]$SessionDir, [string]$ModelName, [string]$Url, [int]$Port,
        $HostFeatures, [string]$PredictedVariant, [string]$HostText,
        [string]$VerificationText, [bool]$VerificationOk,
        [string[]]$HeaderLines, [bool]$OpenBrowser, [bool]$Quiet,
        $HostProbe = $null, [double]$ModelBytes = 0, [int]$ContextRequested = 0,
        [string]$VerificationKind = '', $VerificationProblems = @()
    )
    New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null
    $logPath    = Join-Path $SessionDir 'session.log'
    $outFile    = Join-Path $SessionDir 'server.stdout.txt'
    $errFile    = Join-Path $SessionDir 'server.stderr.txt'
    $writer = New-Object System.IO.StreamWriter($logPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    if (-not $VerificationKind) { $VerificationKind = $(if ($VerificationOk) { 'VERIFIED' } else { 'UNVERIFIED' }) }
    $caps = Get-PLlmTermCaps
    $dash = ($caps.Mode -ne 'Log')
    $st = [pscustomobject]@{
        Log = $writer; LogPath = $logPath; CsvPath = (Join-Path $SessionDir 'requests.csv'); LatestPath = (Join-Path (Split-Path -Parent $SessionDir) 'latest-summary.txt')
        Session = (New-PLlmSession); LastRequest = $null; LastLines = (New-Object System.Collections.ArrayList)
        Backend = $null; BackendAmbiguous = $false; CpuBackendsSeen = (New-Object System.Collections.ArrayList); FindingsShown = $false; SysInfo = $null; BuildLine = $null; OtherBackends = @(); Ready = $false; FirstRequestChecked = $false; CorsWarned = $false
        ModelName = $ModelName; Url = $Url; HostFeatures = $HostFeatures; Predicted = $PredictedVariant; HostText = $HostText
        VerificationText = $VerificationText; VerificationOk = $VerificationOk; VerificationKind = $VerificationKind; VerificationProblems = @($VerificationProblems)
        OpenBrowser = $OpenBrowser; Quiet = $Quiet; StartedAt = (Get-Date)
        # dashboard state
        Echo = (-not $dash); Caps = $caps; Dirty = $true; ShowDiag = $false
        ModelBytes = $ModelBytes; CtxRequested = $ContextRequested; CtxReported = $null; HostProbe = $HostProbe
        Events = (New-Object System.Collections.ArrayList); Warnings = (New-Object System.Collections.ArrayList)
        Findings = @(); FindingSeen = @{}; ErrorSeen = @{}; LastErrorLine = $null; LastErrorHint = $null
        ListeningSeen = $false; LoaderSeen = $false; LogReady = $false; StoppedByUser = $false; ExitedAt = $null
        ServerState = 'Starting'; StateDetail = 'launching server process'; BrowserOpened = $false; HealthReady = $false
        Health = [pscustomobject]@{ Req = $null; Async = $null; Started = $null; Status = $null; At = $null; LastError = '' }
        Mem = $null; MemLevel = 'unknown'; ProcMem = $null; Pid = $null; GuardOk = $false; GuardReason = 'not started'
        Notice = $null; NoticeUntil = [datetime]::MinValue; LastOpen = $null; LogArmedUntil = $null
    }
    foreach ($h in $HeaderLines) { Write-PLlmOut $st $h 'Gray' -LogOnly }
    Write-PLlmOut $st ('Display mode: {0} (color={1}, unicode={2}){3}' -f $caps.Mode, $caps.Color, $caps.Unicode, $(if ($caps.Why) { ' - ' + $caps.Why } else { '' })) 'Gray' -LogOnly
    Write-PLlmOut $st '--- server output follows ---' 'DarkGray' -LogOnly

    $proc = $null; $tailOut = $null; $tailErr = $null; $exitCode = -1; $stopped = $false
    $guard = $null; $screenOn = $false; $painter = New-PLlmPainter
    try {
        $guard = New-PLlmProcessGuard
        $st.GuardOk = $guard.Ok; $st.GuardReason = $guard.Reason
        try {
            $proc = Start-Process -FilePath $ServerExe -ArgumentList $ArgumentString -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
                        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $null = $proc.Handle     # keep the handle so ExitCode is readable after exit
            $st.Pid = $proc.Id
        } catch {
            Write-PLlmOut $st ('[ERROR] Could not start the server: {0}' -f $_.Exception.Message) 'Red'
            $st.Echo = $true
            return -1
        }
        if ($guard.Ok -and -not (Add-PLlmProcessToGuard $guard $proc)) { $st.GuardOk = $false; $st.GuardReason = 'could not attach the server to the job object' }
        Add-PLlmEvent $st 'info' ('Server process started (PID {0})' -f $proc.Id)
        $deadline = (Get-Date).AddSeconds(5)
        while (((-not (Test-Path -LiteralPath $outFile)) -or (-not (Test-Path -LiteralPath $errFile))) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        $tailOut = New-PLlmTail $outFile
        $tailErr = New-PLlmTail $errFile

        if ($dash) { Enter-PLlmScreen $caps; $screenOn = $true }
        $lastBeat = Get-Date; $lastSample = (Get-Date).AddSeconds(-5); $quit = $false
        while ($true) {
            foreach ($l in (Read-PLlmTailLines $tailErr)) { Invoke-PLlmLine $st $l }
            foreach ($l in (Read-PLlmTailLines $tailOut)) { Invoke-PLlmLine $st $l }
            if ($proc.HasExited) {
                Start-Sleep -Milliseconds 200
                foreach ($l in (Read-PLlmTailLines $tailErr -Flush)) { Invoke-PLlmLine $st $l }
                foreach ($l in (Read-PLlmTailLines $tailOut -Flush)) { Invoke-PLlmLine $st $l }
                Update-PLlmServerState $st $proc
                if ($dash) {
                    Update-PLlmScreen $st $caps $painter $false
                    if (-not $st.StoppedByUser) { Wait-PLlmDashboardClose $st $caps $painter $proc }
                }
                break
            }
            Step-PLlmHealth $st
            Update-PLlmServerState $st $proc
            if (((Get-Date) - $lastSample).TotalMilliseconds -ge 1000) { $lastSample = Get-Date; Update-PLlmSystem $st $proc }

            if ($dash) {
                $full = $false
                try {
                    while ([Console]::KeyAvailable) {
                        $cmd = ConvertTo-PLlmCommand ([Console]::ReadKey($true))
                        if ($cmd -eq 'Quit') { $quit = $true; break }
                        if ($cmd) { if (Invoke-PLlmCommand $st $cmd $proc) { $full = $true } }
                    }
                    if ($caps.Width -ne [Console]::WindowWidth -or $caps.Height -ne [Console]::WindowHeight) {
                        $caps.Width = [Console]::WindowWidth; $caps.Height = [Console]::WindowHeight; $full = $true
                    }
                } catch { }
                if ($quit) {
                    Add-PLlmEvent $st 'info' 'Stopping the server ...'
                    Set-PLlmNotice $st 'info' 'Stopping the server ...' 30
                    Update-PLlmScreen $st $caps $painter $false
                    break
                }
                if ($st.Dirty -or $full) { $st.Dirty = $false; Update-PLlmScreen $st $caps $painter $full }
            } elseif (-not $st.Ready -and ((Get-Date) - $lastBeat).TotalSeconds -ge 30) {
                $lastBeat = Get-Date
                Write-PLlmOut $st ('   ... still loading the model ({0} s). Large models on a USB drive can take minutes.' -f [int]((Get-Date) - $st.StartedAt).TotalSeconds) 'DarkGray'
            }
            Start-Sleep -Milliseconds 150
        }
        if ($quit) {
            $gone = Stop-PLlmServerProcess $st $proc
            $stopped = $false
            if (-not $gone) { Add-PLlmEvent $st 'crit' 'The server did not exit; run STOP.bat.' }
            $exitCode = 0
        } else {
            $proc.WaitForExit()
            $exitCode = [int]$proc.ExitCode
        }
    }
    finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } ; $stopped = $true; $st.StoppedByUser = $true }
        if ($tailOut) { $tailOut.Reader.Dispose(); $tailOut.Stream.Dispose() }
        if ($tailErr) { $tailErr.Reader.Dispose(); $tailErr.Stream.Dispose() }
        if ($st.Health.Req) { try { $st.Health.Req.Abort() } catch { } }
        Close-PLlmSession $st.Session
        if ($screenOn) { try { Exit-PLlmScreen $caps } catch { } }
        Close-PLlmProcessGuard $guard
        $st.Echo = $true

        $line = '=' * 78
        Write-PLlmOut $st ''
        Write-PLlmOut $st $line 'White'
        Write-PLlmOut $st ' SERVER STOPPED' 'White'
        Write-PLlmOut $st $line 'White'
        if ($proc -and $proc.HasExited -and -not $stopped -and $exitCode -ne 0) { $exitCode = [int]$proc.ExitCode }
        $hint = Get-PLlmExitHint $exitCode
        if (-not $proc) {
            Write-PLlmOut $st ' [FAIL] The server process could not be started (see the error above).' 'Red'
        } elseif ($stopped) {
            Write-PLlmOut $st ' The launcher stopped the server process (script interrupted).' 'Yellow'
        } elseif ($st.StoppedByUser) {
            Write-PLlmOut $st ' Stopped by you (Q / Ctrl+C in the dashboard).' 'White'
        } elseif (-not $st.Ready -and $exitCode -ne 0 -and $exitCode -ne -1073741510) {
            Write-PLlmOut $st (' [FAIL] The server stopped BEFORE it became ready (exit code {0}): {1}' -f $exitCode, $hint) 'Red'
            if ($st.LastErrorHint) { Write-PLlmOut $st (' What to do: {0}' -f $st.LastErrorHint) 'Yellow' }
            Write-PLlmOut $st ' Last server output:' 'Red'
            foreach ($l in $st.LastLines) { Write-PLlmOut $st ('   | ' + $l) 'Red' }
        } else {
            Write-PLlmOut $st (' Exit code: {0} ({1})' -f $exitCode, $hint) 'White'
        }
        if ($proc -and $st.StoppedByUser) {
            $free = Test-PLlmPortFree $Port
            Write-PLlmOut $st $(if ($free) { (' Port {0} is free again; no server process is left running.' -f $Port) } else { (' [WARN] Port {0} is still in use. Run STOP.bat to end any leftover server.' -f $Port) }) $(if ($free) { 'White' } else { 'Yellow' })
        }
        $stats = Get-PLlmSessionStats $st.Session
        if ($stats.Requests -gt 0) {
            Write-PLlmOut $st (' Latest request  : {0}' -f (Format-PLlmRequestLine $st.LastRequest (Format-PLlmTag $st.Backend $st.SysInfo $st.ModelName))) 'Cyan'
            Write-PLlmOut $st (Format-PLlmSessionLine $stats) 'DarkCyan'
        } else {
            Write-PLlmOut $st ' No completed request timing lines were captured in this session.' 'Yellow'
        }
        if ($stats.Incomplete -gt 0) { Write-PLlmOut $st (' Incomplete requests (timing lines cut short): {0}' -f $stats.Incomplete) 'Yellow' }
        Write-PLlmOut $st (' Backend / ISA : {0}' -f (Format-PLlmTag $st.Backend $st.SysInfo $st.ModelName)) 'White'
        Write-PLlmOut $st (' Build ISA verification: {0}' -f $st.VerificationText) 'White'
        Write-PLlmOut $st (' Session log    : {0}' -f $logPath) 'White'
        if ($stats.Requests -gt 0) { Write-PLlmOut $st (' Request table  : {0}' -f $st.CsvPath) 'White' }
        Write-PLlmOut $st $line 'White'
        Write-PLlmLatestSummaryFile $st
        try { $writer.Dispose() } catch { }
    }
    return $exitCode
}

function Wait-PLlmDashboardClose {
    # The server has exited on its own.  Keep the final state (Error / Stopped) on screen, with diagnostics available,
    # until the user presses Q or Ctrl+C.  Nothing is running any more, so there is nothing to stop.
    param($State, $Caps, $Painter, $Proc)
    $code = $null; try { $code = [int]$Proc.ExitCode } catch { }
    Set-PLlmNotice $State $(if ($State.ServerState -eq 'Error') { 'crit' } else { 'info' }) 'The server has stopped. Press D for diagnostics, L for the log path, Q to close.' 86400
    Update-PLlmScreen $State $Caps $Painter $true
    while ($true) {
        $full = $false
        try {
            while ([Console]::KeyAvailable) {
                $cmd = ConvertTo-PLlmCommand ([Console]::ReadKey($true))
                if ($cmd -eq 'Quit') { return }
                if ($cmd) { if (Invoke-PLlmCommand $State $cmd $Proc) { $full = $true } }
            }
            if ($Caps.Width -ne [Console]::WindowWidth -or $Caps.Height -ne [Console]::WindowHeight) { $Caps.Width = [Console]::WindowWidth; $Caps.Height = [Console]::WindowHeight; $full = $true }
        } catch { return }
        if ($State.Dirty -or $full) { $State.Dirty = $false; Update-PLlmScreen $State $Caps $Painter $full }
        Start-Sleep -Milliseconds 100
    }
}

function Update-PLlmScreen {
    param($State, $Caps, $Painter, [bool]$Full)
    $v = New-PLlmViewModel $State
    $lines = Build-PLlmFrame -V $v -Width $Caps.Width -Height $Caps.Height -Color $Caps.Color -Unicode $Caps.Unicode -Palette256 $Caps.Palette256
    Write-PLlmFrame $Caps $Painter $lines $Full
}
