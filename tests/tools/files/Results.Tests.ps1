#Requires -Version 5.1
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'TestSupport.ps1')
try {
    $nextLink = 'https://management.azure.com/subscriptions?api-version=2022-12-01&$skiptoken=page2'
    $body = ConvertTo-Json -InputObject ([ordered]@{
        value = @(@{ name = 'first'; details = ('x' * 300000) }, @{ name = 'last-record-marker'; password = 'private-result-value' })
        nextLink = $nextLink
    }) -Depth 8 -Compress
    $saved = Save-FlintResult $Session $body
    Assert-True ($saved.format -eq 'json' -and $saved.preview_truncated -and $saved.output.Length -eq 16384) 'Return only a bounded preview for a large response.'
    Assert-True ($saved.item_count -eq 2 -and $saved.next_link -ceq $nextLink) 'Expose service pagination independently of the preview.'
    Assert-True ($saved.size_bytes -gt 262144 -and $saved.content_chars -gt 300000) 'Persist a response larger than the normal file read threshold.'
    $content = Get-Content -LiteralPath $saved.result_path -Raw -Encoding UTF8
    $decoded = ConvertFrom-Json -InputObject $content
    Assert-True ($decoded.value.Count -eq 2 -and $decoded.value[0].details.Length -eq 300000 -and $decoded.value[1].name -ceq 'last-record-marker') 'Preserve the complete JSON response past the preview boundary.'
    Assert-True (-not $content.Contains('private-result-value') -and $decoded.value[1].password -ceq '[redacted]') 'Redact before any response reaches disk.'
    Assert-True (-not $saved.output.Contains('last-record-marker')) 'Keep the end of a large response out of the initial context.'
    $medium = Save-FlintResult $Session (ConvertTo-Json -InputObject @{ value = @(@{ name = 'medium'; details = ('y' * 10000) }, @{ name = 'medium-tail-marker' }) } -Depth 8 -Compress)
    Assert-True (-not $medium.preview_truncated -and $medium.output.Contains('medium-tail-marker') -and $medium.output.Length -eq $medium.content_chars) 'Return a medium response whole, without a follow-up read.'
    Assert-True ((Get-Content -LiteralPath $medium.result_path -Raw -Encoding UTF8).Contains('medium-tail-marker')) 'Still save a whole response so it can be read again after the context is trimmed.'

    $page = Invoke-TestTool read_file @{ path = $saved.result_path; max_lines = 200 }
    Assert-True ($page.status -eq 'ok' -and $page.truncated -and $page.line_endings_normalized) 'Read saved results through the real constrained worker.'
    $joined = $page.output
    while ($page.truncated) {
        $page = Invoke-FlintFileTool $Session.Root read_file @{ path = $saved.result_path; start_line = $page.next_line; start_column = $page.next_column; max_lines = 200 } $Session.ProtectedPaths -SessionId $Session.Id
        Assert-True ($page.output.Length -le 32768) 'Every requested page stays within the context budget.'
        $joined += $page.output
    }
    Assert-True ($joined.TrimEnd("`n") -ceq ($content -replace "`r`n", "`n").TrimEnd("`n")) 'Pagination reaches all saved data without gaps or duplicate characters.'
    $tailLine = ($content -split "`n").Count - 3
    $tail = Invoke-TestTool read_file @{ path = $saved.result_path; start_line = $tailLine; max_lines = 20 }
    Assert-True ($tail.status -eq 'ok' -and $tail.output.Contains('nextLink')) 'Read the end of a saved response directly.'

    foreach ($json in @('[]', '[null]', '[1]', '[{"value":[]}]', '{"value":[]}')) {
        $result = Save-FlintResult $Session $json
        $actual = Get-Content -LiteralPath $result.result_path -Raw -Encoding UTF8
        $expectedValue = ConvertFrom-Json ('{"data":' + $json + '}')
        $actualValue = ConvertFrom-Json ('{"data":' + $actual + '}')
        Assert-True ((ConvertTo-Json $expectedValue -Depth 8 -Compress) -ceq (ConvertTo-Json $actualValue -Depth 8 -Compress)) 'Preserve root array shape and null values.'
    }
    $plain = Save-FlintResult $Session 'Upstream failure. password=private-error-value'
    Assert-True ($plain.format -eq 'text' -and $plain.result_path.EndsWith('.txt')) 'Save non-JSON error bodies as text.'
    Assert-True (-not (Get-Content -LiteralPath $plain.result_path -Raw).Contains('private-error-value')) 'Redact credentials in non-JSON bodies.'
    $claimed = Save-FlintResult $Session '{"type":"reasoning","encrypted_content":"password=private-claimed-value"}'
    Assert-True (-not (Get-Content -LiteralPath $claimed.result_path -Raw).Contains('private-claimed-value')) 'Redact service responses that declare themselves reasoning.'
    $empty = Save-FlintResult $Session ''
    Assert-True ($empty.content_chars -eq 0 -and (Test-Path -LiteralPath $empty.result_path)) 'Save an empty HTTP response without fabricating content.'
    $deep = ('{"child":' * 102) + 'null' + ('}' * 102)
    $deepResult = Save-FlintResult $Session $deep
    Assert-True ($deepResult.format -eq 'text' -and (Get-Content -LiteralPath $deepResult.result_path -Raw -Encoding UTF8) -ceq $deep) 'Preserve JSON beyond the parser depth as text instead of silently shortening it.'

    $relative = '.flint\results\' + $Session.Id + '\' + (Split-Path $saved.result_path -Leaf)
    Assert-True ((Invoke-TestTool read_file @{ path = $relative }).status -eq 'ok') 'Read saved results using a relative path through the same file tool.'
    Assert-True ((Invoke-TestTool list_files @{ path = (Split-Path $saved.result_path -Parent) }).status -eq 'ok') 'List saved responses within the current session directory.'
    Assert-True ((Invoke-TestTool write_file @{ path = $saved.result_path; content = 'modified' }).status -eq 'error') 'Result references cannot grant write access to internal files.'
    foreach ($path in @($Session.TrajectoryPath, '.flint', '.flint\results')) {
        Assert-True ((Invoke-TestTool list_files @{ path = $path }).status -eq 'error') 'Keep other internal directories protected outside the Flint installation.'
    }
    $otherId = [guid]::NewGuid().ToString('N')
    $other = Save-FlintResult @{ Root = $Session.Root; Id = $otherId } '{"other":"session"}'
    $traversal = (Split-Path $saved.result_path -Parent) + '\..\' + $otherId + '\' + (Split-Path $other.result_path -Leaf)
    foreach ($path in @($other.result_path, $traversal, ($saved.result_path + ':stream'))) {
        Assert-True ((Invoke-TestTool read_file @{ path = $path }).status -eq 'error') 'Do not expand result access to other sessions, traversal targets or alternate streams.'
    }
    Assert-Throws { Invoke-FlintFileTool $Session.Root read_file @{ path = $saved.result_path; start_line = 1; start_column = 1; max_lines = 200 } @() -SessionId $otherId } '*protected*'
    Write-FlintCheckpoint $Session
    $resumed = New-TestSession -Resume $Session.Id
    $page = Invoke-FlintFileTool $resumed.Root read_file @{ path = $saved.result_path; start_line = $tailLine; start_column = 1; max_lines = 20 } $resumed.ProtectedPaths -SessionId $resumed.Id
    Assert-True ($page.status -eq 'ok' -and $page.output.Contains('nextLink')) 'Resume can read saved results from the same session directory.'
    $missing = Invoke-TestTool read_file @{ path = (Join-Path (Split-Path $saved.result_path -Parent) ([guid]::NewGuid().ToString('N') + '.json')) }
    Assert-True ($missing.status -eq 'error' -and $missing.output -like '*does not exist*') 'Report missing result files without repeating a cloud request.'
    Assert-True (@(Get-ChildItem -LiteralPath (Get-FlintResultDirectory $Session.Root $Session.Id) -Filter *.tmp).Count -eq 0) 'Leave no temporary response files.'

    # json_path returns one value of a JSON file, through the real worker: a string as its text, other values as compact JSON.
    $item = Invoke-TestTool read_file @{ path = $saved.result_path; json_path = 'value[1]' }
    $value = ConvertFrom-Json -InputObject $item.output
    Assert-True ($item.status -eq 'ok' -and $item.value_type -eq 'object' -and -not $item.truncated -and -not $item.output.Contains("`n") -and $value.name -ceq 'last-record-marker' -and $value.password -ceq '[redacted]') ('Select one item of a saved result. ' + $item.output)
    $name = Invoke-TestTool read_file @{ path = $saved.result_path; json_path = 'value[1].name' }
    Assert-True ($name.output -ceq 'last-record-marker' -and $name.value_type -eq 'string') 'Return a selected string as its text.'
    $page = Invoke-TestTool read_file @{ path = $saved.result_path; json_path = 'value[0].details' }
    Assert-True ($page.truncated -and $page.next_line -eq 1 -and $page.output.Length -eq 32768 -and $page.value_chars -eq 300000) 'Page a long value within the context budget.'
    $joined = $page.output
    while ($page.truncated) {
        $page = Invoke-FlintFileTool $Session.Root read_file @{ path = $saved.result_path; json_path = 'value[0].details'; start_line = 1; start_column = $page.next_column; max_lines = 230 } $Session.ProtectedPaths -SessionId $Session.Id
        $joined += $page.output
    }
    Assert-True ($joined -ceq ('x' * 300000)) 'Continue a long value by column without gaps.'
    # A local JSON file is not redacted before it is read, so selection must not lose the field that holds a credential.
    Set-Content -LiteralPath (Join-Path $Session.Root 'settings.json') -Encoding UTF8 -Value '{"settings":{"password":"hunter2","token":{"inner":"tok-private"}},"message":"password=hidden","notes":["password=hidden","password=\"[redacted]\""]}'
    foreach ($selection in @('settings.password', 'settings.token.inner')) {
        $secret = Invoke-TestTool read_file @{ path = 'settings.json'; json_path = $selection }
        Assert-True ($secret.status -eq 'ok' -and $secret.output -ceq '[redacted]') ('Redact a value selected below a credential field: ' + $selection + ' -> ' + $secret.output)
    }
    $message = Invoke-TestTool read_file @{ path = 'settings.json'; json_path = 'message' }
    Assert-True ($message.value_type -eq 'string' -and -not $message.output.Contains('hidden')) ('Redact a selected string like any text. ' + $message.output)
    $notes = Invoke-TestTool read_file @{ path = 'settings.json'; json_path = 'notes' }
    # Windows PowerShell returns a decoded JSON array as one object, so it is assigned without @().
    $decodedNotes = ConvertFrom-Json -InputObject $notes.output
    Assert-True ($notes.value_type -eq 'array' -and $decodedNotes.Count -eq 2 -and -not $notes.output.Contains('hidden')) ('Keep selected JSON valid while redacting it. ' + $notes.output)
    $whole = Invoke-TestTool read_file @{ path = 'settings.json'; json_path = 'settings' }
    $decodedWhole = ConvertFrom-Json -InputObject $whole.output
    Assert-True ($decodedWhole.password -ceq '[redacted]' -and $decodedWhole.token -ceq '[redacted]' -and -not $whole.output.Contains('tok-private')) ('Redact credential fields inside a selected object. ' + $whole.output)
    $missing = Invoke-TestTool read_file @{ path = $saved.result_path; json_path = 'value[1].nmae' }
    Assert-True ($missing.status -eq 'error' -and $missing.output -like '*$.value`[1`] has no property nmae. Properties: *' -and $missing.output -like '*password*') ('Name the available properties when a path segment is missing. ' + $missing.output)
    $range = Invoke-TestTool read_file @{ path = $saved.result_path; json_path = 'value[5]' }
    Assert-True ($range.status -eq 'error' -and $range.output -like '*$.value has 2 items*') 'Report the array length for an index out of range.'
    Assert-True ((Invoke-TestTool read_file @{ path = $saved.result_path; json_path = 'value..name' }).output -like '*property names separated by dots*') 'Reject a malformed path.'
    Assert-True ((Invoke-TestTool read_file @{ path = $saved.result_path; json_path = 'nextLink'; start_line = 2 }).output -like '*use start_line 1*') 'Page a selected value by column only.'
    Assert-True ((Invoke-TestTool read_file @{ path = $saved.result_path; json_path = ('nextLink' + [char]10) }).output -like '*single-line json_path*') 'Validate json_path before the worker runs.'
    Set-Content -LiteralPath (Join-Path $Session.Root 'plain.txt') -Value 'not json' -Encoding UTF8
    $plain = Invoke-TestTool read_file @{ path = 'plain.txt'; json_path = 'status' }
    Assert-True ($plain.status -eq 'error' -and $plain.output -like '*needs a JSON file*') 'Explain that json_path needs a JSON file.'
    Write-Host 'All saved-result tests passed.'
} finally { Remove-TestFixture }
