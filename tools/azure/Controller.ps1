# Main-process Azure authorization and worker orchestration.
function Get-FlintAzurePollContext {
    param([hashtable]$Session, [string]$Path)
    # Tool results already live in the resumable conversation; no second operation store is needed.
    $azureCalls = @{}; $context = $null
    foreach ($item in $Session.History) {
        if ($item.type -eq 'function_call' -and $item.name -ceq 'azure_request') { $azureCalls[$item.call_id] = $item }
        elseif ($item.type -eq 'function_call_output' -and $azureCalls.ContainsKey([string]$item.call_id)) {
            try { $result = ConvertFrom-Json -InputObject $item.output -ErrorAction Stop } catch { continue }
            if ($result.poll_path -ceq $Path -and $result.poll_kind -in @('status', 'location', 'resource')) { $context = $result }
            elseif ($result.operation_status -in @('Succeeded', 'Failed', 'Canceled', 'Cancelled')) {
                try { $arguments = ConvertFrom-Json -InputObject $azureCalls[$item.call_id].arguments -ErrorAction Stop } catch { continue }
                if ($arguments.path -ceq $Path) { $context = $null }
            }
        }
    }
    return $context
}

function New-FlintAzureInvocation {
    param([hashtable]$Session, $ToolArguments)
    Assert-FlintAzureRequest $ToolArguments
    if ((Protect-FlintValue $Session $ToolArguments.body) -cne $ToolArguments.body) { throw 'Azure request bodies must not contain credentials.' }
    if ($Session.Azure.Status -ne 'ready') { throw $Session.Azure.Message }
    if (-not $Session.Azure.Account -or -not $Session.Azure.Tenant) { throw 'Azure identity is unavailable. Restart Flint.' }
    $invocation = [ordered]@{
        executor = 'azure'; account = $Session.Azure.Account; tenant = $Session.Azure.Tenant
        method = $ToolArguments.method; uri = 'https://management.azure.com' + $ToolArguments.path; body = $ToolArguments.body
    }
    if ($ToolArguments.method -ceq 'GET') {
        $poll = Get-FlintAzurePollContext $Session $ToolArguments.path
        if ($poll) { $invocation.poll_kind = $poll.poll_kind }
    }
    return $invocation
}

function Read-FlintAzureApproval {
    param([hashtable]$Session, $Invocation, [string]$Purpose)
    Initialize-FlintUi $Session
    if (-not $Session.Ui.Live) { return $null }
    Clear-FlintProgress $Session
    Write-Host ''
    Write-Host (Protect-FlintText $Session ('Purpose (model-provided): ' + $Purpose)) -ForegroundColor Yellow
    Write-Host (Protect-FlintText $Session ('Azure account: {0}; tenant: {1}' -f $Invocation.account, $Invocation.tenant))
    Write-Host (Protect-FlintText $Session ($Invocation.method + ' ' + $Invocation.uri)) -ForegroundColor Yellow
    if ($Invocation.body) { Write-Host (Protect-FlintText $Session $Invocation.body) -ForegroundColor Yellow }
    Write-Host 'This request is not classified as read-only and may change Azure resources. Allow this exact request for this session?' -ForegroundColor Yellow
    try { return Read-Host 'y/n (default n)' } catch { return $null }
}

function New-FlintKeyVaultInvocation {
    param([hashtable]$Session, $ToolArguments)
    $uri = Get-FlintKeyVaultListUri $ToolArguments
    return [ordered]@{ executor = 'keyvault'; account = $Session.Azure.Account; tenant = $Session.Azure.Tenant; method = 'GET'; uri = $uri; body = '' }
}

function Complete-FlintAzureResult {
    param([hashtable]$Session, $Result, [string]$Service = 'arm')
    if ($Result.http_status -eq 401 -or $Result.status -eq 'authentication_required') {
        $Result.status = 'authentication_required'; $Result.retryable = $false
        if ($Service -eq 'keyvault') {
            $Session.Azure.KeyVault.Status = 'authentication_required'
            $Result.output = 'Key Vault authentication requires a new sign-in. Restart Flint to sign in to Azure.'
        } else {
            $Session.Azure.Status = 'authentication_required'
            $Session.Azure.Message = 'Azure authentication is no longer valid. Restart Flint to sign in to Azure; no interactive login is attempted during tool calls.'
            $Result.output = $Session.Azure.Message
        }
    }
    return $Result
}

function New-FlintAzureFailure {
    param([hashtable]$Session, $Record, [string]$Service = 'arm')
    $message = Protect-FlintText $Session $Record.Exception.Message
    $failure = Get-FlintFailureDetails $Session $Record
    if (Test-FlintAzureAuthenticationError $message) {
        if ($Service -eq 'keyvault') {
            if ($Session.Azure.KeyVault) { $Session.Azure.KeyVault.Status = 'authentication_required' }
            $message = 'Key Vault authentication requires user interaction. Restart Flint to sign in to Azure.'
        } else {
            $Session.Azure.Status = 'authentication_required'
            $Session.Azure.Message = 'Azure authentication requires user interaction. Restart Flint to sign in to Azure; no interactive login is attempted during tool calls.'
            $message = $Session.Azure.Message
        }
        return @{ status = 'authentication_required'; exit_code = $null; output = $message; retryable = $false; failure = $failure }
    }
    return @{ status = 'error'; exit_code = $null; output = $message; retryable = $false; failure = $failure }
}

function Invoke-FlintKeyVaultListSecrets {
    param([hashtable]$Session, $ToolArguments, $Invocation, [double]$TimeoutSec)
    $current = New-FlintKeyVaultInvocation $Session $ToolArguments
    if ((ConvertTo-Json $current -Compress) -cne (ConvertTo-Json $Invocation -Compress)) { throw 'The Key Vault metadata request changed after authorization.' }
    $started = [datetime]::UtcNow
    try {
        Update-FlintAzureToken $Session -Service keyvault
        $remaining = $TimeoutSec - ((Get-FlintElapsedMs $started) / 1000)
        if ($remaining -le 0) { return @{ status = 'timeout'; exit_code = $null; output = 'The time budget was consumed while obtaining the Key Vault token. No HTTP request was sent.'; retryable = $false } }
        $result = Invoke-FlintWorker $Session keyvault_list_secrets $ToolArguments -TimeoutSec $remaining -CommandInvocation $Invocation -AzureAccessToken $Session.Azure.KeyVault.AccessToken
        return Complete-FlintAzureResult $Session $result keyvault
    } catch {
        if ($Session.LogFailed) { throw }
        return New-FlintAzureFailure $Session $_ keyvault
    }
}

function Resolve-FlintAzurePermission {
    param([hashtable]$Session, $Invocation, [string]$CallId, [string]$Purpose)
    $readOnlyRule = Get-FlintAzureReadOnlyRule $Invocation.method $Invocation.uri $Invocation.body
    if ($readOnlyRule) {
        Write-FlintEvent $Session 'azure_permission' @{ call_id = $CallId; source = $readOnlyRule; invocation = $Invocation }
        return @{ allowed = $true; read_only = $true }
    }
    $signature = ConvertTo-Json -InputObject $Invocation -Depth 16 -Compress
    foreach ($approved in @(Read-FlintCommandApprovals $Session azure)) {
        if ((ConvertTo-Json -InputObject $approved -Depth 16 -Compress) -ceq $signature) { return @{ allowed = $true; read_only = $false } }
    }
    Write-FlintEvent $Session 'azure_approval_requested' @{ call_id = $CallId; invocation = $Invocation; purpose = $Purpose }
    $answer = Read-FlintAzureApproval $Session $Invocation -Purpose $Purpose
    $allowed = $null -ne $answer -and $answer.Trim() -ceq 'y'
    Write-FlintEvent $Session 'azure_approval_decided' @{ call_id = $CallId; allowed = $allowed }
    if ($allowed) { Save-FlintCommandApproval $Session $Invocation }
    $status = 'denied'
    if ($null -eq $answer) { $status = 'approval_required' }
    return @{ allowed = $allowed; read_only = $false; status = $status }
}

function Invoke-FlintAzureRequest {
    param([hashtable]$Session, $ToolArguments, $Invocation, [double]$TimeoutSec)
    $current = New-FlintAzureInvocation $Session $ToolArguments
    if ((ConvertTo-Json $current -Compress) -cne (ConvertTo-Json $Invocation -Compress)) { throw 'The Azure request changed after authorization.' }
    $started = [datetime]::UtcNow
    try {
        if ($Invocation.poll_kind) {
            $poll = Get-FlintAzurePollContext $Session $ToolArguments.path
            $notBefore = $poll.poll_after_utc -as [datetime]
            if ($notBefore -and $notBefore.ToUniversalTime() -gt [datetime]::UtcNow) {
                $seconds = ($notBefore.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds
                $delay = [int]($seconds - ($seconds % 1)) + 1
                $waited = $false
                if ($delay -lt $TimeoutSec) { $waited = Wait-FlintRetry $Session $delay $started.AddSeconds($TimeoutSec) 'Waiting to check Azure operation' }
                if (-not $waited) {
                    if ($Session.StopRequested) { return @{ status = 'stopped'; exit_code = $null; retryable = $false; output = 'Status check stopped before sending a request. The Azure operation may still be running.' } }
                    return @{
                        status = 'pending'; exit_code = $null; retryable = $false; operation_status = $poll.operation_status
                        poll_path = $poll.poll_path; poll_kind = $poll.poll_kind; poll_after_utc = $poll.poll_after_utc
                        output = 'The next status check is due after this call can wait. No HTTP request was sent. Report the operation as pending and continue later.'
                    }
                }
            }
        }
        Update-FlintAzureToken $Session
        $remaining = $TimeoutSec - ((Get-FlintElapsedMs $started) / 1000)
        if ($remaining -le 0) {
            return @{ status = 'timeout'; exit_code = $null; output = 'The time budget was consumed while obtaining the Azure token. No HTTP request was sent.'; retryable = $false }
        }
        $result = Invoke-FlintWorker $Session azure_request $ToolArguments -TimeoutSec $remaining -CommandInvocation $Invocation -AzureAccessToken $Session.Azure.AccessToken
        return Complete-FlintAzureResult $Session $result
    } catch {
        if ($Session.LogFailed) { throw }
        return New-FlintAzureFailure $Session $_
    }
}
