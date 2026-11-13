#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:Replies = @(); $script:Requests = @(); $script:OperationCalls = 0; $script:Waits = @()
$resourcePath = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Test/resources/example?api-version=2026-01-01'
$operationPath = '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Test/operations/123?api-version=2026-01-01'
function Set-OperationFixtureIdentity {
    $Session.Azure = @{ Status = 'ready'; Account = 'user@example.com'; Tenant = '11111111-1111-1111-1111-111111111111'; AccessToken = 'fixture-token'; ExpiresUtc = [datetime]::UtcNow.AddHours(1) }
}
function Read-FlintAzureApproval { return 'y' }
function Invoke-WebRequest {
    [CmdletBinding()]param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, [switch]$UseBasicParsing, $Body, $ContentType)
    $script:Requests += @{ method = $Method; uri = $Uri }
    if ($script:Replies.Count -eq 0) { throw 'Unexpected HTTP call in the offline operation fixture.' }
    $reply = $script:Replies[0]; $script:Replies = @($script:Replies | Select-Object -Skip 1)
    if ($reply.StatusCode -ge 400) {
        try { throw 'Fixture HTTP failure.' } catch { $exception = $_.Exception }
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $reply.StatusCode; Headers = $reply.Headers } -Force
        Write-Error -Exception $exception -Message $reply.Content -ErrorAction Stop
    }
    return $reply
}
function Invoke-FlintWorker {
    param($Session, $Name, $ToolArguments, $TimeoutSec, $CommandInvocation, $AzureAccessToken)
    return Invoke-FlintAzureHttpRequest $Session.Root $Session.Id $ToolArguments $CommandInvocation $AzureAccessToken $TimeoutSec
}
function Wait-FlintRetry {
    param($Session, $Seconds, $Deadline, $Stage)
    $script:Waits += $Seconds
    return -not $Session.StopRequested
}
function Invoke-OperationFixture {
    param([string]$Method, [string]$Path, [string]$Body = '')
    $arguments = @{ method = $Method; path = $Path; body = $Body; purpose = 'Exercise the offline Azure operation lifecycle.' }
    $result = Invoke-TestTool azure_request $arguments
    $script:OperationCalls++
    $callId = 'operation-' + $script:OperationCalls
    $Session.History += @(
        @{ type = 'function_call'; name = 'azure_request'; call_id = $callId; arguments = (ConvertTo-Json $arguments -Compress) },
        @{ type = 'function_call_output'; call_id = $callId; output = (ConvertTo-Json $result -Depth 16 -Compress) }
    )
    return $result
}
try {
    Set-OperationFixtureIdentity
    $script:Replies = @(
        @{ StatusCode = 202; Content = ''; Headers = @{ 'Azure-AsyncOperation' = 'https://management.azure.com' + $operationPath; Location = 'https://management.azure.com' + $resourcePath; 'Retry-After' = '0'; 'x-ms-request-id' = 'start-id'; 'x-ms-correlation-request-id' = 'correlation-id' } },
        @{ StatusCode = 200; Content = '{"status":"Running"}'; Headers = @{ 'Retry-After' = '0' } },
        @{ StatusCode = 200; Content = '{"status":"Succeeded"}'; Headers = @{} }
    )
    $started = Invoke-OperationFixture POST $resourcePath '{}'
    Assert-True ($started.status -eq 'pending' -and $started.http_status -eq 202 -and $started.poll_path -ceq $operationPath -and $started.poll_kind -eq 'status') 'Keep accepted operations pending and prefer Azure-AsyncOperation over Location.'
    Assert-True ($started.request_id -eq 'start-id' -and $started.correlation_id -eq 'correlation-id' -and $started.retry_after_seconds -eq 0 -and $started.result_id) 'Keep response references, request IDs and Retry-After even for an empty response.'
    $running = Invoke-OperationFixture GET $started.poll_path
    Assert-True ($running.status -eq 'pending' -and $running.operation_status -eq 'Running' -and $running.poll_path -eq $operationPath) 'Retain the polling address when an in-progress response omits it.'
    Write-FlintCheckpoint $Session
    Push-Location -LiteralPath $WorkRoot
    try { $script:Session = New-AgentSession -EnvFile $config -Resume $Session.Id } finally { Pop-Location }
    $Session.PermissionSessionDirectory = Join-Path $TestRoot 'permissions'
    Set-OperationFixtureIdentity
    $done = Invoke-OperationFixture GET $running.poll_path
    Assert-True ($done.status -eq 'ok' -and $done.operation_status -eq 'Succeeded') 'Recognize a terminal status after restoring the operation from the conversation.'
    Assert-True (($Requests.method -join ',') -ceq 'POST,GET,GET') 'Poll using reads without replaying the mutation.'
    Assert-True ($null -eq (Get-FlintAzurePollContext $Session $operationPath)) 'Release the polling context after a confirmed terminal result.'

    foreach ($state in @('Failed', 'Canceled', 'Cancelled')) {
        $script:Replies = @(
            @{ StatusCode = 202; Content = ''; Headers = @{ 'Azure-AsyncOperation' = $operationPath; 'Retry-After' = '0' } },
            @{ StatusCode = 200; Content = ('{"status":"' + $state + '","error":{"code":"OperationFailed","message":"Fixture operation failed."}}'); Headers = @{} }
        )
        $null = Invoke-OperationFixture POST $resourcePath '{}'
        $failed = Invoke-OperationFixture GET $operationPath
        Assert-True ($failed.status -eq 'error' -and $failed.operation_status -eq $state -and $failed.service_error.code -eq 'OperationFailed' -and -not $failed.retryable) 'Treat failed or canceled operations as terminal errors, including with HTTP 200.'
    }
    $script:Replies = @(
        @{ StatusCode = 202; Content = ''; Headers = @{ 'Azure-AsyncOperation' = $operationPath; 'Retry-After' = '0' } },
        @{ StatusCode = 200; Content = '{}'; Headers = @{} }
    )
    $null = Invoke-OperationFixture POST $resourcePath '{}'
    Assert-True ((Invoke-OperationFixture GET $operationPath).operation_status -eq 'Unknown') 'Do not infer completion when the status endpoint omits its status.'

    foreach ($header in @('Operation-Location', 'Location')) {
        $pollPath = $operationPath.Replace('/123?', ('/' + $header + '?'))
        $script:Replies = @(@{ StatusCode = 202; Content = ''; Headers = @{ $header = $pollPath; 'Retry-After' = '0' } })
        $pending = Invoke-OperationFixture POST $resourcePath '{}'
        Assert-True ($pending.status -eq 'pending' -and $pending.poll_path -ceq $pollPath) 'Accept safe relative ARM operation addresses.'
        $body = '{"status":"Succeeded"}'; $code = 200
        if ($header -eq 'Location') { $body = ''; $code = 204 }
        $script:Replies = @(@{ StatusCode = $code; Content = $body; Headers = @{} })
        Assert-True ((Invoke-OperationFixture GET $pollPath).operation_status -eq 'Succeeded') 'Apply the status or Location completion protocol associated with the operation.'
        $script:Replies = @(@{ StatusCode = 202; Content = ''; Headers = @{ $header = $pollPath; 'Retry-After' = '0' } }, @{ StatusCode = 200; Content = '{"status":"Failed"}'; Headers = @{} })
        $null = Invoke-OperationFixture POST $resourcePath '{}'
        Assert-True ((Invoke-OperationFixture GET $pollPath).status -eq 'error') 'Respect an explicit operation failure even when Location returns HTTP 200.'
    }
    foreach ($link in @('https://other.example/operations?api-version=1', 'http://management.azure.com/providers/op?api-version=1', '//other.example/providers/op?api-version=1', '/subscriptions/../tenants?api-version=1', '/subscriptions/operations/1', '/subscriptions/operations/1?api-version=1#fragment')) {
        $script:Replies = @(@{ StatusCode = 202; Content = ''; Headers = @{ 'Azure-AsyncOperation' = $link } })
        $pending = Invoke-OperationFixture POST $resourcePath '{}'
        Assert-True ($pending.status -eq 'pending' -and -not $pending.poll_path -and $pending.polling_error) 'Reject unsupported polling addresses without reporting the accepted mutation as failed or sending a second request.'
    }
    $script:Replies = @(@{ StatusCode = 202; Content = ''; Headers = @{} })
    $pending = Invoke-OperationFixture POST $resourcePath '{}'
    Assert-True ($pending.status -eq 'pending' -and -not $pending.poll_path) 'Keep a 202 without polling headers unconfirmed.'
    $script:Replies = @(@{ StatusCode = 201; Content = '{}'; Headers = @{ 'Azure-AsyncOperation' = ('x' * 8193) } })
    $pending = Invoke-OperationFixture POST $resourcePath '{}'
    Assert-True ($pending.status -eq 'pending' -and $pending.polling_error -and -not $pending.poll_path) 'Keep a 201 with an oversized operation header unconfirmed.'

    $script:Replies = @(
        @{ StatusCode = 201; Content = '{"properties":{"provisioningState":"Creating"}}'; Headers = @{ 'Retry-After' = '0' } },
        @{ StatusCode = 200; Content = '{"properties":{"provisioningState":"Succeeded"}}'; Headers = @{} }
    )
    $pending = Invoke-OperationFixture PUT $resourcePath '{}'
    Assert-True ($pending.status -eq 'pending' -and $pending.poll_kind -eq 'resource' -and $pending.poll_path -eq $resourcePath) 'Poll the resource for a PUT with a nonterminal provisioning state.'
    Assert-True ((Invoke-OperationFixture GET $pending.poll_path).operation_status -eq 'Succeeded') 'Confirm the resource provisioning state explicitly.'
    $script:Replies = @(@{ StatusCode = 200; Content = '{}'; Headers = @{} })
    Assert-True ((Invoke-OperationFixture GET $resourcePath).status -eq 'ok') 'Keep ordinary resource reads independent of completed operations.'
    $script:Replies = @(
        @{ StatusCode = 201; Content = '{"properties":{"provisioningState":"Creating"}}'; Headers = @{ 'Retry-After' = '0' } },
        @{ StatusCode = 200; Content = '{}'; Headers = @{} }
    )
    $null = Invoke-OperationFixture PUT $resourcePath '{}'
    Assert-True ((Invoke-OperationFixture GET $resourcePath).operation_status -eq 'Unknown') 'Do not equate resource existence with completion when provisioning state is missing.'

    $script:Replies = @(@{ StatusCode = 202; Content = ''; Headers = @{ 'Azure-AsyncOperation' = $operationPath; 'Retry-After' = '120' } })
    $pending = Invoke-OperationFixture POST $resourcePath '{}'
    $before = $Requests.Count
    $delayed = Invoke-OperationFixture GET $operationPath
    Assert-True ($delayed.status -eq 'pending' -and $Requests.Count -eq $before -and $delayed.poll_after_utc -eq $pending.poll_after_utc) 'Preserve pending work without sending a poll earlier than Retry-After or exceeding the tool budget.'
    $script:Replies = @(@{ StatusCode = 202; Content = ''; Headers = @{ 'Azure-AsyncOperation' = $operationPath; 'Retry-After' = '2' } }, @{ StatusCode = 200; Content = '{"status":"Succeeded"}'; Headers = @{} })
    $null = Invoke-OperationFixture POST $resourcePath '{}'
    $null = Invoke-OperationFixture GET $operationPath
    Assert-True ($Waits[-1] -ge 2 -and $Waits[-1] -le 3) 'Wait through the cancellable runtime before polling within the tool budget.'
    $script:Replies = @(@{ StatusCode = 202; Content = ''; Headers = @{ 'Azure-AsyncOperation' = $operationPath; 'Retry-After' = '2' } })
    $null = Invoke-OperationFixture POST $resourcePath '{}'
    $before = $Requests.Count; $Session.StopRequested = $true
    try { $stopped = Invoke-OperationFixture GET $operationPath } finally { $Session.StopRequested = $false }
    Assert-True ($stopped.status -eq 'stopped' -and $Requests.Count -eq $before) 'Cancel the polling wait without sending another HTTP request.'

    $date = [datetime]::UtcNow.AddSeconds(60).ToString('r')
    $metadata = Get-FlintAzureResponseMetadata @{ 'Retry-After' = $date }
    Assert-True ($metadata.retry_after_seconds -ge 59 -and $metadata.retry_after_seconds -le 61) 'Parse HTTP-date Retry-After headers.'
    $script:Replies = @(
        @{ StatusCode = 429; Content = ''; Headers = @{ 'Retry-After' = '7'; 'x-ms-request-id' = 'throttle-id' } },
        @{ StatusCode = 200; Content = '{}'; Headers = @{} }
    )
    $null = Invoke-OperationFixture GET '/subscriptions?api-version=2022-12-01'
    Assert-True ($Waits[-1] -eq 7) 'Honor Retry-After when retrying a throttled ARM read.'
    $script:Replies = @(@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed","message":"Fixture access denied."}}'; Headers = @{ 'x-ms-request-id' = 'failure-request-id' } })
    $failure = Invoke-OperationFixture GET '/subscriptions?api-version=2022-12-01'
    Assert-True ($failure.request_id -eq 'failure-request-id' -and $failure.service_error.code -eq 'AuthorizationFailed' -and $failure.failure.error_id -and $failure.failure.exception_type) 'Keep service and local failure details with request IDs.'
    $log = Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8
    Assert-True ($log.Contains('failure-request-id') -and $log.Contains('Fixture access denied.') -and -not $log.Contains('fixture-token')) 'Persist useful failure details through the existing redaction path.'
    $originalRoot = $Session.Root
    $Session.Root = Join-Path $TestRoot 'blocked-operation-results'
    New-Item -ItemType Directory -Path (Join-Path $Session.Root '.flint') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Session.Root '.flint\results') -Value 'not a directory'
    $script:Replies = @(@{ StatusCode = 202; Content = ''; Headers = @{ 'Azure-AsyncOperation' = $operationPath; 'x-ms-request-id' = 'accepted-save-failure' } })
    $before = $Requests.Count
    try { $failedSave = Invoke-OperationFixture POST $resourcePath '{}' } finally { $Session.Root = $originalRoot }
    Assert-True ($failedSave.status -eq 'error' -and $failedSave.http_status -eq 202 -and $failedSave.poll_path -eq $operationPath -and $failedSave.request_id -eq 'accepted-save-failure' -and $failedSave.failure.error_id -and $Requests.Count -eq $before + 1) 'Keep the operation reference and failure reason if saving the accepted response fails, without replaying the write.'
    Write-Host 'All Azure operation tests passed.'
} finally { Remove-TestFixture }
