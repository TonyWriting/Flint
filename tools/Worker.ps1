#Requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$scriptStarted = [datetime]::UtcNow
$azureAccessToken = $env:FLINT_AZURE_ACCESS_TOKEN
Remove-Item -LiteralPath Env:FLINT_AZURE_ACCESS_TOKEN -ErrorAction SilentlyContinue
Remove-Item -LiteralPath Env:FLINT_MODEL_API_KEY -ErrorAction SilentlyContinue
foreach ($file in @('Security', 'Telemetry', 'Runtime', 'Results')) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) ('lib\' + $file + '.ps1'))
}
. (Join-Path $PSScriptRoot 'Registry.ps1')
. (Join-Path $PSScriptRoot 'Files.ps1')
. (Join-Path $PSScriptRoot 'Reading.ps1')
. (Join-Path $PSScriptRoot 'Searching.ps1')
. (Join-Path $PSScriptRoot 'azure\Http.ps1')
. (Join-Path $PSScriptRoot 'azure\KeyVault.ps1')
. (Join-Path $PSScriptRoot 'Commands.ps1')
$loadMs = Get-FlintElapsedMs $scriptStarted
$runStarted = [datetime]::UtcNow
$request = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
try {
    $parsed = ConvertTo-FlintToolArguments $request.name (ConvertTo-Json -InputObject $request.arguments -Depth 16 -Compress)
    if ($request.name -ceq 'run_command') {
        $guarded = @($request.guarded_patch_resources | Where-Object { $_ -is [string] -and $_ })
        # Stop kubectl before the parent stops this worker, leaving time to return what kubectl printed.
        $commandTimeout = $request.timeout_sec - ((Get-FlintElapsedMs $scriptStarted) / 1000) - 5
        if ($commandTimeout -lt 1) { $commandTimeout = 1 }
        $result = Invoke-FlintCommand $request.root $parsed $request.command_invocation $commandTimeout -SessionId $request.session_id -GuardedResources $guarded
    }
    elseif ($request.name -ceq 'azure_request') { $result = Invoke-FlintAzureHttpRequest $request.root $request.session_id $parsed $request.command_invocation $azureAccessToken $request.timeout_sec }
    elseif ($request.name -ceq 'keyvault_list_secrets') { $result = Invoke-FlintKeyVaultListSecretsHttp $request.root $request.session_id $parsed $request.command_invocation $azureAccessToken $request.timeout_sec }
    elseif ($request.name -ceq 'search_text') { $result = Search-FlintText $request.root $request.session_id $parsed $request.protected_paths }
    else { $result = Invoke-FlintFileTool $request.root $request.name $parsed $request.protected_paths $request.write_directory -SessionId $request.session_id }
} catch {
    $result = @{ status = 'error'; exit_code = $null; output = $_.Exception.Message; retryable = $false; duration_ms = 0; failure = Get-FlintFailureDetails $null $_ }
}
# Tools that wait on kubectl or an HTTP request report that wait as duration_ms.
$callMs = $result.duration_ms -as [long]
$result = Protect-FlintValue $null $result
Set-Content -LiteralPath $request.result_path -Value (ConvertTo-Json -InputObject $result -Depth 32 -Compress) -Encoding UTF8 -ErrorAction Stop
# Standard output carries only these timings; the parent records them in the trajectory.
$timing = [ordered]@{ load_ms = $loadMs; run_ms = Get-FlintElapsedMs $runStarted }
if ($callMs -gt 0) { $timing.call_ms = $callMs }
ConvertTo-Json -InputObject $timing -Compress
