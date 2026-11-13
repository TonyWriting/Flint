#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

function New-TestResponse {
    param([object[]]$Items)
    @{ status = 'completed'; output = $Items; usage = @{ input_tokens = 10; output_tokens = 5; input_tokens_details = @{ cached_tokens = 3 }; output_tokens_details = @{ reasoning_tokens = 2 } } }
}

function Reset-TestConversation {
    # Each case starts from an empty conversation, as a new Flint session would.
    $Session.History = @()
    $Session.LastInputTokens = $null; $Session.LastOutputTokens = $null; $Session.EstimatedTokens = 0
}

function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, $ErrorAction, $ContentType, $Body, $OutFile)
    Assert-True ($Method -eq 'Post' -and $Uri -eq 'https://test.services.ai.azure.com/openai/v1/responses' -and $Uri -ceq $script:Session.ApiEndpoint) 'POST directly to the configured Responses endpoint without appending another suffix.'
    Assert-True ($Headers.Authorization -eq 'Bearer test-api-key') 'Use the key only for authentication.'
    Assert-True ($ContentType -eq 'application/json; charset=utf-8' -and $MaximumRedirection -eq 0 -and $TimeoutSec -gt 0 -and $TimeoutSec -le 180) 'Bound HTTP requests, disable redirects and use UTF-8.'
    Assert-True (-not $Body.Contains('test-api-key')) 'Do not send the API key in model context.'
    $script:Requests += @{ payload = ConvertFrom-Json $Body; path = $OutFile; raw = $Body }
    if ($script:HttpStatus) {
        try { Write-Error 'Rejected test-api-key' -ErrorAction Stop } catch { $httpError = $_.Exception }
        $httpError | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $script:HttpStatus } -Force
        throw $httpError
    }
    if ($script:InvalidJson) { Set-Content -LiteralPath $OutFile -Value '{broken' -Encoding UTF8; return }
    if ($script:Responses.Count -eq 0) { throw 'Unexpected model request.' }
    $result = $script:Responses[0]
    $script:Responses = @($script:Responses | Select-Object -Skip 1)
    Set-Content -LiteralPath $OutFile -Value (ConvertTo-Json -InputObject $result -Depth 32) -Encoding UTF8
}

$script:Requests = @(); $script:Responses = @(); $script:HttpStatus = 0; $script:InvalidJson = $false
try {
    $unicode = ConvertFrom-Json '"\u4f60\u597d"'
    Set-Content -LiteralPath (Join-Path $WorkRoot 'note.txt') -Value "alpha $unicode test-api-key password=hidden-value" -Encoding UTF8 -NoNewline
    $reasoning = @{ type = 'reasoning'; id = 'rs_1'; summary = @(); encrypted_content = 'opaque-reasoning' }
    $read = @{ type = 'function_call'; call_id = 'call_1'; name = 'read_file'; arguments = '{"path":"note.txt","start_line":1,"start_column":1,"max_lines":200}' }
    $invalid = @{ type = 'function_call'; call_id = 'call_2'; name = 'read_file'; arguments = '{broken' }
    $edit = @{ type = 'function_call'; call_id = 'call_3'; name = 'edit_file'; arguments = '{"path":"note.txt","old_str":"alpha","new_str":"beta"}' }
    $write = @{ type = 'function_call'; call_id = 'call_4'; name = 'write_file'; arguments = '{"path":"report.md","content":"# Report\n\nDone."}' }
    $final = @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = "$unicode test-api-key" }) }
    $script:Responses = @((New-TestResponse @($reasoning, $read, $invalid)), (New-TestResponse @($edit, $write)), (New-TestResponse @($final)))
    $answer = Invoke-AgentTurn $Session "Read $unicode test-api-key" 10
    Assert-True ($answer -ceq "$unicode [redacted]") 'Preserve Unicode and redact model output.'
    Assert-True ($Requests.Count -eq 3 -and $Session.ModelCalls -eq 3) 'Run the complete multi-call loop.'
    $input2 = $Requests[1].payload.input
    Assert-True ($input2[1].encrypted_content -ceq 'opaque-reasoning') 'Preserve encrypted reasoning.'
    $results = @($input2 | Where-Object { $_.type -eq 'function_call_output' })
    Assert-True ($results.Count -eq 2 -and $results[0].call_id -eq 'call_1' -and $results[1].call_id -eq 'call_2') 'Pair every tool result before continuing.'
    $readResult = ConvertFrom-Json $results[0].output
    Assert-True ($readResult.status -eq 'ok' -and $readResult.output.Contains($unicode) -and -not $readResult.output.Contains('hidden-value')) 'Redact tool data before sending it to the model.'
    Assert-True ((ConvertFrom-Json $results[1].output).status -eq 'error') 'Return malformed arguments as a structured tool error.'
    $editResult = @($Requests[2].payload.input | Where-Object { $_.type -eq 'function_call_output' -and $_.call_id -eq 'call_3' })
    Assert-True ((ConvertFrom-Json $editResult[0].output).status -eq 'ok') 'Apply workspace edits without interactive confirmation.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $WorkRoot 'note.txt') -Raw).StartsWith('beta')) 'Apply the requested precise edit.'
    $writeResult = @($Requests[2].payload.input | Where-Object { $_.type -eq 'function_call_output' -and $_.call_id -eq 'call_4' })
    Assert-True ((ConvertFrom-Json $writeResult[0].output).status -eq 'ok') 'Return the direct write result to the model.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $WorkRoot 'report.md') -Raw) -ceq "# Report`n`nDone.") 'Create the complete model-requested file.'
    $stableTools = ConvertTo-Json -InputObject $Requests[0].payload.tools -Depth 16 -Compress
    foreach ($request in $Requests) {
        Assert-True ($request.payload.tools.Count -eq 9 -and 'search_text' -in $request.payload.tools.name -and 'read_result' -notin $request.payload.tools.name -and 'keyvault_list_secrets' -in $request.payload.tools.name -and 'azure_request' -in $request.payload.tools.name) 'Use one file reader alongside text search, Azure requests and Key Vault metadata listing.'
        Assert-True ((ConvertTo-Json -InputObject $request.payload.tools -Depth 16 -Compress) -ceq $stableTools) 'Keep tool definitions stable across requests.'
        Assert-True ($request.payload.instructions -ceq $Requests[0].payload.instructions) 'Keep the instruction prefix stable.'
        Assert-True (-not $request.payload.stream -and -not $request.payload.store -and $request.payload.max_output_tokens -eq 4096) 'Bound output and use stateless requests.'
        Assert-True (-not (Test-Path -LiteralPath $request.path)) 'Clean up response files.'
    }
    Assert-True ($Session.InputTokens -eq 30 -and $Session.OutputTokens -eq 15 -and $Session.CachedTokens -eq 9) 'Accumulate API usage, including cached tokens.'
    Assert-True ($Session.ReasoningTokens -eq 6 -and $Session.UsageReports -eq 3) 'Track reported reasoning tokens as a subset of output usage.'
    $script:Responses = @((New-TestResponse @($final)))
    $previousCount = $Session.History.Count
    Invoke-AgentTurn $Session 'Continue.' 2 | Out-Null
    Assert-True ($Requests[-1].payload.input.Count -eq ($previousCount + 1)) 'Retain context across user turns.'

    foreach ($status in @(400, 401, 403)) {
        $script:HttpStatus = $status
        $before = $Requests.Count
        Assert-Throws { Invoke-AgentResponse $Session @{ model = 'test-deployment'; input = 'test' } } "*HTTP $status*"
        Assert-True ($Requests.Count -eq ($before + 1)) 'Do not retry invalid requests or authentication failures.'
        Assert-True (-not (Test-Path -LiteralPath $Requests[-1].path)) 'Clean up failed HTTP responses.'
    }
    $script:HttpStatus = 0; $script:InvalidJson = $true
    Assert-Throws { Invoke-AgentResponse $Session @{} } 'Azure OpenAI request failed*'
    $script:InvalidJson = $false

    Reset-TestConversation
    $script:Responses = @((New-TestResponse @(
        @{ type = 'message'; role = 'assistant'; content = @() },
        @{ type = 'message'; role = 'assistant'; content = @() }
    )))
    Assert-Throws { Invoke-AgentTurn $Session 'Answer.' 1 } '*neither text nor tool calls*'

    Reset-TestConversation
    $script:Responses = @((New-TestResponse @($read, $invalid)))
    Assert-Throws { Invoke-AgentTurn $Session 'Read.' 1 } 'Stopped after 1*'
    Assert-True (@($Session.History | Where-Object { $_.type -eq 'function_call_output' }).Count -eq 2) 'Preserve all results at the model-call limit.'
    Reset-TestConversation
    $beforeIncomplete = Get-Content -LiteralPath (Join-Path $WorkRoot 'report.md') -Raw
    $incompleteWrite = @{ type = 'function_call'; call_id = 'incomplete_write'; name = 'write_file'; arguments = '{"path":"report.md","content":"must not be written"}' }
    $script:Responses = @(@{ status = 'incomplete'; output = @($incompleteWrite); incomplete_details = @{ reason = 'max_output_tokens' } })
    Assert-Throws { Invoke-AgentTurn $Session 'Edit.' 2 } '*did not complete*'
    Assert-True ($Session.History.Count -eq 1) 'Incomplete responses cannot invoke tools.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $WorkRoot 'report.md') -Raw) -ceq $beforeIncomplete) 'Do not apply writes from incomplete model output.'
    Reset-TestConversation
    $script:Responses = @((New-TestResponse @($read, $read)))
    Assert-Throws { Invoke-AgentTurn $Session 'Read.' 2 } '*duplicate*'
    Assert-True ($Session.History.Count -eq 1) 'Reject an entire malformed tool batch.'
    Reset-TestConversation
    $Session.MaxToolCalls = 1
    $script:Responses = @((New-TestResponse @($read, $invalid)))
    Assert-Throws { Invoke-AgentTurn $Session 'Read.' 2 } '*Tool-call limit*'
    $outputs = @($Session.History | Where-Object { $_.type -eq 'function_call_output' })
    Assert-True ($outputs.Count -eq 2 -and (ConvertFrom-Json $outputs[1].output).status -eq 'skipped') 'Pair skipped calls at the tool-call limit.'
    Reset-TestConversation
    $Session.ContextWindow = 4100
    $before = $Requests.Count
    Assert-Throws { Invoke-AgentTurn $Session 'Read.' 2 } '*Estimated context limit*'
    Assert-True ($before -eq $Requests.Count) 'Stop before HTTP when context plus reserve exceeds the configured limit.'
    $Session.ContextWindow = 0; $Session.MaxRequestChars = 10
    Assert-Throws { Invoke-AgentTurn $Session 'Read.' 2 } '*character limit*'

    $rawLog = Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8
    Assert-True (-not $rawLog.Contains('test-api-key') -and -not $rawLog.Contains('hidden-value')) 'Never persist credentials in the trajectory.'
    $events = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    for ($i = 0; $i -lt $events.Count; $i++) { Assert-True ($events[$i].sequence -eq ($i + 1)) 'Append sequential, independently parseable JSON events.' }
    foreach ($type in @('session_started', 'user_input', 'model_request', 'model_response', 'model_error', 'tool_started', 'tool_finished', 'tool_skipped', 'turn_stopped')) {
        Assert-True ($type -in $events.event) "Record $type."
    }
    Assert-True ('model_limit' -in $events.data.reason -and 'tool_limit' -in $events.data.reason -and 'completed' -in $events.data.reason) 'Record distinct stop reasons.'
    $Session.TrajectoryPath = Join-Path $TestRoot 'missing\unavailable.jsonl'
    Assert-Throws { Invoke-AgentTool $Session 'read_file' '{"path":"note.txt"}' } '*Cannot append*'
    Assert-True $Session.LogFailed 'Stop before tool execution when the trajectory fails.'
    Write-Host 'All agent tests passed.'
} finally { Remove-TestFixture }
