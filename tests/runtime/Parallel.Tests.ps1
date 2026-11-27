#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
$script:Replies = @(); $script:Payloads = @()
function Invoke-AgentResponse {
    param($Session, $Payload)
    $script:Payloads += $Payload
    if ($script:Replies.Count -eq 0) { throw 'Unexpected model call in the parallel fixture.' }
    $reply = $script:Replies[0]; $script:Replies = @($script:Replies | Select-Object -Skip 1)
    return $reply
}
function New-ParallelRead {
    param([string]$Path, [string]$Keyword = 'original')
    # Searches run in workers; file reads run in the main process.
    return New-TestFunctionCall search_text @{ path = $Path; keyword = $Keyword; start_line = 1; max_matches = 50 }
}
function Set-ParallelReplies {
    param([object[]]$Calls)
    # Each case is a new conversation, so it gets a new session ID and trajectory.
    $Session.Id = [guid]::NewGuid().ToString('N')
    $Session.TrajectoryPath = Join-Path (Split-Path $Session.TrajectoryPath -Parent) ('case-' + $Session.Id + '.jsonl')
    $Session.EventSequence = 0; $Session.History = @(); $Session.HistoryLogged = 0; $Session.OmittedOutputs = @{}
    $script:Replies = @(
        @{ status = 'completed'; output = $Calls },
        @{ status = 'completed'; output = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Done.' }) }) }
    )
}
function Get-ParallelOutputs {
    $outputs = @{}
    foreach ($item in $Session.History) { if ($item.type -eq 'function_call_output') { $outputs[$item.call_id] = ConvertFrom-Json $item.output } }
    return $outputs
}
function Read-ParallelTrace {
    param([string]$Name, [string]$Phase)
    return ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $script:TraceDirectory ($Name + '.' + $Phase + '.json')) -Raw -Encoding UTF8)
}
try {
    $app = New-TestRuntime (Join-Path $TestRoot 'parallel-app')
    $script:TraceDirectory = Join-Path $app 'tools\parallel-trace'
    New-Item -ItemType Directory -Path $TraceDirectory | Out-Null
    $implementation = Join-Path $app 'tools\Worker.Implementation.ps1'
    $source = Get-Content -LiteralPath $implementation -Raw -Encoding UTF8
    $marker = '$request = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop'
    $gate = @'
$traceDirectory = Join-Path $PSScriptRoot 'parallel-trace'
$leaf = Split-Path ([string]$request.arguments.path) -Leaf
$traceName = $request.name + '-' + $leaf
Set-Content -LiteralPath (Join-Path $traceDirectory ($traceName + '.start.json')) -Value (ConvertTo-Json @{ ticks = [datetime]::UtcNow.Ticks; pid = $PID; request_path = $RequestPath; mode = [string]$ExecutionContext.SessionState.LanguageMode }) -Encoding UTF8
if ($leaf.StartsWith('slow-')) { Start-Sleep -Seconds 2 }
if ($leaf.StartsWith('hang-')) { Start-Sleep -Seconds 60 }
'@
    Set-Content -LiteralPath $implementation -Value $source.Replace($marker, ($marker + "`r`n" + $gate)) -Encoding UTF8
    Add-Content -LiteralPath $implementation -Encoding UTF8 -Value @'
Set-Content -LiteralPath (Join-Path $traceDirectory ($traceName + '.end.json')) -Value (ConvertTo-Json @{ ticks = [datetime]::UtcNow.Ticks; pid = $PID }) -Encoding UTF8
'@
    $Session.WorkerPath = Join-Path $app 'tools\Worker.ps1'
    $Session.ToolTimeoutSec = 20
    foreach ($name in @('slow-a.txt', 'slow-b.txt', 'fast.txt', 'changed.txt', 'slow-1.txt', 'slow-2.txt', 'slow-3.txt', 'hang-timeout.txt', 'fast-timeout.txt', 'fast-stop.txt', 'hang-stop.txt', 'never-stop.txt', 'fast-log.txt', 'hang-log.txt')) {
        Set-Content -LiteralPath (Join-Path $WorkRoot $name) -Value 'original' -Encoding UTF8 -NoNewline
    }
    $a = New-ParallelRead 'slow-a.txt'; $b = New-ParallelRead 'slow-b.txt'
    $write = New-TestFunctionCall write_file @{ path = 'changed.txt'; content = 'updated' }
    $after = New-ParallelRead 'changed.txt' 'updated'; $fast = New-ParallelRead 'fast.txt'
    Set-ParallelReplies @($a, $b, $write, $after, $fast)
    Assert-True ((Invoke-AgentTurn $Session 'Read, update, and verify.' 2) -eq 'Done.') 'Complete a mixed tool batch.'
    $aStart = Read-ParallelTrace 'search_text-slow-a.txt' start; $aEnd = Read-ParallelTrace 'search_text-slow-a.txt' end
    $bStart = Read-ParallelTrace 'search_text-slow-b.txt' start; $bEnd = Read-ParallelTrace 'search_text-slow-b.txt' end
    $writeStart = Read-ParallelTrace 'write_file-changed.txt' start; $writeEnd = Read-ParallelTrace 'write_file-changed.txt' end
    $afterStart = Read-ParallelTrace 'search_text-changed.txt' start
    Assert-True ($aStart.ticks -lt $bEnd.ticks -and $bStart.ticks -lt $aEnd.ticks) 'Overlap independent read workers.'
    Assert-True ($writeStart.ticks -gt $aEnd.ticks -and $writeStart.ticks -gt $bEnd.ticks -and $afterStart.ticks -gt $writeEnd.ticks) 'Do not move reads across a write barrier.'
    $outputs = Get-ParallelOutputs
    Assert-True ($outputs.Count -eq 5 -and $outputs[$after.call_id].matches_returned -eq 1) 'Pair results with call IDs and observe the completed write.'
    Assert-True ($aStart.mode -eq 'ConstrainedLanguage' -and -not (Test-Path -LiteralPath $aStart.request_path)) 'Run real constrained workers and remove their temporary requests.'
    Assert-True (@($Payloads[-1].input | Where-Object { $_.type -eq 'function_call_output' }).Count -eq 5) 'Send all tool results before the next model request.'
    Assert-True ((New-FlintPayload $Session).parallel_tool_calls) 'Allow the model to propose multiple tool calls.'

    # A file read in a batch runs in the main process while the batch's workers run.
    $slowSearch = New-ParallelRead 'slow-a.txt'
    $read = New-TestFunctionCall read_file @{ path = 'fast.txt'; start_line = 1; start_column = 1; max_lines = 230; json_path = $null }
    Set-ParallelReplies @($slowSearch, $read)
    $null = Invoke-AgentTurn $Session 'Search and read.' 2
    $outputs = Get-ParallelOutputs
    $finishedOrder = @(Get-TestEvents | Where-Object { $_.event -eq 'tool_finished' } | ForEach-Object { $_.data.call_id })
    Assert-True ($outputs[$read.call_id].output -ceq 'original' -and $outputs[$slowSearch.call_id].status -eq 'ok' -and $finishedOrder[0] -ceq $read.call_id -and
        -not (Test-Path -LiteralPath (Join-Path $TraceDirectory 'read_file-fast.txt.start.json'))) 'Read a file in the main process while a batch worker runs.'

    $Session.MaxParallelTools = 2
    # With a limit of two, three slow reads need a second group.
    $calls = @(1..3 | ForEach-Object { New-ParallelRead ('slow-' + $_ + '.txt') })
    Set-ParallelReplies $calls
    $null = Invoke-AgentTurn $Session 'Read three files.' 2
    $timeline = @(foreach ($number in 1..3) {
        $begin = Read-ParallelTrace ('search_text-slow-' + $number + '.txt') start
        $end = Read-ParallelTrace ('search_text-slow-' + $number + '.txt') end
        @{ ticks = $begin.ticks; delta = 1 }; @{ ticks = $end.ticks; delta = -1 }
    })
    $active = 0; $peak = 0
    foreach ($event in ($timeline | Sort-Object -Property { $_.ticks })) { $active += $event.delta; if ($active -gt $peak) { $peak = $active } }
    Assert-True ($peak -eq 2 -and $active -eq 0) 'Respect the configured worker limit across multiple groups.'

    $Session.MaxToolCalls = 1
    Set-ParallelReplies @((New-ParallelRead 'fast.txt'), (New-ParallelRead 'never-limit.txt'))
    Assert-Throws { Invoke-AgentTurn $Session 'Read within the limit.' 2 } '*Tool-call limit*'
    $outputs = Get-ParallelOutputs
    Assert-True ($outputs.Count -eq 2 -and 'skipped' -in $outputs.Values.status -and -not (Test-Path -LiteralPath (Join-Path $TraceDirectory 'search_text-never-limit.txt.start.json'))) 'Keep the tool budget and pair skipped calls.'
    $Session.MaxToolCalls = 40
    # Leave room for worker startup on a loaded machine; the hanging read still exceeds this budget.
    $Session.ToolTimeoutSec = 8
    Set-ParallelReplies @((New-ParallelRead 'hang-timeout.txt'), (New-ParallelRead 'fast-timeout.txt'))
    $null = Invoke-AgentTurn $Session 'Read with independent timeouts.' 2
    $outputs = Get-ParallelOutputs
    Assert-True ('timeout' -in $outputs.Values.status -and 'ok' -in $outputs.Values.status) ('Let a successful sibling finish when another worker times out. Got: ' + ((@($outputs.Values) | ForEach-Object { [string]$_.status + '/' + [string]$_.duration_ms + 'ms' }) -join ', '))
    $timedOut = Read-ParallelTrace 'search_text-hang-timeout.txt' start
    Assert-True (-not (Get-Process -Id $timedOut.pid -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $timedOut.request_path)) 'Clean up the timed-out worker and request.'

    $Session.ToolTimeoutSec = 20
    $script:StopMode = 'stop'
    function Test-FlintStopKey {
        param($Session)
        if ($script:StopMode -eq 'stop' -and (Test-Path -LiteralPath (Join-Path $script:TraceDirectory 'search_text-hang-stop.txt.start.json')) -and
            @($Session.History | Where-Object { $_.type -eq 'function_call_output' -and (ConvertFrom-Json $_.output).status -eq 'ok' }).Count -gt 0) { $Session.StopRequested = $true }
        if ($script:StopMode -eq 'log' -and (Test-Path -LiteralPath (Join-Path $script:TraceDirectory 'search_text-hang-log.txt.start.json')) -and
            (Test-Path -LiteralPath (Join-Path $script:TraceDirectory 'search_text-fast-log.txt.end.json'))) {
            $Session.TrajectoryPath = Join-Path $script:TestRoot 'missing\trajectory.jsonl'
            Write-FlintEvent $Session 'fixture_log_failure' @{} -BestEffort
        }
        return [bool]$Session.StopRequested
    }
    Set-ParallelReplies @((New-ParallelRead 'fast-stop.txt'), (New-ParallelRead 'hang-stop.txt'), (New-ParallelRead 'never-stop.txt'))
    $null = Invoke-AgentTurn $Session 'Read until stopped.' 2
    $outputs = Get-ParallelOutputs
    Assert-True ($outputs.Count -eq 3 -and 'ok' -in $outputs.Values.status -and 'stopped' -in $outputs.Values.status -and 'skipped' -in $outputs.Values.status) 'Preserve finished results, stop running reads and skip the next group.'
    $stopped = Read-ParallelTrace 'search_text-hang-stop.txt' start
    Assert-True (-not (Get-Process -Id $stopped.pid -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $stopped.request_path)) 'Stop every active worker on a user stop.'
    $saved = Read-FlintSession $Session.Id (Split-Path $Session.TrajectoryPath -Parent) $Session.Root
    Assert-True (@($saved.state.History | Where-Object { $_.type -eq 'function_call_output' }).Count -eq 3) 'Save paired parallel results for resume.'

    $script:StopMode = ''
    function Resolve-FlintCommandProgram { param($Executor); return @{ path = (Join-Path $script:TestRoot 'kubectl.exe') } }
    $readCommand = New-TestFunctionCall run_command @{ executor = 'kubectl'; arguments = @('version', '--client'); purpose = 'Read the client version.' }
    Assert-True ([bool](Get-FlintParallelCall $Session $readCommand)) 'Use reviewed kubectl rules for concurrency eligibility.'
    $unknown = New-TestFunctionCall run_command @{ executor = 'kubectl'; arguments = @('unclassified'); purpose = 'Claim a read-only operation.' }
    $invocation = New-FlintCommandInvocation $Session (ConvertFrom-Json $unknown.arguments)
    $Session.Approvals.kubectl = @($Session.Approvals.kubectl) + (ConvertTo-Json -InputObject $invocation -Depth 16 -Compress)
    Assert-True (-not (Get-FlintParallelCall $Session $unknown)) 'An exact session approval never grants read-only concurrency.'
    Assert-True (-not (Get-FlintParallelCall $Session $write) -and -not (Get-FlintParallelCall $Session (New-TestFunctionCall unknown_tool @{}))) 'Keep writes and unknown tools out of concurrent batches.'

    $events = @(Get-TestEvents)
    for ($index = 0; $index -lt $events.Count; $index++) { Assert-True ($events[$index].sequence -eq $index + 1) 'Serialize all log events in the main process.' }
    Assert-True ('tool_batch_started' -in $events.event -and 'tool_batch_finished' -in $events.event) 'Record batch boundaries without exposing worker state.'
    $script:StopMode = 'log'
    Set-ParallelReplies @((New-ParallelRead 'fast-log.txt'), (New-ParallelRead 'hang-log.txt'), (New-TestFunctionCall write_file @{ path = 'must-not-write.txt'; content = 'unexpected' }))
    Assert-Throws { Invoke-AgentTurn $Session 'Stop on a log failure.' 2 } '*Trajectory*'
    $hung = Read-ParallelTrace 'search_text-hang-log.txt' start
    Assert-True ($Session.LogFailed -and -not (Get-Process -Id $hung.pid -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath (Join-Path $WorkRoot 'must-not-write.txt'))) 'Kill concurrent reads and block a following write after logging fails.'
    Write-Host 'All parallel tool tests passed.'
} finally { Remove-TestFixture }
