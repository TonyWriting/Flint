function Complete-FlintToolResult {
    param([hashtable]$Session, [string]$Name, $Parsed, [string]$CallId, [datetime]$Started, $Result)
    if (-not $Result) { $Result = @{ status = 'cancelled'; exit_code = $null; output = 'Tool interrupted; verify actual state before repeating any write.'; retryable = $false } }
    $result = Protect-FlintValue $Session $Result
    if ($Name -ceq 'run_command') { $result.falcon_guide_path = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\Falcon.md' }
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
        if ((Protect-FlintText $Session $Arguments) -cne $Arguments) {
            throw 'Tool arguments contain credential patterns or terminal control characters. Remove them before continuing.'
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

function New-FlintWorkerRequest {
    param([hashtable]$Session, [string]$Name, $ToolArguments, [double]$TimeoutSec = 0, $CommandInvocation, [string]$WriteDirectory, [string]$AzureAccessToken)
    if ($TimeoutSec -le 0) { $TimeoutSec = $Session.ToolTimeoutSec }
    $requestPath = Join-Path $env:TEMP ('flint-tool-' + [guid]::NewGuid().ToString('N') + '.json')
    $resultPath = $requestPath + '.result'
    $ready = $false
    try {
        $request = @{
            root = $Session.Root; session_id = $Session.Id; name = $Name; arguments = $ToolArguments; protected_paths = $Session.ProtectedPaths
            timeout_sec = $TimeoutSec; result_path = $resultPath
            command_invocation = $CommandInvocation
            write_directory = $WriteDirectory
        }
        Set-Content -LiteralPath $requestPath -Value (ConvertTo-Json -InputObject $request -Depth 32 -Compress) -Encoding UTF8 -ErrorAction Stop
        # All command-line values are harness-owned paths, never model-generated commands.
        foreach ($path in @($Session.WorkerPath, $requestPath)) {
            if ($path -match '["\r\n]') { throw 'Unsupported worker path.' }
        }
        $workerArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ('"' + $Session.WorkerPath + '"'), '-RequestPath', ('"' + $requestPath + '"'))
        $authentication = @{}
        if ($Name -cin @('azure_request', 'keyvault_list_secrets')) { $authentication.AzureAccessToken = $AzureAccessToken }
        $nativeArguments = @{
            FilePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            ArgumentList = $workerArguments; TimeoutSec = $TimeoutSec; WorkingDirectory = $Session.Root; Session = $Session
        }
        foreach ($parameterName in $authentication.Keys) { $nativeArguments[$parameterName] = $authentication[$parameterName] }
        $ready = $true
        return @{ request_path = $requestPath; result_path = $resultPath; native_arguments = $nativeArguments; process = $null; name = $Name }
    } finally {
        if (-not $ready) { foreach ($path in @($requestPath, $resultPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
    }
}

function Remove-FlintWorkerRequest {
    param([hashtable]$Worker)
    foreach ($path in @($Worker.request_path, $Worker.result_path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    $Worker.native_arguments = $null
}

function Read-FlintWorkerResult {
    param([hashtable]$Worker, $Native)
    if ($Native.status -eq 'stopped') {
        return @{ status = 'stopped'; exit_code = $null; output = 'Stopped by the user before the tool finished. No result is available.'; retryable = $false; duration_ms = $Native.duration_ms }
    }
    if ($Native.status -ne 'ok') {
        $detail = 'Tool worker stopped: ' + $Native.status + '. ' + $Native.stderr
        if ($Worker.name -in @('write_file', 'edit_file', 'create_directory', 'run_command', 'azure_request')) { $detail += ' The action outcome may be unknown. Query the actual state before proposing another write.' }
        return @{ status = $Native.status; exit_code = $Native.exit_code; output = $detail; retryable = $false; duration_ms = $Native.duration_ms }
    }
    if (-not (Test-Path -LiteralPath $Worker.result_path)) { throw 'Tool worker did not return a result.' }
    if ((Get-Item -LiteralPath $Worker.result_path).Length -gt 524288) { throw 'Tool result exceeded its size limit.' }
    $result = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Worker.result_path -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
    $result | Add-Member -NotePropertyName duration_ms -NotePropertyValue $Native.duration_ms -Force
    return $result
}

function Invoke-FlintWorker {
    param([hashtable]$Session, [string]$Name, $ToolArguments, [double]$TimeoutSec = 0, $CommandInvocation, [string]$WriteDirectory, [string]$AzureAccessToken)
    $worker = $null
    try {
        $worker = New-FlintWorkerRequest @PSBoundParameters
        $nativeArguments = $worker.native_arguments
        $native = Invoke-FlintProcess @nativeArguments
        return Read-FlintWorkerResult $worker $native
    } finally { if ($worker) { Remove-FlintWorkerRequest $worker } }
}

function Start-FlintWorker {
    param([hashtable]$Session, [string]$Name, $ToolArguments, [double]$TimeoutSec, $CommandInvocation, [string]$AzureAccessToken)
    $worker = $null; $ready = $false
    try {
        $worker = New-FlintWorkerRequest @PSBoundParameters
        $nativeArguments = $worker.native_arguments
        $worker.process = Start-FlintProcess @nativeArguments
        $ready = $true
        return $worker
    } finally { if ($worker -and -not $ready) { Remove-FlintWorkerRequest $worker } }
}

function Complete-FlintWorker {
    param([hashtable]$Worker)
    try { return Read-FlintWorkerResult $Worker (Complete-FlintProcess $Worker.process) }
    finally { Remove-FlintWorkerRequest $Worker }
}
