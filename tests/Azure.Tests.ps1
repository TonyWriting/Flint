#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
function New-AzureFixtureAccount {
    param([string]$Tenant = '11111111-1111-1111-1111-111111111111', [string]$Account = 'user@example.com')
    return @{ id = '22222222-2222-2222-2222-222222222222'; tenantId = $Tenant; user = @{ name = $Account; type = 'user' }; environmentName = 'AzureCloud'; state = 'Enabled'; isDefault = $true }
}
function Reset-AzureFixture {
    $script:Accounts = @(New-AzureFixtureAccount); $script:LoginAccount = New-AzureFixtureAccount
    $script:LoginCalls = 0; $script:TokenCalls = 0; $script:CliCalls = 0
    $script:CliFailure = ''; $script:TokenFailure = ''; $script:LoginFailure = $false; $script:TokenTenant = ''
    $Session.Azure = @{}; $Session.NoAzure = $false; $Session.AzureTenant = ''
    Initialize-FlintUi $Session
    $Session.Ui.Live = $true
}
function Get-Command {
    [CmdletBinding()]param($Name, $CommandType)
    Assert-True ($Name -eq 'az' -and $CommandType -eq 'Application') 'Resolve the installed CLI launcher.'
    return @{ Source = 'C:\fixture\az.cmd' }
}
function Invoke-FlintAzureCli {
    param($Session, $Operation)
    $script:CliCalls++
    if ($script:CliFailure) { throw $script:CliFailure }
    switch ($Operation) {
        'account' {
            if (-not $script:Accounts) { throw 'Please run az login to set up an account.' }
            return $script:Accounts | Select-Object -First 1
        }
        'login' { $script:LoginCalls++; if ($script:LoginFailure) { throw 'Sign-in was cancelled.' }; $script:Accounts = @($script:LoginAccount) }
        'token' {
            $script:TokenCalls++
            if ($script:TokenFailure -and $script:LoginCalls -eq 0) { throw $script:TokenFailure }
            $tenant = $Session.Azure.Tenant
            if ($script:TokenTenant) { $tenant = $script:TokenTenant }
            return @{ accessToken = 'private-access-token'; expires_on = [long](([datetime]::UtcNow.AddHours(1) - ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime()).TotalSeconds); tenant = $tenant }
        }
        default { throw 'Unexpected CLI operation.' }
    }
}
try {
    Reset-AzureFixture
    Initialize-FlintAzure $Session
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Status -eq 'ready' -and $LoginCalls -eq 0 -and $TokenCalls -eq 1) 'Reuse valid CLI credentials without login.'
    Update-FlintAzureToken $Session
    Assert-True ($TokenCalls -eq 1) 'Cache tokens until they approach expiration.'
    $Session.Azure.ExpiresUtc = [datetime]::UtcNow
    Update-FlintAzureToken $Session
    Assert-True ($TokenCalls -eq 2 -and $LoginCalls -eq 0) 'Refresh silently through the CLI cache.'
    $originalTenant = $Session.Azure.Tenant
    $script:Accounts[0].id = 'a-different-default-subscription'
    $script:Accounts[0].tenantId = '33333333-3333-3333-3333-333333333333'
    $Session.Azure.ExpiresUtc = [datetime]::UtcNow
    Update-FlintAzureToken $Session
    Assert-True ($Session.Azure.Tenant -eq $originalTenant -and $LoginCalls -eq 0 -and $TokenCalls -eq 3) 'Changing the CLI default subscription does not change the pinned tenant.'
    $script:Accounts[0].user.name = 'other@example.com'
    $Session.Azure.ExpiresUtc = [datetime]::UtcNow
    Assert-Throws { Update-FlintAzureToken $Session } '*account changed*'

    Reset-AzureFixture
    $script:TokenFailure = 'Run az login to refresh the expired login.'
    Initialize-FlintAzure $Session
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Status -eq 'ready' -and $LoginCalls -eq 1 -and $TokenCalls -eq 2) 'Call az login at most once at startup.'

    Reset-AzureFixture
    $script:Accounts = @(); $script:LoginFailure = $true
    Initialize-FlintAzure $Session
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Status -eq 'unavailable' -and $LoginCalls -eq 1) 'Never retry a cancelled startup login.'

    Reset-AzureFixture
    $script:Accounts = @(); $Session.Ui.Live = $false
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Status -eq 'authentication_required' -and $LoginCalls -eq 0) 'Noninteractive startup never launches login.'

    Reset-AzureFixture
    $script:CliFailure = "OSError: 'run_module' is disabled by policy"
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Status -eq 'unavailable' -and $LoginCalls -eq 0 -and $Session.Azure.Message.Contains('run_module')) 'Report CLI execution policy errors.'

    Reset-AzureFixture
    $Session.NoAzure = $true
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Status -eq 'disabled' -and $CliCalls -eq 0) 'Offline mode never invokes the CLI.'

    Reset-AzureFixture
    $Session.AzureTenant = '33333333-3333-3333-3333-333333333333'
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Tenant -eq $Session.AzureTenant -and $LoginCalls -eq 0) 'Request a token for the selected tenant independently of the default subscription.'

    Reset-AzureFixture
    $Session.AzureTenant = 'contoso.onmicrosoft.com'
    $script:TokenTenant = '11111111-1111-1111-1111-111111111111'
    $script:Accounts[0].id = 'tenant-level-account'; $script:Accounts[0].state = $null
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Status -eq 'ready' -and $Session.Azure.Tenant -eq $script:TokenTenant -and $LoginCalls -eq 0) 'Accept a tenant domain and a cached account without a subscription.'

    Reset-AzureFixture
    $Session.AzureTenant = '11111111-1111-1111-1111-111111111111'
    $script:TokenTenant = '33333333-3333-3333-3333-333333333333'
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Status -eq 'unavailable' -and $LoginCalls -eq 0) 'Reject a token for a different explicit tenant ID.'

    Reset-AzureFixture
    $script:Accounts[0].user.type = 'servicePrincipal'
    Initialize-FlintAzure $Session
    Assert-True ($Session.Azure.Account -eq 'user@example.com' -and $LoginCalls -eq 1) 'Use a user account instead of a service principal.'

    Reset-AzureFixture
    Initialize-FlintAzure $Session
    $script:RequestCalls = @(); $script:Stopped = 0; $script:ApprovalCalls = 0
    $script:HttpStatus = 200; $script:ResponseBody = '{"name":"vault","password":"private-response-password"}'
    $script:WorkerState = 'Completed'; $script:Answer = 'y'
    function Invoke-WebRequest {
        [CmdletBinding()]param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, [switch]$UseBasicParsing, $Body, $ContentType)
        Assert-True ($UseBasicParsing -and $Headers.Authorization -ceq 'Bearer private-access-token') 'Use the native HTTP client with the CLI token.'
        Assert-True ($MaximumRedirection -eq 0 -and $Uri.StartsWith('https://management.azure.com/')) 'Pin ARM and disable redirects.'
        $script:RequestCalls += @{ method = $Method; path = $Uri.Substring('https://management.azure.com'.Length); body = $Body }
        if ($script:HttpStatus -ge 400) {
            try { throw 'HTTP request failed.' } catch { $httpException = $_.Exception }
            $httpException | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $script:HttpStatus } -Force
            Write-Error -Exception $httpException -Message $script:ResponseBody -ErrorAction Stop
        }
        return @{ StatusCode = $script:HttpStatus; Content = $script:ResponseBody }
    }
    function Invoke-FlintWorker {
        param($Session, $Name, $ToolArguments, $TimeoutSec, $CommandInvocation, $AzureAccessToken)
        Assert-True ($Name -ceq 'azure_request' -and $AzureAccessToken -ceq 'private-access-token') 'Separate authentication from tool arguments.'
        if ($script:WorkerState -eq 'Running') { $script:Stopped++; return @{ status = 'timeout'; exit_code = $null; output = 'Timed out.'; retryable = $false } }
        return Invoke-FlintAzureHttpRequest $Session.Root $Session.Id $ToolArguments $CommandInvocation $AzureAccessToken $TimeoutSec
    }
    function Read-FlintAzureApproval { param($Session, $Invocation); $script:ApprovalCalls++; return $script:Answer }
    function Wait-FlintRetry { param($Session, $Seconds, $Deadline, $Stage); return $true }

    $read = @{ method = 'GET'; path = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/vault?api-version=2024-11-01'; body = '' }
    $result = Invoke-TestTool azure_request $read
    Assert-True ($result.status -eq 'ok' -and $result.http_status -eq 200 -and $ApprovalCalls -eq 0) 'Query the vault directly over ARM without command approval.'
    Assert-True (-not $result.output.Contains('private-response-password')) 'Redact credential fields in REST responses.'
    foreach ($path in @('https://evil.example/x?api-version=1', '//evil.example/?api-version=1', '/subscriptions/../tenants?api-version=1', '/subscriptions/%2e%2e/tenants?api-version=1', '/subscriptions?api-version=1#fragment', '/subscriptions', '/subscriptions?api-version=1&api-version=2', '/subscriptions?api-version=1&%61pi-version=2')) {
        Assert-True ((Invoke-TestTool azure_request @{ method = 'GET'; path = $path; body = '' }).status -eq 'error') 'Reject hosts, traversal and ambiguous API versions.'
    }
    foreach ($request in @(
        @{ method = 'GET'; path = $read.path; body = '{}' },
        @{ method = 'GET'; path = $read.path; body = ''; headers = @{} },
        @{ method = 'PATCH'; path = $read.path; body = '{broken' },
        @{ method = 'POST'; path = $read.path; body = '{"password":"do-not-send"}' }
    )) { Assert-True ((Invoke-TestTool azure_request $request).status -eq 'error') 'Reject malformed bodies and model-supplied credentials or headers.' }
    Assert-True ($RequestCalls.Count -eq 1) 'Invalid requests never reach the SDK.'
    $nextPath = '/subscriptions?api-version=2022-12-01&$skiptoken=page2'
    Assert-True ((Invoke-TestTool azure_request @{ method = 'GET'; path = $nextPath; body = '' }).status -eq 'ok') 'Accept opaque service continuation cursors without treating them as credentials.'
    Assert-True ($RequestCalls[-1].path -ceq $nextPath) 'Forward the complete continuation cursor.'
    $tokenCount = $TokenCalls
    $otherSubscriptionPath = $read.path.Replace('22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444')
    Assert-True ((Invoke-TestTool azure_request @{ method = 'GET'; path = $otherSubscriptionPath; body = '' }).status -eq 'ok' -and $TokenCalls -eq $tokenCount) 'Use the same tenant token for subscriptions explicitly named in each ARM request.'

    $write = @{ method = 'PATCH'; path = $read.path; body = '{"tags":{"owner":"team"}}' }
    $result = Invoke-TestTool azure_request $write
    $null = Invoke-TestTool azure_request $write
    Assert-True ($result.status -eq 'ok' -and $ApprovalCalls -eq 1) 'Reuse exact write approval.'
    $script:Answer = 'n'
    Assert-True ((Invoke-TestTool azure_request @{ method = 'PATCH'; path = $read.path; body = '{"tags":{"owner":"other"}}' }).status -eq 'denied') 'Changed payloads require new authorization.'
    $Session.Azure.Account = 'other@example.com'
    Assert-True ((Invoke-TestTool azure_request $write).status -eq 'denied') 'Another identity cannot reuse write approval.'
    $Session.Azure.Account = 'user@example.com'
    $script:Answer = $null
    Assert-True ((Invoke-TestTool azure_request @{ method = 'DELETE'; path = $read.path; body = '' }).status -eq 'approval_required') 'Noninteractive writes require approval.'

    $script:HttpStatus = 503; $count = $RequestCalls.Count
    $null = Invoke-TestTool azure_request $read
    Assert-True ($RequestCalls.Count -eq $count + 4) 'Retry transient GET failures within the shared budget.'
    $script:ResponseBody = ''; $count = $RequestCalls.Count
    $null = Invoke-TestTool azure_request $read
    Assert-True ($RequestCalls.Count -eq $count + 4) 'Retry transient HTTP status codes even when their error body is empty.'
    $script:ResponseBody = '{"name":"vault"}'
    $count = $RequestCalls.Count
    $null = Invoke-TestTool azure_request $write
    Assert-True ($RequestCalls.Count -eq $count + 1) 'Never retry an approved mutation.'
    $script:HttpStatus = 403
    $result = Invoke-TestTool azure_request $read
    Assert-True ($result.status -eq 'error' -and $result.http_status -eq 403 -and $Session.Azure.Status -eq 'ready') 'Permission failures do not invalidate authentication or trigger login.'
    $script:HttpStatus = 202
    $result = Invoke-TestTool azure_request $read
    Assert-True ($result.http_status -eq 202) 'Preserve accepted status so the model can check operation completion.'

    $script:WorkerState = 'Running'
    $invocation = New-FlintAzureInvocation $Session $read
    $result = Invoke-FlintAzureRequest $Session $read $invocation 30
    Assert-True ($result.status -eq 'timeout' -and $Stopped -eq 1) 'Preserve the HTTP worker timeout.'
    $script:WorkerState = 'Completed'; $script:HttpStatus = 401
    $result = Invoke-TestTool azure_request $read
    $count = $RequestCalls.Count
    $again = Invoke-TestTool azure_request $read
    Assert-True ($result.status -eq 'authentication_required' -and $again.status -eq 'authentication_required' -and $RequestCalls.Count -eq $count -and $LoginCalls -eq 0) 'Authentication loss disables Azure calls without another login.'
    $Session.Azure.Status = 'ready'; $Session.Azure.ExpiresUtc = [datetime]::UtcNow; $script:TokenFailure = 'Run az login to refresh authentication.'
    $result = Invoke-TestTool azure_request $read
    Assert-True ($result.status -eq 'authentication_required' -and $LoginCalls -eq 0) 'Require restart after CLI refresh fails.'

    $Session.Azure.Status = 'ready'; $script:TokenFailure = ''; $script:HttpStatus = 200
    $script:ResponseBody = '{"data":"' + ('x' * 40000) + '","tail":"saved-body-tail-marker"}'
    $result = Invoke-TestTool azure_request $read
    Assert-True ($result.result_id -and $result.preview_truncated -and $result.output.Length -le 2048) 'Return a result reference instead of a large response body.'
    Assert-True ((Get-Content -LiteralPath $result.result_path -Raw).Contains('saved-body-tail-marker')) 'Keep the complete response outside the model context.'
    $Session.History += @{ type = 'function_call_output'; call_id = 'saved-result'; output = (ConvertTo-Json $result -Depth 16 -Compress) }
    $payload = ConvertTo-Json (New-FlintPayload $Session) -Depth 32 -Compress
    Assert-True (-not $payload.Contains('saved-body-tail-marker') -and $payload.Contains($result.result_id)) 'Send only the preview and reference in subsequent model requests.'

    $originalRoot = $Session.Root
    $Session.Root = Join-Path $TestRoot 'blocked-results'
    New-Item -ItemType Directory -Path (Join-Path $Session.Root '.flint') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Session.Root '.flint\results') -Value 'not a directory'
    $count = $RequestCalls.Count
    try { $failedSave = Invoke-TestTool azure_request $write } finally { $Session.Root = $originalRoot }
    Assert-True ($failedSave.status -eq 'error' -and $failedSave.http_status -eq 200 -and -not $failedSave.result_id -and -not $failedSave.retryable -and $RequestCalls.Count -eq $count + 1) 'Report a completed request whose result could not be saved, without repeating the mutation.'

    Write-FlintCheckpoint $Session
    $log = Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8
    Assert-True (-not $log.Contains('saved-body-tail-marker')) 'Keep the full response out of trajectory checkpoints and model-request logs.'
    foreach ($private in @('private-access-token', 'private-response-password', 'do-not-send')) {
        Assert-True (-not $log.Contains($private)) 'Keep credentials and authentication state out of the trajectory and checkpoint.'
    }
    Write-Host 'All Azure tests passed.'
} finally { Remove-TestFixture }
