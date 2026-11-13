function Get-FlintParallelCall {
    param([hashtable]$Session, $Call)
    # Eligibility comes from registered operations and reviewed rules, never from model-provided purpose text.
    try {
        $parsed = ConvertTo-FlintToolArguments $Call.name $Call.arguments
        if ((Protect-FlintText $Session $Call.arguments) -cne $Call.arguments) { return $null }
        $plan = @{ arguments = $parsed; invocation = $null; service = ''; event = ''; source = '' }
        if ($Call.name -cin @('read_file', 'list_files', 'search_text')) { return $plan }
        if ($Call.name -ceq 'run_command') {
            $plan.invocation = New-FlintCommandInvocation $Session $parsed
            foreach ($rule in @(Read-FlintPermissionRules $Session $plan.invocation.executor)) {
                if (Test-FlintCommandRule $rule $plan.invocation.arguments) {
                    $plan.event = 'command_permission'; $plan.source = 'fixed_read'
                    return $plan
                }
            }
        } elseif ($Call.name -cin @('azure_request', 'keyvault_list_secrets') -and $Session.Azure.Status -eq 'ready') {
            $plan.event = 'azure_permission'
            if ($Call.name -ceq 'keyvault_list_secrets') {
                $plan.invocation = New-FlintKeyVaultInvocation $Session $parsed
                $plan.service = 'keyvault'; $plan.source = 'keyvault_metadata'
                return $plan
            }
            $plan.invocation = New-FlintAzureInvocation $Session $parsed
            # Stateful polling retains its existing wait and continuation protocol.
            if ($plan.invocation.poll_kind) { return $null }
            $plan.source = Get-FlintAzureReadOnlyRule $plan.invocation.method $plan.invocation.uri $plan.invocation.body
            if ($plan.source) { $plan.service = 'arm'; return $plan }
        }
    } catch { }
    return $null
}

function Add-FlintToolOutput {
    param([hashtable]$Session, [string]$CallId, $Result, [hashtable]$Completed)
    if ($Completed.ContainsKey($CallId)) { return }
    # A cancellation can land between the history append and the completion marker.
    foreach ($item in $Session.History) {
        if ($item.type -eq 'function_call_output' -and $item.call_id -ceq $CallId) { $Completed[$CallId] = $true; return }
    }
    $Session.History += @{ type = 'function_call_output'; call_id = $CallId; output = (ConvertTo-Json -InputObject $Result -Depth 16 -Compress) }
    $Completed[$CallId] = $true
}

function Complete-FlintParallelCall {
    param([hashtable]$Session, [hashtable]$State, [hashtable]$Completed)
    if ($State.done) { return }
    $result = Complete-FlintToolResult $Session $State.call.name $State.parsed $State.call.call_id $State.started $State.result
    Add-FlintToolOutput $Session $State.call.call_id $result $Completed
    $State.done = $true; $State.access_token = $null
}

function Invoke-FlintParallelTools {
    param([hashtable]$Session, [object[]]$Calls, [hashtable]$Completed, [hashtable]$Progress)
    $states = @()
    $Session.StopDeferred = $false
    Write-FlintEvent $Session 'tool_batch_started' @{ call_ids = @($Calls | ForEach-Object { $_.call_id }); concurrency = $Calls.Count }
    try {
        # Authenticate in the main process before any concurrent worker is started.
        foreach ($call in $Calls) {
            if (Test-FlintStopKey $Session) { throw 'Stopped by the user.' }
            $state = @{ call = $call; parsed = $null; plan = $null; started = [datetime]::UtcNow; result = $null
                worker = $null; done = $false; attempt = 0; next_attempt = [datetime]::UtcNow; access_token = $null; budget = $Session.ToolTimeoutSec }
            $states += $state; $Progress.tool_count++
            Write-FlintEvent $Session 'tool_started' @{ call_id = $call.call_id; name = $call.name; arguments = $call.arguments }
            try {
                $state.plan = Get-FlintParallelCall $Session $call
                if (-not $state.plan) { throw 'This call is no longer classified for parallel read-only execution. Submit it again for normal authorization.' }
                $state.parsed = $state.plan.arguments
                if ($state.plan.event) {
                    Write-FlintEvent $Session $state.plan.event @{ call_id = $call.call_id; source = $state.plan.source; invocation = $state.plan.invocation }
                }
                if ($state.plan.service) {
                    Show-FlintActivity $Session 'Preparing Azure queries'
                    $authenticationStarted = [datetime]::UtcNow
                    Update-FlintAzureToken $Session -Service $state.plan.service
                    $state.budget -= (Get-FlintElapsedMs $authenticationStarted) / 1000
                    $state.access_token = $Session.Azure.AccessToken
                    if ($state.plan.service -eq 'keyvault') { $state.access_token = $Session.Azure.KeyVault.AccessToken }
                }
                if ($state.budget -le 0) { $state.result = @{ status = 'timeout'; exit_code = $null; retryable = $false; output = 'The time budget was consumed while obtaining authentication. No request was sent.' } }
            } catch {
                if ($Session.LogFailed) { throw }
                if ($state.plan.service) { $state.result = New-FlintAzureFailure $Session $_ $state.plan.service }
                else { $state.result = @{ status = 'error'; exit_code = $null; retryable = $false; output = $_.Exception.Message; failure = Get-FlintFailureDetails $Session $_ } }
            }
        }
        foreach ($state in $states) { $state.deadline = [datetime]::UtcNow.AddSeconds($state.budget) }
        while (@($states | Where-Object { -not $_.done }).Count -gt 0) {
            if ($Session.LogFailed) { throw 'Trajectory write failed. Stopping parallel tools.' }
            $remainingCalls = @($states | Where-Object { -not $_.done }).Count
            Show-FlintActivity $Session ('Parallel tools ({0}/{1} remaining)' -f $remainingCalls, $states.Count)
            Update-FlintProgress $Session
            if (Test-FlintStopKey $Session) { throw 'Stopped by the user.' }
            foreach ($state in $states) {
                if ($state.done) { continue }
                try {
                    if (-not $state.result -and $state.worker -and (Test-FlintProcess $state.worker.process)) {
                        try { $state.result = Complete-FlintWorker $state.worker } finally { $state.worker = $null }
                        if ($state.plan.service) { $state.result = Complete-FlintAzureResult $Session $state.result $state.plan.service }
                        if ($state.result.status -eq 'error' -and $state.result.retryable -and $state.attempt -lt 3) {
                            $delay = @(1, 2, 4)[$state.attempt]
                            if ($null -ne $state.result.retry_after_seconds -and $state.result.retry_after_seconds -gt $delay) { $delay = $state.result.retry_after_seconds }
                            if (($state.deadline - [datetime]::UtcNow).TotalSeconds -gt $delay) {
                                $state.attempt++
                                Write-FlintEvent $Session 'tool_retry' @{ call_id = $state.call.call_id; attempt = $state.attempt + 1; delay_seconds = $delay; result = $state.result }
                                $state.result = $null; $state.next_attempt = [datetime]::UtcNow.AddSeconds($delay)
                            }
                        }
                    }
                    if (-not $state.result -and -not $state.worker -and [datetime]::UtcNow -ge $state.next_attempt) {
                        $remaining = ($state.deadline - [datetime]::UtcNow).TotalSeconds
                        if ($remaining -le 0) { $state.result = @{ status = 'timeout'; exit_code = $null; retryable = $false; output = 'Tool time budget exhausted.' } }
                        elseif ($state.plan.service -and ($Session.Azure.Status -ne 'ready' -or ($state.plan.service -eq 'keyvault' -and $Session.Azure.KeyVault.Status -eq 'authentication_required'))) {
                            $state.result = @{ status = 'authentication_required'; exit_code = $null; retryable = $false; output = 'Azure authentication is unavailable. Restart Flint to sign in.' }
                        } else {
                            $state.worker = Start-FlintWorker $Session $state.call.name $state.parsed -TimeoutSec $remaining -CommandInvocation $state.plan.invocation -AzureAccessToken $state.access_token
                        }
                    }
                } catch {
                    if ($Session.LogFailed) { throw }
                    $state.result = @{ status = 'error'; exit_code = $null; retryable = $false; output = $_.Exception.Message; failure = Get-FlintFailureDetails $Session $_ }
                    if ($state.worker) {
                        $state.worker.process.status = 'error'
                        try { $null = Complete-FlintWorker $state.worker } finally { $state.worker = $null }
                    }
                }
                if ($state.result) { Complete-FlintParallelCall $Session $state $Completed }
                if ($Session.LogFailed) { throw 'Trajectory write failed. Stopping parallel tools.' }
            }
            if (@($states | Where-Object { -not $_.done }).Count -gt 0) { Start-Sleep -Milliseconds 100 }
        }
    } finally {
        $stopStatus = 'cancelled'
        if ($Session.StopRequested) { $stopStatus = 'stopped' }
        # Stop every live process tree before finalizing any capture or conversation item.
        foreach ($state in $states) {
            if ($state.worker) {
                if ($state.worker.process.process.HasExited) { $null = Test-FlintProcess $state.worker.process }
                else {
                    if ($state.worker.process.status -eq 'ok') { $state.worker.process.status = $stopStatus }
                    Stop-FlintProcess $state.worker.process
                }
            }
        }
        foreach ($state in $states) {
            if ($state.done) { continue }
            if ($state.worker) {
                try {
                    $state.result = Complete-FlintWorker $state.worker
                    if ($state.plan.service) { $state.result = Complete-FlintAzureResult $Session $state.result $state.plan.service }
                } catch { $state.result = @{ status = 'error'; exit_code = $null; retryable = $false; output = $_.Exception.Message; failure = Get-FlintFailureDetails $Session $_ } }
                finally { $state.worker = $null }
            }
            if (-not $state.result) { $state.result = @{ status = $stopStatus; exit_code = $null; retryable = $false; output = 'Read-only tool stopped before a confirmed result was available.' } }
            Complete-FlintParallelCall $Session $state $Completed
        }
        $Session.StopDeferred = $false
        Write-FlintEvent $Session 'tool_batch_finished' @{ call_ids = @($states | ForEach-Object { $_.call.call_id }); started = $states.Count } -BestEffort
    }
}
