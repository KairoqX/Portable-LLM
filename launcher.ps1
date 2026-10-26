# Portable-LLM launcher.  ASCII only.  Started by START.bat (or run directly for testing).
#
#   -Choice N          pick model number N without prompting (for scripted tests)
#   -DryRun            do every check and print the exact server command, but do not start the server
#   -NoBrowser         do not open the browser when the server is ready
#   -AllowUnverified   run a build even if its requirements are not met / not verified (also env PORTABLE_LLM_ALLOW_UNVERIFIED=1)
#   -Root PATH         project folder (default: the folder containing this script)
#
# Exit codes:  0 ok | 1 unexpected error | 2 missing executable or models | 3 invalid model selection
#              4 CPU/build compatibility rejected | 5 configuration rejected (non-local host, port busy)
#              any other value = the exit code of llama-server itself
param(
    [int]$Choice = 0,
    [switch]$DryRun,
    [switch]$NoBrowser,
    [switch]$AllowUnverified,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($Root)) { $Root = $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path

. (Join-Path $Root 'lib\PortableLlm.Core.ps1')
. (Join-Path $Root 'monitor.ps1')

$script:Report = New-Object System.Collections.ArrayList
function Write-Rep {
    param([string]$Text = '', [string]$Color = 'Gray')
    [void]$script:Report.Add($Text)
    Write-Host $Text -ForegroundColor $Color
}
function Stop-Launcher {
    param([int]$Code, [string]$Message)
    Write-Host ''
    Write-Host ('[ERROR] ' + $Message) -ForegroundColor Red
    exit $Code
}

# ------------------------------------------------------------------ configuration (CONFIG.bat is parsed, never executed)
function Read-PLlmConfig {
    param([string]$ConfigPath)
    $cfg = @{ CONTEXT = '4096'; PORT = '8080'; HOST = '127.0.0.1' }
    if (Test-Path -LiteralPath $ConfigPath) {
        foreach ($line in (Get-Content -LiteralPath $ConfigPath)) {
            if ($line -match '^\s*set\s+"?(CONTEXT|PORT|HOST)=([^"\r\n]*)"?\s*$') { $cfg[$Matches[1].ToUpperInvariant()] = $Matches[2].Trim() }
        }
    }
    if ($env:PORTABLE_LLM_PORT)    { $cfg.PORT = $env:PORTABLE_LLM_PORT }
    if ($env:PORTABLE_LLM_CONTEXT) { $cfg.CONTEXT = $env:PORTABLE_LLM_CONTEXT }
    return $cfg
}

# ------------------------------------------------------------------ host probe (separate process)
function Invoke-PLlmHostProbe {
    param([string]$LlamaDir)
    $psExe = (Get-Process -Id $PID).Path
    $outTmp = [System.IO.Path]::GetTempFileName(); $errTmp = [System.IO.Path]::GetTempFileName()
    try {
        $argText = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -LlamaDir "{1}" -Json' -f (Join-Path $Root 'cpu-detect.ps1'), $LlamaDir
        $p = Start-Process -FilePath $psExe -ArgumentList $argText -NoNewWindow -PassThru -RedirectStandardOutput $outTmp -RedirectStandardError $errTmp
        $null = $p.Handle
        if (-not $p.WaitForExit(60000)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ Ok = $false; Reason = 'host probe timed out after 60 s'; Data = $null }
        }
        $text = Get-Content -LiteralPath $outTmp -Raw
        if ($p.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{ Ok = $false; Reason = ('host probe failed (exit code {0}: {1})' -f $p.ExitCode, (Get-PLlmExitHint ([int]$p.ExitCode))); Data = $null }
        }
        return [pscustomobject]@{ Ok = $true; Reason = ''; Data = ($text | ConvertFrom-Json) }
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = ('host probe error: ' + $_.Exception.Message); Data = $null }
    } finally {
        Remove-Item -LiteralPath $outTmp, $errTmp -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-PLlmHashtable {
    param($Obj)
    $h = @{}
    if ($null -ne $Obj) { foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

function Test-PLlmBinaryContains {
    param([string[]]$Paths, [string]$Text)
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $s = $latin1.GetString([System.IO.File]::ReadAllBytes($p))
        if ($s.IndexOf($Text, [System.StringComparison]::Ordinal) -ge 0) { return $true }
    }
    return $false
}

function Test-PLlmPortFree {
    param([int]$Port)
    try {
        $l = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        foreach ($e in $l) { if ($e.Port -eq $Port) { return $false } }
    } catch { }
    return $true
}

# ================================================================== main
function Invoke-PLlmMain {
    $cfg = Read-PLlmConfig (Join-Path $Root 'CONFIG.bat')
    $ctx = 0; $port = 0
    if (-not [int]::TryParse($cfg.CONTEXT, [ref]$ctx) -or $ctx -lt 256) { Stop-Launcher 5 ('Invalid CONTEXT value "{0}" (CONFIG.bat). Use a number such as 4096.' -f $cfg.CONTEXT) }
    if (-not [int]::TryParse($cfg.PORT, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { Stop-Launcher 5 ('Invalid PORT value "{0}" (CONFIG.bat).' -f $cfg.PORT) }
    $hostName = $cfg.HOST
    if (@('127.0.0.1', 'localhost', '::1') -notcontains $hostName.ToLowerInvariant()) {
        Stop-Launcher 5 ('HOST "{0}" in CONFIG.bat is not a loopback address. Portable-LLM only serves on this computer (127.0.0.1) because the server has no login. Set HOST=127.0.0.1.' -f $hostName)
    }
    $allowOverride = ($AllowUnverified.IsPresent -or $env:PORTABLE_LLM_ALLOW_UNVERIFIED -eq '1')

    $line = '=' * 78
    Write-Rep $line 'White'
    Write-Rep '                         PORTABLE LLM' 'White'
    Write-Rep $line 'White'
    Write-Rep ('Started {0}   Folder: {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Root)
    Write-Rep ''

    # ---- 1. find builds ------------------------------------------------------------------------
    $llamaRoot = Join-Path $Root 'llama'
    $dirs = @()
    if (Test-Path -LiteralPath $llamaRoot) {
        $dirs += $llamaRoot
        foreach ($d in @(Get-ChildItem -LiteralPath $llamaRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) { $dirs += $d.FullName }
    }
    $candidates = @()
    foreach ($d in $dirs) {
        $exe = Join-Path $d 'llama-server.exe'
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        $manifest = $null; $mProblem = $null
        $mPath = Join-Path $d 'build-manifest.json'
        if (Test-Path -LiteralPath $mPath) {
            try { $manifest = Get-Content -LiteralPath $mPath -Raw | ConvertFrom-Json } catch { $mProblem = 'build-manifest.json is not valid JSON' }
        }
        $candidates += [pscustomobject]@{
            Name = $exe.Substring($Root.Length).TrimStart('\'); Dir = $d; Path = $exe; Exists = $true
            Manifest = $manifest; ManifestProblem = $mProblem; Verified = $false; Problems = @(); MinFeatures = @(); Preference = 50
            Probe = $null; Features = $null; Predicted = $null
        }
    }
    if ($candidates.Count -eq 0) {
        Write-Rep '[ERROR] No llama-server.exe was found.' 'Red'
        Write-Rep '        Expected: llama\llama-server.exe (plus the DLL files that came with it).' 'Red'
        Write-Rep '        Download a Windows CPU build from https://github.com/ggml-org/llama.cpp/releases and extract it into the llama folder.' 'Red'
        exit 2
    }

    # ---- 2. verify files against the manifest, probe the host per build ---------------------------
    Write-Rep 'Checking CPU compatibility ...' 'White'
    $firstProbe = $null
    foreach ($c in $candidates) {
        if ($c.Manifest) {
            Write-Host ('  verifying file hashes for {0} (SHA-256) ...' -f $c.Name) -ForegroundColor DarkGray
            $v = Test-PLlmManifest -Dir $c.Dir -Manifest $c.Manifest -ManifestPath (Join-Path $c.Dir 'build-manifest.json')
            $c.Verified = $v.Verified; $c.Problems = @($v.Problems)
            # min_host_features / preference are only honoured from a structurally valid manifest
            if (@(Test-PLlmManifestSchema $c.Manifest).Count -eq 0) {
                if ($c.Manifest.min_host_features) { $c.MinFeatures = @($c.Manifest.min_host_features) }
                if ($c.Manifest.preference) { $c.Preference = [int]$c.Manifest.preference }
            }
        } elseif ($c.ManifestProblem) { $c.Problems = @($c.ManifestProblem) }
        else { $c.Problems = @('no build-manifest.json: compile-time instruction set unknown') }

        $probe = Invoke-PLlmHostProbe $c.Dir
        $c.Probe = $probe
        $pf = @{}; $scores = $null
        if ($probe.Ok) {
            if (-not $firstProbe) { $firstProbe = $probe.Data }
            $pf = ConvertTo-PLlmHashtable $probe.Data.pf
            if ($probe.Data.scorer.available) { $scores = ConvertTo-PLlmHashtable $probe.Data.scorer.scores }
        }
        $table = $null
        if ($c.Manifest -and $c.Manifest.cpu_variants) {
            $table = [ordered]@{}
            foreach ($vv in @($c.Manifest.cpu_variants)) { $table[$vv.variant] = @($vv.declared_requires) }
        }
        $c.Features = Resolve-PLlmHostFeatures -Pf $pf -Scores $scores -Table $table
        $c.Predicted = Get-PLlmPredictedVariant $scores
    }

    # Selection needs per-candidate host features; evaluate each candidate against its own feature table.
    $rows = @()
    foreach ($c in $candidates) {
        $one = Select-PLlmBuild -Candidates @($c) -HostFeatures $c.Features
        $rows += $one.Rows[0]
    }
    $ok = @($rows | Where-Object { $_.Status -eq 'COMPATIBLE' } | Sort-Object { -[int]$_.Candidate.Preference })
    $pick = $null; $kind = 'NONE'
    if ($ok.Count -gt 0) { $pick = $ok[0]; $kind = 'VERIFIED' }
    else {
        $uv = @($rows | Where-Object { $_.Status -eq 'UNVERIFIED' })
        if ($uv.Count -gt 0) { $pick = $uv[0]; $kind = 'UNVERIFIED' }
    }

    # ---- 3. report -------------------------------------------------------------------------------
    $hostData = $firstProbe
    $cpuName = 'unknown CPU'
    if ($hostData -and $hostData.cpu_name) { $cpuName = [string]$hostData.cpu_name }
    $coreText = ''
    if ($hostData -and $hostData.cores) { $coreText = ('  ({0} cores / {1} threads)' -f $hostData.cores, $hostData.logical_cpus) }
    $pfText = 'Windows feature API unavailable'
    if ($hostData) {
        $parts = @()
        foreach ($n in @('SSE42', 'AVX', 'AVX2', 'AVX512')) {
            $val = $hostData.pf.$n
            $s = 'unknown'; if ($val -eq $true) { $s = 'yes' } elseif ($val -eq $false) { $s = 'no' }
            $parts += ('{0}={1}' -f $n, $s)
        }
        $pfText = ($parts -join '  ')
    }
    Write-Rep ''
    Write-Rep $line 'White'
    Write-Rep ' CPU COMPATIBILITY REPORT' 'White'
    Write-Rep $line 'White'
    Write-Rep (' CPU               : {0}{1}' -f $cpuName, $coreText)
    Write-Rep (' Windows API flags : {0}' -f $pfText)
    Write-Rep '                     (OS-enabled CPU support; says nothing about how any .exe/.dll was compiled)' 'DarkGray'
    $scorerText = 'not available'
    $predictedForPick = $null
    if ($pick) { $predictedForPick = $pick.Candidate.Predicted }
    $refCand = $candidates[0]; if ($pick) { $refCand = $pick.Candidate }
    if ($refCand.Probe -and $refCand.Probe.Ok -and $refCand.Probe.Data.scorer.available) {
        $sc = ConvertTo-PLlmHashtable $refCand.Probe.Data.scorer.scores
        $supported = @(); foreach ($k in $sc.Keys) { if ([int]$sc[$k] -gt 0) { $supported += $k } }
        $scorerText = ('predicted CPU kernel set = {0}   (host can run: {1})' -f $refCand.Probe.Data.scorer.predicted, ($supported -join ', '))
    } elseif ($refCand.Probe -and $refCand.Probe.Ok) { $scorerText = ('not available - {0}' -f $refCand.Probe.Data.scorer.reason) }
    elseif ($refCand.Probe) { $scorerText = ('not available - {0}' -f $refCand.Probe.Reason) }
    Write-Rep (' Bundled scorer    : {0}' -f $scorerText)
    Write-Rep '                     (llama.cpp''s own ggml_backend_score() called from the shipped ggml-cpu-*.dll files)' 'DarkGray'
    if ($pick) {
        $proven = @(); $unk = @()
        foreach ($k in $pick.Candidate.Features.Keys) {
            if ($pick.Candidate.Features[$k] -eq $true) { $proven += $k } elseif ($null -eq $pick.Candidate.Features[$k]) { $unk += $k }
        }
        Write-Rep (' Host features     : confirmed: {0}' -f $(if ($proven.Count) { $proven -join ' ' } else { 'none' }))
        if ($unk.Count) { Write-Rep ('                     unknown (not claimed): {0}' -f ($unk -join ' ')) 'DarkGray' }
    }
    Write-Rep ' Builds found      :'
    Write-Rep '                     ("COMPATIBLE" = files match the local manifest and the host meets its recorded minimum; it is not a proof of safety)' 'DarkGray'
    foreach ($r in $rows) {
        $col = 'Gray'
        switch ($r.Status) { 'COMPATIBLE' { $col = 'Green' } 'UNVERIFIED' { $col = 'Yellow' } 'REJECTED' { $col = 'Red' } 'MISSING' { $col = 'Red' } }
        Write-Rep ('   [{0}] {1}  -  {2}' -f $r.Status, $r.Candidate.Name, $r.Reason) $col
        if ($r.Candidate.Verified -eq $false -and $r.Candidate.Manifest) {
            foreach ($pr in @($r.Candidate.Problems | Select-Object -First 4)) { Write-Rep ('       - {0}' -f $pr) 'Yellow' }
        }
    }

    $overridden = $false
    if (-not $pick) {
        $rej = @($rows | Where-Object { $_.Status -eq 'REJECTED' })
        if ($rej.Count -gt 0 -and $allowOverride) {
            $pick = $rej[0]; $kind = 'OVERRIDE'; $overridden = $true
            Write-Rep ''
            Write-Rep ' [WARN] Running a build that was REJECTED for this CPU because -AllowUnverified / PORTABLE_LLM_ALLOW_UNVERIFIED=1 is set.' 'Yellow'
            Write-Rep '        If the server dies with "illegal instruction" (0xC000001D), this is why.' 'Yellow'
        } else {
            Write-Rep ''
            Write-Rep ' [STOPPED] No build in the llama folder is known to be compatible with this CPU.' 'Red'
            foreach ($r in $rej) { Write-Rep ('   Reason: {0}' -f $r.Reason) 'Red' }
            Write-Rep '   Nothing was started, so you will not get a crash or a mysteriously slow run.' 'Red'
            Write-Rep '   Options: put a llama.cpp build compiled for older CPUs in llama\baseline\ (with its own build-manifest.json),' 'Red'
            Write-Rep '            or set PORTABLE_LLM_ALLOW_UNVERIFIED=1 to try the rejected build anyway (it may crash).' 'Red'
            exit 4
        }
    }
    $chosen = $pick.Candidate
    $verOk = ($kind -eq 'VERIFIED')
    if ($verOk) {
        $minTxt = (@($chosen.MinFeatures) -join ', ')
        $verText = ('FILES MATCH THE LOCAL ANALYSIS MANIFEST (integrity only). Static scan of these exact files recorded a minimum host ISA of {0}; the manifest is unsigned and stored beside the binaries, so its provenance is NOT established, and a static scan is not an execution test. CPU kernels are chosen by llama.cpp at run time.' -f $minTxt)
    } elseif ($overridden) {
        $verText = 'REJECTED FOR THIS CPU (override in effect); instruction-set compatibility NOT established'
    } else {
        $why = 'no build-manifest.json'
        if ($chosen.Problems -and @($chosen.Problems).Count -gt 0) { $why = @($chosen.Problems)[0] }
        $verText = ('UNVERIFIED ({0}). The instruction set actually used will be taken from llama.cpp''s own output after start-up.' -f $why)
    }
    Write-Rep ''
    Write-Rep (' Selected          : {0}' -f $chosen.Name) 'White'
    Write-Rep (' Build ISA verification: {0}' -f $verText) $(if ($verOk) { 'Cyan' } else { 'Yellow' })
    if ($kind -eq 'UNVERIFIED') {
        Write-Rep ' [WARN] This build is UNVERIFIED. Do not assume it is the fast build for your CPU; the ISA line printed after start-up is the evidence.' 'Yellow'
    }
    if ($chosen.Predicted) { Write-Rep (' Expected CPU kernel set at run time: {0}' -f $chosen.Predicted) 'White' }
    Write-Rep $line 'White'
    Write-Rep ''

    # ---- 4. models -------------------------------------------------------------------------------
    $modelDir = Join-Path $Root 'models'
    if (-not (Test-Path -LiteralPath $modelDir)) { Stop-Launcher 2 ('The models folder does not exist: {0}  Create it and put a .gguf model inside.' -f $modelDir) }
    $models = @(Get-ChildItem -LiteralPath $modelDir -Filter '*.gguf' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($models.Count -eq 0) { Stop-Launcher 2 ('No .gguf model files found in {0}' -f $modelDir) }

    $freeGb = $null
    try { $freeGb = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory / 1MB } catch { }
    Write-Host 'Available models:' -ForegroundColor White
    for ($i = 0; $i -lt $models.Count; $i++) {
        $sz = $models[$i].Length / 1GB
        Write-Host ('  [{0}] {1}   ({2:N2} GB)' -f ($i + 1), $models[$i].Name, $sz)
    }
    Write-Host ''
    $picked = $null
    if ($Choice -gt 0) {
        if ($Choice -le $models.Count) { $picked = $models[$Choice - 1] } else { Stop-Launcher 3 ('Invalid model selection: {0}. Choose a number from 1 to {1}.' -f $Choice, $models.Count) }
    } else {
        for ($try = 1; $try -le 3 -and -not $picked; $try++) {
            $answer = Read-Host $(if ($models.Count -eq 1) { 'Select model number (Enter = 1)' } else { 'Select model number' })
            if ([string]::IsNullOrWhiteSpace($answer) -and $models.Count -eq 1) { $answer = '1' }
            $n = 0
            if ([int]::TryParse($answer.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $models.Count) { $picked = $models[$n - 1] }
            else { Write-Host ('  Invalid selection "{0}". Enter a number from 1 to {1}.' -f $answer, $models.Count) -ForegroundColor Yellow }
        }
        if (-not $picked) { Stop-Launcher 3 'Invalid model selection (3 attempts).' }
    }
    $modelGb = $picked.Length / 1GB
    Write-Rep ('Model: {0} ({1:N2} GB)' -f $picked.Name, $modelGb) 'White'
    if ($null -ne $freeGb -and $modelGb -gt ($freeGb * 0.85)) {
        Write-Rep ('[WARN] Only {0:N1} GB of RAM is free and this model is {1:N2} GB. Expect heavy paging/slowness; close other programs or pick a smaller model/quant.' -f $freeGb, $modelGb) 'Yellow'
    }

    # ---- 5. command line -------------------------------------------------------------------------
    if (-not (Test-PLlmPortFree $port)) {
        Stop-Launcher 5 ('Port {0} is already in use (another Portable-LLM window, or another program). Run STOP.bat, or set PORT in CONFIG.bat.' -f $port)
    }
    $argList = @('-m', ('"{0}"' -f $picked.FullName), '-c', [string]$ctx, '--host', $hostName, '--port', [string]$port)
    $supportsCors = $false
    if ($chosen.Manifest -and $chosen.Verified -and $chosen.Manifest.supports_cli) { $supportsCors = (@($chosen.Manifest.supports_cli) -contains '--cors-origins') }
    else {
        $scan = @($chosen.Path) + @(Get-ChildItem -LiteralPath $chosen.Dir -Filter '*-impl.dll' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) + @(Join-Path $chosen.Dir 'llama-common.dll')
        $supportsCors = Test-PLlmBinaryContains -Paths $scan -Text '--cors-origins'
    }
    if ($supportsCors) { $argList += @('--cors-origins', 'localhost') }
    else { Write-Rep '[WARN] This llama-server does not advertise --cors-origins, so CORS cannot be restricted. Keep this window on trusted networks only.' 'Yellow' }
    $argText = ($argList -join ' ')
    $url = ('http://{0}:{1}' -f $(if ($hostName -eq '::1') { '[::1]' } else { $hostName }), $port)
    Write-Rep ('Command: "{0}" {1}' -f $chosen.Path, $argText) 'DarkGray'
    Write-Rep ('Server will listen on {0} only{1}.' -f $url, $(if ($supportsCors) { '; cross-site browser access limited to localhost origins (--cors-origins localhost)' } else { '' })) 'White'

    $hostText = ('{0} | Windows API: {1}' -f $cpuName, $pfText)
    if ($chosen.Predicted) { $hostText += (' | scorer predicts: {0}' -f $chosen.Predicted) }

    if ($DryRun) {
        Write-Rep ''
        Write-Rep '[DRY RUN] Everything above was checked; the server was NOT started.' 'Cyan'
        exit 0
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $logRoot = Join-Path $Root 'logs'
    $sessionDir = Join-Path $logRoot $stamp
    $quiet = ($env:PORTABLE_LLM_QUIET -eq '1')
    $openBrowser = (-not $NoBrowser.IsPresent -and $env:PORTABLE_LLM_NO_BROWSER -ne '1')
    Write-Rep ('Diagnostic log folder: {0}' -f $sessionDir) 'White'
    Write-Rep 'Starting llama.cpp server - the browser opens when the model has finished loading ...' 'White'
    Write-Rep ''

    $code = Invoke-PLlmServerMonitor -ServerExe $chosen.Path -ArgumentString $argText -WorkDir $chosen.Dir `
        -SessionDir $sessionDir -ModelName $picked.Name -Url $url -Port $port -HostFeatures $chosen.Features `
        -PredictedVariant $chosen.Predicted -HostText $hostText -VerificationText $verText -VerificationOk $verOk `
        -HeaderLines @($script:Report) -OpenBrowser $openBrowser -Quiet $quiet
    if ($code -eq -1073741510) { exit 0 }
    exit $code
}

try {
    Invoke-PLlmMain
} catch {
    Write-Host ''
    Write-Host ('[ERROR] Unexpected launcher failure: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ($_.ScriptStackTrace) -ForegroundColor DarkGray
    exit 1
}
