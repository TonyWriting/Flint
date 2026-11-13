function Wait-FlintRetry {
    param([hashtable]$Session, [int]$Seconds, [datetime]$Deadline, [string]$Stage)
    if (($Deadline - [datetime]::UtcNow).TotalSeconds -le $Seconds) { return $false }
    Show-FlintActivity $Session $Stage
    $until = [datetime]::UtcNow.AddSeconds($Seconds)
    while ([datetime]::UtcNow -lt $until) {
        Update-FlintProgress $Session
        if (Test-FlintStopKey $Session) { return $false }
        Start-Sleep -Milliseconds 100
    }
    return [datetime]::UtcNow -lt $Deadline
}

function Start-FlintProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [double]$TimeoutSec, [string]$WorkingDirectory, [hashtable]$Session, [string]$ModelApiKey, [string]$AzureAccessToken)
    $scratch = Join-Path $env:TEMP ('flint-process-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -ErrorAction Stop | Out-Null
    $stdoutPath = Join-Path $scratch 'stdout.txt'
    $stderrPath = Join-Path $scratch 'stderr.txt'
    $state = @{ process = $null; scratch = $scratch; stdout_path = $stdoutPath; stderr_path = $stderrPath
        started = [datetime]::UtcNow; timeout_sec = $TimeoutSec; status = 'ok'; exit_code = $null; result = $null }
    $ready = $false
    try {
        $passModelKey = 'ModelApiKey' -in $PSBoundParameters.Keys
        $previousModelKey = $env:FLINT_MODEL_API_KEY
        $previousAzureToken = $env:FLINT_AZURE_ACCESS_TOKEN
        try {
            # Only the authentication worker inherits this key; never put it in files or arguments.
            if ($passModelKey) { $env:FLINT_MODEL_API_KEY = $ModelApiKey }
            if ('AzureAccessToken' -in $PSBoundParameters.Keys) { $env:FLINT_AZURE_ACCESS_TOKEN = $AzureAccessToken }
            else { Remove-Item -LiteralPath Env:FLINT_AZURE_ACCESS_TOKEN -ErrorAction SilentlyContinue }
            $state.process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory `
                -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        } finally {
            if ($passModelKey) { $env:FLINT_MODEL_API_KEY = $previousModelKey }
            $env:FLINT_AZURE_ACCESS_TOKEN = $previousAzureToken
        }
        # Accessing Handle keeps ExitCode available after a short-lived child exits.
        $null = $state.process.Handle
        $ready = $true
        return $state
    } finally {
        if (-not $ready) { $state.status = 'cancelled'; $null = Complete-FlintProcess $state }
    }
}

function Test-FlintProcess {
    param([hashtable]$State, [hashtable]$Session)
    if ($State.result -or $State.status -ne 'ok') { return $true }
    if ($State.process.HasExited) {
        $State.exit_code = $State.process.ExitCode
        if ($State.exit_code -ne 0) { $State.status = 'error' }
        return $true
    }
    if ($Session) {
        Update-FlintProgress $Session
        if ((Test-FlintStopKey $Session) -and -not $Session.StopDeferred) { $State.status = 'stopped'; return $true }
    }
    if ((Get-FlintElapsedMs $State.started) -ge ($State.timeout_sec * 1000)) { $State.status = 'timeout'; return $true }
    $bytes = 0L
    foreach ($capture in @($State.stdout_path, $State.stderr_path)) {
        if (Test-Path -LiteralPath $capture) { $bytes += (Get-Item -LiteralPath $capture).Length }
    }
    if ($bytes -gt 1048576) { $State.status = 'output_limit'; return $true }
    return $false
}

function Stop-FlintProcess {
    param([hashtable]$State)
    if ($State.process -and -not $State.process.HasExited) {
        # Only the process created above and its descendants are targeted.
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID ([string]$State.process.Id) /T /F 2>&1 | Out-Null
            Stop-Process -Id $State.process.Id -Force -ErrorAction SilentlyContinue
        } finally { $ErrorActionPreference = $savedErrorPreference }
    }
}

function Complete-FlintProcess {
    param([hashtable]$State)
    if ($State.result) { return $State.result }
    $status = $State.status
    try { Stop-FlintProcess $State } finally {
        $stdout = ''; $stderr = ''
        foreach ($capture in @($State.stdout_path, $State.stderr_path)) {
            if (Test-Path -LiteralPath $capture) {
                # Start-Process can finish before its asynchronous stream writers close.
                # A successful rename confirms the capture is no longer locked for writing.
                $closedPath = $capture + '.complete'
                $closed = $false
                for ($attempt = 0; $attempt -lt 20; $attempt++) {
                    try {
                        Move-Item -LiteralPath $capture -Destination $closedPath -ErrorAction Stop
                        $closed = $true
                        break
                    } catch { Start-Sleep -Milliseconds 50 }
                }
                if (-not $closed) { $content = '[process output could not be finalized]'; $status = 'capture_error' }
                elseif ((Get-Item -LiteralPath $closedPath).Length -le 1048576) {
                    $content = [string](Get-Content -LiteralPath $closedPath -Raw -Encoding UTF8 -ErrorAction Stop)
                    if ($null -eq $content) { $content = '' }
                } else { $content = '[output exceeded 1 MiB]'; $status = 'output_limit' }
                if ($capture -eq $State.stdout_path) { $stdout = $content } else { $stderr = $content }
                Remove-Item -LiteralPath $closedPath -Force -ErrorAction SilentlyContinue
            }
        }
        # Never ask for recursive deletion when a capture is still held by Windows.
        if (-not (Get-ChildItem -LiteralPath $State.scratch -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Remove-Item -LiteralPath $State.scratch -Force -ErrorAction SilentlyContinue
        }
    }
    $State.result = @{ status = $status; exit_code = $State.exit_code; stdout = $stdout; stderr = $stderr; duration_ms = Get-FlintElapsedMs $State.started }
    return $State.result
}

function Invoke-FlintProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [double]$TimeoutSec, [string]$WorkingDirectory, [hashtable]$Session, [string]$ModelApiKey, [string]$AzureAccessToken)
    $state = $null; $result = $null
    try {
        $state = Start-FlintProcess @PSBoundParameters
        while (-not (Test-FlintProcess $state $Session)) { Start-Sleep -Milliseconds 100 }
    } finally {
        if ($state) { $result = Complete-FlintProcess $state }
    }
    return $result
}
