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
    param([hashtable]$Session, $Invocation)
    # Runs the original read in the foreground: kubectl chooses the credentials as usual, and its credential plugin
    # prints the sign-in instructions in this terminal. Its output is discarded; the caller runs the read again.
    Write-Host 'Follow the sign-in instructions below. Press s to cancel.' -ForegroundColor Yellow
    $arguments = @(foreach ($value in $Invocation.arguments) { ConvertTo-FlintNativeArgument $value })
    $state = @{ process = $null }
    try {
        # kubectl and its credential plugin must not inherit Flint's own credentials.
        $savedEnvironment = @{}
        Hide-FlintAzureSecretEnvironment $savedEnvironment
        try {
            $state.process = Start-Process -FilePath $Invocation.program.path -ArgumentList $arguments -WorkingDirectory $Session.Root `
                -NoNewWindow -PassThru -RedirectStandardOutput 'NUL' -ErrorAction Stop
        } finally { Restore-FlintAzureEnvironment $savedEnvironment }
        $null = $state.process.Handle
        # Device codes expire after about 15 minutes.
        $deadline = [datetime]::UtcNow.AddMinutes(15)
        while (-not $state.process.HasExited -and [datetime]::UtcNow -lt $deadline -and -not (Test-FlintStopKey $Session)) {
            Start-Sleep -Milliseconds 200
        }
        if (-not $state.process.HasExited) { return @{ finished = $false; exit_code = $null } }
        return @{ finished = $true; exit_code = $state.process.ExitCode }
    } finally { Stop-FlintProcess $state }
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
        } elseif ($Name -ceq 'azure_request') {
            if ($Session.Azure.Status -ne 'ready') {
                $result = @{ status = $Session.Azure.Status; exit_code = $null; output = $Session.Azure.Message; retryable = $false }
                $permission = @{ allowed = $false; read_only = $false }
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
        $signInTried = $false
        for ($attempt = 0; $permission.allowed -and $attempt -le 3; $attempt++) {
            $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
            if ($remaining -le 0) {
                $result = @{ status = 'timeout'; exit_code = $null; output = 'Tool time budget exhausted.'; retryable = $false }
                break
            }
            Show-FlintActivity $Session (Get-FlintToolLabel $Name $parsed)
            if ($Name -ceq 'azure_request') {
                $result = Invoke-FlintAzureRequest $Session $parsed $invocation -TimeoutSec $remaining
            } else {
                $result = Invoke-FlintWorker $Session $Name $parsed -TimeoutSec $remaining -CommandInvocation $invocation -WriteDirectory $permission.directory
            }
            if ($Name -ceq 'run_command' -and $result.status -eq 'sign_in_required') {
                $prefix = 'kubectl stopped at an interactive sign-in prompt from its kubeconfig credential plugin. '
                if ($signInTried) { $result.output = $prefix + 'It asked again after the sign-in attempt, so the sign-in did not take effect. Ask the user to sign in by running the kubectl command in a terminal, then retry.'; break }
                $signInTried = $true
                # Running a change again to sign in would change twice; a read of the actual state offers the sign-in.
                if (-not $permission.read_only) { $result.output = $prefix + 'The change was most likely not sent. Read the actual state first: Flint offers the user the sign-in on that read. Then submit the change again if it is still needed.'; break }
                $answer = Read-FlintSignInApproval $Session @($invocation.arguments)
                $signIn = @{ finished = $false; exit_code = $null }
                if ($null -ne $answer -and $answer.Trim() -ceq 'y') { $signIn = Invoke-FlintCommandSignIn $Session $invocation }
                Write-FlintEvent $Session 'command_sign_in' @{ call_id = $CallId; answer = [string]$answer; finished = $signIn.finished; exit_code = $signIn.exit_code }
                if (-not $signIn.finished) { $result.output = $prefix + 'The user did not complete the sign-in. This is not a network or cluster failure. Ask the user to sign in, for example by running the kubectl command once in a terminal, then retry.'; break }
                # The read runs again even after an error exit, which can still follow a sign-in: its result shows the real state.
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
