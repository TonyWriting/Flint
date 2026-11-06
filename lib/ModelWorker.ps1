#Requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$apiKey = $env:FLINT_MODEL_API_KEY
Remove-Item -LiteralPath Env:FLINT_MODEL_API_KEY -ErrorAction SilentlyContinue
Remove-Item -LiteralPath Env:AZURE_OPENAI_API_KEY -ErrorAction SilentlyContinue
Remove-Item -LiteralPath Env:FLINT_AZURE_ACCESS_TOKEN -ErrorAction SilentlyContinue
. (Join-Path $PSScriptRoot 'Security.ps1')
. (Join-Path $PSScriptRoot 'Client.ps1')
$request = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
$session = @{ ApiKey = $apiKey; ApiEndpoint = $request.endpoint; RequestTimeoutSec = $request.timeout_sec }
try {
    if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'Model worker authentication is missing.' }
    Invoke-FlintHttpRequest $session $request.payload $request.response_path
} catch {
    $failure = Get-FlintHttpFailure $session $_
    Set-Content -LiteralPath $request.error_path -Value (ConvertTo-Json -InputObject $failure -Depth 16 -Compress) -Encoding UTF8 -ErrorAction Stop
    exit 1
}
