#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:Requests = @(); $script:Waits = @(); $script:Failures = @(); $script:ToolWrites = 0
$script:ToolMode = $false; $script:Malformed = $false; $script:WorkerCalls = @()
function Wait-FlintRetry {
    param($Session, $Seconds, $Deadline, $Stage)
    $script:Waits += $Seconds
    Assert-True (($Deadline - [datetime]::UtcNow).TotalSeconds -gt $Seconds) 'Reserve time for the wait within the shared deadline.'
    return $true
}
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, $ErrorAction, $ContentType, $Body, $OutFile)
    $script:Requests += @{ body = $Body; path = $OutFile; timeout = $TimeoutSec }
    if ($script:Failures.Count -gt 0) {
        $failure = $script:Failures[0]; $script:Failures = @($script:Failures | Select-Object -Skip 1)
        try { throw 'Transient test-api-key' } catch { $errorObject = $_.Exception }
        if ($failure -is [int]) { $errorObject | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $failure } -Force }
        else { $errorObject | Add-Member -NotePropertyName Status -NotePropertyValue $failure -Force }
        throw $errorObject
    }
    if ($script:Malformed) { Set-Content -LiteralPath $OutFile -Value '{broken' -Encoding UTF8; return }
    $request = ConvertFrom-Json -InputObject $Body
    $items = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Done.' }) })
    if ($script:ToolMode -and 'function_call_output' -notin $request.input.type) {
        $items = @(@{ type = 'function_call'; call_id = 'write_once'; name = 'write_file'; arguments = '{"path":"report.md","content":"done"}' })
    }
    $response = @{ status = 'completed'; output = $items; usage = @{ input_tokens = 10; output_tokens = 5 } }
    Set-Content -LiteralPath $OutFile -Value (ConvertTo-Json -InputObject $response -Depth 16 -Compress) -Encoding UTF8
}
function Invoke-FlintWorker {
    param($Session, $Name, $ToolArguments, $TimeoutSec, $CommandInvocation)
    $script:WorkerCalls += @{ name = $Name; timeout = $TimeoutSec }
    if ($script:ToolMode) { $script:ToolWrites++; return @{ status = 'ok'; exit_code = 0; output = 'Written.' } }
    return @{ status = 'error'; exit_code = 1; output = 'ServiceUnavailable'; retryable = $true }
}
function Resolve-FlintCommandProgram { param($Executor); return [ordered]@{ path = (Join-Path $TestRoot ($Executor + '.exe')) } }
try {
    foreach ($status in @(429, 502, 503, 504, 'ConnectFailure', 'ConnectionClosed', 'SendFailure', 'ReceiveFailure')) {
        $script:Requests = @(); $script:Waits = @(); $script:Failures = @($status)
        $response = Invoke-AgentResponse $Session @{ input = 'test' }
        Assert-True ($response.status -eq 'completed' -and $Requests.Count -eq 2 -and ($Waits -join ',') -eq '1') 'Retry recognized temporary HTTP and connection failures.'
        Assert-True ($Requests[0].body -ceq $Requests[1].body) 'Resend the same payload without changing the conversation.'
        foreach ($request in $Requests) { Assert-True (-not (Test-Path -LiteralPath $request.path)) 'Remove temporary files before another attempt.' }
    }
    foreach ($status in @(400, 401, 403, 404, 500, 'Timeout', 'TrustFailure', 'NameResolutionFailure')) {
        $script:Requests = @(); $script:Waits = @(); $script:Failures = @($status)
        Assert-Throws { Invoke-AgentResponse $Session @{ input = 'test' } } '*Azure OpenAI request failed*'
        Assert-True ($Requests.Count -eq 1 -and $Waits.Count -eq 0) 'Fail immediately for permanent, ambiguous, or unclassified errors.'
    }
    $script:Requests = @(); $script:Waits = @(); $script:Failures = @(503, 503, 503, 503)
    Assert-Throws { Invoke-AgentResponse $Session @{ input = 'test' } } '*HTTP 503*'
    Assert-True ($Requests.Count -eq 4 -and ($Waits -join ',') -eq '1,2,4') 'Stop after the initial request and three retries.'
    $Session.RequestTimeoutSec = 1
    $script:Requests = @(); $script:Waits = @(); $script:Failures = @(429)
    Assert-Throws { Invoke-AgentResponse $Session @{ input = 'test' } } '*HTTP 429*'
    Assert-True ($Requests.Count -eq 1 -and $Waits.Count -eq 0) 'Stop early when the remaining budget cannot cover the next delay.'
    $Session.RequestTimeoutSec = 180; $script:Malformed = $true
    $script:Requests = @(); $script:Waits = @(); $script:Failures = @()
    Assert-Throws { Invoke-AgentResponse $Session @{ input = 'test' } } '*Azure OpenAI request failed*'
    Assert-True ($Requests.Count -eq 1 -and $Waits.Count -eq 0) 'Do not repeat malformed successful responses.'
    $script:Malformed = $false

    $script:WorkerCalls = @(); $script:Waits = @()
    $result = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('version', '--client') }
    Assert-True ($WorkerCalls.Count -eq 4 -and ($Waits -join ',') -eq '1,2,4') 'Apply the same fixed retry schedule to the read-only network tool.'
    Assert-True ($WorkerCalls[-1].timeout -lt $WorkerCalls[0].timeout) 'Pass only the remaining tool budget to each worker.'
    $Session.ToolTimeoutSec = 1; $script:WorkerCalls = @(); $script:Waits = @()
    $null = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('version', '--client') }
    Assert-True ($WorkerCalls.Count -eq 1 -and $Waits.Count -eq 0) 'Do not restart the tool timeout on retry.'
    $Session.ToolTimeoutSec = 30
    foreach ($tool in @(@{ name = 'write_file'; args = @{ path = 'report.md'; content = 'done' } }, @{ name = 'edit_file'; args = @{ path = 'report.md'; old_str = 'a'; new_str = 'b' } })) {
        $script:WorkerCalls = @(); $script:Waits = @()
        $null = Invoke-TestTool $tool.name $tool.args
        Assert-True ($WorkerCalls.Count -eq 1 -and $Waits.Count -eq 0) 'Never retry a file mutation, even when a result claims to be retryable.'
    }
    $Session.ModelCalls = 0; $script:Requests = @(); $script:Waits = @(); $script:Failures = @(503); $script:ToolMode = $true
    $answer = Invoke-AgentTurn $Session 'Write once.'
    Assert-True ($answer -eq 'Done.' -and $script:ToolWrites -eq 1) 'Execute returned tools once after a successful model response.'
    Assert-True ($Session.ModelCalls -eq 3 -and $Session.UsageReports -eq 2 -and $Session.InputTokens -eq 20 -and $Session.OutputTokens -eq 10) 'Count HTTP attempts while adding each reported usage exactly once.'
    $events = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    Assert-True (@($events | Where-Object { $_.event -eq 'model_retry' }).Count -gt 0 -and -not (Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8).Contains('test-api-key')) 'Record retries without credentials.'
    # Restore the real wait to verify it also works under ConstrainedLanguage.
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\Runtime.ps1')
    $started = [datetime]::UtcNow
    Assert-True (Wait-FlintRetry $Session 1 $started.AddSeconds(5) 'Retrying test (1/3) in 1s') 'Complete a real interruptible retry wait.'
    Assert-True (([datetime]::UtcNow - $started).TotalMilliseconds -ge 1000) 'Wait at least the requested backoff duration.'
    Assert-True (-not (Wait-FlintRetry $Session 2 ([datetime]::UtcNow.AddSeconds(1)) 'Must not wait')) 'Decline a wait that would consume the budget.'
    Write-Host 'All retry tests passed.'
} finally { Remove-TestFixture }
