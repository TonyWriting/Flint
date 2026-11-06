#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$nativePowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
    $fixturePath = Join-Path $TestRoot 'native fixture.ps1'
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value "Write-Output 'stdout'; [Console]::Error.WriteLine('stderr'); exit 7"
    $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 10 $WorkRoot
    Assert-True ($result.status -eq 'error' -and $result.exit_code -eq 7 -and $result.stdout.Contains('stdout') -and $result.stderr.Contains('stderr')) 'Capture stdout, stderr and the real exit code for a path with spaces.'
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value "1..200 | ForEach-Object { Write-Output ('line ' + `$_) }; Write-Output 'final marker'"
    for ($iteration = 0; $iteration -lt 3; $iteration++) {
        $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 10 $WorkRoot
        Assert-True ($result.status -eq 'ok' -and $result.stdout.TrimEnd().EndsWith('final marker')) 'Finalize asynchronous stream capture before reading or deleting files.'
    }
    $pidPath = Join-Path $TestRoot 'pid.txt'
    $pidLiteral = $pidPath.Replace("'", "''")
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value ("Set-Content -LiteralPath '" + $pidLiteral + "' -Value `$PID; Start-Sleep -Seconds 60")
    $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 2 $WorkRoot
    Assert-True ($result.status -eq 'timeout' -and $result.duration_ms -lt 10000) 'Bound a real native process by wall-clock time.'
    $childId = [int](Get-Content -LiteralPath $pidPath)
    Assert-True (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Terminate the timed-out process.'
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value "Write-Output ('x' * 1100000)"
    $result = Invoke-FlintProcess $nativePowerShell @('-NoProfile', '-NonInteractive', '-File', ('"' + $fixturePath + '"')) 10 $WorkRoot
    Assert-True ($result.status -eq 'output_limit') 'Cap native output independently of the tool timeout.'

    # Use a harness-owned fixture as the worker to verify timeout behavior at the tool boundary.
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value 'param($RequestPath); Start-Sleep -Seconds 60'
    $Session.WorkerPath = $fixturePath; $Session.ToolTimeoutSec = 1
    $result = Invoke-TestTool read_file @{ path = 'note.txt' }
    Assert-True ($result.status -eq 'timeout') 'Return a structured tool timeout.'
    $result = Invoke-TestTool edit_file @{ path = 'note.txt'; old_str = 'original'; new_str = 'content' }
    Assert-True ($result.status -eq 'timeout' -and $result.output -like '*outcome may be unknown*') 'Require state verification after a write timeout.'
    $result = Invoke-TestTool write_file @{ path = 'note.txt'; content = 'content' }
    Assert-True ($result.status -eq 'timeout' -and $result.output -like '*outcome may be unknown*') 'Report uncertainty after a full-file write timeout.'
    $events = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    Assert-True (@($events | Where-Object { $_.event -eq 'tool_retry' }).Count -eq 0) 'Never automatically retry an uncertain write.'
    Write-Host 'All process tests passed.'
} finally { Remove-TestFixture }
