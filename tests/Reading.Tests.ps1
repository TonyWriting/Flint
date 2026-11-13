#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
try {
    Set-Content -LiteralPath (Join-Path $WorkRoot 'empty.txt') -Value '' -Encoding UTF8 -NoNewline
    $empty = Invoke-TestTool read_file @{ path = 'empty.txt' }
    Assert-True ($empty.status -eq 'ok' -and $empty.output -ceq '' -and -not $empty.truncated -and $empty.lines_returned -eq 0) 'Read an empty file without a continuation cursor.'
    $mixed = "one`r`ntwo`nthree`r`nfour"
    Set-Content -LiteralPath (Join-Path $WorkRoot 'mixed.txt') -Value $mixed -Encoding UTF8 -NoNewline
    $page = Invoke-TestTool read_file @{ path = 'mixed.txt'; max_lines = 2 }
    Assert-True ($page.output -ceq "one`r`ntwo`n" -and $page.truncated -and $page.next_line -eq 3 -and $page.next_column -eq 1) 'Preserve exact small-file line endings and return the next page position.'
    $last = Invoke-TestTool read_file @{ path = 'mixed.txt'; start_line = $page.next_line; start_column = $page.next_column }
    Assert-True (($page.output + $last.output) -ceq $mixed -and -not $last.truncated) 'Read small files completely without dropping or duplicating content.'
    $emoji = ConvertFrom-Json '"\ud83d\ude80"'
    $long = ('x' * 32767) + $emoji + ('y' * 45000)
    Set-Content -LiteralPath (Join-Path $WorkRoot 'long-line.txt') -Value $long -Encoding UTF8 -NoNewline
    $page = Invoke-TestTool read_file @{ path = 'long-line.txt' }
    Assert-True ($page.output.Length -eq 32767 -and $page.next_line -eq 1 -and $page.next_column -eq 32768) 'Do not split a UTF-16 surrogate pair at the output boundary.'
    $combined = $page.output
    while ($page.truncated) {
        $page = Invoke-TestTool read_file @{ path = 'long-line.txt'; start_line = $page.next_line; start_column = $page.next_column }
        Assert-True ($page.output.Length -le 32768) 'Every page stays within the character budget.'
        $combined += $page.output
    }
    Assert-True ($combined -ceq $long) 'Continuation recovers a long line exactly.'
    $lines = @(1..5000 | ForEach-Object { ('row-{0:D4} ' -f $_) + ('z' * 100) })
    Set-Content -LiteralPath (Join-Path $WorkRoot 'large.log') -Value $lines -Encoding UTF8
    $page = Invoke-TestTool read_file @{ path = 'large.log' }
    Assert-True ($page.size_bytes -gt 262144 -and $page.lines_returned -eq 200 -and $page.next_line -eq 201 -and $page.line_endings_normalized) 'Stream the first 200 lines of a large file.'
    Assert-True ($page.output -ceq (($lines[0..199] -join "`n") + "`n")) 'Return only the requested lines.'
    $page = Invoke-TestTool read_file @{ path = 'large.log'; start_line = 4995 }
    Assert-True ($page.lines_returned -eq 6 -and -not $page.truncated -and $page.output.StartsWith('row-4995')) 'Read near the end of a large file.'
    $page = Invoke-TestTool read_file @{ path = 'large.log'; start_line = 6000 }
    Assert-True ($page.output -ceq '' -and -not $page.truncated) 'An offset beyond EOF returns an empty completed page.'
    Set-Content -LiteralPath (Join-Path $WorkRoot 'binary.txt') -Value ('a' + [char]0 + 'b') -Encoding UTF8 -NoNewline
    Assert-True ((Invoke-TestTool read_file @{ path = 'binary.txt' }).status -eq 'error') 'Reject binary data in text reads.'
    foreach ($arguments in @(
        @{ path = 'mixed.txt'; start_line = 0 }, @{ path = 'mixed.txt'; max_lines = 2001 },
        @{ path = 'mixed.txt'; start_column = '1' }, @{ path = 'mixed.txt'; start_column = 100 }
    )) { Assert-True ((Invoke-TestTool read_file $arguments).status -eq 'error') 'Validate read ranges and column positions.' }
    Write-Host 'All paginated reading tests passed.'
} finally { Remove-TestFixture }
