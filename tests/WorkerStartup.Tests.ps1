#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
try {
    $app = New-TestRuntime (Join-Path $TestRoot 'app')
    # Keep the real worker entry points; replace only remote HTTP boundaries.
    Add-Content -LiteralPath (Join-Path $app 'lib\Client.ps1') -Encoding UTF8 -Value @'
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec, $MaximumRedirection, $OutFile, $ErrorAction)
    if ($Headers.Authorization -cne 'Bearer test-api-key') { throw 'Worker authentication is missing.' }
    if ((Test-Path Env:FLINT_MODEL_API_KEY) -or (Test-Path Env:AZURE_OPENAI_API_KEY)) { throw 'Worker authentication was not removed from the environment.' }
    Set-Content -LiteralPath $OutFile -Value '{"status":"completed","output":[]}' -Encoding UTF8
}
'@
    Add-Content -LiteralPath (Join-Path $app 'tools\azure\Http.ps1') -Encoding UTF8 -Value @'
function Invoke-WebRequest {
    [CmdletBinding()]param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, [switch]$UseBasicParsing)
    if ($Headers.Authorization -cne 'Bearer private-worker-token' -or -not $UseBasicParsing -or $MaximumRedirection -ne 0) { throw 'Incorrect Azure worker transport.' }
    if ((Test-Path Env:FLINT_AZURE_ACCESS_TOKEN) -or (Test-Path Env:FLINT_MODEL_API_KEY) -or (Test-Path Env:AZURE_OPENAI_API_KEY)) { throw 'Worker authentication remains in its environment.' }
    if ($Uri -like '*fixture=transport-failure') { throw 'Fixture connection failed.' }
    if ($Uri -like '*fixture=forbidden' -or $Uri -like '*fixture=unauthorized') {
        $statusCode = 403
        if ($Uri -like '*fixture=unauthorized') { $statusCode = 401 }
        try { throw 'Fixture HTTP error.' } catch { $httpException = $_.Exception }
        $httpException | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $statusCode } -Force
        Write-Error -Exception $httpException -Message '{"error":{"code":"FixtureHttpError"}}' -ErrorAction Stop
    }
    return @{ StatusCode = 200; Content = '{"name":"vault","password":"private-result-value"}' }
}
'@
    foreach ($worker in @('lib\ModelWorker.Implementation.ps1', 'tools\Worker.Implementation.ps1')) {
        Add-Content -LiteralPath (Join-Path $app $worker) -Encoding UTF8 -Value @'
if ((Test-Path Env:FLINT_MODEL_API_KEY) -or (Test-Path Env:AZURE_OPENAI_API_KEY) -or (Test-Path Env:FLINT_AZURE_ACCESS_TOKEN)) { throw 'Worker authentication was not removed from the environment.' }
Set-Content -LiteralPath ($RequestPath + '.mode') -Value ([string]$ExecutionContext.SessionState.LanguageMode) -Encoding ASCII
'@
    }
    Set-Content -LiteralPath (Join-Path $WorkRoot 'note.txt') -Value 'Worker startup fixture.' -Encoding UTF8 -NoNewline
    $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($kind in @('Model', 'Tool', 'Azure')) {
        $requestPath = Join-Path $TestRoot ($kind + '.request')
        $resultPath = $requestPath + '.result'
        if ($kind -eq 'Model') {
            $workerPath = Join-Path $app 'lib\ModelWorker.ps1'
            $request = @{ endpoint = $Session.ApiEndpoint; timeout_sec = 10; payload = @{}; response_path = $resultPath; error_path = $requestPath + '.error' }
        } elseif ($kind -eq 'Azure') {
            $workerPath = Join-Path $app 'tools\Worker.ps1'
            $request = @{
                root = $WorkRoot; session_id = $Session.Id; name = 'azure_request'; timeout_sec = 10; result_path = $resultPath
                arguments = @{ method = 'GET'; path = '/subscriptions?api-version=2022-12-01'; body = ''; purpose = 'List subscriptions in the offline worker fixture.' }
                command_invocation = @{ executor = 'azure'; method = 'GET'; uri = 'https://management.azure.com/subscriptions?api-version=2022-12-01'; body = '' }
            }
        } else {
            $workerPath = Join-Path $app 'tools\Worker.ps1'
            $request = @{ root = $WorkRoot; name = 'read_file'; arguments = @{ path = 'note.txt'; start_line = 1; start_column = 1; max_lines = 200 }; protected_paths = @(); timeout_sec = 10; result_path = $resultPath }
        }
        Set-Content -LiteralPath $requestPath -Value (ConvertTo-Json $request -Depth 16 -Compress) -Encoding UTF8
        $arguments = @('-NoProfile', '-NonInteractive', '-File', ('"' + $workerPath + '"'), '-RequestPath', ('"' + $requestPath + '"'))
        $authentication = @{}
        if ($kind -eq 'Azure') { $authentication.AzureAccessToken = 'private-worker-token' }
        $native = Invoke-FlintProcess -FilePath $executable -ArgumentList $arguments -TimeoutSec 15 -WorkingDirectory $WorkRoot -ModelApiKey $Session.ApiKey @authentication
        Assert-True ($native.status -eq 'ok') ($kind + ' worker must start in an already constrained session. ' + $native.stderr)
        Assert-True ((Get-Content -LiteralPath ($requestPath + '.mode')).Trim() -ceq 'ConstrainedLanguage') 'Preserve the ambient language restrictions.'
        $result = ConvertFrom-Json (Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8)
        if ($kind -eq 'Model') { Assert-True ($result.status -eq 'completed') 'Reach the model transport from an already constrained worker.' }
        elseif ($kind -eq 'Azure') {
            Assert-True ($result.status -eq 'ok' -and $result.http_status -eq 200 -and $result.result_id) 'Execute and persist a native HTTP result in a constrained worker.'
            Assert-True (-not (Get-Content -LiteralPath $result.result_path -Raw).Contains('private-result-value')) 'Redact the saved HTTP response inside the worker.'
            foreach ($path in @($requestPath, $resultPath, $result.result_path)) {
                Assert-True (-not (Get-Content -LiteralPath $path -Raw).Contains('private-worker-token')) 'Keep the access token out of request and response files.'
            }
        } else { Assert-True ($result.status -eq 'ok' -and $result.output -ceq 'Worker startup fixture.') 'Execute a file tool from an already constrained worker.' }
    }

    # Exercise parent dispatch, worker serialization and parent result handling together.
    $Session.WorkerPath = Join-Path $app 'tools\Worker.ps1'
    $Session.Azure = @{
        Status = 'ready'; Account = 'user@example.com'; Tenant = '11111111-1111-1111-1111-111111111111'
        AccessToken = 'private-worker-token'; ExpiresUtc = [datetime]::UtcNow.AddHours(1)
    }
    foreach ($case in @(
        @{ name = 'success'; status = 'ok'; http_status = 200 },
        @{ name = 'forbidden'; status = 'error'; http_status = 403 },
        @{ name = 'transport-failure'; status = 'error'; http_status = $null },
        @{ name = 'unauthorized'; status = 'authentication_required'; http_status = 401 }
    )) {
        $result = Invoke-TestTool azure_request @{
            method = 'GET'; path = '/subscriptions?api-version=2022-12-01&fixture=' + $case.name; body = ''
        }
        Assert-True ($result.status -eq $case.status -and $result.http_status -eq $case.http_status) ('Preserve the worker result through the parent for ' + $case.name + ': ' + $result.output)
        Assert-True ('duration_ms' -in $result.Keys -and $result.duration_ms -gt 0) 'Attach parent timing even when worker JSON has no duration_ms property.'
        if ($null -ne $case.http_status) {
            Assert-True ($result.result_id -and (Test-Path -LiteralPath $result.result_path)) 'Keep the saved response reference after worker deserialization.'
        } else { Assert-True ($result.output -like '*Fixture connection failed*') 'Keep the transport error instead of replacing it with a result-processing error.' }
        if ($case.name -eq 'success') {
            $saved = Invoke-TestTool read_result @{ result_id = $result.result_id }
            Assert-True ($saved.status -eq 'ok' -and $saved.duration_ms -gt 0 -and $saved.output.Contains('vault')) 'Also replace an existing worker timing property when reading the saved result.'
        }
    }
    Assert-True ($Session.Azure.Status -eq 'authentication_required') 'Propagate HTTP 401 into the parent authentication state.'
} finally { Remove-TestFixture }
Write-Host 'All worker startup tests passed.'
