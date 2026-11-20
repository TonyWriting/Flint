#Requires -Version 5.1
# Runs every *.Tests.ps1 below this directory in its own Windows PowerShell 5.1 process.
# -Filter selects suites by relative name, for example 'agent\*' or 'tools\azure\KeyVault'.
# -Parallel sets how many suites run at once; timing-sensitive suites then run one at a time.
param([string]$Filter = '*', [ValidateRange(1, 8)][int]$Parallel = 2)
$ErrorActionPreference = 'Stop'
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# Suites that cover several scenarios run once per scenario.
$variants = @{
    'runtime\Cancellation' = @('Tool', 'Model', 'Approval', 'Azure', 'Parallel')
    'runtime\Exit' = @('Model', 'Retry', 'Completed')
}
# These suites assert waits, timeouts or worker overlap, so they run without competing suites.
$serial = @('runtime\*', 'agent\Model', 'agent\Retry', 'tools\azure\Operations')
foreach ($name in $variants.Keys) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot ($name + '.Tests.ps1')) -PathType Leaf)) { throw "Scenario suite not found: $name" }
}
$runs = @()
foreach ($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.Tests.ps1' | Sort-Object FullName)) {
    if ($file.FullName -eq $PSCommandPath) { continue }
    $name = $file.FullName.Substring($PSScriptRoot.Length + 1) -replace '\.Tests\.ps1$', ''
    if ($name -notlike $Filter) { continue }
    $alone = @($serial | Where-Object { $name -like $_ }).Count -gt 0
    $scenarios = @($null)
    if ($variants.ContainsKey($name)) { $scenarios = $variants[$name] }
    foreach ($scenario in $scenarios) {
        $run = @{ name = $name; path = $file.FullName; arguments = @(); serial = $alone }
        if ($scenario) { $run.name = '{0} ({1})' -f $name, $scenario; $run.arguments = @('-During', $scenario) }
        $runs += $run
    }
}
if ($runs.Count -eq 0) { throw "No test suites match '$Filter'." }

$scratch = Join-Path $env:TEMP ('flint-test-run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$script:Passed = 0
$script:Failed = @()
$script:Active = @()

function Start-TestRun {
    param([hashtable]$Run, [int]$Index)
    $Run.stdout = Join-Path $scratch ([string]$Index + '.out.txt')
    $Run.stderr = Join-Path $scratch ([string]$Index + '.err.txt')
    $arguments = @('-NoProfile', '-NonInteractive', '-File', ('"' + $Run.path + '"')) + $Run.arguments
    $Run.started = [datetime]::UtcNow
    $Run.process = Start-Process -FilePath $powerShell -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $Run.stdout -RedirectStandardError $Run.stderr
    # Reading the handle keeps the exit code available after the process ends.
    $null = $Run.process.Handle
    $script:Active += $Run
}

function Complete-TestRun {
    param([hashtable]$Run)
    $seconds = '{0:N1}s' -f ([datetime]::UtcNow - $Run.started).TotalSeconds
    if ($Run.process.ExitCode -eq 0) {
        $script:Passed++
        Write-Host ('PASS {0} ({1})' -f $Run.name, $seconds)
        return
    }
    foreach ($path in @($Run.stdout, $Run.stderr)) {
        $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
        if ($text) { Write-Host $text.TrimEnd() }
    }
    $script:Failed += $Run.name
    Write-Host ('FAIL {0} ({1}, exit {2})' -f $Run.name, $seconds, $Run.process.ExitCode)
}

function Invoke-TestRuns {
    param([object[]]$Queue, [int]$Limit)
    $next = 0
    while ($next -lt $Queue.Count -or $script:Active.Count -gt 0) {
        while ($next -lt $Queue.Count -and $script:Active.Count -lt $Limit) {
            Start-TestRun $Queue[$next] $script:Launched.Count
            $script:Launched += $Queue[$next]
            $next++
        }
        Start-Sleep -Milliseconds 200
        $running = @()
        foreach ($run in $script:Active) {
            if ($run.process.HasExited) { Complete-TestRun $run } else { $running += $run }
        }
        $script:Active = $running
    }
}

$started = [datetime]::UtcNow
$script:Launched = @()
try {
    Invoke-TestRuns @($runs | Where-Object { -not $_.serial }) $Parallel
    Invoke-TestRuns @($runs | Where-Object { $_.serial }) 1
} finally {
    # Stop any suite that is still running, including its worker processes.
    foreach ($run in $script:Active) {
        if (-not $run.process.HasExited) { & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /T /F /PID $run.process.Id 2>&1 | Out-Null }
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
$total = '{0:N1}s' -f ([datetime]::UtcNow - $started).TotalSeconds
if ($script:Failed.Count -gt 0) { throw ('{0} suites failed: {1}. {2} suites passed in {3}.' -f $script:Failed.Count, ($script:Failed -join ', '), $script:Passed, $total) }
Write-Host ('All {0} suites passed on Windows PowerShell 5.1 (ConstrainedLanguage) in {1}.' -f $script:Passed, $total)
