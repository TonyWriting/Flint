#Requires -Version 5.1
param([ValidateSet('Model', 'Prompt', 'Retry', 'Completed')][string]$During = 'Model')
$ErrorActionPreference = 'Stop'
# Exercise pipeline cancellation. Use Preview.Exit.ps1 for actual ConsoleHost Ctrl+C events.
$testParent = (Resolve-Path -LiteralPath $env:TEMP).ProviderPath.TrimEnd('\')
$testRoot = Join-Path $testParent ('flint-exit-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$agentPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'agent.ps1'
$pidPath = Join-Path $testRoot 'pid.txt'
Set-Content -LiteralPath (Join-Path $testRoot 'wait.ps1') -Encoding ASCII -Value @(
    'param($PidPath)'
    'Set-Content -LiteralPath $PidPath -Value $PID; Start-Sleep -Seconds 60'
)
Set-Content -LiteralPath (Join-Path $testRoot '.env') -Encoding ASCII -Value @(
    'AZURE_OPENAI_ENDPOINT=https://test.services.ai.azure.com/openai/v1/responses'
    'AZURE_OPENAI_API_KEY=test-api-key'
    'AZURE_OPENAI_DEPLOYMENT=test-deployment'
)
$driver = [powershell]::Create()
try {
    $scriptText = @'
param($AgentPath, $TestRoot, $During)
$ErrorActionPreference = 'Stop'
if ($ExecutionContext.SessionState.LanguageMode -ne 'ConstrainedLanguage') { $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage' }
. $AgentPath
Set-Location -LiteralPath $TestRoot
$global:FlintExitFixtureRoot = $TestRoot
$global:FlintExitDuring = $During
$global:FlintExitReads = 0
function Wait-ExitFixture {
    $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $child = Join-Path $global:FlintExitFixtureRoot 'wait.ps1'
    $pidPath = Join-Path $global:FlintExitFixtureRoot 'pid.txt'
    Invoke-FlintProcess $executable @('-NoProfile', '-File', ('"' + $child + '"'), '-PidPath', ('"' + $pidPath + '"')) 60 $global:FlintExitFixtureRoot | Out-Null
}
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec, $MaximumRedirection, $OutFile, $ErrorAction)
    if ($global:FlintExitDuring -eq 'Completed') {
        $response = @{ status = 'completed'; usage = @{ input_tokens = 1234; output_tokens = 56 }; output = @(
            @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Completed offline answer.' }) }
        ) }
        Set-Content -LiteralPath $OutFile -Value (ConvertTo-Json -InputObject $response -Depth 16 -Compress) -Encoding UTF8
        return
    }
    if ($global:FlintExitDuring -eq 'Retry') {
        try { throw 'Service temporarily unavailable.' } catch { $errorObject = $_.Exception }
        $errorObject | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 503 } -Force
        throw $errorObject
    }
    Wait-ExitFixture
}
function Read-Host {
    if ($global:FlintExitDuring -eq 'Completed' -and $global:FlintExitReads -eq 0) {
        $global:FlintExitReads++
        return 'Wait for the model.'
    }
    Wait-ExitFixture
}
if ($During -in @('Model', 'Retry')) { & $AgentPath -NoAzure -EnvFile (Join-Path $TestRoot '.env') -Prompt 'Wait for the model.' }
else { & $AgentPath -NoAzure -EnvFile (Join-Path $TestRoot '.env') }
'@
    $null = $driver.AddScript($scriptText).AddArgument($agentPath).AddArgument($testRoot).AddArgument($During)
    $pending = $driver.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(15)
    $ready = $false
    while ((Get-Date) -lt $deadline -and -not $pending.IsCompleted) {
        if ($During -eq 'Retry') {
            $ready = @($driver.Streams.Information | Where-Object { [string]$_.MessageData -like '*Retrying model (1/3) in 1s*' }).Count -gt 0
        } else { $ready = Test-Path -LiteralPath $pidPath }
        if ($ready) { break }
        Start-Sleep -Milliseconds 50
    }
    if (-not $ready) { throw ('The CLI cancellation fixture did not start: ' + [string]$driver.Streams.Error + ' ' + (($driver.Streams.Information | ForEach-Object { [string]$_.MessageData }) -join ' ')) }
    $driver.Stop()
    try { $null = $driver.EndInvoke($pending) } catch { }
    if ($During -ne 'Retry') {
        $childId = [int](Get-Content -LiteralPath $pidPath)
        if (Get-Process -Id $childId -ErrorAction SilentlyContinue) { throw 'CLI cancellation left a child process running.' }
    }
    $transcript = @($driver.Streams.Information | ForEach-Object { [string]$_.MessageData }) -join "`n"
    $expectedUsage = 'Token usage: not reported'
    if ($During -eq 'Prompt') { $expectedUsage = 'Token usage: total=0 input=0 output=0' }
    if ($During -eq 'Completed') { $expectedUsage = 'Token usage: total=1,290 input=1,234 output=56' }
    if (-not $transcript.Contains($expectedUsage) -or -not $transcript.Contains('-Resume ')) { throw ('CLI cancellation did not show an honest exit summary and resume command: ' + $transcript) }
    if ($transcript.Contains('test-api-key')) { throw 'The exit summary leaked credentials.' }
    $log = Get-ChildItem -LiteralPath (Join-Path $testRoot '.flint\trajectories') -Filter *.jsonl
    $events = @(Get-Content -LiteralPath $log.FullName -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    if ($events[-1].event -ne 'session_stopped' -or $events[-1].data.reason -ne 'cancelled') { throw 'CLI cancellation did not record session shutdown.' }
    $checkpoint = @($events | Where-Object { $_.event -eq 'session_checkpoint' })[-1]
    if ($During -ne 'Prompt' -and $checkpoint.data.state.History[0].content -ne 'Wait for the model.') { throw 'The exit checkpoint lost the interrupted request.' }
    if ($During -eq 'Retry' -and @($events | Where-Object { $_.event -eq 'model_request' }).Count -ne 1) { throw 'Cancellation during backoff sent another request.' }
    if ($During -eq 'Prompt' -and $checkpoint.data.state.History.Count -ne 0) { throw 'Idle cancellation changed the conversation.' }
    if ($During -eq 'Completed' -and ($checkpoint.data.state.History.Count -ne 2 -or $checkpoint.data.state.InputTokens -ne 1234)) { throw 'Cancellation after an answer lost conversation state or usage.' }
    Write-Host ('CLI exit cancellation passed (During={0}, ConstrainedLanguage).' -f $During)
} finally {
    $driver.Stop(); $driver.Dispose()
    $resolved = (Resolve-Path -LiteralPath $testRoot).ProviderPath
    if ($resolved -ne $testRoot -or (Split-Path $resolved -Parent) -ne $testParent) { throw 'Refusing cleanup outside the temporary exit test directory.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
