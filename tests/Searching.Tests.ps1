#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
try {
    $directory = Join-Path $WorkRoot 'listing'
    New-Item -ItemType Directory -Path $directory | Out-Null
    foreach ($number in 0..224) { Set-Content -LiteralPath (Join-Path $directory ('file-{0:D3}.log' -f $number)) -Value '' -Encoding UTF8 }
    Set-Content -LiteralPath (Join-Path $directory 'other.txt') -Value 'not a log'
    $first = Invoke-TestTool list_files @{ path = 'listing'; name_filter = '*.LOG'; offset = 0 }
    $page = ConvertFrom-Json $first.output
    Assert-True ($first.status -eq 'ok' -and $page.entries.Count -eq 200 -and $page.entries[0] -ceq 'file-000.log' -and $first.next_offset -eq 200) 'Filter names case-insensitively and return a sorted first page.'
    $last = Invoke-TestTool list_files @{ path = 'listing'; name_filter = '*.LOG'; offset = $page.next_offset }
    $page2 = ConvertFrom-Json $last.output
    Assert-True ($page2.entries.Count -eq 25 -and $page2.entries[0] -ceq 'file-200.log' -and -not $last.truncated -and $null -eq $last.next_offset) 'Continue the same filtered directory without losing entries.'
    $empty = Invoke-TestTool list_files @{ path = 'listing'; name_filter = '*.missing' }
    Assert-True ((ConvertFrom-Json $empty.output).entries.Count -eq 0 -and -not $empty.truncated) 'Return an empty complete page for an unmatched filter.'
    $empty = Invoke-TestTool list_files @{ path = 'listing'; offset = 999 }
    Assert-True ((ConvertFrom-Json $empty.output).entries.Count -eq 0 -and -not $empty.truncated) 'Handle offsets beyond the directory end.'
    $longNames = Join-Path $WorkRoot 'long-names'
    New-Item -ItemType Directory -Path $longNames | Out-Null
    foreach ($number in 1..80) { Set-Content -LiteralPath (Join-Path $longNames (('name-{0:D3}-' -f $number) + ("'" * 80) + '.txt')) -Value '' }
    $listing = Invoke-TestTool list_files @{ path = 'long-names' }
    $bounded = ConvertFrom-Json $listing.output
    Assert-True ($listing.truncated -and $bounded.entries.Count -lt 80 -and $listing.output.Length -lt 32768 -and $listing.next_offset -eq $bounded.entries.Count) 'Page before JSON escaping can exceed the output budget.'
    $rest = Invoke-TestTool list_files @{ path = 'long-names'; offset = $listing.next_offset }
    Assert-True (($bounded.entries.Count + (ConvertFrom-Json $rest.output).entries.Count) -eq 80) 'Continue after a character-limited directory page.'

    $path = Join-Path $WorkRoot 'search.log'
    Set-Content -LiteralPath $path -Value "zero`r`nWarning a.b a.b`nA.B tail`r`nlast" -Encoding UTF8 -NoNewline
    $result = Invoke-TestTool search_text @{ path = 'search.log'; keyword = 'a.b' }
    Assert-True ($result.status -eq 'ok' -and $result.matches_returned -eq 2 -and $result.matches[0].line -eq 2 -and $result.matches[0].column -eq 9 -and $result.matches[1].line -eq 3) 'Return one result per matching line, with literal case-insensitive matches and source positions.'
    $first = Invoke-TestTool search_text @{ path = $path; keyword = 'A.B'; max_matches = 1 }
    Assert-True ($first.truncated -and $first.next_line -eq 3 -and $first.matches_returned -eq 1) 'Return a line cursor at the match limit.'
    $last = Invoke-TestTool search_text @{ path = $path; keyword = 'A.B'; start_line = $first.next_line }
    Assert-True ($last.matches_returned -eq 1 -and $last.matches[0].line -eq 3 -and -not $last.truncated) 'Continue search without repeating previous hits.'
    $read = Invoke-TestTool read_file @{ path = $path; start_line = $first.matches[0].line; start_column = $first.matches[0].column; max_lines = 1 }
    Assert-True ($read.output.StartsWith('a.b a.b')) 'Use returned positions with the ordinary read tool.'
    $none = Invoke-TestTool search_text @{ path = $path; keyword = '.*' }
    Assert-True ($none.matches_returned -eq 0 -and -not $none.truncated) 'Treat regex metacharacters as literal text.'
    $none = Invoke-TestTool search_text @{ path = $path; keyword = 'a.b'; start_line = 999 }
    Assert-True ($none.matches_returned -eq 0 -and -not $none.truncated) 'Handle a search position beyond EOF.'
    Set-Content -LiteralPath $path -Value '' -Encoding UTF8 -NoNewline
    Assert-True ((Invoke-TestTool search_text @{ path = $path; keyword = 'a' }).matches_returned -eq 0) 'Search empty files.'
    Set-Content -LiteralPath $path -Value "first`rneedle`rlast" -Encoding UTF8 -NoNewline
    $hit = Invoke-TestTool search_text @{ path = $path; keyword = 'needle' }
    $read = Invoke-TestTool read_file @{ path = $path; start_line = $hit.matches[0].line; max_lines = 1 }
    Assert-True ($hit.matches[0].line -eq 2 -and $read.output -ceq "needle`r") 'Keep search and read line numbers consistent for CR-only text.'

    $longPath = Join-Path $WorkRoot 'long-line.log'
    Set-Content -LiteralPath $longPath -Value (('x' * 40000) + 'Needle' + ('y' * 300000)) -Encoding UTF8 -NoNewline
    $hit = Invoke-TestTool search_text @{ path = $longPath; keyword = 'needle' }
    Assert-True ($hit.matches_returned -eq 1 -and $hit.matches[0].column -eq 40001 -and $hit.matches[0].text.Length -le 512 -and $hit.matches[0].text.Contains('Needle') -and $hit.matches[0].text_truncated -and -not $hit.truncated) 'Find matches past the read preview limit and bound snippets independently of search completion.'
    $emoji = ConvertFrom-Json '"\ud83d\ude80"'
    Set-Content -LiteralPath $path -Value (('a' * 80) + 'needle' + ('b' * 425) + $emoji + 'tail') -Encoding UTF8 -NoNewline
    $hit = Invoke-TestTool search_text @{ path = $path; keyword = 'needle' }
    Assert-True ($hit.matches[0].text.Length -eq 511) 'Avoid splitting a surrogate pair at the snippet end.'
    Set-Content -LiteralPath $path -Value ('a' + $emoji + ('b' * 79) + 'needle' + ('z' * 600)) -Encoding UTF8 -NoNewline
    $hit = Invoke-TestTool search_text @{ path = $path; keyword = 'needle' }
    Assert-True ($hit.matches[0].text.StartsWith($emoji) -and $hit.matches[0].text_start_column -eq 2) 'Avoid splitting a surrogate pair at the snippet start.'

    Set-Content -LiteralPath $path -Value @(1..60 | ForEach-Object { 'needle ' + ("'" * 500) }) -Encoding UTF8
    $arguments = @{ path = $path; keyword = 'needle'; start_line = 1; max_matches = 100 }
    $allLines = @()
    do {
        $page = Search-FlintText $Session.Root $Session.Id $arguments $Session.ProtectedPaths
        Assert-True ((ConvertTo-Json $page -Depth 16 -Compress).Length -lt 32768) 'Keep escaped match JSON within the result budget.'
        $allLines += @($page.matches | ForEach-Object { $_.line })
        $arguments.start_line = $page.next_line
    } while ($page.truncated)
    Assert-True (($allLines -join ',') -ceq ((1..60) -join ',')) 'Return every line exactly once across character-limited search pages.'

    $saved = Save-FlintAzureResult $Session '{"value":[{"name":"needle-result","password":"fixture-private-value"}]}'
    $hit = Invoke-TestTool search_text @{ path = $saved.result_path; keyword = 'needle-result' }
    Assert-True ($hit.status -eq 'ok' -and $hit.matches_returned -eq 1) 'Search saved results through the same constrained worker.'
    $read = Invoke-TestTool read_file @{ path = $saved.result_path; start_line = $hit.matches[0].line; max_lines = 1 }
    Assert-True ($read.output.Contains('needle-result')) 'Use result search positions with the shared file reader.'
    $other = Save-FlintAzureResult @{ Root = $Session.Root; Id = [guid]::NewGuid().ToString('N') } '{"other":"needle"}'
    Assert-True ((Invoke-TestTool search_text @{ path = $other.result_path; keyword = 'needle' }).status -eq 'error') 'Keep another session result directory protected outside the Flint installation.'
    Assert-Throws { Search-FlintText $Session.Root ([guid]::NewGuid().ToString('N')) @{ path = $saved.result_path; keyword = 'needle'; start_line = 1; max_matches = 50 } @() } '*protected*'
    Write-FlintCheckpoint $Session
    Push-Location -LiteralPath $WorkRoot
    try { $resumed = New-AgentSession -EnvFile $config -Resume $Session.Id } finally { Pop-Location }
    Assert-True ((Search-FlintText $resumed.Root $resumed.Id @{ path = $saved.result_path; keyword = 'needle'; start_line = 1; max_matches = 50 } @()).matches_returned -eq 1) 'Search saved results after resuming the same session.'

    Set-Content -LiteralPath $path -Value 'needle test-api-key password=fixture-private-value' -Encoding UTF8 -NoNewline
    $hit = Invoke-TestTool search_text @{ path = $path; keyword = 'needle' }
    $serialized = ConvertTo-Json $hit -Depth 16
    Assert-True (-not $serialized.Contains('test-api-key') -and -not $serialized.Contains('fixture-private-value')) 'Apply existing output redaction to search results.'
    Set-Content -LiteralPath $path -Value ('needle' + [char]0 + 'binary') -Encoding UTF8 -NoNewline
    Assert-True ((Invoke-TestTool search_text @{ path = $path; keyword = 'needle' }).status -eq 'error') 'Reject binary text input.'
    foreach ($caseArguments in @(
        @{ path = $path; keyword = 'x'; extra = 'x' }, @{ path = '.env'; keyword = 'x' },
        @{ path = '.flint\trajectories'; keyword = 'x' }, @{ path = $path; keyword = '' },
        @{ path = $path; keyword = ('x' * 257) }, @{ path = $path; keyword = "x`ny" },
        @{ path = $path; keyword = 'x'; start_line = 0 }, @{ path = $path; keyword = 'x'; max_matches = 101 }
    )) { Assert-True ((Invoke-TestTool search_text $caseArguments).status -eq 'error') 'Enforce search schema and source boundaries.' }
    foreach ($caseArguments in @(@{ path = 'listing'; name_filter = '../*' }, @{ path = 'listing'; name_filter = '' }, @{ path = 'listing'; offset = -1 }, @{ path = 'listing'; offset = '1' })) {
        Assert-True ((Invoke-TestTool list_files $caseArguments).status -eq 'error') 'Validate directory filtering and pagination.'
    }
    Write-Host 'All directory pagination and text search tests passed.'
} finally { Remove-TestFixture }
