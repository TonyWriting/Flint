# Main-process Azure authorization and worker orchestration.
function New-FlintAzureInvocation {
    param([hashtable]$Session, $ToolArguments)
    Assert-FlintAzureRequest $ToolArguments
    if ((Protect-FlintValue $Session $ToolArguments.body) -cne $ToolArguments.body) { throw 'Azure request bodies must not contain credentials.' }
    if ($Session.Azure.Status -ne 'ready') { throw $Session.Azure.Message }
    if (-not $Session.Azure.Account -or -not $Session.Azure.Tenant) { throw 'Azure identity is unavailable. Restart Flint.' }
    return [ordered]@{
        executor = 'azure'; account = $Session.Azure.Account; tenant = $Session.Azure.Tenant
        method = $ToolArguments.method; uri = 'https://management.azure.com' + $ToolArguments.path; body = $ToolArguments.body
    }
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
        if ($result.http_status -eq 401 -or $result.status -eq 'authentication_required') {
            $Session.Azure.KeyVault.Status = 'authentication_required'
            $result.status = 'authentication_required'
            $result.output = 'Key Vault authentication requires a new sign-in. Restart Flint to sign in to Azure.'
            $result.retryable = $false
        }
        return $result
    } catch {
        $message = Protect-FlintText $Session $_.Exception.Message
        if (Test-FlintAzureAuthenticationError $message) {
            if ($Session.Azure.KeyVault) { $Session.Azure.KeyVault.Status = 'authentication_required' }
            return @{ status = 'authentication_required'; exit_code = $null; output = 'Key Vault authentication requires user interaction. Restart Flint to sign in to Azure.'; retryable = $false }
        }
        return @{ status = 'error'; exit_code = $null; output = $message; retryable = $false }
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
        Update-FlintAzureToken $Session
        $remaining = $TimeoutSec - ((Get-FlintElapsedMs $started) / 1000)
        if ($remaining -le 0) {
            return @{ status = 'timeout'; exit_code = $null; output = 'The time budget was consumed while obtaining the Azure token. No HTTP request was sent.'; retryable = $false }
        }
        $result = Invoke-FlintWorker $Session azure_request $ToolArguments -TimeoutSec $remaining -CommandInvocation $Invocation -AzureAccessToken $Session.Azure.AccessToken
        if ($result.http_status -eq 401 -or $result.status -eq 'authentication_required') {
            $Session.Azure.Status = 'authentication_required'
            $Session.Azure.Message = 'Azure authentication is no longer valid. Restart Flint to sign in to Azure; no interactive login is attempted during tool calls.'
            $result.status = 'authentication_required'
            $result.output = $Session.Azure.Message
            $result.retryable = $false
        }
        return $result
    } catch {
        $message = Protect-FlintText $Session $_.Exception.Message
        if (Test-FlintAzureAuthenticationError $message) {
            $Session.Azure.Status = 'authentication_required'
            $Session.Azure.Message = 'Azure authentication requires user interaction. Restart Flint to sign in to Azure; no interactive login is attempted during tool calls.'
            return @{ status = 'authentication_required'; exit_code = $null; output = $Session.Azure.Message; retryable = $false }
        }
        return @{ status = 'error'; exit_code = $null; output = $message; retryable = $false }
    }
}
