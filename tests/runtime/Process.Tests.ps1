#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
$nativePowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Format-TestResult {
    param($Result)
    # Process timing varies with machine load; report what actually happened when an assertion fails.
    $streams = @{}
    foreach ($name in @('stdout', 'stderr')) {
        $text = [string]$Result.$name
        if ($text.Length -gt 200) { $text = $text.Substring(0, 200) + '...' }
        $streams[$name] = $text
    }
    return ' Got: ' + (ConvertTo-Json -InputObject @{ status = $Result.status; exit_code = $Result.exit_code; duration_ms = $Result.duration_ms; stdout = $streams.stdout; stderr = $streams.stderr } -Compress)
}

try {
    $fixturePath = Join-Path $TestRoot 'native fixture.ps1'
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value "Write-Output 'stdout'; [Console]::Error.WriteLine('stderr'); exit 7"
    $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 10 $WorkRoot
    Assert-True ($result.status -eq 'error' -and $result.exit_code -eq 7 -and $result.stdout.Contains('stdout') -and $result.stderr.Contains('stderr')) ('Capture stdout, stderr and the real exit code for a path with spaces.' + (Format-TestResult $result))
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value "1..200 | ForEach-Object { Write-Output ('line ' + `$_) }; Write-Output 'final marker'"
    for ($iteration = 0; $iteration -lt 3; $iteration++) {
        $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 10 $WorkRoot
        Assert-True ($result.status -eq 'ok' -and $result.stdout.TrimEnd().EndsWith('final marker')) ('Finalize asynchronous stream capture before reading or deleting files.' + (Format-TestResult $result))
    }
    # A prompt printed after more than 64 KiB of diagnostics, and after a pause, still stops the wait at once.
    $promptPattern = '(?i)\bopen the page\s+https://\S+\s+and enter the code\s+\S+'
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value @(
        "1..100 | ForEach-Object { [Console]::Error.WriteLine('diagnostic ' + ('d' * 800)) }"
        'Start-Sleep -Milliseconds 1500'
        "[Console]::Error.WriteLine('To sign in, use a web browser to open the page https://login.example.com/device and enter the code LATE42 to authenticate.')"
        'Start-Sleep -Seconds 30'
    )
    $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 15 $WorkRoot -PromptPattern $promptPattern
    Assert-True ($result.status -eq 'prompted' -and $result.duration_ms -lt 10000 -and $result.stderr.Contains('LATE42')) ('Stop at a prompt that follows long stderr output.' + (Format-TestResult $result))
    # Stderr beyond the output limit is never read for a prompt; the limit ends the process instead.
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value @(
        "[Console]::Error.Write('x' * 1200000)"
        "[Console]::Error.WriteLine()"
        "[Console]::Error.WriteLine('To sign in, use a web browser to open the page https://login.example.com/device and enter the code BIG42 to authenticate.')"
        'Start-Sleep -Seconds 30'
    )
    $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 15 $WorkRoot -PromptPattern $promptPattern
    Assert-True ($result.status -eq 'output_limit') ('Apply the output limit before scanning stderr for a prompt.' + (Format-TestResult $result))
    # The limit covers stdout and stderr together, even when stderr alone is small and holds a prompt.
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value @(
        "[Console]::Out.Write('o' * 800000)"
        "[Console]::Error.WriteLine('e' * 300000)"
        "[Console]::Error.WriteLine('To sign in, use a web browser to open the page https://login.example.com/device and enter the code BOTH42 to authenticate.')"
        'Start-Sleep -Seconds 30'
    )
    $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 15 $WorkRoot -PromptPattern $promptPattern
    Assert-True ($result.status -eq 'output_limit') ('Apply the combined output limit before a prompt.' + (Format-TestResult $result))
    $pidPath = Join-Path $TestRoot 'pid.txt'
    $pidLiteral = $pidPath.Replace("'", "''")
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value ("Set-Content -LiteralPath '" + $pidLiteral + "' -Value `$PID; Start-Sleep -Seconds 60")
    $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 2 $WorkRoot
    Assert-True ($result.status -eq 'timeout' -and $result.duration_ms -lt 10000) ('Bound a real native process by wall-clock time.' + (Format-TestResult $result))
    $childId = [int](Get-Content -LiteralPath $pidPath)
    Assert-True (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Terminate the timed-out process.'
    # A process that keeps writing must stop at the output cap well before its time budget.
    # Large writes reach the 1 MiB cap in a few iterations, even on a slow shared runner.
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value "while (`$true) { Write-Output ('x' * 65536) }"
    $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 30 $WorkRoot
    Assert-True ($result.status -eq 'output_limit' -and $result.duration_ms -lt 30000) ('Cap native output independently of the tool timeout.' + (Format-TestResult $result))

    # Use a harness-owned fixture as the worker to verify timeout behavior at the tool boundary.
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value 'param($RequestPath); Start-Sleep -Seconds 60'
    $Session.WorkerPath = $fixturePath; $Session.ToolTimeoutSec = 1
    $result = Invoke-TestTool read_file @{ path = 'note.txt' }
    Assert-True ($result.status -eq 'timeout') ('Return a structured tool timeout.' + (Format-TestResult $result))
    $result = Invoke-TestTool edit_file @{ path = 'note.txt'; old_str = 'original'; new_str = 'content' }
    Assert-True ($result.status -eq 'timeout' -and $result.output -like '*outcome may be unknown*') 'Require state verification after a write timeout.'
    $result = Invoke-TestTool write_file @{ path = 'note.txt'; content = 'content' }
    Assert-True ($result.status -eq 'timeout' -and $result.output -like '*outcome may be unknown*') 'Report uncertainty after a full-file write timeout.'
    $events = @(Get-TestEvents)
    Assert-True (@($events | Where-Object { $_.event -eq 'tool_retry' }).Count -eq 0) 'Never automatically retry an uncertain write.'
    Write-Host 'All process tests passed.'
} finally { Remove-TestFixture }
