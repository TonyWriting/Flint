#Requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$scriptStarted = [datetime]::UtcNow
$apiKey = $env:FLINT_MODEL_API_KEY
Remove-Item -LiteralPath Env:FLINT_MODEL_API_KEY -ErrorAction SilentlyContinue
Remove-Item -LiteralPath Env:FLINT_AZURE_ACCESS_TOKEN -ErrorAction SilentlyContinue
. (Join-Path $PSScriptRoot 'Security.ps1')
. (Join-Path $PSScriptRoot 'Telemetry.ps1')
. (Join-Path $PSScriptRoot 'Client.ps1')
$timing = [ordered]@{ load_ms = Get-FlintElapsedMs $scriptStarted }
$readStarted = [datetime]::UtcNow
$request = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
$timing.request_ms = Get-FlintElapsedMs $readStarted
$session = @{ ApiKey = $apiKey; ApiEndpoint = $request.endpoint; RequestTimeoutSec = $request.timeout_sec }
try {
    if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'Model worker authentication is missing.' }
    $sent = Invoke-FlintHttpRequest $session $request.payload $request.response_path
    $timing.serialize_ms = $sent.serialize_ms; $timing.http_ms = $sent.http_ms
} catch {
    $failure = Get-FlintHttpFailure $session $_
    Set-Content -LiteralPath $request.error_path -Value (ConvertTo-Json -InputObject $failure -Depth 16 -Compress) -Encoding UTF8 -ErrorAction Stop
    exit 1
}
# Standard output carries only these timings; the parent records them in the trajectory.
ConvertTo-Json -InputObject $timing -Compress
