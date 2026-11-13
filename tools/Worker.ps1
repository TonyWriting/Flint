#Requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$azureAccessToken = $env:FLINT_AZURE_ACCESS_TOKEN
Remove-Item -LiteralPath Env:FLINT_AZURE_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item -LiteralPath Env:AZURE_OPENAI_API_KEY -ErrorAction SilentlyContinue
Remove-Item -LiteralPath Env:FLINT_MODEL_API_KEY -ErrorAction SilentlyContinue
foreach ($file in @('Security', 'Telemetry', 'Runtime')) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) ('lib\' + $file + '.ps1'))
}
. (Join-Path $PSScriptRoot 'Registry.ps1')
. (Join-Path $PSScriptRoot 'Files.ps1')
. (Join-Path $PSScriptRoot 'Reading.ps1')
. (Join-Path $PSScriptRoot 'Results.ps1')
. (Join-Path $PSScriptRoot 'Searching.ps1')
. (Join-Path $PSScriptRoot 'azure\Http.ps1')
. (Join-Path $PSScriptRoot 'azure\KeyVault.ps1')
. (Join-Path $PSScriptRoot 'Commands.ps1')
$request = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
try {
    $parsed = ConvertTo-FlintToolArguments $request.name (ConvertTo-Json -InputObject $request.arguments -Depth 16 -Compress)
    if ($request.name -ceq 'run_command') { $result = Invoke-FlintCommand $request.root $parsed $request.command_invocation $request.timeout_sec -SessionId $request.session_id }
    elseif ($request.name -ceq 'azure_request') { $result = Invoke-FlintAzureHttpRequest $request.root $request.session_id $parsed $request.command_invocation $azureAccessToken $request.timeout_sec }
    elseif ($request.name -ceq 'keyvault_list_secrets') { $result = Invoke-FlintKeyVaultListSecretsHttp $request.root $request.session_id $parsed $request.command_invocation $azureAccessToken $request.timeout_sec }
    elseif ($request.name -ceq 'search_text') { $result = Search-FlintText $request.root $request.session_id $parsed $request.protected_paths }
    else { $result = Invoke-FlintFileTool $request.root $request.name $parsed $request.protected_paths $request.write_directory -SessionId $request.session_id }
} catch {
    $result = @{ status = 'error'; exit_code = $null; output = $_.Exception.Message; retryable = $false; duration_ms = 0; failure = Get-FlintFailureDetails $null $_ }
}
$result = Protect-FlintValue $null $result
Set-Content -LiteralPath $request.result_path -Value (ConvertTo-Json -InputObject $result -Depth 32 -Compress) -Encoding UTF8 -ErrorAction Stop
