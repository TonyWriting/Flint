#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
try {
    $Session.Root = Split-Path $PSScriptRoot -Parent
    $Session.Model = 'demo-model'
    Write-Host 'Offline UI preview; no model or cluster requests.' -ForegroundColor DarkGray
    Show-FlintSession $Session
    Write-Host ''
    Write-FlintColoredText '> Show the files in this directory.' $Session -Color Green
    $delayPath = Join-Path $TestRoot 'delay.ps1'
    Set-Content -LiteralPath $delayPath -Encoding ASCII -Value 'param([int]$Seconds); Start-Sleep -Seconds $Seconds'
    $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-FlintTurnUi $Session
    foreach ($step in @(@{ stage = 'Thinking'; seconds = 3 }, @{ stage = 'Listing files'; seconds = 1 }, @{ stage = 'Thinking'; seconds = 2 })) {
        Show-FlintActivity $Session $step.stage
        $null = Invoke-FlintProcess $executable @('-NoProfile', '-File', ('"' + $delayPath + '"'), '-Seconds', [string]$step.seconds) 10 $Session.Root -Session $Session
        if ($step.stage -eq 'Listing files') { Show-FlintToolResult $Session 'list_files' @{ path = '.' } @{ status = 'ok'; exit_code = 0 } }
    }
    Stop-FlintTurnUi $Session
    Show-FlintAnswer $Session @'
Current workspace files:

**Directories**
- `lib/`
- `tools/`

**Files**
- `agent.ps1`
- `README.md`

## Links
[Visit OpenAI](https://www.openai.com)

## Table
| Name | Status | Notes |
|---|:---:|---|
| Service A | Ready | Running normally |
| Service B | Warning | Check configuration |
'@
    $sample = ConvertFrom-Json '"| \u540d\u79f0 | \u72b6\u6001 | \u8bf4\u660e |\n|---|:---:|---|\n| \u670d\u52a1 A | \u2705\u6b63\u5e38 | \u6b63\u5728\u8fd0\u884c |\n| \u670d\u52a1 B | \u26a0\ufe0f\u8b66\u544a | \u9700\u8981\u68c0\u67e5 |\n| \u670d\u52a1 C | \u274c\u5f02\u5e38 | \u5df2\u505c\u6b62 |"'
    Write-Host ''
    Write-FlintMarkdown $sample $Session
    Write-Host ''
    Write-FlintColoredText '> ' $Session -Color Green -NoNewline
} finally { Stop-FlintTurnUi $Session; Remove-TestFixture }
