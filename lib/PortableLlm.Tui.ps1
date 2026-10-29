# Portable-LLM terminal dashboard: rendering only.  ASCII only (Windows PowerShell 5.1 reads BOM-less files as ANSI;
# block/box glyphs are generated from code points at run time).  Dot-source after PortableLlm.Core.ps1.
#
# Build-PLlmFrame is PURE: view model in, array of lines out.  No parsing, no process control, no console access.
# Only the painter functions (Enter-/Exit-PLlmScreen, Write-PLlmFrame) touch the console.

$script:PLlmEsc = [string][char]27
$script:PLlmRxAnsi = New-Object System.Text.RegularExpressions.Regex('\x1b\[[0-9;?]*[A-Za-z]')
$script:PLlmRxAnsiAt = New-Object System.Text.RegularExpressions.Regex('\G\x1b\[[0-9;?]*[A-Za-z]')
$script:PLlmTheme = $null
$script:PLlmStyleCache = @{}
$script:PLlmGlyph = $null

# ------------------------------------------------------------------------------------------------ style
function Set-PLlmUiStyle {
    param([bool]$Color, [bool]$Unicode, [bool]$Palette256 = $true)
    $e = $script:PLlmEsc
    $codes = @{}
    if ($Color -and $Palette256) {
        $codes = @{ cyan = '38;5;81'; blue = '38;5;75'; green = '38;5;78'; violet = '38;5;141'; yellow = '38;5;221'; orange = '38;5;208'
                    red = '38;5;203'; gray = '38;5;245'; dim = '38;5;240'; white = '38;5;255'; bold = '1' }
    } elseif ($Color) {
        $codes = @{ cyan = '36'; blue = '34'; green = '32'; violet = '35'; yellow = '33'; orange = '33;1'
                    red = '31'; gray = '90'; dim = '90'; white = '97'; bold = '1' }
    }
    $theme = @{}
    foreach ($k in @('cyan', 'blue', 'green', 'violet', 'yellow', 'orange', 'red', 'gray', 'dim', 'white', 'bold')) {
        if ($codes.ContainsKey($k)) { $theme[$k] = ($e + '[' + $codes[$k] + 'm') } else { $theme[$k] = '' }
    }
    $theme['reset'] = $(if ($Color) { $e + '[0m' } else { '' })
    $script:PLlmTheme = $theme
    $script:PLlmStyleCache = @{}
    if ($Unicode) {
        $script:PLlmGlyph = @{ Full = [string][char]0x2588; Empty = [string][char]0x2591; Dot = [string][char]0x25CF; Rule = [string][char]0x2500; Ell = [string][char]0x2026; Sep = [string][char]0x00B7 }
    } else {
        $script:PLlmGlyph = @{ Full = '#'; Empty = '-'; Dot = '*'; Rule = '-'; Ell = '...'; Sep = '|' }
    }
}

function S {
    # Style a piece of text with one or two roles, e.g. (S 'green' 'Ready') or (S 'cyan+bold' 'x').
    param([string]$Role, [string]$Text)
    $open = $script:PLlmStyleCache[$Role]
    if ($null -eq $open) {
        $open = ''
        foreach ($r in ($Role -split '\+')) { if ($script:PLlmTheme.ContainsKey($r)) { $open += $script:PLlmTheme[$r] } }
        $script:PLlmStyleCache[$Role] = $open
    }
    if ($open.Length -eq 0) { return $Text }
    return ($open + $Text + $script:PLlmTheme['reset'])
}

function Get-PLlmVisibleLength {
    param([string]$Text)
    if ($Text.IndexOf([char]27) -lt 0) { return $Text.Length }     # fast path: nothing to strip
    return ($script:PLlmRxAnsi.Replace($Text, '')).Length
}

function Limit-PLlmLine {
    # Truncate to Width visible characters without cutting an escape sequence.  -Mark appends an ellipsis so cut text is visible.
    param([string]$Text, [int]$Width, [switch]$Mark)
    if ($Width -lt 1) { return '' }
    if ((Get-PLlmVisibleLength $Text) -le $Width) { return $Text }
    $ell = ''
    if ($Mark) { $ell = $script:PLlmGlyph.Ell; $Width = [math]::Max(1, $Width - $ell.Length) }
    $sb = New-Object System.Text.StringBuilder
    $vis = 0; $i = 0; $n = $Text.Length
    while ($i -lt $n) {
        if ($Text[$i] -eq [char]27) {
            $m = $script:PLlmRxAnsiAt.Match($Text, $i)
            if ($m.Success) { [void]$sb.Append($m.Value); $i += $m.Length; continue }
        }
        if ($vis -ge $Width) { break }
        [void]$sb.Append($Text[$i]); $vis++; $i++
    }
    [void]$sb.Append($script:PLlmTheme['reset'] + $ell)
    return $sb.ToString()
}

function Format-PLlmPad {
    param([string]$Text, [int]$Width)
    $v = Get-PLlmVisibleLength $Text
    if ($v -gt $Width) { return (Limit-PLlmLine $Text $Width -Mark) }
    if ($v -eq $Width) { return $Text }
    return ($Text + (' ' * ($Width - $v)))
}

function Split-PLlmWrap {
    # Word-wrap plain text to Width; returns a string array (never empty).
    param([string]$Text, [int]$Width)
    if ($Width -lt 8) { $Width = 8 }
    $out = @(); $cur = ''
    foreach ($w in ($Text -split '\s+')) {
        if ($w.Length -eq 0) { continue }
        if ($cur.Length -eq 0) { $cur = $w }
        elseif (($cur.Length + 1 + $w.Length) -le $Width) { $cur += (' ' + $w) }
        else { $out += $cur; $cur = $w }
        while ($cur.Length -gt $Width) { $out += $cur.Substring(0, $Width); $cur = $cur.Substring($Width) }
    }
    if ($cur.Length -gt 0) { $out += $cur }
    if ($out.Count -eq 0) { $out = @('') }
    return @($out)
}

function Get-PLlmLevelRole {
    param([string]$Level)
    switch ($Level) { 'ok' { 'green' } 'good' { 'green' } 'info' { 'cyan' } 'warn' { 'yellow' } 'crit' { 'red' } 'fail' { 'red' } 'error' { 'red' } 'unknown' { 'gray' } default { 'gray' } }
}

# ------------------------------------------------------------------------------------------------ section helpers
function New-PLlmSection {
    param([string]$Title, [string]$Role, [int]$Width, [string[]]$Body)
    $g = $script:PLlmGlyph
    $fill = $Width - $Title.Length - 3
    if ($fill -lt 0) { $fill = 0 }
    $head = ' ' + (S ($Role + '+bold') $Title.ToUpperInvariant()) + ' ' + (S 'dim' ($g.Rule * $fill))
    return @($head) + @($Body)
}

function Get-PLlmRow {
    param([string]$Label, [string]$Value)
    return ('  ' + (S 'gray' $Label.PadRight(9)) + $Value)
}

function Get-PLlmBar {
    param([double]$Percent, [int]$Width, [string]$Role)
    $g = $script:PLlmGlyph
    if ($Width -lt 4) { $Width = 4 }
    $p = [math]::Max(0.0, [math]::Min(100.0, $Percent))
    $filled = [int][math]::Round($p * $Width / 100.0)
    return ((S $Role ($g.Full * $filled)) + (S 'dim' ($g.Empty * ($Width - $filled))))
}

function Get-PLlmRate {
    param($Value)
    if ($null -eq $Value) { return '--' }
    return ((Format-PLlmNumber $Value '0.0') + ' tok/s')
}

# ------------------------------------------------------------------------------------------------ sections
function Build-PLlmHeader {
    param($V, [int]$W)
    $stateRole = switch ($V.State) { 'Ready' { 'green' } 'Error' { 'red' } 'Stopped' { 'gray' } default { 'cyan' } }
    $left = ' ' + (S 'white+bold' 'Portable-LLM') + ' ' + (S 'gray' ('v' + $V.Version))
    $state = (S ($stateRole + '+bold') ($script:PLlmGlyph.Dot + ' ' + $V.State))
    $url = (S 'cyan' $V.Url)
    $line = $left + '   ' + $state
    $room = $W - (Get-PLlmVisibleLength $line) - (Get-PLlmVisibleLength $url) - 2
    $out = @()
    if ($room -ge 1) { $out += ($line + (' ' * $room) + $url + ' ') }
    else { $out += $line; $out += (' ' + $url) }
    if ($V.StateDetail) { $out += ('   ' + (S 'dim' $V.StateDetail)) }
    return @($out)
}

function Build-PLlmModel {
    param($V, [int]$W, [bool]$Dense)
    $m = $V.Model
    $size = Format-PLlmBytes $m.SizeBytes
    $stRole = Get-PLlmLevelRole $m.StatusLevel
    if ($Dense) {
        $lines = @(('  ' + (S 'white' $m.Name) + ' ' + (S 'gray' ('(' + $size + ')'))),
                   ('  ' + (S $stRole $m.Status) + (S 'gray' ('  ' + $script:PLlmGlyph.Sep + '  ctx ' + $m.CtxShort))))
    } else {
        $lines = @((Get-PLlmRow 'File' (S 'white' $m.Name)),
                   (Get-PLlmRow 'Size' $size),
                   (Get-PLlmRow 'Status' (S $stRole $m.Status)),
                   (Get-PLlmRow 'Context' $m.CtxText))
    }
    return (New-PLlmSection 'Model' 'violet' $W $lines)
}

function Build-PLlmPerf {
    param($V, [int]$W, [bool]$Dense)
    $p = $V.Perf
    $lines = @()
    if ($null -eq $p.Last) {
        $lines += ('  ' + (S 'cyan' 'Waiting for first request'))
        $lines += (Get-PLlmRow 'Requests' ('{0} completed, {1} failed/incomplete' -f $p.Completed, $p.Incomplete))
        return (New-PLlmSection 'Performance' 'blue' $W $lines)
    }
    $r = $p.Last; $s = $p.Stats
    $pr = '--'; $pt = ''
    if ($null -ne $r.PromptTokens -and $r.PromptTokens -gt 0) { $pr = Get-PLlmRate $r.PromptTps; $pt = ('{0} tokens' -f $r.PromptTokens) }
    elseif ($null -ne $r.PromptTokens) { $pt = '0 tokens processed' }
    $gr = '--'; $gt = ''
    if ($null -ne $r.GenTokens) { $gr = Get-PLlmRate $r.GenTps; $gt = ('{0} tokens' -f $r.GenTokens) }
    $dur = '--'; if ($null -ne $r.TotalMs) { $dur = ((Format-PLlmNumber ($r.TotalMs / 1000.0) '0.0') + ' s') }
    $gAvg = Get-PLlmRate $s.GenAvgTps; $pAvg = Get-PLlmRate $s.PromptAvgTps
    $reqLine = ('{0} completed, {1} failed/incomplete' -f $p.Completed, $p.Incomplete)
    if ($Dense) {
        $lines += ('  ' + (S 'gray' ('#' + $r.Index + ' ' + $r.Time.ToString('HH:mm:ss') + ' ' + $dur)))
        $lines += ('  ' + (S 'gray' 'prompt ') + (S 'white+bold' $pr) + (S 'gray' (' ' + $pt)))
        $lines += ('  ' + (S 'gray' 'gen    ') + (S 'white+bold' $gr) + (S 'gray' (' ' + $gt)))
        $lines += ('  ' + (S 'gray' ('avg gen ' + $gAvg + ' | prompt ' + $pAvg + ' | ' + $reqLine)))
    } else {
        $lines += (Get-PLlmRow 'Latest' (S 'gray' ('request #' + $r.Index + ' at ' + $r.Time.ToString('HH:mm:ss') + ', took ' + $dur)))
        $lines += (Get-PLlmRow 'Prompt' ((S 'white+bold' $pr.PadRight(13)) + (S 'gray' $pt)))
        $lines += (Get-PLlmRow 'Generate' ((S 'white+bold' $gr.PadRight(13)) + (S 'gray' $gt)))
        $lines += (Get-PLlmRow 'Session' (S 'gray' ('avg gen ' + $gAvg + ' | prompt ' + $pAvg)))
        $lines += (Get-PLlmRow 'Requests' $reqLine)
    }
    return (New-PLlmSection 'Performance' 'blue' $W $lines)
}

function Build-PLlmSystem {
    param($V, [int]$W, [bool]$Dense)
    $s = $V.Sys
    $cpu = $s.CpuName; if ([string]::IsNullOrEmpty($cpu)) { $cpu = 'Unknown' }
    if ($null -ne $s.Logical) { $cpu += (' ({0} logical)' -f $s.Logical) }
    $sup = @()
    foreach ($k in $s.Support.Keys) {
        $val = $s.Support[$k]; $t = 'unknown'; $role = 'gray'
        if ($val -eq $true) { $t = 'yes'; $role = 'green' } elseif ($val -eq $false) { $t = 'no'; $role = 'yellow' }
        $sup += ((S 'gray' $k) + ' ' + (S $role $t))
    }
    $supText = ($sup -join '  ')
    $ram = ''; $ram2 = $null; $ramNote = $null; $noteRole = 'gray'
    if ($null -ne $s.MemTotal) {
        $role = Get-PLlmLevelRole $s.MemLevel; if ($s.MemLevel -eq 'ok') { $role = 'green' }
        $barW = [math]::Max(8, [math]::Min(24, $W - 30))
        $ram = (Get-PLlmBar $s.MemUsedPct $barW $role) + ' ' + (S $role ((Format-PLlmNumber $s.MemUsedPct '0') + '% used'))
        $ram2 = (S 'gray' ((Format-PLlmBytes ($s.MemTotal - $s.MemAvail)) + ' used of ' + (Format-PLlmBytes $s.MemTotal) + ', ' + (Format-PLlmBytes $s.MemAvail) + ' available'))
        if ($s.MemLevel -eq 'warn') { $ramNote = ('Low memory: ' + (Format-PLlmBytes $s.MemAvail) + ' free. Close other programs or use a smaller model.'); $noteRole = 'yellow' }
        if ($s.MemLevel -eq 'crit') { $ramNote = ('Critical: only ' + (Format-PLlmBytes $s.MemAvail) + ' free. Close programs or use a smaller model.'); $noteRole = 'red' }
    } else { $ram = (S 'gray' 'Unknown (memory API unavailable)') }
    $srv = (S 'gray' 'not running'); if ($null -ne $s.ServerWorkingSet) { $srv = (Format-PLlmBytes $s.ServerWorkingSet) + (S 'gray' ' working set') }
    $up = Format-PLlmDuration $s.Uptime
    $cw = @(Split-PLlmWrap $cpu ($W - 13))
    $lines = @()
    if ($Dense) {
        $lines += ('  ' + (S 'white' $cw[0]))
        $freeTxt = ''; if ($null -ne $s.MemTotal) { $freeTxt = (S 'gray' (' ' + (Format-PLlmBytes $s.MemAvail) + ' free')) }
        $lines += ('  ' + (S 'gray' 'RAM ') + $ram + $freeTxt)
        $lines += ('  ' + (S 'gray' 'Server ') + $srv + (S 'gray' ('  up ' + $up)))
        $lines += ('  ' + $supText)
        if ($ramNote) { $lines += ('  ' + (S $noteRole $ramNote)) }
    } else {
        $lines += (Get-PLlmRow 'CPU' (S 'white' $cw[0]))
        for ($i = 1; $i -lt $cw.Count; $i++) { $lines += ('           ' + (S 'white' $cw[$i])) }
        $lines += (Get-PLlmRow 'OS flags' $supText)
        $lines += (Get-PLlmRow 'RAM' $ram)
        if ($ram2) { $lines += ('           ' + $ram2) }
        if ($ramNote) { $lines += ('           ' + (S $noteRole $ramNote)) }
        $lines += (Get-PLlmRow 'Server' $srv)
        $lines += (Get-PLlmRow 'Uptime' $up)
    }
    if ($s.PSObject.Properties['PreflightText'] -and $s.PreflightText) {
        # preflight reasons are wrapped, never cut: they explain a decision
        $pw = @(Split-PLlmWrap $s.PreflightText ($W - 13)); $pr = Get-PLlmLevelRole $s.PreflightLevel
        $nPf = $(if ($s.PreflightLevel -eq 'ok') { 2 } elseif ($Dense) { 3 } else { 7 })       # decisions that need action get room
        if ($pw.Count -gt $nPf) { $pw = @($pw | Select-Object -First $nPf); $last = $pw[$nPf - 1]; if ($last.Length -gt ($W - 30)) { $last = $last.Substring(0, $W - 30) }; $pw[$nPf - 1] = $last + ' ... (D: full text)' }
        $lines += ('  ' + (S 'gray' 'Preflight ') + (S $pr $pw[0]))          # 9-char label: needs its own separating space
        for ($i = 1; $i -lt [math]::Min($nPf, $pw.Count); $i++) { $lines += ('            ' + (S $pr $pw[$i])) }
    }
    return (New-PLlmSection 'System' 'blue' $W $lines)
}

function Build-PLlmCompat {
    param($V, [int]$W, [bool]$Dense)
    $c = $V.Compat
    $exp = $c.Expected; $expNote = $c.ExpectedNote
    $act = $c.Actual; $actNote = $c.ActualNote
    $mRole = 'gray'; $mText = ''
    if ($c.Match -eq 'match') { $mRole = 'green'; $mText = 'match' }
    elseif ($c.Match -eq 'mismatch') { $mRole = 'yellow'; $mText = 'differs' }
    $room = [math]::Max(20, $W - 14)
    $lines = @()
    $maxNote = $(if ($Dense) { 1 } else { 3 })
    foreach ($spec in @(@('Expected', $exp, '', $expNote), @('Runtime', $act, $mText, $actNote))) {
        $val = (S 'violet' $spec[1]); if ($spec[2]) { $val += ('  ' + (S ($mRole + '+bold') $spec[2])) }
        $head = Get-PLlmRow $spec[0] $val
        $free = $W - (Get-PLlmVisibleLength $head) - 3
        if ($spec[3].Length -le $free) { $lines += ($head + (S 'gray' ('  ' + $spec[3]))) }
        else {
            # long reasons are wrapped, never cut: the explanation is the point of showing "Unknown"
            $lines += $head
            $nw = @(Split-PLlmWrap $spec[3] ($W - 12))
            for ($i = 0; $i -lt [math]::Min($maxNote, $nw.Count); $i++) { $lines += ('           ' + (S 'gray' $nw[$i])) }
        }
    }
    if (-not $Dense) { $lines += (Get-PLlmRow 'ISA used' (S 'gray' $c.Isa)) }
    if ($c.PSObject.Properties['Selected'] -and $c.Selected) {
        $sw = @(Split-PLlmWrap $c.Selected ($W - 12)); $sr = Get-PLlmLevelRole $c.SelectedLevel
        $lines += (Get-PLlmRow 'Selected' (S $sr $sw[0]))
        if (-not $Dense -and $sw.Count -gt 1) { $lines += ('           ' + (S $sr $sw[1])) }
    }
    $iRole = Get-PLlmLevelRole $c.IntegrityLevel
    $iw = @(Split-PLlmWrap $c.IntegrityShort $room)
    $lines += (Get-PLlmRow 'Build' (S $iRole $iw[0]))
    if (-not $Dense) { for ($i = 1; $i -lt [math]::Min(3, $iw.Count); $i++) { $lines += ('           ' + (S $iRole $iw[$i])) } }
    $maxF = $(if ($Dense) { 1 } else { 3 })
    foreach ($f in @($c.Findings | Select-Object -First $maxF)) {
        $fr = Get-PLlmLevelRole ($f.Level.ToLowerInvariant())
        $fw = @(Split-PLlmWrap $f.Text ($W - 6))
        $lines += ('  ' + (S $fr ('! ' + $fw[0])))
        if (-not $Dense -and $fw.Count -gt 1) { $lines += ('    ' + (S $fr $fw[1])) }
    }
    return (New-PLlmSection 'Compatibility' 'violet' $W $lines)
}

function Build-PLlmActivity {
    param($V, [int]$W, [int]$Rows)
    $lines = @()
    $ev = @($V.Events)
    if ($ev.Count -eq 0) { $lines += ('  ' + (S 'dim' 'No events yet')) }
    else {
        $take = [math]::Min($Rows, $ev.Count)
        foreach ($e in @($ev[($ev.Count - $take)..($ev.Count - 1)])) {
            $role = Get-PLlmLevelRole $e.Level
            $lines += ('  ' + (S 'dim' $e.Time.ToString('HH:mm:ss')) + '  ' + (S $role $e.Text))
        }
    }
    return (New-PLlmSection 'Recent activity' 'cyan' $W $lines)
}

function Build-PLlmDiag {
    param($V, [int]$W)
    $lines = @()
    foreach ($d in @($V.Diag)) {
        $role = Get-PLlmLevelRole $d.Level; if ($d.Level -eq 'info' -or -not $d.Level) { $role = 'white' }
        $wrapped = @(Split-PLlmWrap $d.Text ($W - 17))
        $lines += ('  ' + (S 'gray' $d.Label.PadRight(13)) + (S $role $wrapped[0]))
        for ($i = 1; $i -lt $wrapped.Count; $i++) { $lines += ('               ' + (S $role $wrapped[$i])) }
    }
    return (New-PLlmSection 'Diagnostics' 'orange' $W $lines)
}

function Build-PLlmFooter {
    param($V, [int]$W)
    $out = @()
    if ($V.Notice) { $out += (' ' + (S (Get-PLlmLevelRole $V.Notice.Level) $V.Notice.Text)) }
    $items = @(@('O', 'Open browser'), @('D', $(if ($V.ShowDiag) { 'Hide diagnostics' } else { 'Diagnostics' })), @('L', 'Log path'), @('R', 'Redraw'), @('Q', 'Quit'))
    $parts = @()
    foreach ($i in $items) { $parts += ((S 'cyan+bold' ('[' + $i[0] + ']')) + ' ' + (S 'gray' $i[1])) }
    $line = (' ' + ($parts -join '  '))
    if ((Get-PLlmVisibleLength $line) -gt $W) {
        $short = @('Open', 'Diag', 'Log', 'Redraw', 'Quit'); $parts = @()
        for ($k = 0; $k -lt 5; $k++) { $parts += ((S 'cyan+bold' ('[' + $items[$k][0] + ']')) + (S 'gray' $short[$k].Substring(1))) }
        $line = (' ' + ($parts -join ' '))
    }
    $out += $line
    return @($out)
}

# ------------------------------------------------------------------------------------------------ frame
function Join-PLlmColumns {
    param([string[]]$Left, [string[]]$Right, [int]$LeftW, [int]$RightW)
    $n = [math]::Max($Left.Count, $Right.Count)
    $out = @()
    for ($i = 0; $i -lt $n; $i++) {
        $l = ''; if ($i -lt $Left.Count) { $l = $Left[$i] }
        $r = ''; if ($i -lt $Right.Count) { $r = $Right[$i] }
        $out += ((Format-PLlmPad $l $LeftW) + '   ' + (Limit-PLlmLine $r $RightW -Mark))
    }
    return @($out)
}

function Build-PLlmFrame {
    # Returns the lines to paint.  Never longer than Height; the footer is always the last lines.
    param($V, [int]$Width, [int]$Height, [bool]$Color, [bool]$Unicode, [bool]$Palette256 = $true)
    Set-PLlmUiStyle -Color $Color -Unicode $Unicode -Palette256 $Palette256
    $usable = $Width - 1
    if ($Width -lt 44 -or $Height -lt 9) {
        $role = switch ($V.State) { 'Ready' { 'green' } 'Error' { 'red' } 'Stopped' { 'gray' } default { 'cyan' } }
        $g = ''; if ($null -ne $V.Perf.Last) { $g = ' gen ' + (Get-PLlmRate $V.Perf.Last.GenTps) }
        $lines = @((' ' + (S 'white+bold' 'Portable-LLM') + ' ' + (S ($role + '+bold') $V.State) + $g),
                   (' ' + (S 'dim' 'Window too small for the dashboard.')),
                   (' ' + (S 'cyan+bold' '[Q]') + ' ' + (S 'gray' 'Quit') + '  ' + (S 'cyan+bold' '[O]') + ' ' + (S 'gray' 'Browser')))
        return @($lines | ForEach-Object { Limit-PLlmLine $_ $usable } | Select-Object -First $Height)
    }
    $footer = @(Build-PLlmFooter $V $usable)
    $wide = ($Width -ge 110)
    foreach ($dense in @($false, $true)) {
        $head = @(Build-PLlmHeader $V $usable)
        foreach ($a in @($V.Alerts | Select-Object -First 2)) { $head += (' ' + (S (Get-PLlmLevelRole $a.Level) ('! ' + $a.Text))) }
        $body = @()
        if ($wide) {
            $lw = [int][math]::Floor(($usable - 3) / 2); $rw = $usable - 3 - $lw
            $body += (Join-PLlmColumns (Build-PLlmModel $V $lw $dense) (Build-PLlmPerf $V $rw $dense) $lw $rw)
            $body += (Join-PLlmColumns (Build-PLlmSystem $V $lw $dense) (Build-PLlmCompat $V $rw $dense) $lw $rw)
        } else {
            $body += (Build-PLlmModel $V $usable $dense)
            $body += (Build-PLlmPerf $V $usable $dense)
            $body += (Build-PLlmSystem $V $usable $dense)
            $body += (Build-PLlmCompat $V $usable $dense)
        }
        if ($V.ShowDiag) { $body += (Build-PLlmDiag $V $usable) }
        $fixed = $head.Count + $body.Count + $footer.Count
        $room = $Height - $fixed - 1            # 1 = activity header
        if ($room -ge 1 -or $dense) { break }
    }
    $rows = [math]::Max(0, [math]::Min(5, $Height - ($head.Count + $body.Count + $footer.Count) - 1))
    $act = @()
    if ($rows -ge 1) { $act = Build-PLlmActivity $V $usable $rows }
    $all = @($head) + @($body) + @($act)
    $max = $Height - $footer.Count
    if ($all.Count -gt $max) {
        $all = @($all | Select-Object -First ($max - 1))
        $all += (' ' + (S 'dim' ('(window too small to show everything; enlarge it or press D to hide diagnostics)')))
    }
    # pad so the footer sits on the bottom rows
    while (($all.Count + $footer.Count) -lt $Height) { $all += '' }
    $final = @($all) + @($footer)
    return @($final | ForEach-Object { Limit-PLlmLine $_ $usable -Mark })
}

# ------------------------------------------------------------------------------------------------ keys
function ConvertTo-PLlmCommand {
    # Maps a ConsoleKeyInfo to Open | Diag | Log | Redraw | Quit | $null.  Ctrl+C arrives as a key because
    # TreatControlCAsInput is set while the dashboard runs.
    param($Key)
    if ($null -eq $Key) { return $null }
    $ctrl = (([int]$Key.Modifiers -band [int][ConsoleModifiers]::Control) -ne 0)
    if ($ctrl -and $Key.Key -eq [ConsoleKey]::C) { return 'Quit' }
    if ($ctrl -or (([int]$Key.Modifiers -band [int][ConsoleModifiers]::Alt) -ne 0)) { return $null }
    switch ($Key.Key) {
        ([ConsoleKey]::O) { return 'Open' }
        ([ConsoleKey]::D) { return 'Diag' }
        ([ConsoleKey]::L) { return 'Log' }
        ([ConsoleKey]::R) { return 'Redraw' }
        ([ConsoleKey]::Q) { return 'Quit' }
    }
    return $null
}

# ------------------------------------------------------------------------------------------------ terminal capabilities + painter
function Get-PLlmTermCaps {
    # Decides how the dashboard may be drawn.  Mode: Ansi (cursor addressing by escape codes) | Console (cursor
    # addressing by .NET, no escape codes) | Log (no dashboard: output is redirected or the user asked for it).
    $c = [pscustomobject]@{ Mode = 'Log'; Vt = $false; Color = $false; Unicode = $false; Palette256 = $true; Width = 80; Height = 24; Why = ''; VtInfo = $null; OrigEncoding = $null }
    $force = ([string]$env:PORTABLE_LLM_UI).ToLowerInvariant()
    if ($force -eq 'log') { $c.Why = 'PORTABLE_LLM_UI=log'; return $c }
    try {
        if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { $c.Why = 'input or output is redirected'; return $c }
        $c.Width = [Console]::WindowWidth; $c.Height = [Console]::WindowHeight
        if ($c.Width -lt 1 -or $c.Height -lt 1) { $c.Why = 'console size unavailable'; return $c }
    } catch { $c.Why = 'no interactive console'; return $c }
    $dumb = (([string]$env:TERM).ToLowerInvariant() -eq 'dumb')
    if ($script:PLlmIsWindows) {
        $c.VtInfo = Enable-PLlmVt
        $c.Vt = ($null -ne $c.VtInfo)
    } else { $c.Vt = (-not $dumb) }
    if ($dumb) { $c.Vt = $false }
    $c.Mode = $(if ($c.Vt) { 'Ansi' } else { 'Console' })
    $plain = ($force -eq 'plain')
    $c.Color = ($c.Vt -and -not $plain -and [string]::IsNullOrEmpty($env:NO_COLOR) -and $env:PORTABLE_LLM_COLOR -ne '0')
    $c.Unicode = ($c.Vt -and -not $plain -and $env:PORTABLE_LLM_ASCII -ne '1')
    $c.Palette256 = ($env:PORTABLE_LLM_COLORS -ne '16')
    if (-not $c.Vt) { $c.Why = 'terminal does not support ANSI escape codes; using plain text' }
    elseif (-not $c.Color) { $c.Why = 'colors disabled (NO_COLOR / PORTABLE_LLM_COLOR=0 / plain)' }
    return $c
}

function Enter-PLlmScreen {
    param($Caps)
    $e = $script:PLlmEsc
    if ($Caps.Unicode) {
        try { $Caps.OrigEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = (New-Object System.Text.UTF8Encoding($false)) } catch { $Caps.Unicode = $false }
    }
    try { [Console]::TreatControlCAsInput = $true } catch { }
    if ($Caps.Mode -eq 'Ansi') { [Console]::Out.Write($e + '[?1049h' + $e + '[?25l' + $e + '[?7l' + $e + '[2J') }
    else { try { [Console]::CursorVisible = $false; [Console]::Clear() } catch { } }
}

function Exit-PLlmScreen {
    param($Caps)
    $e = $script:PLlmEsc
    if ($Caps.Mode -eq 'Ansi') { try { [Console]::Out.Write($(if ($Caps.Color) { $e + '[0m' } else { '' }) + $e + '[?7h' + $e + '[?25h' + $e + '[?1049l') } catch { } }
    else { try { [Console]::CursorVisible = $true; [Console]::Clear() } catch { } }
    try { [Console]::TreatControlCAsInput = $false } catch { }
    if ($Caps.OrigEncoding) { try { [Console]::OutputEncoding = $Caps.OrigEncoding } catch { } }
    Restore-PLlmConsoleMode $Caps.VtInfo
}

function New-PLlmPainter { return [pscustomobject]@{ Prev = @(); W = 0; H = 0 } }

function Write-PLlmFrame {
    # Repaints only the rows that changed.  A size change or -Full clears the screen first.
    param($Caps, $Painter, [string[]]$Lines, [bool]$Full = $false)
    $e = $script:PLlmEsc
    $sb = New-Object System.Text.StringBuilder
    $ansi = ($Caps.Mode -eq 'Ansi')
    if ($Full -or $Painter.W -ne $Caps.Width -or $Painter.H -ne $Caps.Height) {
        if ($ansi) { [void]$sb.Append($e + '[2J') } else { try { [Console]::Clear() } catch { } }
        $Painter.Prev = @()
    }
    $n = [math]::Min($Lines.Count, $Caps.Height)
    for ($i = 0; $i -lt $n; $i++) {
        $old = $null; if ($i -lt $Painter.Prev.Count) { $old = $Painter.Prev[$i] }
        if ($Lines[$i] -ceq $old) { continue }
        if ($ansi) { [void]$sb.Append($e + '[' + ($i + 1) + ';1H' + $Lines[$i] + $(if ($Caps.Color) { $e + '[0m' } else { '' }) + $e + '[K') }
        else {
            try { [Console]::SetCursorPosition(0, $i) } catch { }
            [void]$sb.Append((Format-PLlmPad $Lines[$i] ($Caps.Width - 1)))
            [Console]::Out.Write($sb.ToString()); [void]$sb.Clear()
        }
    }
    for ($i = $n; $i -lt $Painter.Prev.Count; $i++) {
        if ($ansi) { [void]$sb.Append($e + '[' + ($i + 1) + ';1H' + $e + '[2K') }
        else { try { [Console]::SetCursorPosition(0, $i); [Console]::Out.Write(' ' * ($Caps.Width - 1)) } catch { } }
    }
    if ($sb.Length -gt 0) { [Console]::Out.Write($sb.ToString()) }
    $Painter.Prev = @($Lines | Select-Object -First $n)
    $Painter.W = $Caps.Width; $Painter.H = $Caps.Height
}
