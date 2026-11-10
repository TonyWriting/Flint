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

function Invoke-FlintProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [double]$TimeoutSec, [string]$WorkingDirectory, [hashtable]$Session, [string]$ModelApiKey, [string]$AzureAccessToken)
    $scratch = Join-Path $env:TEMP ('flint-process-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -ErrorAction Stop | Out-Null
    $stdoutPath = Join-Path $scratch 'stdout.txt'
    $stderrPath = Join-Path $scratch 'stderr.txt'
    $process = $null
    $started = [datetime]::UtcNow
    $status = 'ok'
    $exitCode = $null
    try {
        $passModelKey = 'ModelApiKey' -in $PSBoundParameters.Keys
        $previousModelKey = $env:FLINT_MODEL_API_KEY
        $previousAzureToken = $env:FLINT_AZURE_ACCESS_TOKEN
        try {
            # Only the authentication worker inherits this key; never put it in files or arguments.
            if ($passModelKey) { $env:FLINT_MODEL_API_KEY = $ModelApiKey }
            if ('AzureAccessToken' -in $PSBoundParameters.Keys) { $env:FLINT_AZURE_ACCESS_TOKEN = $AzureAccessToken }
            else { Remove-Item -LiteralPath Env:FLINT_AZURE_ACCESS_TOKEN -ErrorAction SilentlyContinue }
            $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory `
                -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        } finally {
            if ($passModelKey) { $env:FLINT_MODEL_API_KEY = $previousModelKey }
            $env:FLINT_AZURE_ACCESS_TOKEN = $previousAzureToken
        }
        # Accessing Handle keeps ExitCode available after a short-lived child exits.
        $null = $process.Handle
        while (-not $process.HasExited) {
            if ($Session) {
                Update-FlintProgress $Session
                # A deferred stop lets an in-flight change finish so its result is not lost.
                if ((Test-FlintStopKey $Session) -and -not $Session.StopDeferred) { $status = 'stopped'; break }
            }
            if ((Get-FlintElapsedMs $started) -ge ($TimeoutSec * 1000)) { $status = 'timeout'; break }
            $bytes = 0L
            foreach ($capture in @($stdoutPath, $stderrPath)) {
                if (Test-Path -LiteralPath $capture) { $bytes += (Get-Item -LiteralPath $capture).Length }
            }
            if ($bytes -gt 1048576) { $status = 'output_limit'; break }
            Start-Sleep -Milliseconds 100
        }
        if ($status -eq 'ok') { $exitCode = $process.ExitCode; if ($exitCode -ne 0) { $status = 'error' } }
    } finally {
        if ($process -and -not $process.HasExited) {
            # Only the process created above and its descendants are targeted.
            $savedErrorPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID ([string]$process.Id) /T /F 2>&1 | Out-Null
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            } finally { $ErrorActionPreference = $savedErrorPreference }
        }
        $stdout = ''; $stderr = ''
        foreach ($capture in @($stdoutPath, $stderrPath)) {
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
                if ($capture -eq $stdoutPath) { $stdout = $content } else { $stderr = $content }
                Remove-Item -LiteralPath $closedPath -Force -ErrorAction SilentlyContinue
            }
        }
        # Never ask for recursive deletion when a capture is still held by Windows.
        if (-not (Get-ChildItem -LiteralPath $scratch -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue
        }
    }
    return @{ status = $status; exit_code = $exitCode; stdout = $stdout; stderr = $stderr; duration_ms = Get-FlintElapsedMs $started }
}
