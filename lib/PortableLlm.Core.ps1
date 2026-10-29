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
$PLlmRx_Listening = '(?i)\blistening on\b|http server (?:is )?listening'
# REGEX:CorsWarning
$PLlmRx_CorsWarning = 'CORS is set to allow all origins'

# REGEX:CtxReported
$PLlmRx_CtxReported = '\bn_ctx(?:_seq)?\s*=\s*(\d+)'
# REGEX:ModelLoadStart
$PLlmRx_ModelLoadStart = '\(startup\) loading model|\bllama_model_loader:|\bload_tensors:'
# REGEX:ModelLoaded
$PLlmRx_ModelLoaded = '(?i)\bmodel loaded\b|all slots are idle'
# REGEX:ErrorLine
$PLlmRx_ErrorLine = '(?i)\b(?:error|fatal|exception)\b(?!\s*=\s*0)|\bfailed to\b|\bunable to\b|couldn''t|\bcannot\b|out of memory|\bbad_alloc\b'
# REGEX:WarnLine
$PLlmRx_WarnLine = '(?i)\bwarn(?:ing)?\b'

# REGEX:TaskStart
$PLlmRx_TaskStart = 'task\s+(-?\d+)\s*\|\s*processing task'
# REGEX:TaskEnd
$PLlmRx_TaskEnd = 'task\s+(-?\d+)\s*\|\s*stop processing'

# Shown in the dashboard header.  Change it here only.
$script:PLlmVersion = '2.1'

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
        Incomplete = 0
    }
}

function Add-PLlmTimingEvent {
    # Feeds one parsed timing event into the session. Returns a completed request record when a
    # "total time" line closes a request; otherwise $null.
    param($Session, $TimingEvent)
    if ($null -eq $TimingEvent) { return $null }
    switch ($TimingEvent.Kind) {
        'Prompt' {
            # a previous request that never reached its "total time" line is counted, not silently dropped
            if ($null -ne $Session.Current -and $null -eq $Session.Current.Total) { $Session.Incomplete++ }
            $Session.Current = [pscustomobject]@{ Prompt = $TimingEvent; Eval = $null; Total = $null; Seen = (Get-Date) }; return $null }
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
        Requests = $n; Incomplete = $Session.Incomplete
        GenTokens = $gTok; GenSeconds = ($gMs / 1000.0); GenAvgTps = $gAvg; GenMinTps = $gMin; GenMaxTps = $gMax
        PromptTokens = $pTok; PromptSeconds = ($pMs / 1000.0); PromptAvgTps = $pAvg; PromptMinTps = $pMin; PromptMaxTps = $pMax
    }
}

function Format-PLlmTag {
    # Compact "[CPU/haswell | AVX2 FMA F16C BMI2 | model.gguf]" tag; unknown parts say UNKNOWN - never guessed.
    param($BackendInfo, $SysInfo, [string]$ModelName)
    $b = 'backend UNKNOWN'
    if ($BackendInfo) {
        $b = [string]$BackendInfo.Backend
        if ($BackendInfo.Variant) { $b = $b + '/' + $BackendInfo.Variant }
    }
    $isa = 'ISA UNKNOWN'
    if ($SysInfo) { if ($SysInfo.Enabled.Count -gt 0) { $isa = ($SysInfo.Enabled -join ' ') } else { $isa = 'no SIMD flags' } }
    $m = 'model UNKNOWN'
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
    # The bundled scorer reads CPUID bits only (disassembly: no XGETBV in ggml_backend_score). If Windows says the OS
    # does not provide a feature, treat it as unavailable even when the scorer accepted a variant: conservative.
    if ($Pf) {
        foreach ($k in @('SSE42','AVX','AVX2','AVX512')) {
            if ($Pf.ContainsKey($k) -and $Pf[$k] -eq $false) { $feat[$k] = $false }
        }
    }
    return $feat
}

function Get-PLlmPredictedVariant {
    # Mirrors the loader rule seen in ggml.dll (strictly greater score wins; 0 never wins).
    # Returns $null when there are no scores, no non-zero score, or the top score is shared by two variants
    # (the winner then depends on file enumeration order, which we do not claim to know).
    param($Scores)
    if ($null -eq $Scores) { return $null }
    $bestScore = 0
    foreach ($k in $Scores.Keys) { if ($null -ne $Scores[$k] -and [int]$Scores[$k] -gt $bestScore) { $bestScore = [int]$Scores[$k] } }
    if ($bestScore -le 0) { return $null }
    $top = @()
    foreach ($k in $Scores.Keys) { if ($null -ne $Scores[$k] -and [int]$Scores[$k] -eq $bestScore) { $top += $k } }
    if ($top.Count -ne 1) { return $null }
    return $top[0]
}

function Get-PLlmResolvedBackend {
    # The loaded CPU backend is known ONLY if llama.cpp logged exactly one distinct "loaded CPU backend from <path>".
    # Zero lines -> $null (UNKNOWN). Several different paths -> $null (AMBIGUOUS). Never inferred from host CPU or file names on disk.
    param($Seen)
    $paths = @{}
    foreach ($b in @($Seen)) { if ($b -and $b.Path) { $paths[$b.Path.ToLowerInvariant()] = $b } }
    if ($paths.Count -eq 1) { return @($paths.Values)[0] }
    return $null
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

function Test-PLlmManifestSchema {
    # Structural validation. A manifest that fails here must never produce "verified" (an empty manifest used to pass).
    param($Manifest)
    $errs = New-Object System.Collections.ArrayList
    if ($null -eq $Manifest) { return @('manifest is empty') }
    if ($Manifest.schema -ne 1) { [void]$errs.Add('unsupported or missing schema version') }
    $core = @(); if ($Manifest.core_modules) { $core = @($Manifest.core_modules) }
    $vars = @(); if ($Manifest.cpu_variants) { $vars = @($Manifest.cpu_variants) }
    if ($core.Count -eq 0) { [void]$errs.Add('core_modules is missing or empty') }
    $names = @{}
    foreach ($e in ($core + $vars)) {
        if ($null -eq $e -or [string]::IsNullOrEmpty([string]$e.file)) { [void]$errs.Add('entry without a file name'); continue }
        $f = [string]$e.file
        if ($f -match '[\\/:*?"<>|]' -or $f -eq '.' -or $f -eq '..' -or $f.Contains('..') -or $f -match '[. ]$' -or $f -match '^(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$') { [void]$errs.Add(('unsafe file name in manifest: {0}' -f $f)) }
        if (([string]$e.sha256) -notmatch '^[0-9a-fA-F]{64}$') { [void]$errs.Add(('bad sha256 for {0}' -f $f)) }
        if ($names.ContainsKey($f.ToLowerInvariant())) { [void]$errs.Add(('duplicate entry: {0}' -f $f)) }
        $names[$f.ToLowerInvariant()] = $true
    }
    foreach ($req in @('llama-server.exe', 'ggml.dll', 'ggml-base.dll', 'llama.dll')) {
        if (-not $names.ContainsKey($req)) { [void]$errs.Add(('required module not listed: {0}' -f $req)) }
    }
    $allowed = @('SSE42','AVX','F16C','AVX2','BMI2','FMA','AVX512','AVX_VNNI','AVX512_VBMI','AVX512_VNNI','AVX512_BF16','AMX_TILE','AMX_INT8')
    foreach ($m in @($Manifest.min_host_features)) {
        if ($m -and ($allowed -notcontains [string]$m)) { [void]$errs.Add(('unknown min_host_features entry: {0}' -f $m)) }
    }
    return @($errs)
}

function Test-PLlmManifest {
    # Compares the files in $Dir with the SHA-256 values recorded in the manifest.  Result.Verified means ONLY:
    #   "the manifest is structurally valid, matches its sidecar digest (if present), every listed file is present with the
    #    recorded hash, and no extra ggml-*.dll exists".  It does NOT establish who produced the manifest.
    param([string]$Dir, $Manifest, [string]$ManifestPath, [scriptblock]$HashFunction)
    $problems = New-Object System.Collections.ArrayList
    if ($null -eq $HashFunction) { $HashFunction = { param($p) Get-PLlmFileSha256 $p } }
    foreach ($e in (Test-PLlmManifestSchema $Manifest)) { [void]$problems.Add(('invalid manifest: {0}' -f $e)) }
    $sidecarState = 'absent'
    if ($ManifestPath) {
        $side = $ManifestPath + '.sha256'
        if (Test-Path -LiteralPath $side) {
            $want = ((Get-Content -LiteralPath $side -Raw) -split '\s+')[0].Trim().ToLowerInvariant()
            $have = (& $HashFunction $ManifestPath)
            if ($want -notmatch '^[0-9a-f]{64}$') { $sidecarState = 'MALFORMED'; [void]$problems.Add('build-manifest.json.sha256 does not contain a valid SHA-256 digest') }
            elseif ($want -eq $have) { $sidecarState = 'matches' } else { $sidecarState = 'MISMATCH'; [void]$problems.Add('manifest does not match build-manifest.json.sha256 (edited or corrupted)') }
        } else { [void]$problems.Add('no build-manifest.json.sha256 sidecar (manifest integrity unchecked)') }
    }
    if ($problems.Count -eq 0 -or $Manifest) {
        $listed = @{}
        $entries = @()
        if ($Manifest.core_modules) { $entries += @($Manifest.core_modules) }
        if ($Manifest.cpu_variants) { $entries += @($Manifest.cpu_variants) }
        foreach ($e in $entries) {
            if ($null -eq $e -or [string]::IsNullOrEmpty([string]$e.file) -or ([string]$e.file) -match '[\\/:]') { continue }
            $listed[([string]$e.file).ToLowerInvariant()] = $true
            $p = Join-Path $Dir $e.file
            if (-not (Test-Path -LiteralPath $p)) { [void]$problems.Add(('missing file: {0}' -f $e.file)); continue }
            $h = & $HashFunction $p
            if ($h -ne ([string]$e.sha256).ToLowerInvariant()) { [void]$problems.Add(('hash differs: {0} (not the file that was analysed)' -f $e.file)) }
        }
        # ggml's loader scans the folder for ggml-*.dll backends (CPU variants, and GPU backends such as vulkan/cuda)
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter 'ggml-*.dll' -ErrorAction SilentlyContinue)) {
            if (-not $listed.ContainsKey($f.Name.ToLowerInvariant())) { [void]$problems.Add(('unlisted backend DLL: {0} (not analysed; the loader could load it)' -f $f.Name)) }
        }
    }
    return [pscustomobject]@{ Verified = ($problems.Count -eq 0); Problems = @($problems); SidecarState = $sidecarState }
}

function Select-PLlmBuild {
    # Pure, deterministic selection.
    #   Candidates: objects with Name, Exists, Verified, Problems, MinFeatures, Preference and (optionally) Features, the
    #               candidate's own host-feature table. HostFeatures is used for candidates that carry no table.
    #   Features:   ordered table feature -> $true / $false / $null (unknown). Unknown is NEVER treated as supported.
    # Rules:
    #   1. COMPATIBLE = manifest verified AND every recorded minimum feature is confirmed $true on this host.
    #   2. A recorded minimum that the host lacks ($false) or cannot confirm ($null) -> REJECTED. This applies to
    #      unverified builds too whenever a structurally valid manifest recorded a minimum (fail closed).
    #   3. UNVERIFIED (no manifest, or files differ from it) is only a fallback when nothing is COMPATIBLE.
    #      A build with no manifest has NO recorded requirements; that is stated, never guessed from file names.
    #   4. Among COMPATIBLE builds: highest Preference, then Name (deterministic; Sort-Object alone is not stable in WinPS 5.1).
    param($Candidates, $HostFeatures)
    $rows = @()
    foreach ($c in $Candidates) {
        $status = ''; $reason = ''; $missing = @(); $unknown = @()
        $feat = $HostFeatures
        if ($c.PSObject.Properties['Features'] -and $c.Features) { $feat = $c.Features }
        if (-not $c.Exists) { $status = 'MISSING'; $reason = 'executable not found' }
        else {
            foreach ($f in @($c.MinFeatures)) {
                if ([string]::IsNullOrEmpty($f)) { continue }
                $have = $null
                if ($feat -and $feat.Contains($f)) { $have = $feat[$f] }
                if ($have -eq $false) { $missing += $f } elseif ($null -eq $have) { $unknown += $f }
            }
            if ($missing.Count -gt 0) { $status = 'REJECTED'; $reason = ('host CPU lacks ' + ($missing -join ', ') + ' required by this build') }
            elseif ($unknown.Count -gt 0) { $status = 'REJECTED'; $reason = ('cannot confirm host support for ' + ($unknown -join ', ') + ', which this build requires (unknown is not treated as supported)') }
            elseif ($c.Verified) { $status = 'COMPATIBLE'; $reason = 'files match the local manifest; host meets its recorded minimum' }
            else {
                $status = 'UNVERIFIED'
                if ($c.Problems -and @($c.Problems).Count -gt 0) { $reason = (@($c.Problems)[0]) } else { $reason = 'no build manifest; compile-time ISA unknown' }
            }
        }
        $rows += [pscustomobject]@{ Candidate = $c; Status = $status; Reason = $reason; Missing = @($missing); Unknown = @($unknown) }
    }
    $pick = $null; $pickKind = 'NONE'
    $ok = @($rows | Where-Object { $_.Status -eq 'COMPATIBLE' } | Sort-Object @{ Expression = { -[int]$_.Candidate.Preference } }, @{ Expression = { [string]$_.Candidate.Name } })
    if ($ok.Count -gt 0) { $pick = $ok[0]; $pickKind = 'VERIFIED' }
    else {
        $uv = @($rows | Where-Object { $_.Status -eq 'UNVERIFIED' } | Sort-Object @{ Expression = { -[int]$_.Candidate.Preference } }, @{ Expression = { [string]$_.Candidate.Name } })
        if ($uv.Count -gt 0) { $pick = $uv[0]; $pickKind = 'UNVERIFIED' }
    }
    $summary = ''
    if ($pick) { $summary = ('Selected {0} ({1}): {2}' -f $pick.Candidate.Name, $pickKind, $pick.Reason) }
    else { $summary = 'No build can be started: ' + ((@($rows | ForEach-Object { '{0}: {1}' -f $_.Candidate.Name, $_.Reason })) -join '; ') }
    return [pscustomobject]@{ Rows = $rows; Selected = $pick; Kind = $pickKind; Summary = $summary }
}

function Select-PLlmOverrideRow {
    # Only used when the user explicitly overrides.  Never changes a status; just picks the least risky rejected build:
    # one rejected only because support is UNKNOWN beats one the host is KNOWN to lack; then Preference, then Name.
    param($Rows)
    $rej = @($Rows | Where-Object { $_.Status -eq 'REJECTED' })
    if ($rej.Count -eq 0) { return $null }
    return @($rej | Sort-Object @{ Expression = { @($_.Missing).Count } }, @{ Expression = { -[int]$_.Candidate.Preference } }, @{ Expression = { [string]$_.Candidate.Name } })[0]
}

# ---------------------------------------------------------------------------------------------
# Backend-vs-host cross-check ("fail loud")
# ---------------------------------------------------------------------------------------------
function Test-PLlmBackendAgainstHost {
    # Returns a list of findings: Level = OK | INFO | WARN | FAIL.  Never claims more than the evidence shows.
    param($HostFeatures, $PredictedVariant, $BackendInfo, $SysInfo, [bool]$BackendAmbiguous = $false)
    $out = New-Object System.Collections.ArrayList
    function Add-F([string]$Level, [string]$Text) { [void]$out.Add([pscustomobject]@{ Level = $Level; Text = $Text }) }
    if ($null -eq $BackendInfo -and $BackendAmbiguous) {
        Add-F 'WARN' 'llama.cpp logged several different "loaded CPU backend" paths; which one is in use is UNKNOWN (not guessed).'
    }
    elseif ($null -eq $BackendInfo) {
        Add-F 'INFO' 'llama.cpp did not report which CPU backend it loaded (no "loaded CPU backend from" line seen); backend is UNKNOWN. The host CPU and DLL file names on disk are not used to guess it.'
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

# ---------------------------------------------------------------------------------------------
# Dashboard helpers (pure: no console, no processes)
# ---------------------------------------------------------------------------------------------
function Close-PLlmSession {
    # Call once when the server has exited: a request that started but never finished counts as incomplete.
    param($Session)
    if ($null -ne $Session.Current -and $null -eq $Session.Current.Total) { $Session.Incomplete++ }
    $Session.Current = $null
}

function Format-PLlmBytes {
    param($Bytes)
    if ($null -eq $Bytes) { return 'unknown' }
    $b = [double]$Bytes
    if ($b -ge 1GB) { return ((Format-PLlmNumber ($b / 1GB) '0.00') + ' GB') }
    if ($b -ge 1MB) { return ((Format-PLlmNumber ($b / 1MB) '0') + ' MB') }
    return ((Format-PLlmNumber ($b / 1KB) '0') + ' KB')
}

function Format-PLlmDuration {
    param([TimeSpan]$Span)
    if ($Span.TotalDays -ge 1) { return ('{0}d {1:00}:{2:00}:{3:00}' -f [int][math]::Floor($Span.TotalDays), $Span.Hours, $Span.Minutes, $Span.Seconds) }
    return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
}

# Memory thresholds (measured values only).  Levels: ok | warn | crit | unknown
$script:PLlmMemThresholds = @{ WarnUsedPct = 85; CritUsedPct = 95; WarnAvailGB = 1.5; CritAvailGB = 0.75; HystPct = 3; HystGB = 0.25 }
function Get-PLlmMemoryLevel {
    # Previous gives hysteresis so the level does not flap around a threshold.
    param($TotalBytes, $AvailBytes, [string]$Previous = 'ok')
    if ($null -eq $TotalBytes -or $null -eq $AvailBytes -or [double]$TotalBytes -le 0) { return 'unknown' }
    $th = $script:PLlmMemThresholds
    $usedPct = 100.0 * ([double]$TotalBytes - [double]$AvailBytes) / [double]$TotalBytes
    $availGb = [double]$AvailBytes / 1GB
    $hp = 0.0; $hg = 0.0
    $critHp = 0.0; $critHg = 0.0
    if ($Previous -eq 'crit') { $critHp = $th.HystPct; $critHg = $th.HystGB }
    if ($Previous -eq 'warn' -or $Previous -eq 'crit') { $hp = $th.HystPct; $hg = $th.HystGB }
    if ($usedPct -ge ($th.CritUsedPct - $critHp) -or $availGb -lt ($th.CritAvailGB + $critHg)) { return 'crit' }
    if ($usedPct -ge ($th.WarnUsedPct - $hp) -or $availGb -lt ($th.WarnAvailGB + $hg)) { return 'warn' }
    return 'ok'
}

function Get-PLlmErrorHint {
    # Maps a llama.cpp error line to one actionable sentence, or $null when there is nothing specific to say.
    param([string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $rules = @(
        @('couldn''t bind|failed to bind|address already in use|WSAEADDRINUSE', 'The port is already in use. Close the other Portable-LLM window or change PORT in CONFIG.bat.'),
        @('out of memory|failed to allocate|unable to allocate|bad_alloc|ggml_aligned_malloc', 'Not enough memory. Close other programs, choose a smaller model or quantization, or lower CONTEXT in CONFIG.bat.'),
        @('unknown model architecture', 'This llama.cpp build does not know this model type. Use a newer llama.cpp build or another model.'),
        @('invalid magic|not a gguf|failed to read magic|gguf_init_from_file', 'The file is not a valid GGUF model (incomplete download?). Download it again.'),
        @('failed to load model|error loading model', 'The model could not be loaded. Check that the file is complete and that enough RAM is free.')
    )
    foreach ($r in $rules) { if ($Line -match ('(?i)' + $r[0])) { return $r[1] } }
    return $null
}

function Get-PLlmServerState {
    # Pure state machine for the header.  Facts in, one of Starting | Loading Model | Ready | Error | Stopped out.
    # HealthStatus is the last HTTP status code from GET /health ($null = never answered): 503 means llama.cpp is still
    # loading; any other answer below 500 means the HTTP server is up and not reporting "loading".
    param([bool]$Exited, [bool]$StoppedByUser, $ExitCode, $HealthStatus, [bool]$ListeningSeen, [bool]$LoaderSeen, [bool]$LogReady)
    if ($Exited) {
        if ($StoppedByUser -or $ExitCode -eq 0 -or $ExitCode -eq -1073741510) { return [pscustomobject]@{ State = 'Stopped'; Detail = 'server process has exited' } }
        return [pscustomobject]@{ State = 'Error'; Detail = ('server process exited with code {0}' -f $ExitCode) }
    }
    if ($null -ne $HealthStatus) {
        if ($HealthStatus -eq 503) { return [pscustomobject]@{ State = 'Loading Model'; Detail = 'server reports it is still loading the model' } }
        if ($HealthStatus -ge 200 -and $HealthStatus -lt 500) { return [pscustomobject]@{ State = 'Ready'; Detail = 'server answers HTTP requests' } }
    }
    if ($LogReady) { return [pscustomobject]@{ State = 'Ready'; Detail = 'llama.cpp logged that the model is loaded' } }
    if ($ListeningSeen) { return [pscustomobject]@{ State = 'Loading Model'; Detail = 'listening; waiting for readiness confirmation' } }
    if ($LoaderSeen) { return [pscustomobject]@{ State = 'Loading Model'; Detail = 'reading model file' } }
    return [pscustomobject]@{ State = 'Starting'; Detail = 'server process started' }
}

# ---------------------------------------------------------------------------------------------
# Local TCP helper (used by the launcher before start and by the monitor after stop)
# ---------------------------------------------------------------------------------------------
function Test-PLlmPortFree {
    param([int]$Port)
    try {
        $l = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        foreach ($e in $l) { if ($e.Port -eq $Port) { return $false } }
    } catch { }
    return $true
}

# ---------------------------------------------------------------------------------------------
# Memory preflight (pure; every external fact comes in through a parameter or an injectable scriptblock)
# ---------------------------------------------------------------------------------------------
# Policy constants.  These are HEURISTICS, documented in docs/PREFLIGHT.md; nothing here claims an exact peak.
$script:PLlmMemPolicy = @{
    OverheadFixedBytes      = 512MB     # compute buffers, graph, tokenizer, server and runtime allocations
    OverheadWeightFraction  = 0.03      # plus this fraction of the weights
    UnknownKvFractionPer4096 = 0.20     # KV guess (fraction of weights per 4096 ctx) ONLY when GGUF metadata is unusable
    KvBytesPerElement       = 2.0       # f16 cache (llama-server default)
    OsReserveMinBytes       = 1GB       # kept for Windows and other programs when judging what can EVER fit
    OsReserveFraction       = 0.10
    HeadroomMinBytes        = 512MB     # extra free RAM wanted on top of the expected need before we say PASS
    HeadroomFraction        = 0.05
    BlockAvailFraction      = 0.75      # BLOCK when free RAM is below this fraction of (weights + KV), the bare minimum
}

function Read-PLlmGgufMetadata {
    # Reads ONLY the GGUF header key/value section (never the tensors) and stops at the first tokenizer.* key, so a
    # multi-GB model costs a few KB of reads.  Never throws; Ok = $false with a Reason when the file is not usable.
    param([string]$Path)
    $res = [pscustomobject]@{ Ok = $false; Reason = ''; Version = $null; Arch = $null; BlockCount = $null; EmbeddingLength = $null
                              HeadCount = $null; HeadCountKv = $null; KeyLength = $null; ValueLength = $null; ContextLength = $null }
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $br = New-Object System.IO.BinaryReader($fs)
        $len = $fs.Length
        if ($len -lt 24) { $res.Reason = 'file too small to be a GGUF model'; return $res }
        if ($br.ReadUInt32() -ne 0x46554747) { $res.Reason = 'not a GGUF file (bad magic)'; return $res }
        $ver = $br.ReadUInt32(); $res.Version = $ver
        if ($ver -lt 2 -or $ver -gt 3) { $res.Reason = ('unsupported GGUF version {0}' -f $ver); return $res }
        [void]$br.ReadUInt64()                         # tensor count
        $kvCount = $br.ReadUInt64()
        if ($kvCount -gt 100000) { $res.Reason = 'implausible metadata count (corrupt header?)'; return $res }
        $sizes = @{ 0 = 1; 1 = 1; 2 = 2; 3 = 2; 4 = 4; 5 = 4; 6 = 4; 7 = 1; 10 = 8; 11 = 8; 12 = 8 }
        $kv = @{}
        $readScalar = {
            param($type)
            switch ($type) {
                0 { return [double]$br.ReadByte() } 1 { return [double]$br.ReadSByte() } 2 { return [double]$br.ReadUInt16() } 3 { return [double]$br.ReadInt16() }
                4 { return [double]$br.ReadUInt32() } 5 { return [double]$br.ReadInt32() } 6 { return [double]$br.ReadSingle() } 7 { return [double]$br.ReadByte() }
                10 { return [double]$br.ReadUInt64() } 11 { return [double]$br.ReadInt64() } 12 { return [double]$br.ReadDouble() }
            }
            return $null
        }
        for ($i = 0; $i -lt [int]$kvCount; $i++) {
            $kl = $br.ReadUInt64()
            if ($kl -gt 4096 -or ($fs.Position + [int64]$kl) -gt $len) { $res.Reason = 'corrupt metadata key'; return $res }
            $key = [System.Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$kl))
            if ($key.StartsWith('tokenizer.')) { break }     # all architecture keys precede the (huge) tokenizer arrays
            $type = $br.ReadUInt32()
            $value = $null
            if ($type -eq 8) {
                $sl = $br.ReadUInt64()
                if (($fs.Position + [int64][math]::Min([double]$sl, 9e15)) -gt $len) { $res.Reason = 'corrupt string value'; return $res }
                if ($sl -le 256) { $value = [System.Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$sl)) } else { [void]$fs.Seek([int64]$sl, [System.IO.SeekOrigin]::Current) }
            }
            elseif ($type -eq 9) {
                $et = $br.ReadUInt32(); $cnt = $br.ReadUInt64()
                if ($sizes.ContainsKey([int]$et)) {
                    if ($cnt -le 512) { $arr = @(); for ($j = 0; $j -lt [int]$cnt; $j++) { $arr += (& $readScalar ([int]$et)) }; $value = $arr }
                    else { [void]$fs.Seek([int64]$cnt * $sizes[[int]$et], [System.IO.SeekOrigin]::Current) }
                } else { $res.Reason = 'metadata contains a large array before the architecture keys; not parsed'; return $res }
            }
            elseif ($sizes.ContainsKey([int]$type)) { $value = & $readScalar ([int]$type) }
            else { $res.Reason = ('unknown metadata type {0}' -f $type); return $res }
            if ($fs.Position -gt $len) { $res.Reason = 'metadata runs past the end of the file'; return $res }
            $kv[$key] = $value
        }
        $arch = $kv['general.architecture']
        if (-not $arch) { $res.Reason = 'general.architecture not found in the GGUF header'; return $res }
        $res.Arch = [string]$arch
        $get = { param($suffix) $v = $kv[($arch + '.' + $suffix)]; if ($v -is [array]) { $v = ($v | Measure-Object -Maximum).Maximum }; return $v }   # per-layer arrays: use the largest (conservative)
        $res.BlockCount = & $get 'block_count'; $res.EmbeddingLength = & $get 'embedding_length'
        $res.HeadCount = & $get 'attention.head_count'; $res.HeadCountKv = & $get 'attention.head_count_kv'
        $res.KeyLength = & $get 'attention.key_length'; $res.ValueLength = & $get 'attention.value_length'
        $res.ContextLength = & $get 'context_length'
        $res.Ok = $true
        return $res
    } catch { $res.Reason = ('could not read GGUF header: ' + $_.Exception.Message); return $res }
    finally { if ($fs) { $fs.Dispose() } }
}

function Get-PLlmMemoryEstimate {
    # Weights + KV cache + overhead.  Confidence 'metadata' = KV cache computed from the GGUF header
    #   KV = block_count * context * kv_heads * (key_len + value_len) * bytes_per_element
    # Confidence 'low' = metadata unusable; KV is then a stated fraction of the weights (heuristic).
    # MinBytes (weights + known KV) is the lower bound used for BLOCK; ExpectedBytes adds overhead and is used for WARN.
    param([double]$FileBytes, $Meta, [int]$Context)
    $pol = $script:PLlmMemPolicy
    $kv = $null; $notes = New-Object System.Collections.ArrayList
    if ($Meta -and $Meta.Ok -and $Meta.BlockCount -and $Meta.EmbeddingLength -and ($Meta.HeadCount -or $Meta.HeadCountKv)) {
        $headKv = $Meta.HeadCountKv; if (-not $headKv) { $headKv = $Meta.HeadCount }
        $keyLen = $Meta.KeyLength
        if (-not $keyLen -and $Meta.HeadCount) { $keyLen = [double]$Meta.EmbeddingLength / [double]$Meta.HeadCount }
        $valLen = $Meta.ValueLength; if (-not $valLen) { $valLen = $keyLen }
        if ($keyLen -and $valLen -and $headKv) {
            $kv = [double]$Meta.BlockCount * [double]$Context * [double]$headKv * ([double]$keyLen + [double]$valLen) * $pol.KvBytesPerElement
        }
    }
    $overhead = $pol.OverheadFixedBytes + $pol.OverheadWeightFraction * $FileBytes
    $conf = 'metadata'
    $kvExpected = $kv
    if ($null -eq $kv) {
        $conf = 'low'
        $kvExpected = $FileBytes * $pol.UnknownKvFractionPer4096 * ([double]$Context / 4096.0)
        $why = 'GGUF metadata not available'; if ($Meta -and $Meta.Reason) { $why = $Meta.Reason } elseif ($Meta -and $Meta.Ok) { $why = 'GGUF header lacks the attention/layer keys' }
        [void]$notes.Add(('KV cache size could not be computed ({0}); a heuristic is used, so this estimate is uncertain.' -f $why))
    }
    $min = $FileBytes; if ($null -ne $kv) { $min += $kv }
    return [pscustomobject]@{ WeightsBytes = $FileBytes; KvBytes = $kv; KvExpectedBytes = $kvExpected; OverheadBytes = $overhead
        MinBytes = $min; ExpectedBytes = ($FileBytes + $kvExpected + $overhead); Confidence = $conf; Context = $Context; Notes = @($notes) }
}

function Get-PLlmMemoryVerdict {
    # PASS | WARN | BLOCK from an estimate and a memory reading { TotalBytes, AvailBytes, [CommitAvailBytes] }.
    #   BLOCK (static)  : weights + KV cannot fit in total RAM minus a Windows reserve, however many programs are closed.
    #   BLOCK (dynamic) : free RAM right now is below BlockAvailFraction of weights + KV (heavy paging expected).
    #   WARN            : expected need plus headroom exceeds free RAM; or RAM could not be measured; or commit limit is tight.
    #   PASS            : otherwise.  None of these is a guarantee either way.
    param($Estimate, $Mem)
    $pol = $script:PLlmMemPolicy
    $reasons = New-Object System.Collections.ArrayList; $remedies = New-Object System.Collections.ArrayList
    $out = [pscustomobject]@{ Verdict = 'WARN'; Measured = $false; Kind = ''; Reasons = @(); Remedies = @(); TotalBytes = $null; AvailBytes = $null
                              MinBytes = $Estimate.MinBytes; ExpectedBytes = $Estimate.ExpectedBytes; Confidence = $Estimate.Confidence; SuggestedContext = $null; Notes = @($Estimate.Notes) }
    if ($null -eq $Mem -or $null -eq $Mem.TotalBytes -or $null -eq $Mem.AvailBytes -or [double]$Mem.TotalBytes -le 0) {
        $out.Kind = 'unmeasured'
        $out.Reasons = @('Memory could not be measured on this computer, so no safety decision could be made. Expected need is about ' + (Format-PLlmBytes $Estimate.ExpectedBytes) + '.')
        $out.Remedies = @('Check free RAM in Task Manager before continuing; close other programs if it is below that figure.')
        return $out
    }
    $T = [double]$Mem.TotalBytes; $A = [double]$Mem.AvailBytes
    $out.Measured = $true; $out.TotalBytes = $T; $out.AvailBytes = $A
    $reserve = [math]::Max($pol.OsReserveMinBytes, $pol.OsReserveFraction * $T)
    $machine = $T - $reserve
    $min = $Estimate.MinBytes
    $headroom = [math]::Max($pol.HeadroomMinBytes, $pol.HeadroomFraction * $T)
    # A context size that would leave the KV cache inside a given RAM budget (weights and overhead already paid for).
    $ctxFor = {
        param([double]$budget)
        if (-not ($Estimate.KvBytes -and $Estimate.KvBytes -gt 0)) { return $null }
        $room = $budget - $Estimate.WeightsBytes - $Estimate.OverheadBytes
        if ($room -le 0) { return $null }
        $c = [int]([math]::Floor([double]$Estimate.Context * $room / $Estimate.KvBytes / 256.0) * 256)
        if ($c -lt 256 -or $c -ge $Estimate.Context) { return $null }
        return $c
    }
    $maxCtx = & $ctxFor ([math]::Min($machine, $A - $headroom))     # fits now AND is not larger than the PC could ever hold
    if ($min -gt $machine) {
        $out.Verdict = 'BLOCK'; $out.Kind = 'static'
        [void]$reasons.Add(('The model needs at least {0} ({1}) but this PC has {2} in total ({3} after keeping {4} for Windows). It cannot be expected to fit even with every other program closed.' -f (Format-PLlmBytes $min), $(if ($Estimate.KvBytes) { 'weights + KV cache at context ' + $Estimate.Context } else { 'model weights alone' }), (Format-PLlmBytes $T), (Format-PLlmBytes $machine), (Format-PLlmBytes $reserve)))
        [void]$remedies.Add('Choose a smaller model or a more heavily quantized file (for example Q4 instead of Q8).')
        if ($maxCtx) { [void]$remedies.Add(('Lower CONTEXT in CONFIG.bat (about {0} might fit; an estimate, not a guarantee).' -f $maxCtx)) }
    }
    elseif ($A -lt ($pol.BlockAvailFraction * $min)) {
        $out.Verdict = 'BLOCK'; $out.Kind = 'dynamic'
        [void]$reasons.Add(('Only {0} of RAM is free right now, but the model needs at least {1} ({2}). Starting would force heavy paging and may make the whole PC unresponsive.' -f (Format-PLlmBytes $A), (Format-PLlmBytes $min), $(if ($Estimate.KvBytes) { 'weights + KV cache' } else { 'weights alone' })))
        [void]$remedies.Add('Close memory-hungry programs (browsers with many tabs, games, editors) and start again; this may help but is not guaranteed.')
        if ($maxCtx) { [void]$remedies.Add(('Lower CONTEXT in CONFIG.bat; about {0} might fit.' -f $maxCtx)) }
        [void]$remedies.Add('Or choose a smaller model.')
    }
    else {
        if ($Estimate.ExpectedBytes + $headroom -gt $A) {
            $out.Verdict = 'WARN'; $out.Kind = 'tight'
            [void]$reasons.Add(('Expected need is about {0} ({1} estimate) and {2} is free. This may work but is tight; other programs growing could cause paging or an out-of-memory failure.' -f (Format-PLlmBytes $Estimate.ExpectedBytes), $(if ($Estimate.Confidence -eq 'metadata') { 'from the GGUF header' } else { 'rough' }), (Format-PLlmBytes $A)))
            [void]$remedies.Add('Close other memory-intensive programs; this may help but is not guaranteed.')
            if ($maxCtx) { [void]$remedies.Add(('A smaller CONTEXT in CONFIG.bat (for example {0}) reduces the KV cache and might fit.' -f $maxCtx)) }
            [void]$remedies.Add('Or choose a smaller model / quantization, or retry when more memory is free.')
        } else { $out.Verdict = 'PASS'; $out.Kind = 'ok'
            [void]$reasons.Add(('Expected need about {0} ({1}); {2} free.' -f (Format-PLlmBytes $Estimate.ExpectedBytes), $(if ($Estimate.Confidence -eq 'metadata') { 'estimate from GGUF header' } else { 'rough estimate' }), (Format-PLlmBytes $A))) }
    }
    if ($out.Verdict -ne 'BLOCK' -and $null -ne $Mem.CommitAvailBytes) {
        $commitNeed = $Estimate.KvExpectedBytes + $Estimate.OverheadBytes
        if ($commitNeed -gt [double]$Mem.CommitAvailBytes) {
            if ($out.Verdict -eq 'PASS') { $out.Verdict = 'WARN'; $out.Kind = 'commit'; $out.Reasons = @(); $reasons.Clear() }
            [void]$reasons.Add(('Windows has only {0} of commit (RAM + page file) left for the KV cache and buffers (about {1}). Allocation could fail.' -f (Format-PLlmBytes $Mem.CommitAvailBytes), (Format-PLlmBytes $commitNeed)))
            [void]$remedies.Add('Close programs or enlarge the Windows page file.')
        }
    }
    $out.Reasons = @($reasons); $out.Remedies = @($remedies)
    return $out
}

function Invoke-PLlmMemoryProvider {
    # A provider that throws is a failed measurement ($null -> explicit WARN 'could not be measured'), never a pass.
    param([scriptblock]$Provider)
    try { return (& $Provider) } catch { return $null }
}

function Invoke-PLlmLaunchGate {
    # The only path to starting the server.  Measures, decides, re-measures immediately before launch, and calls -Start
    # only if the final decision allows it.  A BLOCK without an explicit override NEVER calls -Start.
    #   MemoryProvider : scriptblock -> { TotalBytes; AvailBytes; [CommitAvailBytes] } or $null (measurement failed)
    #   MetadataReader : scriptblock(path) -> object like Read-PLlmGgufMetadata
    #   Confirm        : scriptblock(verdict) -> $true only when the user explicitly confirmed a BLOCK (typed phrase)
    #   Notify         : scriptblock(stage, verdict) for the caller to print; called once per distinct result
    #   Start          : scriptblock(verdict) -> the server result
    param([string]$ModelPath, [double]$FileBytes, [int]$Context, [scriptblock]$MemoryProvider, [scriptblock]$MetadataReader,
          [bool]$AllowOverride = $false, [scriptblock]$Confirm = $null, [scriptblock]$Notify = $null, [scriptblock]$Start)
    $meta = & $MetadataReader $ModelPath
    $est = Get-PLlmMemoryEstimate -FileBytes $FileBytes -Meta $meta -Context $Context
    $first = Get-PLlmMemoryVerdict $est (Invoke-PLlmMemoryProvider $MemoryProvider)
    if ($Notify) { & $Notify 'preflight' $first }
    $override = $false
    if ($first.Verdict -eq 'BLOCK') {
        if ($AllowOverride) { $override = $true }
        elseif ($Confirm -and (& $Confirm $first)) { $override = $true }
        else { return [pscustomobject]@{ Outcome = 'Blocked'; Started = $false; First = $first; Final = $first; OverrideUsed = $false; Estimate = $est; Result = $null } }
    }
    $final = Get-PLlmMemoryVerdict $est (Invoke-PLlmMemoryProvider $MemoryProvider)      # recheck: memory may have changed while the user read or answered
    $rank = @{ PASS = 0; WARN = 1; BLOCK = 2 }
    if ($rank[$final.Verdict] -ne $rank[$first.Verdict] -and $Notify) { & $Notify 'recheck' $final }
    if ($final.Verdict -eq 'BLOCK' -and -not $override) {
        return [pscustomobject]@{ Outcome = 'BlockedAtLaunch'; Started = $false; First = $first; Final = $final; OverrideUsed = $false; Estimate = $est; Result = $null }
    }
    $res = & $Start $final
    return [pscustomobject]@{ Outcome = 'Started'; Started = $true; First = $first; Final = $final; OverrideUsed = $override; Estimate = $est; Result = $res }
}
