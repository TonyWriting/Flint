#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:Replies = @()
function Invoke-AgentResponse {
    param($Session, $Payload)
    if ($script:Replies.Count -eq 0) { throw 'Unexpected model call in the parallel Azure fixture.' }
    $reply = $script:Replies[0]; $script:Replies = @($script:Replies | Select-Object -Skip 1)
    return $reply
}
function New-AzureParallelCall {
    param([string]$Name, [hashtable]$Arguments)
    return @{ type = 'function_call'; name = $Name; call_id = [guid]::NewGuid().ToString('N'); arguments = (ConvertTo-Json $Arguments -Depth 16 -Compress) }
}
function New-AzureParallelGet {
    param([string]$Fixture)
    return New-AzureParallelCall azure_request @{ method = 'GET'; path = '/subscriptions?api-version=2022-12-01&fixture=' + $Fixture; body = ''; purpose = 'Read the offline Azure fixture.' }
}
function Set-AzureParallelReplies {
    param([object[]]$Calls)
    $Session.History = @()
    $script:Replies = @(
        @{ status = 'completed'; output = $Calls },
        @{ status = 'completed'; output = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Done.' }) }) }
    )
}
try {
    $app = New-TestRuntime (Join-Path $TestRoot 'parallel-azure-app')
    $httpDirectory = Join-Path $app 'tools\azure'
    Add-Content -LiteralPath (Join-Path $httpDirectory 'Http.ps1') -Encoding UTF8 -Value @'
function Invoke-WebRequest {
    [CmdletBinding()]param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, [switch]$UseBasicParsing, $Body, $ContentType)
    $name = 'graph'; $token = 'parallel-arm-token'
    if ($Uri -match 'fixture=([a-z]+)') { $name = $Matches[1] }
    if ($Uri -match 'vault\.azure\.net') { $name = 'keyvault'; $token = 'parallel-keyvault-token' }
    if ($Headers.Authorization -cne ('Bearer ' + $token)) { throw 'Incorrect worker token audience.' }
    if ((Test-Path Env:FLINT_AZURE_ACCESS_TOKEN) -or (Test-Path Env:FLINT_MODEL_API_KEY) -or (Test-Path Env:AZURE_OPENAI_API_KEY)) { throw 'Worker authentication remains in its environment.' }
    $requestText = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8
    if ($requestText.Contains($token) -or $requestText.Contains('test-api-key')) { throw 'Worker request contains authentication.' }
    $counter = Join-Path $PSScriptRoot ($name + '.count')
    $attempt = 0
    if (Test-Path -LiteralPath $counter) { $attempt = [int](Get-Content -LiteralPath $counter) }
    $attempt++
    Set-Content -LiteralPath $counter -Value $attempt -Encoding ASCII
    $trace = Join-Path $PSScriptRoot ($name + '-' + $attempt)
    Set-Content -LiteralPath ($trace + '.start') -Value ([datetime]::UtcNow.Ticks) -Encoding ASCII
    if ($name -eq 'slow') {
        $retryMarker = Join-Path $PSScriptRoot 'retry-2.start'
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $retryMarker) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        if (-not (Test-Path -LiteralPath $retryMarker)) { throw 'The independent retry did not start while the slow request was running.' }
        Start-Sleep -Milliseconds 100
    }
    if ($name -eq 'retryagain') { Start-Sleep -Seconds 2 }
    $status = 200
    if ($name -in @('retry', 'retryagain') -and $attempt -eq 1) { $status = 503 }
    if ($name -eq 'unauthorized') { $status = 401 }
    Set-Content -LiteralPath ($trace + '.end') -Value ([datetime]::UtcNow.Ticks) -Encoding ASCII
    if ($status -ne 200) {
        try { throw 'Offline HTTP failure.' } catch { $exception = $_.Exception }
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $status; Headers = @{ 'Retry-After' = '1'; 'x-ms-request-id' = $name + '-' + $attempt } } -Force
        Write-Error -Exception $exception -Message '{"error":{"code":"FixtureFailure"}}' -ErrorAction Stop
    }
    return @{ StatusCode = 200; Content = '{"value":[]}'; Headers = @{ 'x-ms-request-id' = $name + '-' + $attempt } }
}
'@
    $Session.WorkerPath = Join-Path $app 'tools\Worker.ps1'; $Session.ToolTimeoutSec = 20
    $Session.Azure = @{
        Status = 'ready'; Account = 'user@example.com'; Tenant = '11111111-1111-1111-1111-111111111111'
        AccessToken = 'parallel-arm-token'; ExpiresUtc = [datetime]::UtcNow.AddHours(1)
        KeyVault = @{ Status = 'ready'; AccessToken = 'parallel-keyvault-token'; ExpiresUtc = [datetime]::UtcNow.AddHours(1) }
    }
    $slow = New-AzureParallelGet slow; $retry = New-AzureParallelGet retry
    $graph = New-AzureParallelCall azure_request @{ method = 'POST'; path = '/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01'; body = '{"query":"resources"}'; purpose = 'Query resources in the offline fixture.' }
    $keyvault = New-AzureParallelCall keyvault_list_secrets @{ vault_name = 'fixture-vault'; next_link = '' }
    Set-AzureParallelReplies @($slow, $retry, $graph, $keyvault)
    Assert-True ((Invoke-AgentTurn $Session 'Run independent Azure queries.' 2) -eq 'Done.') 'Complete concurrent ARM, Resource Graph and Key Vault reads.'
    $outputs = @($Session.History | Where-Object { $_.type -eq 'function_call_output' } | ForEach-Object { ConvertFrom-Json $_.output })
    Assert-True ($outputs.Count -eq 4 -and @($outputs | Where-Object { $_.status -ne 'ok' }).Count -eq 0) 'Keep every service result across worker serialization.'
    Assert-True ([int](Get-Content -LiteralPath (Join-Path $httpDirectory 'retry.count')) -eq 2) 'Retry only the transient read with its own attempt count.'
    $slowStart = [long](Get-Content -LiteralPath (Join-Path $httpDirectory 'slow-1.start'))
    $slowEnd = [long](Get-Content -LiteralPath (Join-Path $httpDirectory 'slow-1.end'))
    $retryStart = [long](Get-Content -LiteralPath (Join-Path $httpDirectory 'retry-2.start'))
    Assert-True ($retryStart -gt $slowStart -and $retryStart -lt $slowEnd) 'Start another HTTP query while the slow query is still executing.'
    $events = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    Assert-True (@($events | Where-Object { $_.event -eq 'tool_retry' -and $_.data.call_id -eq $retry.call_id }).Count -eq 1) 'Record retries under the original tool call ID.'
    Assert-True (@($events | Where-Object { $_.event -eq 'azure_approval_requested' }).Count -eq 0) 'Keep reviewed reads free of approval prompts.'
    $log = Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8
    Assert-True (-not $log.Contains('parallel-arm-token') -and -not $log.Contains('parallel-keyvault-token')) 'Keep both token audiences out of the parent trajectory.'

    $write = New-AzureParallelCall azure_request @{ method = 'PATCH'; path = '/subscriptions?api-version=2022-12-01'; body = '{}'; purpose = 'A model claim that this is read-only.' }
    Assert-True (-not (Get-FlintParallelCall $Session $write)) 'Classify actual HTTP operations independently of the purpose text.'
    $pollPath = '/providers/Microsoft.Test/operations/123?api-version=2026-01-01'
    $Session.History = @(
        @{ type = 'function_call'; name = 'azure_request'; call_id = 'accepted'; arguments = $write.arguments },
        @{ type = 'function_call_output'; call_id = 'accepted'; output = (ConvertTo-Json @{ status = 'pending'; poll_path = $pollPath; poll_kind = 'status'; poll_after_utc = [datetime]::UtcNow.AddSeconds(5).ToString('o') } -Compress) }
    )
    $poll = New-AzureParallelCall azure_request @{ method = 'GET'; path = $pollPath; body = ''; purpose = 'Check an operation.' }
    Assert-True (-not (Get-FlintParallelCall $Session $poll)) 'Preserve serial operation polling and its wait protocol.'

    Set-AzureParallelReplies @((New-AzureParallelGet unauthorized), (New-AzureParallelGet retryagain))
    $null = Invoke-AgentTurn $Session 'Stop retrying after authentication expires.' 2
    Assert-True ($Session.Azure.Status -eq 'authentication_required' -and [int](Get-Content -LiteralPath (Join-Path $httpDirectory 'retryagain.count')) -eq 1) 'Propagate authentication loss to the main process before another retry can launch.'
    Write-Host 'All parallel Azure tests passed.'
} finally { Remove-TestFixture }
