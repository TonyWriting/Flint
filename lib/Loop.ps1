function Get-FlintContinuePrompt {
    return 'Continue the previous task from where it stopped. First verify the actual state of any step without a confirmed result, then carry on.'
}

function Add-FlintStopNote {
    param([hashtable]$Session, [string]$Reason)
    # The note is part of the saved conversation, so a resumed session gives the model the same facts.
    $text = 'The user stopped the previous request before it finished.'
    if ($Reason -eq 'cancelled') { $text = 'The previous request was cancelled before it finished because the user exited Flint.' }
    $text += ' Tool results with status ok are confirmed. Calls marked stopped, skipped, cancelled or interrupted have no confirmed outcome. Do not resume that work unless the user asks; when resuming, verify the actual state first.'
    $Session.History += @{ role = 'developer'; content = $text }
}

function Invoke-AgentTurn {
    param([hashtable]$Session, [string]$UserPrompt, [int]$TurnLimit = 20)
    $started = [datetime]::UtcNow
    $reason = 'cancelled'
    $detail = ''
    $calls = @(); $completed = @{}
    $toolCount = 0; $modelCount = 0
    $Session.StopRequested = $false; $Session.StopDeferred = $false
    Start-FlintTurnUi $Session
    try {
        if ($Session.LogFailed) { throw 'Trajectory is unavailable. Start a new session.' }
        $safePrompt = Protect-FlintText $Session $UserPrompt
        Write-FlintEvent $Session 'user_input' @{ text = $safePrompt; max_model_calls = $TurnLimit }
        $Session.History += @{ role = 'user'; content = $safePrompt }
        for ($turn = 0; $turn -lt $TurnLimit; $turn++) {
            if (Test-FlintStopKey $Session) { throw 'Stopped by the user.' }
            $payload = New-FlintPayload $Session
            Show-FlintActivity $Session 'Thinking'
            $Session.ModelCalls++; $modelCount++
            $response = Invoke-AgentResponse $Session $payload
            Add-FlintUsage $Session $response.usage
            if ($response.status -ne 'completed') {
                throw ('Azure OpenAI did not complete the response: ' + (ConvertTo-Json -InputObject @{ status = $response.status; error = $response.error; incomplete_details = $response.incomplete_details } -Depth 16 -Compress))
            }
            $nextCalls = @($response.output | Where-Object { $_.type -eq 'function_call' })
            $seen = @{}
            foreach ($item in $Session.History) { if ($item.type -eq 'function_call') { $seen[$item.call_id] = $true } }
            foreach ($call in $nextCalls) {
                if ($call.call_id -isnot [string] -or [string]::IsNullOrWhiteSpace($call.call_id) -or $seen.ContainsKey($call.call_id) -or
                    $call.name -isnot [string] -or $call.arguments -isnot [string]) { throw 'Malformed or duplicate model tool call. No tools from this response were executed.' }
                $seen[$call.call_id] = $true
            }
            $calls = $nextCalls; $completed = @{}
            # Keep opaque reasoning and every function call for stateless continuation.
            $Session.History += @($response.output)
            if ($calls.Count -eq 0) {
                $answer = @($response.output | Where-Object { $_.type -eq 'message' } | ForEach-Object {
                    Get-FlintMessageText $_
                }) -join [Environment]::NewLine
                if (-not $answer) { throw 'Azure OpenAI returned neither text nor tool calls.' }
                $reason = 'completed'
                return Protect-FlintText $Session $answer
            }
            foreach ($call in $calls) {
                if (Test-FlintStopKey $Session) { throw 'Stopped by the user.' }
                if ($toolCount -ge $Session.MaxToolCalls) {
                    $result = @{ status = 'skipped'; exit_code = $null; output = 'Tool-call limit reached. No action was taken.' }
                    Write-FlintEvent $Session 'tool_skipped' @{ call_id = $call.call_id; name = $call.name; result = $result }
                } else {
                    $toolCount++
                    $result = Invoke-AgentTool $Session $call.name $call.arguments $call.call_id
                }
                $Session.History += @{ type = 'function_call_output'; call_id = $call.call_id; output = (ConvertTo-Json -InputObject $result -Depth 16 -Compress) }
                $completed[$call.call_id] = $true
            }
            if ($toolCount -ge $Session.MaxToolCalls) { $reason = 'tool_limit'; throw 'Tool-call limit reached. Results are retained; send /c to continue, or narrow the request.' }
        }
        $reason = 'model_limit'
        throw "Stopped after $TurnLimit model calls. Tool results are retained; send /c or another message to continue."
    } catch {
        # A user stop ends the turn normally; the session continues at the next prompt.
        if ($Session.StopRequested -and -not $Session.LogFailed) { $reason = 'interrupted'; return }
        if ($reason -eq 'cancelled') { $reason = 'error' }
        $detail = Protect-FlintText $Session $_.Exception.Message
        throw $detail
    } finally {
        # Interruption or a logging failure must not leave unmatched calls in the next request.
        foreach ($call in $calls) {
            if (-not $completed.ContainsKey($call.call_id)) {
                $result = @{ status = 'interrupted'; exit_code = $null; output = 'No confirmed tool result. Verify the actual state before repeating any write.' }
                # A user stop only interrupts between calls, so unfinished calls never started.
                if ($reason -eq 'interrupted') { $result = @{ status = 'skipped'; exit_code = $null; output = 'Not run: the user stopped the turn before this call started.' } }
                $Session.History += @{ type = 'function_call_output'; call_id = $call.call_id; output = (ConvertTo-Json -InputObject $result -Depth 16 -Compress) }
                Write-FlintEvent $Session 'tool_interrupted' @{ call_id = $call.call_id; result = $result } -BestEffort
            }
        }
        $Session.TurnInterrupted = $reason -in @('interrupted', 'cancelled')
        if ($Session.TurnInterrupted) { Add-FlintStopNote $Session $reason }
        Write-FlintCheckpoint $Session -BestEffort
        Write-FlintEvent $Session 'turn_stopped' @{
            reason = $reason; message = $detail; duration_ms = Get-FlintElapsedMs $started
            model_calls = $modelCount; tool_calls = $toolCount
            total_input_tokens = $Session.InputTokens; total_output_tokens = $Session.OutputTokens; total_cached_tokens = $Session.CachedTokens
            total_reasoning_tokens = $Session.ReasoningTokens
        } -BestEffort
        Stop-FlintTurnUi $Session
        $Session.StopRequested = $false
        if ($reason -eq 'cancelled') { Show-FlintInterruption $Session }
        if ($reason -eq 'interrupted') { Show-FlintStopped $Session }
    }
}
