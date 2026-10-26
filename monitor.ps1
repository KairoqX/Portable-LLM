# Portable-LLM live server monitor.  ASCII only.  Dot-sourced by launcher.ps1 (requires lib\PortableLlm.Core.ps1).
#
# Starts llama-server with stdout/stderr redirected to files, then tails those files while the server runs:
#   - every server line is shown live and saved to the session log
#   - llama.cpp's own timing lines are parsed per request and summarised immediately (not only at exit)
#   - the backend/ISA that llama.cpp reports is printed next to the speeds and cross-checked against the host
# It never invents numbers: every figure printed comes from a line llama.cpp wrote, or is marked "(computed)".

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
    if (-not $LogOnly) { Write-Host $Text -ForegroundColor $Color }
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

function Invoke-PLlmLine {
    # Handles ONE line of server output.
    param($State, [string]$Line)
    # keep a short history for failure reports
    [void]$State.LastLines.Add($Line)
    if ($State.LastLines.Count -gt 40) { $State.LastLines.RemoveAt(0) }

    $shown = $true
    $color = 'Gray'
    if ($Line -match '(?i)\b(error|failed|fatal)\b') { $color = 'Red' }
    elseif ($Line -match '(?i)\bwarn(ing)?\b') { $color = 'Yellow' }
    if ($State.Quiet -and $color -eq 'Gray') { $shown = $false }
    Write-PLlmOut $State $Line $color -LogOnly:(-not $shown)

    if ($Line -match $PLlmRx_CorsWarning -and -not $State.CorsWarned) {
        $State.CorsWarned = $true
        Write-PLlmOut $State '   [WARN] The server still reports permissive CORS (any website could script this local server). Check the --cors-origins setting.' 'Yellow'
    }

    if ($null -eq $State.BuildLine -and $Line -match $PLlmRx_BuildInfo) { $State.BuildLine = $Matches[1].Trim() }

    $be = ConvertFrom-PLlmLoadBackendLine $Line
    if ($be -and $be.Backend -eq 'CPU') {
        [void]$State.CpuBackendsSeen.Add($be)
        $State.Backend = Get-PLlmResolvedBackend $State.CpuBackendsSeen
        $State.BackendAmbiguous = ($null -eq $State.Backend)
    }
    elseif ($be) { $State.OtherBackends += $be.Backend }

    $newFacts = $false
    if ($null -eq $State.SysInfo -and $Line -match $PLlmRx_SystemInfo) { $State.SysInfo = ConvertFrom-PLlmSystemInfo $Line; $newFacts = $true }
    if ($State.Ready -and $State.FindingsShown -and ($newFacts -or $be)) {
        Write-PLlmOut $State ' Update from llama.cpp output received after the banner:' 'Cyan'
        Write-PLlmFindings $State
    }

    if (-not $State.Ready -and $Line -match $PLlmRx_Listening) {
        $State.Ready = $true
        Write-PLlmReadyBanner $State
        if ($State.OpenBrowser) {
            try { Start-Process $State.Url } catch { Write-PLlmOut $State ('   [INFO] Could not open the browser automatically: open {0} yourself.' -f $State.Url) 'Cyan' }
        }
    }

    $ev = ConvertFrom-PLlmTimingLine $Line
    if ($ev -and $ev.Kind -eq 'Total' -and $State.Ready -and -not $State.FirstRequestChecked) {
        $State.FirstRequestChecked = $true
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
        }
    }
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
    # Returns the server's exit code (or -1 if it could not be started).
    param(
        [string]$ServerExe, [string]$ArgumentString, [string]$WorkDir,
        [string]$SessionDir, [string]$ModelName, [string]$Url, [int]$Port,
        $HostFeatures, [string]$PredictedVariant, [string]$HostText,
        [string]$VerificationText, [bool]$VerificationOk,
        [string[]]$HeaderLines, [bool]$OpenBrowser, [bool]$Quiet
    )
    New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null
    $logPath    = Join-Path $SessionDir 'session.log'
    $outFile    = Join-Path $SessionDir 'server.stdout.txt'
    $errFile    = Join-Path $SessionDir 'server.stderr.txt'
    $writer = New-Object System.IO.StreamWriter($logPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    $st = [pscustomobject]@{
        Log = $writer; LogPath = $logPath; CsvPath = (Join-Path $SessionDir 'requests.csv'); LatestPath = (Join-Path (Split-Path -Parent $SessionDir) 'latest-summary.txt')
        Session = (New-PLlmSession); LastRequest = $null; LastLines = (New-Object System.Collections.ArrayList)
        Backend = $null; BackendAmbiguous = $false; CpuBackendsSeen = (New-Object System.Collections.ArrayList); FindingsShown = $false; SysInfo = $null; BuildLine = $null; OtherBackends = @(); Ready = $false; FirstRequestChecked = $false; CorsWarned = $false
        ModelName = $ModelName; Url = $Url; HostFeatures = $HostFeatures; Predicted = $PredictedVariant; HostText = $HostText
        VerificationText = $VerificationText; VerificationOk = $VerificationOk
        OpenBrowser = $OpenBrowser; Quiet = $Quiet; StartedAt = (Get-Date)
    }
    foreach ($h in $HeaderLines) { Write-PLlmOut $st $h 'Gray' -LogOnly }
    Write-PLlmOut $st '--- server output follows ---' 'DarkGray' -LogOnly

    $proc = $null; $tailOut = $null; $tailErr = $null; $exitCode = -1; $stopped = $false
    try {
        try {
            $proc = Start-Process -FilePath $ServerExe -ArgumentList $ArgumentString -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
                        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $null = $proc.Handle     # keep the handle so ExitCode is readable after exit
        } catch {
            Write-PLlmOut $st ('[ERROR] Could not start the server: {0}' -f $_.Exception.Message) 'Red'
            return -1
        }
        $deadline = (Get-Date).AddSeconds(5)
        while (((-not (Test-Path -LiteralPath $outFile)) -or (-not (Test-Path -LiteralPath $errFile))) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        $tailOut = New-PLlmTail $outFile
        $tailErr = New-PLlmTail $errFile

        $lastBeat = Get-Date
        while ($true) {
            foreach ($l in (Read-PLlmTailLines $tailErr)) { Invoke-PLlmLine $st $l }
            foreach ($l in (Read-PLlmTailLines $tailOut)) { Invoke-PLlmLine $st $l }
            if ($proc.HasExited) {
                Start-Sleep -Milliseconds 200
                foreach ($l in (Read-PLlmTailLines $tailErr -Flush)) { Invoke-PLlmLine $st $l }
                foreach ($l in (Read-PLlmTailLines $tailOut -Flush)) { Invoke-PLlmLine $st $l }
                break
            }
            if (-not $st.Ready -and ((Get-Date) - $lastBeat).TotalSeconds -ge 30) {
                $lastBeat = Get-Date
                Write-PLlmOut $st ('   ... still loading the model ({0} s). Large models on a USB drive can take minutes.' -f [int]((Get-Date) - $st.StartedAt).TotalSeconds) 'DarkGray'
            }
            Start-Sleep -Milliseconds 150
        }
        $proc.WaitForExit()
        $exitCode = [int]$proc.ExitCode
    }
    finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } ; $stopped = $true }
        if ($tailOut) { $tailOut.Reader.Dispose(); $tailOut.Stream.Dispose() }
        if ($tailErr) { $tailErr.Reader.Dispose(); $tailErr.Stream.Dispose() }

        $line = '=' * 78
        Write-PLlmOut $st ''
        Write-PLlmOut $st $line 'White'
        Write-PLlmOut $st ' SERVER STOPPED' 'White'
        Write-PLlmOut $st $line 'White'
        if ($proc -and $proc.HasExited -and -not $stopped) { $exitCode = [int]$proc.ExitCode }
        $hint = Get-PLlmExitHint $exitCode
        if (-not $proc) {
            Write-PLlmOut $st ' [FAIL] The server process could not be started (see the error above).' 'Red'
        } elseif ($stopped) {
            Write-PLlmOut $st ' The launcher stopped the server process (script interrupted).' 'Yellow'
        } elseif (-not $st.Ready -and $exitCode -ne 0 -and $exitCode -ne -1073741510) {
            Write-PLlmOut $st (' [FAIL] The server stopped BEFORE it became ready (exit code {0}): {1}' -f $exitCode, $hint) 'Red'
            Write-PLlmOut $st ' Last server output:' 'Red'
            foreach ($l in $st.LastLines) { Write-PLlmOut $st ('   | ' + $l) 'Red' }
        } else {
            Write-PLlmOut $st (' Exit code: {0} ({1})' -f $exitCode, $hint) 'White'
        }
        $stats = Get-PLlmSessionStats $st.Session
        if ($stats.Requests -gt 0) {
            Write-PLlmOut $st (' Latest request  : {0}' -f (Format-PLlmRequestLine $st.LastRequest (Format-PLlmTag $st.Backend $st.SysInfo $st.ModelName))) 'Cyan'
            Write-PLlmOut $st (Format-PLlmSessionLine $stats) 'DarkCyan'
        } else {
            Write-PLlmOut $st ' No completed request timing lines were captured in this session.' 'Yellow'
        }
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
