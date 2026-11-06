#Requires -Version 5.1
param([switch]$ResumeSaved, [int]$ContextWindow = 128000)
$previewContextWindow = $ContextWindow
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$app = New-TestRuntime (Join-Path $TestRoot 'app')
# Keep the entry point, input reader and model worker; stub only the network boundary.
Add-Content -LiteralPath (Join-Path $app 'lib\Client.ps1') -Encoding UTF8 -Value @'
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec, $MaximumRedirection, $OutFile, $ErrorAction)
    $response = @{ status = 'completed'; usage = @{ input_tokens = 1234; output_tokens = 56 }; output = @(
        @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Offline answer. Press Ctrl+C at the next prompt to verify the exit summary.' }) }
    ) }
    Set-Content -LiteralPath $OutFile -Value (ConvertTo-Json -InputObject $response -Depth 16 -Compress) -Encoding UTF8
}
'@
$resumeId = ''
if ($ResumeSaved) {
    $Session.History = @(
        @{ role = 'user'; content = 'Show the previous conversation.' },
        @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'This is the saved answer. **History restored.**' }) }
    )
    $Session.ModelCalls = 1; $Session.UsageReports = 1; $Session.InputTokens = 1234; $Session.OutputTokens = 56
    Write-FlintCheckpoint $Session
    $resumeId = $Session.Id
    Write-Host ('Offline resume test. Verify the saved conversation, then press Ctrl+C. The exit ID must stay ' + $resumeId + '.') -ForegroundColor DarkGray
} else { Write-Host 'Offline console test. Enter a message, then press Ctrl+C after the answer. No network requests are made.' -ForegroundColor DarkGray }
Push-Location -LiteralPath $WorkRoot
try { & (Join-Path $app 'agent.ps1') -NoAzure -EnvFile $config -Resume $resumeId -ContextWindow $previewContextWindow }
finally {
    try {
        $log = Get-ChildItem -LiteralPath (Join-Path $WorkRoot '.flint\trajectories') -Filter *.jsonl | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $events = @(Get-Content -LiteralPath $log.FullName -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
        Assert-True ($events[-1].event -eq 'session_stopped') 'Complete shutdown after a real console interrupt.'
        $saved = Read-FlintSession $events[0].session_id (Split-Path $log.FullName -Parent) $WorkRoot
        Assert-True ($saved.state.UsageReports -gt 0 -and $saved.state.InputTokens -eq (1234 * $saved.state.UsageReports)) 'Save the completed conversation and measured token usage.'
        if ($ResumeSaved) { Assert-True ($events[-1].session_id -ceq $resumeId -and @(Get-ChildItem -LiteralPath (Join-Path $WorkRoot '.flint\trajectories') -Filter *.jsonl).Count -eq 1) 'Keep one session ID and one trajectory after resume and Ctrl+C.' }
        Write-Host 'Console exit verification passed. Temporary preview sessions will now be removed.' -ForegroundColor Green
    } finally { Pop-Location; Remove-TestFixture }
}
