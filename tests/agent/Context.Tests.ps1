#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')

function New-TestCall {
    param([string]$CallId, [string]$Name, [string]$Arguments, [hashtable]$Result)
    @{ type = 'function_call'; call_id = $CallId; name = $Name; arguments = $Arguments }
    @{ type = 'function_call_output'; call_id = $CallId; output = (ConvertTo-Json -InputObject $Result -Depth 8 -Compress) }
}

function Get-TestOutput {
    param($Payload, [string]$CallId)
    $item = @($Payload.input | Where-Object { $_.type -eq 'function_call_output' -and $_.call_id -ceq $CallId })
    Assert-True ($item.Count -eq 1) "Send exactly one output for $CallId."
    return ConvertFrom-Json $item[0].output
}

function Get-TestBudget { param([hashtable]$Session) return $Session.ContextWindow - $Session.MaxOutputTokens }
function Set-TestBudget {
    param([hashtable]$Session, [long]$Tokens)
    # Input budget in tokens; the window adds the answer reserve on top.
    $Session.ContextWindow = $Tokens + $Session.MaxOutputTokens
}

$script:Writes = @()
function Write-Host {
    param($Object, $ForegroundColor, [switch]$NoNewline)
    $script:Writes += [string]$Object
}

try {
    $searchMatches = @(foreach ($line in 1..150) { @{ line = $line; column = 1; text = ('y' * 150); text_start_column = 1; text_truncated = $false } })
    $Session.History = @(@{ role = 'user'; content = 'Inspect the saved results.' })
    $Session.History += New-TestCall 'write_1' 'write_file' '{"path":"a.txt","content":"a"}' @{ status = 'ok'; exit_code = 0; output = 'File written and verified: a.txt' }
    $Session.History += New-TestCall 'read_1' 'read_file' '{"path":"page1.txt","start_line":1,"start_column":1,"max_lines":200}' @{ status = 'ok'; exit_code = 0; output = ('page-1-marker ' + ('x' * 30000)); truncated = $true; next_line = 201; next_column = 1 }
    $Session.History += New-TestCall 'search_1' 'search_text' '{"path":"page1.txt","keyword":"y","start_line":1,"max_matches":100}' @{ status = 'ok'; exit_code = 0; output = 'Found 150 matching line(s) on this page.'; matches = $searchMatches; matches_returned = 150; next_line = 151 }
    $Session.History += New-TestCall 'read_2' 'read_file' '{"path":"page2.txt","start_line":1,"start_column":1,"max_lines":200}' @{ status = 'ok'; exit_code = 0; output = ('x' * 30000) }
    $Session.History += New-TestCall 'read_3' 'read_file' '{"path":"page3.txt","start_line":1,"start_column":1,"max_lines":200}' @{ status = 'ok'; exit_code = 0; output = ('x' * 30000) }
    $Session.History += New-TestCall 'read_4' 'read_file' '{"path":"page4.txt","start_line":1,"start_column":1,"max_lines":200}' @{ status = 'ok'; exit_code = 0; output = ('x' * 30000) }
    $historyCount = $Session.History.Count

    Set-TestBudget $Session 100000000
    $null = New-FlintPayload $Session
    $full = $Session.RequestChars
    Assert-True ($Session.OmittedOutputs.Count -eq 0) 'Keep every output while the request is below the high watermark.'

    # Above 60% of the input budget, omit the oldest outputs the model has already read until the request fits 30%.
    # No usage is reported yet, so two characters make a token.
    $fullTokens = [long]($full / 2) + 1
    Set-TestBudget $Session ([long]($fullTokens / 0.61))
    $script:Writes = @()
    $payload = New-FlintPayload $Session
    $omitted = @($Session.OmittedOutputs.Keys | Sort-Object)
    Assert-True (($omitted -join ',') -ceq 'read_1,read_2,search_1') 'Omit the oldest large outputs first and stop at the low watermark.'
    Assert-True ($Session.EstimatedTokens -le [long]((Get-TestBudget $Session) * 0.3) + 1) 'Reduce the request to the low watermark.'
    $read = Get-TestOutput $payload 'read_1'
    $names = @($read.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-True ('output' -cnotin $names -and $read.next_line -eq 201 -and $read.status -eq 'ok' -and $read.output_omitted -like '*read_file*') 'Replace only the bulky field and keep cursors and status.'
    $search = Get-TestOutput $payload 'search_1'
    $names = @($search.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-True ('matches' -cnotin $names -and 'output' -cnotin $names -and $search.matches_returned -eq 150) 'Omit search matches as bulky output.'
    Assert-True ((Get-TestOutput $payload 'write_1').output -like 'File written*') 'Keep small outputs.'
    Assert-True ((Get-TestOutput $payload 'read_3').output.Length -eq 30000) 'Keep read outputs that are not needed to reach the low watermark.'
    Assert-True ((Get-TestOutput $payload 'read_4').output.Length -eq 30000) 'Never omit an output the model has not read yet.'
    Assert-True ($Session.History.Count -eq $historyCount -and (ConvertFrom-Json $Session.History[4].output).output.StartsWith('page-1-marker')) 'Keep the full conversation in memory.'
    $compactions = @(Get-TestEvents | Where-Object { $_.event -eq 'context_compacted' })
    Assert-True ($compactions.Count -eq 1 -and @($compactions[0].data.call_ids).Count -eq 3) 'Record which outputs were omitted.'
    Assert-True ($compactions[0].data.request_chars_before -eq $full -and $compactions[0].data.request_chars_after -eq $Session.RequestChars -and
        $compactions[0].data.estimated_tokens_before -eq $fullTokens -and $compactions[0].data.estimated_tokens_after -eq $Session.EstimatedTokens) 'Record the request size before and after omission.'
    $notice = $script:Writes -join "`n"
    Assert-True ($notice -like '*Context trimmed: 3 earlier tool outputs omitted*' -and $notice -like ('*Request about {0:N0} to {1:N0} input tokens*' -f $fullTokens, $Session.EstimatedTokens)) 'Tell the user when earlier outputs are omitted.'
    $script:Writes = @()
    Show-FlintSession $Session -Details
    Assert-True (($script:Writes -join "`n") -like ('*Context: about {0:N0} of {1:N0} input tokens ({2:N0}-token window, {3:N0} reserved for the answer); omitted tool outputs: 3*' -f $Session.EstimatedTokens, (Get-TestBudget $Session), $Session.ContextWindow, $Session.MaxOutputTokens)) 'Show the request size in tokens and omitted outputs in /status.'

    # Later requests reuse the same view, so the prompt cache prefix stays stable.
    $firstInput = ConvertTo-Json -InputObject $payload.input -Depth 32 -Compress
    $again = New-FlintPayload $Session
    Assert-True ((ConvertTo-Json -InputObject $again.input -Depth 32 -Compress) -ceq $firstInput) 'Keep the omitted view stable between requests.'
    Assert-True (@(Get-TestEvents | Where-Object { $_.event -eq 'context_compacted' }).Count -eq 1) 'Compact again only above the high watermark.'

    Write-FlintCheckpoint $Session
    $events = Get-TestEvents
    $logged = @($events | Where-Object { $_.event -eq 'history_appended' } | ForEach-Object { $_.data.items })
    Assert-True ($logged.Count -eq $historyCount) 'Write each conversation item to the trajectory.'
    $raw = Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8
    Assert-True ((($raw -split 'page-1-marker').Count - 1) -eq 1) 'Write each conversation item to the trajectory only once.'
    $checkpoint = @($events | Where-Object { $_.event -eq 'session_checkpoint' })[-1]
    Assert-True ($checkpoint.data.version -eq 3 -and $checkpoint.data.history_count -eq $historyCount -and @($checkpoint.data.omitted_call_ids).Count -eq 3) 'Checkpoint the conversation length and omitted outputs.'

    $resumed = New-TestSession -Resume $Session.Id
    $resumed.ContextWindow = $Session.ContextWindow
    Assert-True ($resumed.History.Count -eq $historyCount -and $resumed.OmittedOutputs.Count -eq 3) 'Restore the conversation and omitted outputs.'
    $restored = New-FlintPayload $resumed
    Assert-True ((ConvertTo-Json -InputObject $restored.input -Depth 32 -Compress) -ceq $firstInput) 'Send the same view after resume.'
    $raw = Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8
    Assert-True ((($raw -split 'page-1-marker').Count - 1) -eq 1) 'Do not rewrite restored conversation items.'

    # The hard limit still applies once every read output has been omitted.
    Set-TestBudget $resumed 334
    Assert-Throws { New-FlintPayload $resumed } '*Context window reached: this request needs about*reserving 16,384 for the answer*'
    Assert-True (-not $resumed.OmittedOutputs.ContainsKey('read_4') -and $resumed.OmittedOutputs.ContainsKey('read_3')) 'Omit every read output but the unread one before stopping.'

    # Through the agent loop, compaction runs between model calls of one turn with real file reads.
    $loop = New-TestSession
    $loop.WorkerPath = $Session.WorkerPath
    Set-TestBudget $loop 50000
    foreach ($index in 1..4) { Set-Content -LiteralPath (Join-Path $WorkRoot ('loop' + $index + '.txt')) -Value (('loop-page-' + $index + ' ') + ('z' * 20000)) -Encoding UTF8 -NoNewline }
    $script:LoopPayloads = @()
    $script:LoopReplies = @(foreach ($index in 1..4) {
        @{ status = 'completed'; output = @(@{ type = 'function_call'; call_id = ('loop_' + $index); name = 'read_file'; arguments = ('{"path":"loop' + $index + '.txt","start_line":1,"start_column":1,"max_lines":200,"json_path":null}') }) }
    })
    $script:LoopReplies += @{ status = 'completed'; output = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Read every page.' }) }) }
    function Invoke-AgentResponse {
        param($Session, $Payload)
        $script:LoopPayloads += $Payload
        $reply = $script:LoopReplies[0]; $script:LoopReplies = @($script:LoopReplies | Select-Object -Skip 1)
        return $reply
    }
    $script:Writes = @()
    Assert-True ((Invoke-AgentTurn $loop 'Read every page.' 10) -ceq 'Read every page.') 'Finish a long turn after compacting its context.'
    Assert-True ($script:LoopPayloads.Count -eq 5 -and $loop.OmittedOutputs.ContainsKey('loop_1')) 'Compact during the turn instead of stopping at the request limit.'
    foreach ($sent in $script:LoopPayloads) {
        $json = ConvertTo-Json -InputObject $sent -Depth 64 -Compress
        Assert-True (([long]($json.Length / 2) + 1) -le (Get-TestBudget $loop)) 'Send every request within the input budget.'
        $outputs = @($sent.input | Where-Object { $_.type -eq 'function_call_output' })
        if ($outputs.Count -gt 0) { Assert-True ($null -ne (ConvertFrom-Json $outputs[-1].output).output) 'Always send the newest unread result in full.' }
    }
    $last = $script:LoopPayloads[-1]
    Assert-True ((Get-TestOutput $last 'loop_1').output_omitted -and (Get-TestOutput $last 'loop_4').output.Contains('loop-page-4')) 'Replace the oldest read and keep the latest one.'
    Assert-True (($script:Writes -join "`n") -like '*Context trimmed:*') 'Show the compaction notice during the turn.'
    $loopEvents = @(Get-TestEvents $loop.TrajectoryPath)
    Assert-True (@($loopEvents | Where-Object { $_.event -eq 'context_compacted' }).Count -ge 1 -and $loopEvents[-1].event -eq 'turn_stopped' -and $loopEvents[-1].data.reason -eq 'completed') 'Record compaction in a completed turn.'
    Assert-True (@($loopEvents | Where-Object { $_.event -eq 'context_near_limit' }).Count -eq 0 -and @(Get-TestEvents | Where-Object { $_.event -eq 'context_near_limit' }).Count -eq 0) 'Do not warn when trimming makes enough room.'

    # Content that cannot be omitted can keep the request above 80% of the limit after trimming.
    $near = New-TestSession
    $near.History = @(@{ role = 'user'; content = ('n' * 100000) })
    Set-TestBudget $near 100000000
    $null = New-FlintPayload $near
    Set-TestBudget $near ([long]($near.EstimatedTokens / 0.85))
    $script:Writes = @()
    $null = New-FlintPayload $near
    $null = New-FlintPayload $near
    $nearEvents = @(Get-TestEvents $near.TrajectoryPath | Where-Object { $_.event -eq 'context_near_limit' })
    Assert-True ($nearEvents.Count -eq 1 -and $nearEvents[0].data.estimated_tokens -eq $near.EstimatedTokens -and $nearEvents[0].data.input_budget -eq (Get-TestBudget $near) -and $nearEvents[0].data.context_window -eq $near.ContextWindow) 'Record the near-limit warning once with the request size.'
    $warnings = @($script:Writes | Where-Object { $_ -like '*Context is nearly full*' })
    Assert-True ($warnings.Count -eq 1 -and ($script:Writes -join "`n") -like ('*Request about {0:N0} of {1:N0} input tokens. Finish this task*' -f $near.EstimatedTokens, (Get-TestBudget $near))) 'Tell the user once to finish the task and start a new session.'

    # Once the service reports usage, the next request is that count plus an estimate of what changed.
    $rate = New-TestSession
    $rate.History = @(@{ role = 'user'; content = 'Measure the rate.' })
    $null = New-FlintPayload $rate
    $measured = $rate.RequestChars
    Assert-True ($rate.EstimatedTokens -eq ([long]($measured / 2) + 1)) 'Assume two characters a token before any usage is reported.'
    $reported = [long]($measured / 2)
    $rate.ModelCalls = 1
    Add-FlintUsage $rate @{ input_tokens = $reported; output_tokens = 10 }
    Assert-True ($rate.LastRequestChars -eq $measured) 'Remember the size of the request that the usage measured.'
    $rate.History += @{ role = 'user'; content = ('m' * 6000) }
    $null = New-FlintPayload $rate
    Assert-True ($rate.RequestChars -gt $measured -and $rate.EstimatedTokens -eq ($reported + [long](($rate.RequestChars - $measured) / 2) + 1)) 'Add two characters a token for content added since the measured request.'
    Write-FlintCheckpoint $rate
    $rateResumed = New-TestSession -Resume $rate.Id
    Assert-True ($rateResumed.LastRequestChars -eq $measured -and $rateResumed.LastInputTokens -eq $reported) 'Keep the measured request across a resume.'

    # After reported usage, trimming stops where the estimate reaches the target, crediting omissions at eight characters a token.
    $trim = New-TestSession
    $trim.History = @(@{ role = 'user'; content = 'Read every page.' })
    foreach ($index in 1..20) {
        $trim.History += New-TestCall ('page_' + $index) 'read_file' ('{"path":"page' + $index + '.txt","start_line":1,"start_column":1,"max_lines":200}') @{ status = 'ok'; exit_code = 0; output = ('p' * 30000) }
    }
    $trim.History += @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Read every page.' }) }
    Set-TestBudget $trim 100000000
    $null = New-FlintPayload $trim
    $baseChars = $trim.RequestChars
    $trim.ModelCalls = 1
    Add-FlintUsage $trim @{ input_tokens = 80000; output_tokens = 10 }
    Set-TestBudget $trim 100000
    $null = New-FlintPayload $trim
    $count = $trim.OmittedOutputs.Count
    Assert-True ($trim.EstimatedTokens -le 30001 -and $count -gt 0 -and $count -lt 20) ('Trim until the estimate reaches the target, and no further: ' + $count + ' omitted, ' + $trim.EstimatedTokens + ' tokens.')
    Assert-True ($trim.TrimmedChars -eq ($baseChars - $trim.RequestChars) -and $trim.EstimatedTokens -eq (80000 - [long]($trim.TrimmedChars / 8) + 1)) 'Credit omitted characters at eight a token.'
    $lastOmitted = 'page_' + $count
    $trim.OmittedOutputs.Remove($lastOmitted)
    $trim.TrimmedChars = 0L
    $null = New-FlintPayload $trim
    Assert-True ($trim.OmittedOutputs.ContainsKey($lastOmitted)) 'Trim again when the estimate climbs back above 60%.'

    # Content added and omitted in one request is counted apart, so the two never cancel.
    $mixed = New-TestSession
    $mixed.History = @(@{ role = 'user'; content = 'Read.' })
    foreach ($index in 1..4) {
        $mixed.History += New-TestCall ('old_' + $index) 'read_file' ('{"path":"old' + $index + '.txt","start_line":1,"start_column":1,"max_lines":200}') @{ status = 'ok'; exit_code = 0; output = ('o' * 10000) }
    }
    $mixed.History += @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Read.' }) }
    Set-TestBudget $mixed 100000000
    $null = New-FlintPayload $mixed
    $mixedChars = $mixed.RequestChars
    $mixed.ModelCalls = 1
    Add-FlintUsage $mixed @{ input_tokens = 20000; output_tokens = 10 }
    $mixed.History += @{ role = 'user'; content = ('n' * 40000) }
    Set-TestBudget $mixed 50000
    $null = New-FlintPayload $mixed
    $added = $mixed.RequestChars - $mixedChars + $mixed.TrimmedChars
    Assert-True ($mixed.TrimmedChars -gt 0 -and $added -gt 40000 -and $mixed.EstimatedTokens -eq (20000 + [long]($added / 2) - [long]($mixed.TrimmedChars / 8) + 1)) 'Count content added and omitted in one request apart.'
    Assert-True ($mixed.EstimatedTokens -gt 20000 + 15000) 'Do not let omissions cancel the content added since the measured request.'
    Write-FlintCheckpoint $mixed
    $mixedResumed = New-TestSession -Resume $mixed.Id
    Assert-True ($mixedResumed.TrimmedChars -eq $mixed.TrimmedChars) 'Keep the omitted count across a resume.'

    # Redaction with newer credentials can shrink an omitted output; a recorded omission must still resume.
    $small = New-TestSession
    $small.History = @(@{ role = 'user'; content = 'Read a short file.' })
    $small.History += New-TestCall 'short_1' 'read_file' '{"path":"short.txt","start_line":1,"start_column":1,"max_lines":200}' @{ status = 'ok'; exit_code = 0; output = 'short'; next_line = $null }
    $small.History += @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Done.' }) }
    $small.OmittedOutputs['short_1'] = (Get-FlintOmittedOutput ([string]$small.History[2].output)).output
    Write-FlintCheckpoint $small
    $smallResumed = New-TestSession -Resume $small.Id
    Assert-True ($smallResumed.OmittedOutputs['short_1'] -ceq $small.OmittedOutputs['short_1']) 'Rebuild every recorded omission on resume, whatever its size.'

    # History items are redacted when they are added. A request and the trajectory still never carry Flint's own credentials.
    $leak = New-TestSession
    Assert-True ([bool]$leak.ApiKey) 'Use a session with a model credential.'
    $leak.History = @(@{ role = 'user'; content = ('Use ' + $leak.ApiKey) })
    $sent = ConvertTo-Json -InputObject (New-FlintPayload $leak) -Depth 64 -Compress
    Assert-True (-not $sent.Contains($leak.ApiKey) -and $sent.Contains('Use [redacted]')) 'Never send Flint''s own credentials, even from a history item added without redaction.'
    $logged = Get-Content -LiteralPath $leak.TrajectoryPath -Raw -Encoding UTF8
    Assert-True (-not $logged.Contains($leak.ApiKey) -and $logged.Contains('Use [redacted]')) 'Never log Flint''s own credentials in the appended history.'

    # Credentials can hide behind JSON escapes. Look in every string, decoding JSON inside strings as the service could.
    function Test-TestDecodedText {
        param($Value, [string]$Needle)
        foreach ($text in @(Get-FlintJsonStrings $Value)) {
            if ($text.Contains($Needle)) { return $true }
            if ($text.TrimStart().StartsWith('{') -or $text.TrimStart().StartsWith('[')) {
                try { if (Test-TestDecodedText (ConvertFrom-Json -InputObject $text -ErrorAction Stop) $Needle) { return $true } } catch { }
            }
        }
        return $false
    }
    $escaped = New-TestSession
    $script:LoopPayloads = @()
    $script:LoopReplies = @(@{ status = 'completed'; output = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Noted.' }) }) })
    $prompt = '{"note":"\u' + ('{0:x4}' -f [int][char]$escaped.ApiKey[0]) + $escaped.ApiKey.Substring(1) + '"}'
    $null = Invoke-AgentTurn $escaped $prompt 2
    $sent = ConvertFrom-Json (ConvertTo-Json -InputObject $script:LoopPayloads[0] -Depth 64 -Compress)
    Assert-True (-not (Test-TestDecodedText $sent $escaped.ApiKey) -and -not (Test-TestDecodedText @(Get-TestEvents $escaped.TrajectoryPath) $escaped.ApiKey)) 'Redact a credential written with a JSON escape in a prompt.'
    $quoted = New-TestSession
    $quoted.ApiKey = 'key"with\escapes-0123'
    $quoted.History = @(@{ role = 'user'; content = 'Read the note.' })
    $quoted.History += New-TestCall 'note_1' 'read_file' '{"path":"note.txt","start_line":1,"start_column":1,"max_lines":200}' @{ status = 'ok'; exit_code = 0; output = (ConvertTo-Json -InputObject @{ note = $quoted.ApiKey } -Compress) }
    $sent = ConvertFrom-Json (ConvertTo-Json -InputObject (New-FlintPayload $quoted) -Depth 64 -Compress)
    Assert-True (-not (Test-TestDecodedText $sent $quoted.ApiKey) -and -not (Test-TestDecodedText @(Get-TestEvents $quoted.TrajectoryPath) $quoted.ApiKey)) 'Find a credential that JSON escapes inside embedded JSON.'
    Remove-Item -LiteralPath function:Write-Host
    Write-Host 'All context tests passed.'
} finally { Remove-TestFixture }
