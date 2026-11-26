function Complete-FlintToolResult {
    param([hashtable]$Session, [string]$Name, $Parsed, [string]$CallId, [datetime]$Started, $Result)
    if (-not $Result) { $Result = @{ status = 'cancelled'; exit_code = $null; output = 'Tool interrupted; verify actual state before repeating any write.'; retryable = $false } }
    # Timing goes to the trajectory record; the model sees only the total duration.
    $timing = [ordered]@{ total_ms = Get-FlintElapsedMs $Started }
    if ($Result.timing -is [System.Collections.IDictionary]) { foreach ($part in @($Result.timing.Keys)) { $timing[$part] = $Result.timing[$part] } }
    # Variable names are case-insensitive: these loops must not reuse $Name.
    if ($Result -is [System.Collections.IDictionary]) { $keys = @($Result.Keys) }
    else { $keys = @($Result.PSObject.Properties | ForEach-Object { $_.Name }) }
    $fields = [ordered]@{}
    foreach ($key in $keys) { if ($key -cne 'timing') { $fields[$key] = $Result.$key } }
    $result = Protect-FlintValue $Session $fields
    $result.duration_ms = $timing.total_ms
    Write-FlintEvent $Session 'tool_finished' @{ call_id = $CallId; name = $Name; result = $result } -Timing $timing -BestEffort
    if ($result.output.Length -gt 32768) { $result.output = $result.output.Substring(0, 32768) + "`n[truncated at 32768 characters]"; $result.truncated = $true }
    Show-FlintToolResult $Session $Name $Parsed $result
    return $result
}

function Invoke-FlintCommandSignIn {
    param([hashtable]$Session, $Invocation, [datetime]$CallStarted, [string]$CallId)
    # Returns the outcome: signed_in, exited (the sign-in ended with an error exit code), declined, cancelled or failed.
    # A sign-in that exited with an error may still have signed in, for example when only the cluster is unreachable.
    $signIn = @(); $key = $null; $failure = $null
    try {
        $signIn = @(Get-FlintSignInArguments @($Invocation.arguments))
        $key = ($signIn | Select-Object -Skip 1) -join ' '
    } catch { $failure = 'Flint could not tell which kubeconfig credentials the command uses: ' + $_.Exception.Message }
    if ($null -ne $key) {
        # Parallel calls hit the same prompt; one answer covers every call that started before it.
        # Context and user names are case-sensitive, so keys are compared with -ceq rather than a hashtable lookup.
        $previous = @($Session.CommandSignIns | Where-Object { $_.key -ceq $key }) | Select-Object -Last 1
        if ($previous -and $previous.completed -gt $CallStarted) { return $previous.outcome }
    }
    # After the user pressed s, for example during an earlier sign-in, offer no further sign-in.
    if ($Session.StopRequested -or (Test-FlintStopKey $Session)) { return @{ outcome = 'cancelled' } }
    $outcome = @{ outcome = 'failed'; exit_code = $null; failure = $failure }
    $approved = $false; $started = [datetime]::UtcNow
    if (-not $failure) {
        $answer = Read-FlintSignInApproval $Session $signIn
        $approved = $null -ne $answer -and $answer.Trim() -ceq 'y'
        $outcome.outcome = 'declined'
        if ($approved) {
            Write-Host 'Follow the sign-in instructions below. Press s to cancel.' -ForegroundColor Yellow
            $outputPath = Join-Path $env:TEMP ('flint-sign-in-' + [guid]::NewGuid().ToString('N') + '.txt')
            $arguments = @(foreach ($value in $signIn) { ConvertTo-FlintNativeArgument $value })
            # No window and no stderr redirection: the plugin prints its sign-in instructions in this terminal.
            $state = @{ process = $null }
            try {
                # kubectl and its credential plugin must not inherit Flint's own credentials.
                $savedEnvironment = @{}
                Hide-FlintAzureSecretEnvironment $savedEnvironment
                try {
                    $state.process = Start-Process -FilePath $Invocation.program.path -ArgumentList $arguments -WorkingDirectory $Session.Root `
                        -NoNewWindow -PassThru -RedirectStandardOutput $outputPath -ErrorAction Stop
                } finally { Restore-FlintAzureEnvironment $savedEnvironment }
                $null = $state.process.Handle
                # Device codes expire after about 15 minutes.
                $deadline = [datetime]::UtcNow.AddMinutes(15)
                while (-not $state.process.HasExited -and [datetime]::UtcNow -lt $deadline) {
                    if (Test-FlintStopKey $Session) { break }
                    Start-Sleep -Milliseconds 200
                }
                $outcome.outcome = 'cancelled'
                if ($state.process.HasExited) {
                    $outcome.exit_code = $state.process.ExitCode
                    $outcome.outcome = 'exited'
                    if ($outcome.exit_code -eq 0) { $outcome.outcome = 'signed_in' }
                }
            } catch {
                # A failed launch ends this call only; it must not abort the other calls in a batch.
                $outcome.outcome = 'failed'; $outcome.failure = 'Flint could not start the sign-in: ' + $_.Exception.Message
            } finally {
                Stop-FlintProcess $state
                Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
            }
            if ($outcome.outcome -eq 'signed_in') { Write-Host 'Signed in.' -ForegroundColor Green }
            elseif ($outcome.outcome -eq 'exited') { Write-Host ('The sign-in command exited with code ' + $outcome.exit_code + '.') -ForegroundColor Yellow }
            else { Write-Host 'Sign-in did not complete.' -ForegroundColor Yellow }
        }
        $Session.CommandSignIns = @(@($Session.CommandSignIns | Where-Object { $_.key -cne $key }) + @{ key = $key; completed = [datetime]::UtcNow; outcome = $outcome })
    }
    Write-FlintEvent $Session 'command_sign_in' @{
        call_id = $CallId; arguments = $signIn; approved = $approved; outcome = $outcome.outcome; exit_code = $outcome.exit_code
        failure = $outcome.failure; duration_ms = Get-FlintElapsedMs $started
    }
    return $outcome
}

function Resolve-FlintCommandSignIn {
    param([hashtable]$Session, $Invocation, [bool]$ReadOnly, [datetime]$CallStarted, [string]$CallId, $Result)
    # Returns whether to run the call again; otherwise explains the outcome to the model in the result.
    $signIn = Invoke-FlintCommandSignIn $Session $Invocation $CallStarted $CallId
    $prefix = 'kubectl stopped at an interactive sign-in prompt from its kubeconfig credential plugin. '
    # A read runs again whenever the sign-in ran to the end: the rerun shows whether it worked.
    if ($ReadOnly -and $signIn.outcome -in @('signed_in', 'exited')) { return $true }
    switch ($signIn.outcome) {
        'signed_in' { $Result.output = $prefix + 'The user has now signed in. The change was most likely not sent: read the actual state, then submit the same command again if it is still needed.' }
        'exited' { $Result.output = $prefix + 'The sign-in command exited with code ' + $signIn.exit_code + ', so sign-in may not have completed, or the cluster may be unreachable. The change was not run again: ask the user to check, then read the actual state.' }
        'cancelled' { $Result.output = $prefix + 'The user cancelled the sign-in.' }
        'failed' { $Result.output = $prefix + $signIn.failure + ' Ask the user to sign in, for example by running the kubectl command once in a terminal, then retry.' }
        default { $Result.output = $prefix + 'The user did not sign in. This is not a network or cluster failure. Ask the user to sign in, for example by running the kubectl command once in a terminal, then retry.' }
    }
    return $false
}

function Get-FlintRepeatedSignInOutput {
    return 'kubectl stopped at a sign-in prompt again after the sign-in attempt, so the sign-in did not take effect. Ask the user to sign in by running the kubectl command once in a terminal, then retry.'
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
        $signInHandled = $false
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
            if ($Name -ceq 'run_command' -and $result.status -eq 'sign_in_required') {
                if ($signInHandled) { $result.output = Get-FlintRepeatedSignInOutput; break }
                $signInHandled = $true
                if (-not (Resolve-FlintCommandSignIn $Session $invocation ([bool]$permission.read_only) $started $CallId $result)) { break }
                # Signing in waited for the user, so the read starts over with a fresh time budget and its retries.
                $deadline = ([datetime]::UtcNow).AddSeconds($Session.ToolTimeoutSec)
                $attempt = -1
                continue
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
