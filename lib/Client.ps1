function New-FlintPayloadBody {
    param([hashtable]$Session)
    # Stable instructions and tools precede the changing conversation for prompt caching.
    $payload = [ordered]@{
        model = $Session.Model; instructions = $Session.Instructions; tools = $Session.Tools
        reasoning = [ordered]@{ effort = $Session.Effort }
        include = @('reasoning.encrypted_content'); store = $false; stream = $false
        max_output_tokens = $Session.MaxOutputTokens
        parallel_tool_calls = $true
        input = @(Get-FlintModelInput $Session)
    }
    # History items and instructions are redacted when they enter the session, so a request does not redact them
    # again. Every request is still checked for Flint's own credentials; finding one redacts the whole request.
    if (Test-FlintSecretInJson $Session (ConvertTo-Json -InputObject $payload -Depth 64 -Compress)) { return Protect-FlintValue $Session $payload }
    return $payload
}

function Join-FlintMessageParts {
    param($Item)
    # Redaction works on one string at a time, so a credential split across the text parts of one message would leave
    # the part without its start. A message made only of text parts becomes one part, joined as Flint displays it.
    if ($Item.type -cne 'message' -or @($Item.content).Count -lt 2) { return $Item }
    $texts = @($Item.content | Where-Object { $_.type -ceq 'output_text' })
    if ($texts.Count -ne @($Item.content).Count) { return $Item }
    $merged = [ordered]@{}
    foreach ($property in @($Item.PSObject.Properties)) { $merged[$property.Name] = $property.Value }
    $merged.content = @([ordered]@{ type = 'output_text'; text = (@($texts | ForEach-Object { [string]$_.text }) -join [Environment]::NewLine); annotations = @() })
    return $merged
}

function New-FlintPayload {
    param([hashtable]$Session)
    # Log new conversation items before a compaction or request event refers to them.
    Save-FlintHistory $Session
    $payload = New-FlintPayloadBody $Session
    $json = ConvertTo-Json -InputObject $payload -Depth 64 -Compress
    # The context window holds the request and the answer, so MaxOutputTokens stays free for the answer.
    $budget = $Session.ContextWindow - $Session.MaxOutputTokens
    $estimate = Get-FlintTokenEstimate $Session $json.Length
    $omitted = @()
    if ($estimate -gt [long]($budget * 0.6)) {
        # Omit outputs the model has read until the request is about 30% of the budget, in characters at the same rate.
        $omitted = @(Compress-FlintContext $Session $json.Length ([long]($json.Length * $budget * 0.3 / $estimate)))
    }
    if ($omitted.Count -gt 0) {
        $before = $json.Length; $beforeTokens = $estimate
        $payload = New-FlintPayloadBody $Session
        $json = ConvertTo-Json -InputObject $payload -Depth 64 -Compress
        $estimate = Get-FlintTokenEstimate $Session $json.Length
        Write-FlintEvent $Session 'context_compacted' @{
            call_ids = $omitted; request_chars_before = $before; request_chars_after = $json.Length
            estimated_tokens_before = $beforeTokens; estimated_tokens_after = $estimate
        }
        Show-FlintContextTrimmed $Session $omitted.Count $beforeTokens $estimate
    }
    $Session.RequestChars = $json.Length; $Session.EstimatedTokens = $estimate
    if ($estimate -gt $budget) {
        throw ('Context window reached: this request needs about {0:N0} input tokens, and the context window of {1:N0} tokens leaves {2:N0} after reserving {3:N0} for the answer. Start a new Flint session with a narrower request.' -f $estimate, $Session.ContextWindow, $budget, $Session.MaxOutputTokens)
    }
    # Trimming could not make enough room; tell the user once so they can wrap up this task.
    if (-not $Session.ContextWarned -and $estimate -gt [long]($budget * 0.8)) {
        $Session.ContextWarned = $true
        Write-FlintEvent $Session 'context_near_limit' @{ estimated_tokens = $estimate; input_budget = $budget; context_window = $Session.ContextWindow }
        Show-FlintContextNearLimit $Session $estimate $budget
    }
    return $payload
}

function Get-FlintTokenEstimate {
    param([hashtable]$Session, [long]$Chars)
    # The service reports the exact input tokens of every request, so the next request is that count plus what changed.
    # Added characters count as one token per two: more than JSON and English take, and about what Chinese takes.
    # Omitted characters count as one token per four, so trimming never makes the estimate fall short.
    if ($Session.LastInputTokens -gt 0 -and $Session.LastRequestChars -gt 0) {
        $change = $Chars - $Session.LastRequestChars
        if ($change -ge 0) { return [long]$Session.LastInputTokens + [long]($change / 2) + 1 }
        $estimate = [long]$Session.LastInputTokens + [long]($change / 4) + 1
        if ($estimate -lt 1) { return 1 }
        return $estimate
    }
    return [long]($Chars / 2) + 1
}

function Invoke-FlintHttpRequest {
    param([hashtable]$Session, $Payload, [string]$ResponsePath, [int]$TimeoutSec = 0)
    if ($TimeoutSec -le 0) { $TimeoutSec = $Session.RequestTimeoutSec }
    $headers = @{ Authorization = 'Bearer ' + $Session.ApiKey; Accept = 'application/json' }
    $serializeStarted = [datetime]::UtcNow
    $json = ConvertTo-Json -InputObject $Payload -Depth 64 -Compress
    $sendStarted = [datetime]::UtcNow
    # Decode the raw response as UTF-8 even when the service omits a charset.
    Invoke-RestMethod -Method Post -Uri $Session.ApiEndpoint `
        -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $json `
        -TimeoutSec $TimeoutSec -MaximumRedirection 0 -OutFile $ResponsePath -ErrorAction Stop
    # The response is in ResponsePath; only timings are returned.
    return [ordered]@{ serialize_ms = [long](($sendStarted - $serializeStarted).TotalMilliseconds); http_ms = Get-FlintElapsedMs $sendStarted }
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
    return @{ http_status = $status; retryable = $retryable; message = Protect-FlintText $Session $detail; failure = Get-FlintFailureDetails $Session $Record }
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
        # The request is instructions and tools from the latest session start, plus the model view of the logged history.
        Write-FlintEvent $Session 'model_request' @{
            model_call = $Session.ModelCalls; attempt = $attempt + 1
            history_count = @($Payload.input).Count; omitted_outputs = $Session.OmittedOutputs.Count; request_chars = $Session.RequestChars
            estimated_tokens = $Session.EstimatedTokens
        }
        try {
            $attemptStarted = [datetime]::UtcNow
            $timing = [ordered]@{}
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
                $timing.prepare_ms = Get-FlintElapsedMs $attemptStarted
                $native = Invoke-FlintProcess -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                    -ArgumentList $arguments -TimeoutSec $remaining -WorkingDirectory $Session.Root -Session $Session -ModelApiKey $Session.ApiKey
                # process_ms runs from starting the worker to collecting its output; the worker reports its own parts.
                $timing.process_ms = $native.duration_ms
                $timing.worker = ConvertFrom-FlintTiming $native.stdout
                if ($native.status -eq 'stopped') { throw 'Stopped by the user.' }
                if ($native.status -eq 'timeout') { throw ('Model request timed out after ' + $Session.RequestTimeoutSec + ' seconds.') }
                if (Test-Path -LiteralPath $errorPath) {
                    if ((Get-Item -LiteralPath $errorPath).Length -gt 1048576) { throw 'Model error exceeds its size limit.' }
                    $failure = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $errorPath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
                    throw [string]$failure.message
                }
                if ($native.status -ne 'ok') { throw ('Model worker stopped: ' + $native.status + '. ' + $native.stderr) }
            } else {
                # Plain and redirected hosts do not need an animation process.
                $timing.prepare_ms = Get-FlintElapsedMs $attemptStarted
                $sent = Invoke-FlintHttpRequest $Session $Payload $responsePath -TimeoutSec $timeout
                if ($sent -is [System.Collections.IDictionary]) { foreach ($part in @($sent.Keys)) { $timing[$part] = $sent[$part] } }
            }
            $readStarted = [datetime]::UtcNow
            if ((Get-Item -LiteralPath $responsePath).Length -gt 8388608) { throw 'Model response exceeds 8 MiB.' }
            $response = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
            if ($response -is [pscustomobject]) {
                # The service echoes the request's instructions and tools. The session start records them, so the
                # response drops them before it is redacted and logged.
                $kept = [ordered]@{}
                foreach ($property in @($response.PSObject.Properties)) { if ($property.Name -cnotin @('instructions', 'tools')) { $kept[$property.Name] = $property.Value } }
                $response = $kept
                if ($null -ne $response.output) { $response.output = @(foreach ($item in @($response.output)) { Join-FlintMessageParts $item }) }
            }
            $timing.read_ms = Get-FlintElapsedMs $readStarted
            $timing.attempt_ms = Get-FlintElapsedMs $attemptStarted
            # The trajectory event is redacted. The caller keeps a redacted copy and runs tool calls exactly as the model wrote them.
            Write-FlintEvent $Session 'model_response' @{ model_call = $Session.ModelCalls; attempt = $attempt + 1; duration_ms = Get-FlintElapsedMs $started; response = $response } -Timing $timing
            return $response
        } catch {
            # A user stop is not a service failure: never log it as a model error or retry it.
            if ($Session.LogFailed -or $Session.StopRequested) { throw }
            if (-not $failure) { $failure = Get-FlintHttpFailure $Session $_ }
            Write-FlintEvent $Session 'model_error' @{
                model_call = $Session.ModelCalls; attempt = $attempt + 1; duration_ms = Get-FlintElapsedMs $started
                http_status = $failure.http_status; message = $failure.message; failure = $failure.failure
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
        if ($Session.StopRequested) { throw 'Stopped by the user.' }
        $message = 'Azure OpenAI request failed (HTTP {0}): {1}' -f $failure.http_status, $failure.message
        # A rejected key usually means it was rotated; point to where the team keeps the current one.
        if ($failure.http_status -eq 401 -and $Session.ApiKeyHelp) { $message += ' ' + $Session.ApiKeyHelp }
        throw $message
    }
}
