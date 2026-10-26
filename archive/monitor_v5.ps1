param(
    [Parameter(Mandatory = $true)]
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'
$latestPrompt = $null
$latestEval = $null
$latestTotal = $null

try {
    $parent = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $writer = [System.IO.StreamWriter]::new($LogPath, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true

    while ($null -ne ($line = [Console]::In.ReadLine())) {
        # Keep the server output visible and write the exact same line to the log.
        [Console]::Out.WriteLine($line)
        $writer.WriteLine($line)

        if ($line -match 'prompt eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens.*?([\d.]+)\s*tokens per second') {
            $latestPrompt = [pscustomobject]@{
                Milliseconds = [double]$Matches[1]
                Tokens = [int]$Matches[2]
                TokensPerSecond = [double]$Matches[3]
            }
        }
        elseif ($line -match 'eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens.*?([\d.]+)\s*tokens per second') {
            $latestEval = [pscustomobject]@{
                Milliseconds = [double]$Matches[1]
                Tokens = [int]$Matches[2]
                TokensPerSecond = [double]$Matches[3]
            }
            $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $writer.WriteLine("[$stamp] Parsed generation speed: $($latestEval.TokensPerSecond) tokens/s")
        }
        elseif ($line -match 'total time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens') {
            $latestTotal = [pscustomobject]@{
                Milliseconds = [double]$Matches[1]
                Tokens = [int]$Matches[2]
            }
        }
    }
}
finally {
    if ($writer) { $writer.Dispose() }
}

Write-Host ''
Write-Host '=========================================='
Write-Host '       LATEST PERFORMANCE SUMMARY'
Write-Host '=========================================='
if ($latestPrompt) {
    Write-Host ('Prompt processing: {0:N2} tokens/s ({1} tokens)' -f $latestPrompt.TokensPerSecond, $latestPrompt.Tokens)
} else {
    Write-Host 'Prompt processing: no timing line captured in this session.'
}
if ($latestEval) {
    Write-Host ('Text generation:  {0:N2} tokens/s ({1} tokens, {2:N2} seconds)' -f $latestEval.TokensPerSecond, $latestEval.Tokens, ($latestEval.Milliseconds / 1000.0))
} else {
    Write-Host 'Text generation: no completed eval-time line captured yet.'
}
if ($latestTotal) {
    Write-Host ('Total request:    {0:N2} seconds ({1} tokens)' -f ($latestTotal.Milliseconds / 1000.0), $latestTotal.Tokens)
}
Write-Host ('Full session log: {0}' -f $LogPath)
Write-Host 'Build ISA remains UNVERIFIED unless the binary build itself is inspected.'
Write-Host '=========================================='
