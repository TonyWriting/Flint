#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
function Invoke-AgentResponse {
    param($Session, $Payload)
    $script:ResumedPayload = $Payload
    return @{ status = 'completed'; output = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Continued.' }) });
        usage = @{ input_tokens = 9; output_tokens = 4; input_tokens_details = @{ cached_tokens = 3 }; output_tokens_details = @{ reasoning_tokens = 2 } } }
}
try {
    $Session.History = @(
        @{ role = 'user'; content = 'Remember this test-api-key.' },
        @{ type = 'reasoning'; encrypted_content = 'opaque-reasoning'; summary = @() },
        @{ type = 'function_call'; name = 'write_file'; call_id = 'uncertain_write'; arguments = '{"path":"report.md","content":"draft"}' },
        @{ type = 'function_call_output'; call_id = 'uncertain_write'; output = '{"status":"interrupted","output":"Verify the actual state before repeating any write."}' }
    )
    $Session.ModelCalls = 3; $Session.UsageReports = 2
    $Session.InputTokens = 1234L; $Session.OutputTokens = 56L; $Session.CachedTokens = 1000L; $Session.ReasoningTokens = 20L
    $Session.CachedReported = $true; $Session.ReasoningReported = $true
    $Session.LastInputTokens = 100; $Session.LastOutputTokens = 20; $Session.EstimatedTokens = 180
    Write-FlintCheckpoint $Session
    $source = Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8
    Assert-True (-not $source.Contains('test-api-key')) 'Redact credentials from the saved checkpoint.'
    $directory = Split-Path $Session.TrajectoryPath -Parent
    $previousSequence = $Session.EventSequence
    Push-Location -LiteralPath $WorkRoot
    try { $resumed = New-AgentSession -EnvFile $config -Resume $Session.Id }
    finally { Pop-Location }
    Assert-True ($resumed.Id -ceq $Session.Id -and $resumed.TrajectoryPath -ceq $Session.TrajectoryPath) 'Keep the original session ID and trajectory path on resume.'
    Assert-True ($resumed.EventSequence -eq ($previousSequence + 2)) 'Append the resume event and checkpoint after the existing event sequence.'
    Assert-True ([string]$resumed.Started.Kind -eq 'Utc' -and ($resumed.Started - $Session.Started).TotalMilliseconds -gt -10 -and ($resumed.Started - $Session.Started).TotalMilliseconds -lt 10) 'Restore the original UTC time origin independently of the local timezone.'
    Assert-True ($resumed.History.Count -eq 4 -and $resumed.History[0].content -eq 'Remember this [redacted].') 'Restore a flat conversation with redacted input.'
    Assert-True ($resumed.History[1].encrypted_content -eq 'opaque-reasoning') 'Preserve opaque reasoning for stateless continuation.'
    Assert-True ((ConvertFrom-Json $resumed.History[3].output).status -eq 'interrupted') 'Preserve uncertain tool outcomes without replaying the tool.'
    Assert-True ($resumed.InputTokens -eq 1234 -and $resumed.CachedTokens -eq 1000 -and $resumed.ReasoningTokens -eq 20 -and $resumed.UsageReports -eq 2) 'Restore cumulative reported usage and unreported requests.'
    $answer = Invoke-AgentTurn $resumed 'Continue with a read before any write.'
    Assert-True ($answer -eq 'Continued.' -and $script:ResumedPayload.input.Count -eq 5) 'Send restored history and the new user message in the next model request.'
    Assert-True ($resumed.InputTokens -eq 1243 -and $resumed.OutputTokens -eq 60 -and $resumed.CachedTokens -eq 1003 -and $resumed.ReasoningTokens -eq 22) 'Accumulate new usage on the restored totals without double counting.'
    Assert-True ((Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8).StartsWith($source)) 'Preserve every existing record and append new events.'
    Push-Location -LiteralPath $WorkRoot
    try { $again = New-AgentSession -EnvFile $config -Resume $Session.Id.ToUpperInvariant() }
    finally { Pop-Location }
    Assert-True ($again.Id -ceq $Session.Id -and $again.History.Count -eq $resumed.History.Count -and $again.InputTokens -eq 1243) 'Keep identity, history and usage stable across repeated resumes.'
    Assert-True ($again.Started -eq $resumed.Started) 'Keep the session time origin across resumes.'
    $resumed = $again
    $events = @(Get-Content -LiteralPath $resumed.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    Assert-True (@($events | Where-Object { $_.event -eq 'session_started' }).Count -eq 1 -and @($events | Where-Object { $_.event -eq 'session_resumed' }).Count -eq 2) 'Distinguish session creation from continuation.'
    for ($i = 0; $i -lt $events.Count; $i++) {
        Assert-True ($events[$i].sequence -eq ($i + 1) -and $events[$i].session_id -ceq $Session.Id) 'Keep one session ID and a continuous sequence in the trajectory.'
        Assert-True ($events[$i].elapsed_ms -ge 0) 'Keep elapsed time nonnegative after resume.'
    }
    Assert-True (@(Get-ChildItem -LiteralPath $directory -Filter *.jsonl).Count -eq 1) 'Do not create a new trajectory on resume.'
    Assert-Throws { Read-FlintSession '..\outside' $directory $WorkRoot } '*32-character session ID*'
    Assert-Throws { Read-FlintSession ('0' * 32) $directory $WorkRoot } '*not found*'
    Assert-Throws { Read-FlintSession $Session.Id $directory $TestRoot } '*original working directory*'
    Write-FlintEvent $resumed 'user_input' @{ text = 'An unfinished turn.' }
    Assert-Throws { Read-FlintSession $resumed.Id $directory $WorkRoot } '*no saved checkpoint*'
    Write-FlintCheckpoint $resumed
    Add-Content -LiteralPath $resumed.TrajectoryPath -Value '{broken' -Encoding UTF8
    Assert-Throws { Read-FlintSession $resumed.Id $directory $WorkRoot } '*invalid JSON*'
    Write-Host 'All session tests passed.'
} finally { Remove-TestFixture }
