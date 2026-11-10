#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

function New-TestResponse {
    param([object[]]$Items)
    @{ status = 'completed'; output = $Items; usage = @{ input_tokens = 10; output_tokens = 5 } }
}

function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, $ErrorAction, $ContentType, $Body, $OutFile)
    $script:Requests += @{ payload = ConvertFrom-Json $Body }
    if ($script:Responses.Count -eq 0) { throw 'Unexpected model request.' }
    $result = $script:Responses[0]
    $script:Responses = @($script:Responses | Select-Object -Skip 1)
    Set-Content -LiteralPath $OutFile -Value (ConvertTo-Json -InputObject $result -Depth 32) -Encoding UTF8
}

function Get-TestOutputs {
    $outputs = @{}
    foreach ($item in $Session.History) {
        if ($item.type -eq 'function_call_output') { $outputs[$item.call_id] = ConvertFrom-Json $item.output }
    }
    return $outputs
}

function Get-TestEvents {
    return @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
}

function Test-ProcessGone {
    param([int]$Id)
    # Termination is synchronous, but the process list can lag briefly.
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if (-not (Get-Process -Id $Id -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

$script:Requests = @(); $script:Responses = @()
try {
    # The real key probe needs an interactive console; without one it must stay silent.
    Initialize-FlintUi $Session
    $Session.Ui.Live = $false
    Assert-True (-not (Test-FlintStopKey $Session)) 'Never probe keys without an interactive console.'
    $Session.Ui.Live = $true
    Assert-True (-not (Test-FlintStopKey $Session) -and -not $Session.StopRequested) 'Ignore the stop key when console input is unavailable.'

    Start-FlintTurnUi $Session
    $frame = (Show-FlintActivity $Session 'Thinking' 6>&1) | Out-String
    Assert-True ($frame.Contains('s to stop') -and $frame.Contains('Ctrl+C to exit')) 'Tell the user that s stops the running task.'
    $Session.StopRequested = $true
    $frame = (Update-FlintProgress $Session 6>&1) | Out-String
    Assert-True ($frame.Contains('Stopping after the current step')) 'Show that a stop request is pending.'
    Stop-FlintTurnUi $Session
    $Session.StopRequested = $false; $Session.Ui.Live = $false
    $help = (Show-FlintHelp $Session 6>&1) | Out-String
    Assert-True ($help.Contains('/c, /continue') -and $help.Contains('  s ')) 'Document stopping and resuming in /help.'

    # From here on, the key probe is replaced; the turn, worker and process code stay real.
    $script:StopWhen = { param($State) $false }
    function Test-FlintStopKey {
        param([hashtable]$Session)
        if (-not $Session.StopRequested -and (& $script:StopWhen $Session)) { $Session.StopRequested = $true }
        return [bool]$Session.StopRequested
    }

    Set-Content -LiteralPath (Join-Path $WorkRoot 'note.txt') -Value 'stop fixture' -Encoding UTF8
    $read1 = @{ type = 'function_call'; call_id = 'call_1'; name = 'read_file'; arguments = '{"path":"note.txt","start_line":1,"start_column":1,"max_lines":200}' }
    $read2 = @{ type = 'function_call'; call_id = 'call_2'; name = 'read_file'; arguments = '{"path":"note.txt","start_line":1,"start_column":1,"max_lines":200}' }
    $script:Responses = @(New-TestResponse @($read1, $read2))
    $script:StopWhen = { param($State) @($State.History | Where-Object { $_.type -eq 'function_call_output' }).Count -ge 1 }
    $answer = Invoke-AgentTurn $Session 'Read the note twice.' 10
    $outputs = Get-TestOutputs
    Assert-True ($null -eq $answer -and $script:Requests.Count -eq 1) 'End the turn without an answer or another model request.'
    Assert-True ($outputs['call_1'].status -eq 'ok' -and $outputs['call_2'].status -eq 'skipped') 'Keep completed results and mark calls that never started as skipped.'
    $note = $Session.History[-1]
    Assert-True ($note.role -eq 'developer' -and $note.content -like '*user stopped the previous request*' -and $note.content -like '*verify the actual state*') 'Tell the model that the user stopped the turn.'
    Assert-True ($Session.TurnInterrupted -and -not $Session.StopRequested) 'Leave the session ready for the next prompt.'
    $stopped = @(Get-TestEvents | Where-Object { $_.event -eq 'turn_stopped' })[-1]
    Assert-True ($stopped.data.reason -eq 'interrupted') 'Record a user stop separately from Ctrl+C cancellation.'
    $saved = Read-FlintSession $Session.Id (Split-Path $Session.TrajectoryPath -Parent) $Session.Root
    Assert-True ($saved.state.History[-1].role -eq 'developer') 'Save the stop note in the resumable checkpoint.'
    $history = (Show-FlintHistory $Session 6>&1) | Out-String
    Assert-True ($history.Contains('Stopped before completion.')) 'Show where the conversation stopped after resume.'

    $script:StopWhen = { param($State) $false }
    $final = @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Resumed.' }) }
    $script:Responses = @(New-TestResponse @($final))
    $answer = Invoke-AgentTurn $Session (Get-FlintContinuePrompt) 10
    $requestInput = @($script:Requests[-1].payload.input)
    Assert-True ($answer -ceq 'Resumed.' -and -not $Session.TurnInterrupted) 'Continue the stopped task in the same session.'
    Assert-True ($requestInput[-2].role -eq 'developer' -and $requestInput[-1].role -eq 'user' -and $requestInput[-1].content -like 'Continue the previous task*') 'Send the stop note before the continue request.'

    # A change in progress finishes before the stop takes effect.
    $write = @{ type = 'function_call'; call_id = 'call_3'; name = 'write_file'; arguments = '{"path":"stop.txt","content":"kept"}' }
    $read4 = @{ type = 'function_call'; call_id = 'call_4'; name = 'read_file'; arguments = '{"path":"note.txt","start_line":1,"start_column":1,"max_lines":200}' }
    $script:Responses = @(New-TestResponse @($write, $read4))
    $script:StopWhen = { param($State) [bool]$State.StopDeferred }
    $answer = Invoke-AgentTurn $Session 'Write a file, then read the note.' 10
    $outputs = Get-TestOutputs
    Assert-True ($null -eq $answer -and $outputs['call_3'].status -eq 'ok' -and $outputs['call_4'].status -eq 'skipped') 'Finish an in-flight write, then stop before the next call.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $WorkRoot 'stop.txt') -Raw) -ceq 'kept') 'Keep the completed write.'

    # Reads and model requests stop at once and their process tree is terminated.
    $pidPath = Join-Path $TestRoot 'sleeper.pid'
    $sleeper = Join-Path $TestRoot 'sleeper.ps1'
    Set-Content -LiteralPath $sleeper -Encoding ASCII -Value @(
        'param($RequestPath, [int]$Seconds = 60)'
        ("Set-Content -LiteralPath '" + $pidPath.Replace("'", "''") + "' -Value `$PID")
        'Start-Sleep -Seconds $Seconds'
    )
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile', '-NonInteractive', '-File', ('"' + $sleeper + '"'))
    $Session.StopRequested = $false; $Session.StopDeferred = $false
    Remove-Item -LiteralPath $pidPath -ErrorAction SilentlyContinue
    $script:StopAfter = [datetime]::UtcNow.AddSeconds(3)
    $script:StopWhen = { param($State) [datetime]::UtcNow -gt $script:StopAfter }
    $started = [datetime]::UtcNow
    $native = Invoke-FlintProcess -FilePath $powerShell -ArgumentList $arguments -TimeoutSec 50 -WorkingDirectory $WorkRoot -Session $Session
    Assert-True ($native.status -eq 'stopped' -and ([datetime]::UtcNow - $started).TotalSeconds -lt 20) 'Stop a running read at once.'
    $sleeperId = [int](Get-Content -LiteralPath $pidPath)
    Assert-True (Test-ProcessGone $sleeperId) 'Terminate the stopped process.'

    $Session.StopRequested = $false; $Session.StopDeferred = $true
    $script:StopWhen = { param($State) $true }
    $native = Invoke-FlintProcess -FilePath $powerShell -ArgumentList ($arguments + @('-Seconds', '2')) -TimeoutSec 50 -WorkingDirectory $WorkRoot -Session $Session
    Assert-True ($native.status -eq 'ok' -and $native.exit_code -eq 0 -and $Session.StopRequested) 'Let a deferred process finish while recording the stop request.'

    $Session.Ui.Live = $true; $Session.ModelWorkerPath = $sleeper
    $Session.StopRequested = $false; $Session.StopDeferred = $false
    Remove-Item -LiteralPath $pidPath -ErrorAction SilentlyContinue
    $errors = @(Get-TestEvents | Where-Object { $_.event -eq 'model_error' }).Count
    $script:StopAfter = [datetime]::UtcNow.AddSeconds(3)
    $script:StopWhen = { param($State) [datetime]::UtcNow -gt $script:StopAfter }
    $started = [datetime]::UtcNow
    Assert-Throws { Invoke-AgentResponse $Session @{ input = 'stop' } } '*Stopped by the user*'
    Assert-True (([datetime]::UtcNow - $started).TotalSeconds -lt 20) 'Stop a running model request at once.'
    Assert-True (@(Get-TestEvents | Where-Object { $_.event -eq 'model_error' }).Count -eq $errors) 'Do not record or retry a user stop as a model failure.'
    $sleeperId = [int](Get-Content -LiteralPath $pidPath)
    Assert-True (Test-ProcessGone $sleeperId) 'Terminate the stopped model worker.'
    Write-Host 'All stop tests passed.'
} finally { Remove-TestFixture }
