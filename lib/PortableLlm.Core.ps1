# Portable-LLM core logic.  Dot-source this file; it defines functions only (no side effects).
# ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less files as ANSI.
#
# Regex patterns are declared one per line, preceded by a "# REGEX:<name>" marker, so that
# tests\test_logic.py can load the exact same pattern text and exercise it against fixtures.

# ---------------------------------------------------------------------------------------------
# Regular expressions (.NET syntax; the subset used here is also valid in Python after (?<n> -> (?P<n>)
# ---------------------------------------------------------------------------------------------
# REGEX:TimingPrompt
$PLlmRx_TimingPrompt = 'prompt eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*(?:tokens|runs)(?:[^)]*?,\s*([-\w.]+)\s*tokens per second)?'
# REGEX:TimingEval
$PLlmRx_TimingEval = '(?<!prompt )eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*(?:tokens|runs)(?:[^)]*?,\s*([-\w.]+)\s*tokens per second)?'
# REGEX:TimingTotal
$PLlmRx_TimingTotal = 'total time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens'
# REGEX:SystemInfo
$PLlmRx_SystemInfo = 'system_info:\s*(.*)$'
# REGEX:SysInfoFlag
$PLlmRx_SysInfoFlag = '\b([A-Z][A-Z0-9_]*)\s*=\s*(\d+)'
# REGEX:Threads
$PLlmRx_Threads = 'n_threads\s*=\s*(\d+)'
# REGEX:BuildInfo
$PLlmRx_BuildInfo = '\bbuild(?:_info)?:\s*(\S.*)$'
# REGEX:LoadBackend
$PLlmRx_LoadBackend = 'loaded\s+(\S+)\s+backend\s+from\s+(.+?)\s*$'
# REGEX:Variant
$PLlmRx_Variant = 'ggml-cpu-([A-Za-z0-9_]+)\.dll'
# REGEX:Listening
$PLlmRx_Listening = '(?i)server is listening on|http server (?:is )?listening|listening on http'
# REGEX:CorsWarning
$PLlmRx_CorsWarning = 'CORS is set to allow all origins'

# ISA flags we show from llama.cpp's system_info line (order = display order)
$script:PLlmIsaFlagOrder = @('SSE3','SSSE3','AVX','AVX_VNNI','AVX2','F16C','FMA','BMI2','AVX512','AVX512_VBMI','AVX512_VNNI','AVX512_BF16','AMX_INT8','AMX_TILE')

# Upstream ggml CPU variant names -> declared requirements (also stored in llama\build-manifest.json)
$script:PLlmBase = @('SSE42','AVX','F16C','AVX2','BMI2','FMA')
$script:PLlmVariantTable = [ordered]@{
    'x64'            = @()
    'sse42'          = @('SSE42')
    'sandybridge'    = @('SSE42','AVX')
    'ivybridge'      = @('SSE42','AVX','F16C')
    'piledriver'     = @('SSE42','AVX','F16C','FMA')
    'haswell'        = $script:PLlmBase
    'alderlake'      = ($script:PLlmBase + @('AVX_VNNI'))
    'skylakex'       = ($script:PLlmBase + @('AVX512'))
    'cannonlake'     = ($script:PLlmBase + @('AVX512','AVX512_VBMI'))
    'cascadelake'    = ($script:PLlmBase + @('AVX512','AVX512_VNNI'))
    'icelake'        = ($script:PLlmBase + @('AVX512','AVX512_VBMI','AVX512_VNNI'))
    'cooperlake'     = ($script:PLlmBase + @('AVX512','AVX512_VNNI','AVX512_BF16'))
    'zen4'           = ($script:PLlmBase + @('AVX512','AVX512_VBMI','AVX512_VNNI','AVX512_BF16'))
    'sapphirerapids' = ($script:PLlmBase + @('AVX512','AVX512_VBMI','AVX512_VNNI','AVX512_BF16','AMX_TILE','AMX_INT8'))
}

# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------
function ConvertTo-PLlmDouble {
    # Returns $null for "inf", "nan", "-nan", empty, or anything that is not a plain number.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $v = 0.0
    $ok = [double]::TryParse($Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)
    if ($ok -and -not [double]::IsNaN($v) -and -not [double]::IsInfinity($v)) { return $v }
    return $null
}

function Format-PLlmNumber {
    param($Value, [string]$Format = '0.00')
    if ($null -eq $Value) { return 'n/a' }
    return ([double]$Value).ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

# ---------------------------------------------------------------------------------------------
# llama.cpp log parsing
# ---------------------------------------------------------------------------------------------
function ConvertFrom-PLlmTimingLine {
    # Returns $null, or an object: Kind = Prompt | Eval | Total, Ms, Tokens, TpsReported (may be $null), TpsComputed
    param([string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $kind = $null; $m = $null
    if ($Line -match $PLlmRx_TimingPrompt)     { $kind = 'Prompt'; $m = $Matches }
    elseif ($Line -match $PLlmRx_TimingEval)   { $kind = 'Eval';   $m = $Matches }
    elseif ($Line -match $PLlmRx_TimingTotal)  { $kind = 'Total';  $m = $Matches }
    if ($null -eq $kind) { return $null }
    $ms  = ConvertTo-PLlmDouble $m[1]
    $tok = [int]$m[2]
    $reported = $null
    if ($kind -ne 'Total' -and $m.Count -gt 3) { $reported = ConvertTo-PLlmDouble $m[3] }
    $computed = $null
    if ($null -ne $ms -and $ms -gt 0 -and $tok -gt 0) { $computed = $tok * 1000.0 / $ms }
    return [pscustomobject]@{ Kind = $kind; Ms = $ms; Tokens = $tok; TpsReported = $reported; TpsComputed = $computed }
}

function ConvertFrom-PLlmSystemInfo {
    # Parses the text after "system_info:" into flag name -> 0/1 plus thread count.
    param([string]$Line)
    if ($Line -notmatch $PLlmRx_SystemInfo) { return $null }
    $text = $Matches[1]
    $flags = [ordered]@{}
    foreach ($mm in [regex]::Matches($text, $PLlmRx_SysInfoFlag)) {
        $flags[$mm.Groups[1].Value] = [int]$mm.Groups[2].Value
    }
    $threads = $null
    if ($text -match $PLlmRx_Threads) { $threads = [int]$Matches[1] }
    $enabled = @()
    foreach ($n in $script:PLlmIsaFlagOrder) { if ($flags.Contains($n) -and $flags[$n] -eq 1) { $enabled += $n } }
    return [pscustomobject]@{ Flags = $flags; Enabled = $enabled; Threads = $threads; Raw = $text }
}

function ConvertFrom-PLlmLoadBackendLine {
    # "load_backend: loaded CPU backend from C:\...\ggml-cpu-haswell.dll"
    param([string]$Line)
    if ($Line -notmatch $PLlmRx_LoadBackend) { return $null }
    $kind = $Matches[1]; $path = $Matches[2]
    $variant = $null
    if ($path -match $PLlmRx_Variant) { $variant = $Matches[1] }
    return [pscustomobject]@{ Backend = $kind; Path = $path; Variant = $variant }
}

# ---------------------------------------------------------------------------------------------
# Request/session accounting
# ---------------------------------------------------------------------------------------------
function New-PLlmSession {
    return [pscustomobject]@{
        Requests = (New-Object System.Collections.ArrayList)
        Current  = $null
    }
}

function Add-PLlmTimingEvent {
    # Feeds one parsed timing event into the session. Returns a completed request record when a
    # "total time" line closes a request; otherwise $null.
    param($Session, $TimingEvent)
    if ($null -eq $TimingEvent) { return $null }
    switch ($TimingEvent.Kind) {
        'Prompt' { $Session.Current = [pscustomobject]@{ Prompt = $TimingEvent; Eval = $null; Total = $null; Seen = (Get-Date) }; return $null }
        'Eval'   {
            if ($null -eq $Session.Current) { $Session.Current = [pscustomobject]@{ Prompt = $null; Eval = $null; Total = $null; Seen = (Get-Date) } }
            $Session.Current.Eval = $TimingEvent
            return $null
        }
        'Total'  {
            if ($null -eq $Session.Current) { $Session.Current = [pscustomobject]@{ Prompt = $null; Eval = $null; Total = $null; Seen = (Get-Date) } }
            $c = $Session.Current
            $c.Total = $TimingEvent
            $rec = [pscustomobject]@{
                Index          = $Session.Requests.Count + 1
                Time           = $c.Seen
                PromptTokens   = $(if ($c.Prompt) { $c.Prompt.Tokens } else { $null })
                PromptMs       = $(if ($c.Prompt) { $c.Prompt.Ms } else { $null })
                PromptTps      = $(if ($c.Prompt) { $(if ($null -ne $c.Prompt.TpsReported) { $c.Prompt.TpsReported } else { $c.Prompt.TpsComputed }) } else { $null })
                PromptTpsFromLog = $(if ($c.Prompt) { ($null -ne $c.Prompt.TpsReported) } else { $false })
                GenTokens      = $(if ($c.Eval) { $c.Eval.Tokens } else { $null })
                GenMs          = $(if ($c.Eval) { $c.Eval.Ms } else { $null })
                GenTps         = $(if ($c.Eval) { $(if ($null -ne $c.Eval.TpsReported) { $c.Eval.TpsReported } else { $c.Eval.TpsComputed }) } else { $null })
                GenTpsFromLog  = $(if ($c.Eval) { ($null -ne $c.Eval.TpsReported) } else { $false })
                GenTpsComputed = $(if ($c.Eval) { $c.Eval.TpsComputed } else { $null })
                TotalMs        = $c.Total.Ms
                TotalTokens    = $c.Total.Tokens
            }
            [void]$Session.Requests.Add($rec)
            $Session.Current = $null
            return $rec
        }
    }
    return $null
}

function Get-PLlmSessionStats {
    # Token-weighted session averages (sum tokens / sum time), plus min/max of per-request rates.
    param($Session)
    $n = $Session.Requests.Count
    $gTok = 0; $gMs = 0.0; $pTok = 0; $pMs = 0.0
    $gMin = $null; $gMax = $null; $pMin = $null; $pMax = $null
    foreach ($r in $Session.Requests) {
        if ($null -ne $r.GenTokens -and $null -ne $r.GenMs -and $r.GenTokens -gt 0) {
            $gTok += $r.GenTokens; $gMs += $r.GenMs
            if ($null -ne $r.GenTps) {
                if ($null -eq $gMin -or $r.GenTps -lt $gMin) { $gMin = $r.GenTps }
                if ($null -eq $gMax -or $r.GenTps -gt $gMax) { $gMax = $r.GenTps }
            }
        }
        if ($null -ne $r.PromptTokens -and $null -ne $r.PromptMs -and $r.PromptTokens -gt 0) {
            $pTok += $r.PromptTokens; $pMs += $r.PromptMs
            if ($null -ne $r.PromptTps) {
                if ($null -eq $pMin -or $r.PromptTps -lt $pMin) { $pMin = $r.PromptTps }
                if ($null -eq $pMax -or $r.PromptTps -gt $pMax) { $pMax = $r.PromptTps }
            }
        }
    }
    $gAvg = $null; if ($gMs -gt 0) { $gAvg = $gTok * 1000.0 / $gMs }
    $pAvg = $null; if ($pMs -gt 0) { $pAvg = $pTok * 1000.0 / $pMs }
    return [pscustomobject]@{
        Requests = $n
        GenTokens = $gTok; GenSeconds = ($gMs / 1000.0); GenAvgTps = $gAvg; GenMinTps = $gMin; GenMaxTps = $gMax
        PromptTokens = $pTok; PromptSeconds = ($pMs / 1000.0); PromptAvgTps = $pAvg; PromptMinTps = $pMin; PromptMaxTps = $pMax
    }
}

function Format-PLlmTag {
    # Compact "[CPU/haswell | AVX2 FMA F16C BMI2 | model.gguf]" tag; unknown parts are shown as "?" - never guessed.
    param($BackendInfo, $SysInfo, [string]$ModelName)
    $b = '?'
    if ($BackendInfo) {
        $b = [string]$BackendInfo.Backend
        if ($BackendInfo.Variant) { $b = $b + '/' + $BackendInfo.Variant }
    }
    $isa = '?'
    if ($SysInfo) { if ($SysInfo.Enabled.Count -gt 0) { $isa = ($SysInfo.Enabled -join ' ') } else { $isa = 'no SIMD flags' } }
    $m = '?'
    if ($ModelName) { $m = $ModelName }
    return ('[{0} | {1} | {2}]' -f $b, $isa, $m)
}

function Format-PLlmRequestLine {
    param($Request, [string]$Tag)
    $p = 'prompt: n/a'
    if ($null -ne $Request.PromptTokens) {
        $p = ('prompt processing {0} tok @ {1} tok/s' -f $Request.PromptTokens, (Format-PLlmNumber $Request.PromptTps))
        if (-not $Request.PromptTpsFromLog) { $p += ' (computed)' }
    }
    $g = 'generation: n/a'
    if ($null -ne $Request.GenTokens) {
        $g = ('generation {0} tok in {1} s @ {2} tok/s' -f $Request.GenTokens, (Format-PLlmNumber ($Request.GenMs / 1000.0)), (Format-PLlmNumber $Request.GenTps))
        if (-not $Request.GenTpsFromLog) { $g += ' (computed)' }
        elseif ($null -ne $Request.GenTpsComputed -and [math]::Abs($Request.GenTpsComputed - $Request.GenTps) -gt 0.011) {
            $g += (' (tokens/ms give {0})' -f (Format-PLlmNumber $Request.GenTpsComputed))
        }
    }
    $t = ('total {0} s ({1} tok)' -f (Format-PLlmNumber ($Request.TotalMs / 1000.0)), $Request.TotalTokens)
    return ('[req #{0} {1}] {2}  {3} | {4} | {5}' -f $Request.Index, $Request.Time.ToString('HH:mm:ss'), $Tag, $p, $g, $t)
}

function Format-PLlmSessionLine {
    param($Stats)
    $g = 'generation n/a'
    if ($null -ne $Stats.GenAvgTps) {
        $g = ('generation {0} tok/s avg over {1} tok [min {2}, max {3}]' -f (Format-PLlmNumber $Stats.GenAvgTps), $Stats.GenTokens, (Format-PLlmNumber $Stats.GenMinTps), (Format-PLlmNumber $Stats.GenMaxTps))
    }
    $p = 'prompt n/a'
    if ($null -ne $Stats.PromptAvgTps) {
        $p = ('prompt processing {0} tok/s avg over {1} tok [min {2}, max {3}]' -f (Format-PLlmNumber $Stats.PromptAvgTps), $Stats.PromptTokens, (Format-PLlmNumber $Stats.PromptMinTps), (Format-PLlmNumber $Stats.PromptMaxTps))
    }
    return ('   session ({0} request(s)): {1} | {2}' -f $Stats.Requests, $g, $p)
}

# ---------------------------------------------------------------------------------------------
# Exit-code hints (Windows NTSTATUS values as reported by .NET: signed 32-bit)
# ---------------------------------------------------------------------------------------------
function Get-PLlmExitHint {
    param([int]$Code)
    switch ($Code) {
        0           { return 'normal exit' }
        -1073741510 { return 'stopped by Ctrl+C / console close (0xC000013A)' }
        -1073741795 { return 'ILLEGAL INSTRUCTION (0xC000001D): a binary used a CPU instruction this CPU does not have. This is a wrong-ISA build/DLL, not a slow model.' }
        -1073741819 { return 'access violation (0xC0000005): crash inside the server or a DLL' }
        -1073741515 { return 'a required DLL was not found (0xC0000135): missing file in llama\, or the Visual C++ runtime is not installed' }
        -1073741701 { return 'bad image (0xC000007B): a DLL has the wrong architecture or is corrupted' }
        -1073740791 { return 'stack buffer overrun / fail-fast (0xC0000409)' }
        -1073740940 { return 'heap corruption (0xC0000374)' }
        default     { return 'non-zero exit code' }
    }
}

# ---------------------------------------------------------------------------------------------
# Host features and variant prediction
# ---------------------------------------------------------------------------------------------
function Resolve-PLlmHostFeatures {
    # Merges Windows IsProcessorFeaturePresent results with the bundled-scorer results.
    # Each feature becomes $true, $false or $null (unknown). Unknown is never treated as supported.
    #   Pf     : hashtable SSE42/AVX/AVX2/AVX512 -> $true/$false/$null
    #   Scores : hashtable variant -> int score (0 = host cannot run it), or $null when the scorer is unavailable
    #   Table  : variant -> declared requirements (defaults to the built-in table)
    param($Pf, $Scores, $Table)
    if ($null -eq $Table) { $Table = $script:PLlmVariantTable }
    $feat = [ordered]@{}
    foreach ($name in @('SSE42','AVX','F16C','AVX2','BMI2','FMA','AVX512','AVX_VNNI','AVX512_VBMI','AVX512_VNNI','AVX512_BF16','AMX_TILE','AMX_INT8')) { $feat[$name] = $null }
    if ($Pf) {
        foreach ($k in @('SSE42','AVX','AVX2','AVX512')) {
            if ($Pf.ContainsKey($k) -and $null -ne $Pf[$k]) { $feat[$k] = [bool]$Pf[$k] }
        }
    }
    if ($Scores) {
        # A variant with a non-zero score proves every feature it declares (the scorer is llama.cpp's own check).
        foreach ($v in $Table.Keys) {
            if ($Scores.ContainsKey($v) -and $null -ne $Scores[$v] -and [int]$Scores[$v] -gt 0) {
                foreach ($f in $Table[$v]) { $feat[$f] = $true }
            }
        }
    }
    return $feat
}

function Get-PLlmPredictedVariant {
    # Highest non-zero scorer result, i.e. what ggml's loader will pick. $null if no scores or none supported.
    param($Scores)
    if ($null -eq $Scores) { return $null }
    $best = $null; $bestScore = 0
    foreach ($k in $Scores.Keys) {
        $s = $Scores[$k]
        if ($null -ne $s -and [int]$s -gt $bestScore) { $bestScore = [int]$s; $best = $k }
    }
    return $best
}

# ---------------------------------------------------------------------------------------------
# Build verification and selection
# ---------------------------------------------------------------------------------------------
function Get-PLlmFileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { $hash = $sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-PLlmManifest {
    # Compares the files in $Dir with the SHA-256 values recorded in the manifest.
    # Verified = every listed file present with matching hash AND no unlisted ggml-cpu-*.dll (it could be loaded and win).
    param([string]$Dir, $Manifest, [scriptblock]$HashFunction)
    $problems = New-Object System.Collections.ArrayList
    if ($null -eq $HashFunction) { $HashFunction = { param($p) Get-PLlmFileSha256 $p } }
    $listed = @{}
    $entries = @()
    if ($Manifest.core_modules) { $entries += @($Manifest.core_modules) }
    if ($Manifest.cpu_variants) { $entries += @($Manifest.cpu_variants) }
    foreach ($e in $entries) {
        $listed[$e.file.ToLowerInvariant()] = $true
        $p = Join-Path $Dir $e.file
        if (-not (Test-Path -LiteralPath $p)) { [void]$problems.Add(('missing file: {0}' -f $e.file)); continue }
        $h = & $HashFunction $p
        if ($h -ne $e.sha256) { [void]$problems.Add(('hash differs from analysed file: {0}' -f $e.file)) }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter 'ggml-cpu-*.dll' -ErrorAction SilentlyContinue)) {
        if (-not $listed.ContainsKey($f.Name.ToLowerInvariant())) { [void]$problems.Add(('unlisted CPU backend DLL (not analysed): {0}' -f $f.Name)) }
    }
    return [pscustomobject]@{ Verified = ($problems.Count -eq 0); Problems = @($problems) }
}

function Select-PLlmBuild {
    # Pure selection logic.
    #   Candidates: objects with Path, Exists, Manifest ($null if none), Verified, Problems, MinFeatures, Preference
    #   HostFeatures: ordered table feature -> $true/$false/$null
    # Rules:
    #   1. A verified candidate whose every required feature is $true on the host is "compatible". Highest Preference wins.
    #   2. Otherwise an UNVERIFIED candidate is used as a fallback (flagged UNVERIFIED), never reported as verified.
    #   3. Verified-but-incompatible candidates are never selected here (the caller decides about an explicit override).
    param($Candidates, $HostFeatures)
    $rows = @()
    foreach ($c in $Candidates) {
        $status = ''; $reason = ''
        if (-not $c.Exists) { $status = 'MISSING'; $reason = 'executable not found' }
        else {
            $missing = @(); $unknown = @()
            foreach ($f in @($c.MinFeatures)) {
                if ([string]::IsNullOrEmpty($f)) { continue }
                $have = $null
                if ($HostFeatures -and $HostFeatures.Contains($f)) { $have = $HostFeatures[$f] }
                if ($have -eq $false) { $missing += $f } elseif ($null -eq $have) { $unknown += $f }
            }
            if ($c.Verified) {
                if ($missing.Count -gt 0) { $status = 'REJECTED'; $reason = ('host CPU lacks ' + ($missing -join ', ') + ' required by this build') }
                elseif ($unknown.Count -gt 0) { $status = 'REJECTED'; $reason = ('cannot confirm host support for ' + ($unknown -join ', ')) }
                else { $status = 'COMPATIBLE'; $reason = 'verified by file hashes; host meets the verified minimum' }
            } else {
                $status = 'UNVERIFIED'
                if ($c.Problems -and @($c.Problems).Count -gt 0) { $reason = (@($c.Problems)[0]) } else { $reason = 'no build manifest; compile-time ISA unknown' }
                if ($missing.Count -gt 0) { $status = 'REJECTED'; $reason = ('host CPU lacks ' + ($missing -join ', ')) }
            }
        }
        $rows += [pscustomobject]@{ Candidate = $c; Status = $status; Reason = $reason }
    }
    $pick = $null; $pickKind = 'NONE'
    $ok = @($rows | Where-Object { $_.Status -eq 'COMPATIBLE' } | Sort-Object { -[int]$_.Candidate.Preference })
    if ($ok.Count -gt 0) { $pick = $ok[0]; $pickKind = 'VERIFIED' }
    else {
        $uv = @($rows | Where-Object { $_.Status -eq 'UNVERIFIED' })
        if ($uv.Count -gt 0) { $pick = $uv[0]; $pickKind = 'UNVERIFIED' }
    }
    return [pscustomobject]@{ Rows = $rows; Selected = $pick; Kind = $pickKind }
}

# ---------------------------------------------------------------------------------------------
# Backend-vs-host cross-check ("fail loud")
# ---------------------------------------------------------------------------------------------
function Test-PLlmBackendAgainstHost {
    # Returns a list of findings: Level = OK | INFO | WARN | FAIL.  Never claims more than the evidence shows.
    param($HostFeatures, $PredictedVariant, $BackendInfo, $SysInfo)
    $out = New-Object System.Collections.ArrayList
    function Add-F([string]$Level, [string]$Text) { [void]$out.Add([pscustomobject]@{ Level = $Level; Text = $Text }) }
    if ($null -eq $BackendInfo) {
        Add-F 'INFO' 'llama.cpp did not report which CPU backend it loaded (no "loaded ... backend from" line seen); backend is UNKNOWN.'
    }
    elseif ($BackendInfo.Variant -and $PredictedVariant) {
        if ($BackendInfo.Variant -eq $PredictedVariant) {
            Add-F 'OK' ('Loaded CPU backend "{0}" matches the variant predicted by the bundled scorer.' -f $BackendInfo.Variant)
        } else {
            Add-F 'WARN' ('Loaded CPU backend "{0}" but the bundled scorer predicted "{1}" for this host. llama.cpp may be running a different (possibly slower) kernel set than expected; check llama\ for missing/replaced ggml-cpu-*.dll files.' -f $BackendInfo.Variant, $PredictedVariant)
        }
    }
    elseif ($BackendInfo.Variant) {
        Add-F 'INFO' ('Loaded CPU backend "{0}"; no scorer prediction available to compare against.' -f $BackendInfo.Variant)
    }
    if ($SysInfo -and $HostFeatures) {
        $hostAvx2 = $HostFeatures['AVX2']
        $flagAvx2 = $null; if ($SysInfo.Flags.Contains('AVX2')) { $flagAvx2 = $SysInfo.Flags['AVX2'] }
        if ($hostAvx2 -eq $true -and $flagAvx2 -eq 0) {
            Add-F 'FAIL' 'Host CPU supports AVX2 but the loaded llama.cpp backend was built WITHOUT AVX2: matrix kernels are on a slower SSE/AVX/scalar path. Slowness here is a build/DLL problem, not the model.'
        }
        $hostAvx512 = $HostFeatures['AVX512']
        if ($hostAvx512 -eq $true -and $SysInfo.Flags.Contains('AVX512') -and $SysInfo.Flags['AVX512'] -eq 0) {
            Add-F 'INFO' 'Host supports AVX-512 but the loaded backend does not use it. That is not necessarily a problem (AVX2 variants are often as fast on memory-bound generation).'
        }
    } elseif (-not $SysInfo) {
        Add-F 'INFO' 'No "system_info" line seen yet; compile-time ISA flags of the loaded backend are UNKNOWN.'
    }
    return @($out)
}
