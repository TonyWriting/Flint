function Complete-FlintToolResult {
    param([hashtable]$Session, [string]$Name, $Parsed, [string]$CallId, [datetime]$Started, $Result)
    if (-not $Result) { $Result = @{ status = 'cancelled'; exit_code = $null; output = 'Tool interrupted; verify actual state before repeating any write.'; retryable = $false } }
    $result = Protect-FlintValue $Session $Result
    $result.duration_ms = Get-FlintElapsedMs $Started
    Write-FlintEvent $Session 'tool_finished' @{ call_id = $CallId; name = $Name; result = $result } -BestEffort
    if ($result.output.Length -gt 32768) { $result.output = $result.output.Substring(0, 32768) + "`n[truncated at 32768 characters]"; $result.truncated = $true }
    Show-FlintToolResult $Session $Name $Parsed $result
    return $result
}

function Invoke-AgentTool {
    param([hashtable]$Session, [string]$Name, [string]$Arguments, [string]$CallId)
    $started = [datetime]::UtcNow
    $invocation = $null
    $permission = @{ allowed = $true; read_only = $false }
    $result = $null
    $parsed = $null
    Write-FlintEvent $Session 'tool_started' @{ call_id = $CallId; name = $Name; arguments = $Arguments }
    try {
        $parsed = ConvertTo-FlintToolArguments $Name $Arguments
        if (Test-FlintUnsafeArguments $Session $Arguments) {
            throw 'Tool arguments contain one of Flint''s own credentials or terminal control characters. No action was taken.'
        }
        if ($Name -ceq 'run_command') {
            $invocation = New-FlintCommandInvocation $Session $parsed
            $permission = Resolve-FlintCommandPermission $Session $invocation $CallId -Purpose $parsed.purpose
        } elseif ($Name -cin @('azure_request', 'keyvault_list_secrets')) {
            if ($Session.Azure.Status -ne 'ready') {
                $result = @{ status = $Session.Azure.Status; exit_code = $null; output = $Session.Azure.Message; retryable = $false }
                $permission = @{ allowed = $false; read_only = $false }
            } elseif ($Name -ceq 'keyvault_list_secrets') {
                $invocation = New-FlintKeyVaultInvocation $Session $parsed
                $permission = @{ allowed = $true; read_only = $true }
                Write-FlintEvent $Session 'azure_permission' @{ call_id = $CallId; source = 'keyvault_metadata'; invocation = $invocation }
            } else {
                $invocation = New-FlintAzureInvocation $Session $parsed
                $permission = Resolve-FlintAzurePermission $Session $invocation $CallId -Purpose $parsed.purpose
            }
        } elseif ($Name -in @('write_file', 'edit_file', 'create_directory')) {
            $permission = Resolve-FlintFilePermission $Session $Name $parsed $CallId
        }
        if (-not $permission.allowed -and -not $result) {
            $result = @{ status = $permission.status; exit_code = $null; output = 'No action was taken. Explicit y/n approval is required in an interactive terminal.'; retryable = $false }
            if ($permission.status -eq 'denied') { $result.output = 'User declined approval. No action was taken. Do not resubmit it without a new user request.' }
        }
        # Human approval time is outside the execution timeout.
        $deadline = ([datetime]::UtcNow).AddSeconds($Session.ToolTimeoutSec)
        # Reads stop at once; a change runs to completion so its outcome stays known.
        $Session.StopDeferred = -not ($permission.read_only -or $Name -cin @('list_files', 'read_file', 'search_text'))
        for ($attempt = 0; $permission.allowed -and $attempt -le 3; $attempt++) {
            $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
            if ($remaining -le 0) {
                $result = @{ status = 'timeout'; exit_code = $null; output = 'Tool time budget exhausted.'; retryable = $false }
                break
            }
            Show-FlintActivity $Session (Get-FlintToolLabel $Name $parsed)
            if ($Name -ceq 'azure_request') {
                $result = Invoke-FlintAzureRequest $Session $parsed $invocation -TimeoutSec $remaining
            } elseif ($Name -ceq 'keyvault_list_secrets') {
                $result = Invoke-FlintKeyVaultListSecrets $Session $parsed $invocation -TimeoutSec $remaining
            } else {
                $result = Invoke-FlintWorker $Session $Name $parsed -TimeoutSec $remaining -CommandInvocation $invocation -WriteDirectory $permission.directory
            }
            # A session approval never classifies an unknown command as read-only.
            if (-not $permission.read_only -or $result.status -ne 'error' -or -not $result.retryable -or $attempt -eq 3) { break }
            $delay = @(1, 2, 4)[$attempt]
            if ($null -ne $result.retry_after_seconds -and $result.retry_after_seconds -gt $delay) { $delay = $result.retry_after_seconds }
            if (($deadline - [datetime]::UtcNow).TotalSeconds -le $delay) { break }
            Write-FlintEvent $Session 'tool_retry' @{ call_id = $CallId; attempt = $attempt + 2; delay_seconds = $delay; result = $result }
            if (-not (Wait-FlintRetry $Session $delay $deadline ('Retrying command ({0}/3) in {1}s' -f ($attempt + 1), $delay))) { break }
        }
    } catch {
        if ($Session.LogFailed) { throw }
        $result = @{ status = 'error'; exit_code = $null; output = $_.Exception.Message; retryable = $false; failure = Get-FlintFailureDetails $Session $_ }
    } finally {
        $Session.StopDeferred = $false
        $result = Complete-FlintToolResult $Session $Name $parsed $CallId $started $result
    }
    if ($Session.LogFailed) { throw 'Trajectory write failed after the tool. Stopping.' }
    return $result
}
