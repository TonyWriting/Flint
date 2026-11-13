#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
try {
    $nextLink = 'https://management.azure.com/subscriptions?api-version=2022-12-01&$skiptoken=page2'
    $body = ConvertTo-Json -InputObject ([ordered]@{
        value = @(@{ name = 'first'; details = ('x' * 300000) }, @{ name = 'last-record-marker'; password = 'private-result-value' })
        nextLink = $nextLink
    }) -Depth 8 -Compress
    $saved = Save-FlintAzureResult $Session $body
    Assert-True ($saved.format -eq 'json' -and $saved.preview_truncated -and $saved.output.Length -le 2048) 'Return only a bounded preview for a large response.'
    Assert-True ($saved.item_count -eq 2 -and $saved.next_link -ceq $nextLink) 'Expose service pagination independently of the preview.'
    Assert-True ($saved.size_bytes -gt 262144 -and $saved.content_chars -gt 300000) 'Persist a response larger than the normal file read threshold.'
    $content = Get-Content -LiteralPath $saved.result_path -Raw -Encoding UTF8
    $decoded = ConvertFrom-Json -InputObject $content
    Assert-True ($decoded.value.Count -eq 2 -and $decoded.value[0].details.Length -eq 300000 -and $decoded.value[1].name -ceq 'last-record-marker') 'Preserve the complete JSON response past the preview boundary.'
    Assert-True (-not $content.Contains('private-result-value') -and $decoded.value[1].password -ceq '[redacted]') 'Redact before any response reaches disk.'
    Assert-True (-not $saved.output.Contains('last-record-marker')) 'Keep the end of a large response out of the initial context.'

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
        $result = Save-FlintAzureResult $Session $json
        $actual = Get-Content -LiteralPath $result.result_path -Raw -Encoding UTF8
        $expectedValue = ConvertFrom-Json ('{"data":' + $json + '}')
        $actualValue = ConvertFrom-Json ('{"data":' + $actual + '}')
        Assert-True ((ConvertTo-Json $expectedValue -Depth 8 -Compress) -ceq (ConvertTo-Json $actualValue -Depth 8 -Compress)) 'Preserve root array shape and null values.'
    }
    $plain = Save-FlintAzureResult $Session 'Upstream failure. password=private-error-value'
    Assert-True ($plain.format -eq 'text' -and $plain.result_path.EndsWith('.txt')) 'Save non-JSON error bodies as text.'
    Assert-True (-not (Get-Content -LiteralPath $plain.result_path -Raw).Contains('private-error-value')) 'Redact credentials in non-JSON bodies.'
    $empty = Save-FlintAzureResult $Session ''
    Assert-True ($empty.content_chars -eq 0 -and (Test-Path -LiteralPath $empty.result_path)) 'Save an empty HTTP response without fabricating content.'
    $deep = ('{"child":' * 102) + 'null' + ('}' * 102)
    $deepResult = Save-FlintAzureResult $Session $deep
    Assert-True ($deepResult.format -eq 'text' -and (Get-Content -LiteralPath $deepResult.result_path -Raw -Encoding UTF8) -ceq $deep) 'Preserve JSON beyond the parser depth as text instead of silently shortening it.'

    $relative = '.flint\results\' + $Session.Id + '\' + (Split-Path $saved.result_path -Leaf)
    Assert-True ((Invoke-TestTool read_file @{ path = $relative }).status -eq 'ok') 'Read saved results using a relative path through the same file tool.'
    Assert-True ((Invoke-TestTool list_files @{ path = (Split-Path $saved.result_path -Parent) }).status -eq 'ok') 'List saved responses within the current session directory.'
    Assert-True ((Invoke-TestTool write_file @{ path = $saved.result_path; content = 'modified' }).status -eq 'error') 'Result references cannot grant write access to internal files.'
    foreach ($path in @($Session.TrajectoryPath, '.flint', '.flint\results')) {
        Assert-True ((Invoke-TestTool list_files @{ path = $path }).status -eq 'error') 'Keep other internal directories protected outside the Flint installation.'
    }
    $otherId = [guid]::NewGuid().ToString('N')
    $other = Save-FlintAzureResult @{ Root = $Session.Root; Id = $otherId } '{"other":"session"}'
    $traversal = (Split-Path $saved.result_path -Parent) + '\..\' + $otherId + '\' + (Split-Path $other.result_path -Leaf)
    foreach ($path in @($other.result_path, $traversal, ($saved.result_path + ':stream'))) {
        Assert-True ((Invoke-TestTool read_file @{ path = $path }).status -eq 'error') 'Do not expand result access to other sessions, traversal targets or alternate streams.'
    }
    Assert-Throws { Invoke-FlintFileTool $Session.Root read_file @{ path = $saved.result_path; start_line = 1; start_column = 1; max_lines = 200 } @() -SessionId $otherId } '*protected*'
    Assert-Throws { ConvertTo-FlintToolArguments read_result '{}' } '*Unknown tool*'
    Write-FlintCheckpoint $Session
    Push-Location -LiteralPath $WorkRoot
    try { $resumed = New-AgentSession -EnvFile $config -Resume $Session.Id } finally { Pop-Location }
    $page = Invoke-FlintFileTool $resumed.Root read_file @{ path = $saved.result_path; start_line = $tailLine; start_column = 1; max_lines = 20 } $resumed.ProtectedPaths -SessionId $resumed.Id
    Assert-True ($page.status -eq 'ok' -and $page.output.Contains('nextLink')) 'Resume can read saved results from the same session directory.'
    $missing = Invoke-TestTool read_file @{ path = (Join-Path (Split-Path $saved.result_path -Parent) ([guid]::NewGuid().ToString('N') + '.json')) }
    Assert-True ($missing.status -eq 'error' -and $missing.output -like '*does not exist*') 'Report missing result files without repeating a cloud request.'
    Assert-True (@(Get-ChildItem -LiteralPath (Get-FlintResultDirectory $Session.Root $Session.Id) -Filter *.tmp).Count -eq 0) 'Leave no temporary response files.'
    Write-Host 'All saved-result tests passed.'
} finally { Remove-TestFixture }
