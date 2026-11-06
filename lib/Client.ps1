function New-FlintPayload {
    param([hashtable]$Session)
    # Stable instructions and tools precede the changing conversation for prompt caching.
    $payload = [ordered]@{
        model = $Session.Model; instructions = $Session.Instructions; tools = $Session.Tools
        reasoning = [ordered]@{ effort = $Session.Effort }
        include = @('reasoning.encrypted_content'); store = $false; stream = $false
        max_output_tokens = $Session.MaxOutputTokens
        input = @($Session.History)
    }
    $payload = Protect-FlintValue $Session $payload
    $json = ConvertTo-Json -InputObject $payload -Depth 64 -Compress
    if ($json.Length -gt $Session.MaxRequestChars) { throw 'Request character limit reached. Use /clear and provide a smaller diagnostic scope.' }
    # An estimate is not a tokenizer. The server-reported input usage remains authoritative.
    $estimate = [int]($json.Length / 3) + 1
    if ($null -ne $Session.LastInputTokens -and ($Session.LastInputTokens + $Session.LastOutputTokens) -gt $estimate) {
        $estimate = $Session.LastInputTokens + $Session.LastOutputTokens
    }
    $Session.EstimatedTokens = $estimate
    if ($Session.ContextWindow -gt 0 -and ($estimate + $Session.MaxOutputTokens) -gt $Session.ContextWindow) {
        throw 'Estimated context limit reached (including the output reserve). Use /clear and narrow the request.'
    }
    return $payload
}

function Invoke-FlintHttpRequest {
    param([hashtable]$Session, $Payload, [string]$ResponsePath, [int]$TimeoutSec = 0)
    if ($TimeoutSec -le 0) { $TimeoutSec = $Session.RequestTimeoutSec }
    $headers = @{ Authorization = 'Bearer ' + $Session.ApiKey; Accept = 'application/json' }
    $json = ConvertTo-Json -InputObject $Payload -Depth 64 -Compress
    # Decode the raw response as UTF-8 even when the service omits a charset.
    Invoke-RestMethod -Method Post -Uri $Session.ApiEndpoint `
        -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $json `
        -TimeoutSec $TimeoutSec -MaximumRedirection 0 -OutFile $ResponsePath -ErrorAction Stop
}

function Get-FlintHttpFailure {
    param([hashtable]$Session, $Record)
    $status = 0
    if ($Record.Exception.Response) { $status = [int]$Record.Exception.Response.StatusCode }
    $transport = [string]$Record.Exception.Status
    $retryable = $status -in @(429, 502, 503, 504) -or
        ($status -eq 0 -and $transport -in @('ConnectFailure', 'ConnectionClosed', 'SendFailure', 'ReceiveFailure'))
    $detail = $Record.Exception.Message
    if ($Record.ErrorDetails.Message) { $detail += ' ' + $Record.ErrorDetails.Message }
    return @{ http_status = $status; retryable = $retryable; message = Protect-FlintText $Session $detail }
}

function Invoke-AgentResponse {
    param([hashtable]$Session, $Payload)
    $responsePath = Join-Path $env:TEMP ('flint-response-' + [guid]::NewGuid().ToString('N') + '.json')
    $requestPath = $responsePath + '.request'
    $errorPath = $responsePath + '.error'
    $started = [datetime]::UtcNow
    $deadline = $started.AddSeconds($Session.RequestTimeoutSec)
    for ($attempt = 0; $attempt -le 3; $attempt++) {
        $failure = $null
        $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
        if ($remaining -le 0) { throw ('Model request timed out after ' + $Session.RequestTimeoutSec + ' seconds.') }
        # Retries count as HTTP attempts for usage reporting, within one agent-loop turn.
        if ($attempt -gt 0) { $Session.ModelCalls++ }
        Write-FlintEvent $Session 'model_request' @{ model_call = $Session.ModelCalls; attempt = $attempt + 1; payload = $Payload }
        try {
            Show-FlintActivity $Session 'Thinking'
            New-Item -ItemType File -Path $responsePath -ErrorAction Stop | Out-Null
            $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
            if ($remaining -le 0) { throw ('Model request timed out after ' + $Session.RequestTimeoutSec + ' seconds.') }
            # Invoke-RestMethod accepts whole seconds; the parent process enforces the finer deadline in live mode.
            $timeout = [int]($remaining - ($remaining % 1))
            if ($remaining % 1 -gt 0) { $timeout++ }
            if ($Session.Ui -and $Session.Ui.Live) {
                $request = @{
                    endpoint = $Session.ApiEndpoint; timeout_sec = $timeout; payload = $Payload
                    response_path = $responsePath; error_path = $errorPath
                }
                Set-Content -LiteralPath $requestPath -Value (ConvertTo-Json -InputObject $request -Depth 64 -Compress) -Encoding UTF8 -ErrorAction Stop
                foreach ($path in @($Session.ModelWorkerPath, $requestPath)) {
                    if ($path -match '["\r\n]') { throw 'Unsupported model worker path.' }
                }
                $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ('"' + $Session.ModelWorkerPath + '"'), '-RequestPath', ('"' + $requestPath + '"'))
                $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
                if ($remaining -le 0) { throw ('Model request timed out after ' + $Session.RequestTimeoutSec + ' seconds.') }
                $native = Invoke-FlintProcess -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                    -ArgumentList $arguments -TimeoutSec $remaining -WorkingDirectory $Session.Root -Session $Session -ModelApiKey $Session.ApiKey
                if ($native.status -eq 'timeout') { throw ('Model request timed out after ' + $Session.RequestTimeoutSec + ' seconds.') }
                if (Test-Path -LiteralPath $errorPath) {
                    if ((Get-Item -LiteralPath $errorPath).Length -gt 1048576) { throw 'Model error exceeds its size limit.' }
                    $failure = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $errorPath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
                    throw [string]$failure.message
                }
                if ($native.status -ne 'ok') { throw ('Model worker stopped: ' + $native.status + '. ' + $native.stderr) }
            } else {
                # Plain and redirected hosts do not need an animation process.
                Invoke-FlintHttpRequest $Session $Payload $responsePath -TimeoutSec $timeout
            }
            if ((Get-Item -LiteralPath $responsePath).Length -gt 8388608) { throw 'Model response exceeds 8 MiB.' }
            $response = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
            $safe = Protect-FlintValue $Session $response
            Write-FlintEvent $Session 'model_response' @{ model_call = $Session.ModelCalls; attempt = $attempt + 1; duration_ms = Get-FlintElapsedMs $started; response = $safe }
            return $safe
        } catch {
            if ($Session.LogFailed) { throw }
            if (-not $failure) { $failure = Get-FlintHttpFailure $Session $_ }
            Write-FlintEvent $Session 'model_error' @{
                model_call = $Session.ModelCalls; attempt = $attempt + 1; duration_ms = Get-FlintElapsedMs $started
                http_status = $failure.http_status; message = $failure.message
            } -BestEffort
        } finally {
            foreach ($path in @($responsePath, $requestPath, $errorPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        if ($failure.retryable -and $attempt -lt 3 -and -not $Session.LogFailed) {
            $delay = @(1, 2, 4)[$attempt]
            if (($deadline - [datetime]::UtcNow).TotalSeconds -gt $delay) {
                Write-FlintEvent $Session 'model_retry' @{ model_call = $Session.ModelCalls; attempt = $attempt + 2; delay_seconds = $delay; http_status = $failure.http_status }
                if (Wait-FlintRetry $Session $delay $deadline ('Retrying model ({0}/3) in {1}s' -f ($attempt + 1), $delay)) { continue }
            }
        }
        throw ('Azure OpenAI request failed (HTTP {0}): {1}' -f $failure.http_status, $failure.message)
    }
}
