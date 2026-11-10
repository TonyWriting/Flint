#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
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
    $source = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'
    foreach ($file in @('ModelWorker.ps1', 'Client.ps1', 'Security.ps1')) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination $fixture }
    # Keep the actual worker and HTTP transport; replace only the remote service boundary.
    Add-Content -LiteralPath (Join-Path $fixture 'Client.ps1') -Encoding UTF8 -Value @'
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, $ErrorAction, $ContentType, $Body, $OutFile)
    if ($Method -ne 'Post' -or $Uri -ne 'https://test.services.ai.azure.com/openai/v1/responses' -or $Headers.Authorization -cne 'Bearer test-api-key') { throw 'Incorrect HTTP authentication or endpoint.' }
    if ((Test-Path Env:FLINT_MODEL_API_KEY) -or (Test-Path Env:AZURE_OPENAI_API_KEY)) { throw 'Worker authentication must be removed from its environment.' }
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
        $errorObject | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 429 } -Force
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
    foreach ($path in @($observed.request_path, $observed.response_path, ($observed.response_path + '.error'))) {
        Assert-True (-not (Test-Path -LiteralPath $path)) 'Clean up request, response and error files.'
    }
    # Four worker starts plus 7 seconds of backoff must fit inside the request deadline on slow hosts.
    $Session.RequestTimeoutSec = 60
    Assert-Throws { Invoke-TestModel 'failure' } '*HTTP 429*Rejected*redacted*'
    Assert-True ([int](Get-Content -LiteralPath (Join-Path $fixture 'failure.count')) -eq 4) 'Carry retryable HTTP status across the worker boundary and stop after four attempts.'
    $response = Invoke-TestModel 'recover'
    Assert-True ($response.status -eq 'completed' -and [int](Get-Content -LiteralPath (Join-Path $fixture 'recover.count')) -eq 2) 'Recover from a transient worker HTTP failure.'
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
