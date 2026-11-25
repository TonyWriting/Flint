#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
$savedModelKey = $env:FLINT_MODEL_API_KEY
$script:Frames = @()
function Write-Host { param($Object, [switch]$NoNewline, [string]$ForegroundColor); $script:Frames += [string]$Object }
function Get-FlintTerminalWidth {
    Assert-True ($env:FLINT_MODEL_API_KEY -ceq 'preserved-parent-value') 'Restore the parent environment before waiting for the worker.'
    return 100
}
function Invoke-TestModel {
    param([string]$InputText)
    Start-FlintTurnUi $Session
    Show-FlintActivity $Session 'Thinking'
    try { Invoke-AgentResponse $Session @{ model = $Session.Model; input = $InputText } }
    finally { Stop-FlintTurnUi $Session }
}
try {
    $env:FLINT_MODEL_API_KEY = 'preserved-parent-value'
    $fixture = Join-Path $TestRoot 'model worker'
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $source = Join-Path $RepoRoot 'lib'
    foreach ($file in @('ModelWorker.ps1', 'Client.ps1', 'Security.ps1', 'Telemetry.ps1')) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination $fixture }
    # Keep the actual worker and HTTP transport; replace only the remote service boundary.
    Add-Content -LiteralPath (Join-Path $fixture 'Client.ps1') -Encoding UTF8 -Value @'
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, $ErrorAction, $ContentType, $Body, $OutFile)
    if ($Method -ne 'Post' -or $Uri -ne 'https://test.services.ai.azure.com/openai/v1/responses' -or $Headers.Authorization -cne 'Bearer test-api-key') { throw 'Incorrect HTTP authentication or endpoint.' }
    if (Test-Path Env:FLINT_MODEL_API_KEY) { throw 'Worker authentication must be removed from its environment.' }
    if ($Body.Contains('test-api-key')) { throw 'Model credentials appeared in the request payload.' }
    if ($MaximumRedirection -ne 0 -or $TimeoutSec -le 0 -or $ContentType -ne 'application/json; charset=utf-8') { throw 'Incorrect HTTP request options.' }
    $metadata = @{ request_path = $RequestPath; response_path = $OutFile; language_mode = [string]$ExecutionContext.SessionState.LanguageMode }
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'observed.json') -Value (ConvertTo-Json -InputObject $metadata -Depth 8) -Encoding UTF8
    $request = ConvertFrom-Json -InputObject $Body
    $counterPath = Join-Path $PSScriptRoot ($request.input + '.count')
    $count = 0
    if (Test-Path -LiteralPath $counterPath) { $count = [int](Get-Content -LiteralPath $counterPath) }
    Set-Content -LiteralPath $counterPath -Value ($count + 1) -Encoding ASCII
    if ($request.input -eq 'slow') { Start-Sleep -Seconds 2 }
    if ($request.input -eq 'failure' -or ($request.input -eq 'recover' -and $count -eq 0)) {
        try { throw 'Rejected test-api-key' } catch { $errorObject = $_.Exception }
        $status = 429
        if ($request.input -eq 'failure') { $status = 401 }
        $errorObject | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $status } -Force
        throw $errorObject
    }
    if ($request.input -eq 'malformed') { Set-Content -LiteralPath $OutFile -Value '{broken' -Encoding UTF8; return }
    $response = @{ status = 'completed'; output = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Ready.' }) }) }
    Set-Content -LiteralPath $OutFile -Value (ConvertTo-Json -InputObject $response -Depth 16) -Encoding UTF8
}
'@
    $Session.ModelWorkerPath = New-TestWorkerLauncher (Join-Path $fixture 'ModelWorker.ps1') (Join-Path $fixture 'launch.ps1')
    $Session.RequestTimeoutSec = 10
    Initialize-FlintUi $Session
    $Session.Ui.Live = $true; $Session.Ui.Ansi = $false
    $response = Invoke-TestModel 'slow'
    Assert-True ($response.status -eq 'completed') 'Receive a model response through a real worker process.'
    Assert-True (@($script:Frames | Where-Object { $_ -like '*Working (1s*' }).Count -gt 0 -and @($script:Frames | Where-Object { $_ -like '*Working (2s*' }).Count -gt 0) 'Continue updating elapsed time while HTTP is blocked.'
    $observed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $fixture 'observed.json') -Raw -Encoding UTF8)
    Assert-True ($observed.language_mode -ceq 'ConstrainedLanguage') 'Execute the model request in ConstrainedLanguage.'
    $timing = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json -InputObject $_ } | Where-Object { $_.event -eq 'model_response' })[-1].timing
    Assert-True ($timing.worker.http_ms -ge 1900 -and $timing.process_ms -ge $timing.worker.http_ms -and $timing.worker.load_ms -gt 0 -and
        $null -ne $timing.worker.request_ms -and $null -ne $timing.prepare_ms -and $timing.attempt_ms -ge $timing.process_ms) 'Separate the model service wait from worker and file overhead.'
    $parsed = ConvertFrom-FlintTiming ("unrelated output`r`n" + '{"load_ms":12,"note":"x","http_ms":"slow","run_ms":3}' + "`r`n")
    Assert-True ($parsed.Count -eq 2 -and $parsed.load_ms -eq 12 -and $parsed.run_ms -eq 3) 'Read only numeric worker timings and ignore other output.'
    foreach ($path in @($observed.request_path, $observed.response_path, ($observed.response_path + '.error'))) {
        Assert-True (-not (Test-Path -LiteralPath $path)) 'Clean up request, response and error files.'
    }
    # Two worker starts plus one second of backoff must fit inside the request deadline on slow hosts.
    $Session.RequestTimeoutSec = 30
    Assert-Throws { Invoke-TestModel 'failure' } '*HTTP 401*Rejected*redacted*'
    Assert-True ([int](Get-Content -LiteralPath (Join-Path $fixture 'failure.count')) -eq 1) 'Carry a redacted HTTP failure across the worker boundary without retrying an authentication error.'
    $response = Invoke-TestModel 'recover'
    Assert-True ($response.status -eq 'completed' -and [int](Get-Content -LiteralPath (Join-Path $fixture 'recover.count')) -eq 2) 'Carry a retryable HTTP status across the worker boundary and recover.'
    Assert-True (@($script:Frames | Where-Object { $_ -like '*Retrying model (1/3) in 1s*' }).Count -gt 0) 'Show retries while the elapsed-time display remains active.'
    Assert-Throws { Invoke-TestModel 'malformed' } '*Azure OpenAI request failed*'
    Assert-True ([int](Get-Content -LiteralPath (Join-Path $fixture 'malformed.count')) -eq 1) 'Do not retry a successful HTTP response with invalid JSON.'
    $Session.RequestTimeoutSec = 1
    Assert-Throws { Invoke-TestModel 'slow' } '*timed out after 1 seconds*'
    Assert-True ($env:FLINT_MODEL_API_KEY -ceq 'preserved-parent-value' -and -not $Session.Ui.Active -and $Session.Ui.Width -eq 0) 'Restore environment and clear the timer after failures.'
    Assert-Throws { Invoke-FlintProcess -FilePath (Join-Path $TestRoot 'missing.exe') -ArgumentList @('unused') -TimeoutSec 1 -WorkingDirectory $WorkRoot -ModelApiKey $Session.ApiKey } '*cannot*'
    Assert-True ($env:FLINT_MODEL_API_KEY -ceq 'preserved-parent-value') 'Restore credentials even when process creation fails.'
    Assert-True (-not (Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8).Contains('test-api-key')) 'Keep worker credentials out of the trajectory.'
} finally { $env:FLINT_MODEL_API_KEY = $savedModelKey; Remove-TestFixture }
Microsoft.PowerShell.Utility\Write-Host 'All model worker tests passed.'
