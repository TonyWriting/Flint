#Requires -Version 5.1
param([ValidateSet('Tool', 'Model', 'Approval', 'Azure')][string]$During = 'Tool')
$ErrorActionPreference = 'Stop'
# The test driver owns a runspace; the harness inside it runs in ConstrainedLanguage.
$testParent = (Resolve-Path -LiteralPath $env:TEMP).ProviderPath.TrimEnd('\')
$testRoot = Join-Path $testParent ('flint-cancel-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$agentPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'agent.ps1'
$childPath = Join-Path $testRoot 'child.ps1'
$pidPath = Join-Path $testRoot 'pid.txt'
Set-Content -LiteralPath $childPath -Encoding ASCII -Value @(
    'param($RequestPath)'
    'if ($RequestPath) { Set-Content -LiteralPath (Join-Path $PSScriptRoot ''request-path.txt'') -Value $RequestPath }'
    ("Set-Content -LiteralPath '" + $pidPath.Replace("'", "''") + "' -Value `$PID; Start-Sleep -Seconds 60")
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
$script:TestRoot = $TestRoot
$session = New-AgentSession -EnvFile (Join-Path $TestRoot '.env')
$session.PermissionSessionDirectory = Join-Path $TestRoot 'permissions'
if ($During -eq 'Azure') {
    $session.Azure = @{ Status = 'ready'; Account = 'user@example.com'; Tenant = 'tenant'; AccessToken = 'private-test-token'; ExpiresUtc = [datetime]::UtcNow.AddHours(1) }
}
if ($During -eq 'Approval') {
    Initialize-FlintUi $session
    $session.Ui.Live = $true
    function Resolve-FlintCommandProgram { param($Executor); return [ordered]@{ path = (Join-Path $script:TestRoot 'kubectl.exe') } }
    function Read-Host {
        param($Prompt)
        Set-Content -LiteralPath (Join-Path $script:TestRoot 'pid.txt') -Value 'approval'
        Start-Sleep -Seconds 60
        return 'n'
    }
}
if ($During -eq 'Model') {
    Initialize-FlintUi $session
    $session.Ui.Live = $true
    $session.ModelWorkerPath = Join-Path $TestRoot 'child.ps1'
} else {
function Invoke-AgentResponse {
    param($Session, $Payload)
    if ($During -eq 'Azure') {
        return @{ status = 'completed'; output = @(
            @{ type = 'function_call'; call_id = 'call_1'; name = 'azure_request'; arguments = '{"method":"GET","path":"/subscriptions?api-version=2022-12-01","body":"","purpose":"List subscriptions for the cancellation fixture."}' },
            @{ type = 'function_call'; call_id = 'call_2'; name = 'azure_request'; arguments = '{"method":"GET","path":"/subscriptions?api-version=2022-12-01","body":"","purpose":"List subscriptions for the cancellation fixture."}' }
        ) }
    }
    if ($During -eq 'Approval') {
        return @{ status = 'completed'; output = @(
            @{ type = 'function_call'; call_id = 'call_1'; name = 'run_command'; arguments = '{"executor":"kubectl","arguments":["unclassified"],"purpose":"Exercise an unclassified command in the cancellation fixture."}' },
            @{ type = 'function_call'; call_id = 'call_2'; name = 'run_command'; arguments = '{"executor":"kubectl","arguments":["unclassified"],"purpose":"Exercise an unclassified command in the cancellation fixture."}' }
        ) }
    }
    return @{ status = 'completed'; output = @(
        @{ type = 'function_call'; call_id = 'call_1'; name = 'read_file'; arguments = '{"path":"file.txt","start_line":1,"start_column":1,"max_lines":200}' },
        @{ type = 'function_call'; call_id = 'call_2'; name = 'read_file'; arguments = '{"path":"file.txt","start_line":1,"start_column":1,"max_lines":200}' }
    ) }
}
}
function Invoke-FlintWorker {
    param($Session, $Name, $ToolArguments, $TimeoutSec, $CommandInvocation, $AzureAccessToken)
    if ($During -eq 'Approval') { Set-Content -LiteralPath (Join-Path $script:TestRoot 'executed.txt') -Value 'unexpected'; throw 'Worker started before approval.' }
    $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $fixture = Join-Path $script:TestRoot 'child.ps1'
    Invoke-FlintProcess $executable @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixture + '"')) 60 $script:TestRoot -Session $Session
}
try { Invoke-AgentTurn $session 'Read the file.' 2 | Out-Null }
finally {
    Set-Content -LiteralPath (Join-Path $TestRoot 'history.json') -Value (ConvertTo-Json -InputObject $session.History -Depth 32) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $TestRoot 'log-path.txt') -Value $session.TrajectoryPath -Encoding UTF8
}
'@
    $null = $driver.AddScript($scriptText).AddArgument($agentPath).AddArgument($testRoot).AddArgument($During)
    $pending = $driver.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path -LiteralPath $pidPath) -and (Get-Date) -lt $deadline -and -not $pending.IsCompleted) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $pidPath)) { throw ('The cancellation fixture did not start: ' + [string]$driver.Streams.Error) }
    $driver.Stop()
    try { $null = $driver.EndInvoke($pending) } catch { }
    if ($During -eq 'Approval') {
        if (Test-Path -LiteralPath (Join-Path $testRoot 'executed.txt')) { throw 'Cancelled approval executed a command.' }
        if (Test-Path -LiteralPath (Join-Path $testRoot 'permissions')) { throw 'Cancelled approval saved authorization.' }
    } else {
        $childId = [int](Get-Content -LiteralPath $pidPath)
        if (Get-Process -Id $childId -ErrorAction SilentlyContinue) { throw 'Cancellation left a child process running.' }
    }
    $history = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $testRoot 'history.json') -Raw -Encoding UTF8)
    $outputs = @($history | Where-Object { $_.type -eq 'function_call_output' })
    if ($During -in @('Tool', 'Approval', 'Azure') -and $outputs.Count -ne 2) { throw 'Cancellation left unmatched tool calls.' }
    if ($During -eq 'Model') {
        $requestPath = Get-Content -LiteralPath (Join-Path $testRoot 'request-path.txt')
        $responsePath = $requestPath.Substring(0, $requestPath.Length - '.request'.Length)
        foreach ($path in @($requestPath, $responsePath, ($responsePath + '.error'))) {
            if (Test-Path -LiteralPath $path) { throw 'Model cancellation left a temporary request or response file.' }
        }
    }
    $logPath = Get-Content -LiteralPath (Join-Path $testRoot 'log-path.txt') -Encoding UTF8
    $events = @(Get-Content -LiteralPath $logPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    if ('cancelled' -notin $events.data.reason) { throw 'Cancellation stop reason was not recorded.' }
    $checkpoint = @($events | Where-Object { $_.event -eq 'session_checkpoint' })[-1]
    if ($checkpoint.data.state.History.Count -ne $history.Count) { throw 'Cancellation did not save the final conversation for resume.' }
    if ($During -in @('Tool', 'Approval', 'Azure') -and @($checkpoint.data.state.History | Where-Object { $_.type -eq 'function_call_output' }).Count -ne 2) {
        throw 'The cancelled checkpoint lost uncertain tool results.'
    }
    Write-Host ('{0} cancellation passed (ConstrainedLanguage).' -f $During)
} finally {
    $driver.Stop(); $driver.Dispose()
    $resolved = (Resolve-Path -LiteralPath $testRoot).ProviderPath
    if ($resolved -ne $testRoot -or (Split-Path $resolved -Parent) -ne $testParent) { throw 'Refusing cleanup outside the temporary cancellation directory.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
