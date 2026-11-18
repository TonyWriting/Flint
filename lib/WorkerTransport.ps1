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
            # The worker re-checks command shape against the guarded resources loaded for this session.
            guarded_patch_resources = @($Session.GuardedPatchResources)
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
