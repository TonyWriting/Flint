#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$passed = 0
foreach ($suite in @('Config', 'Ui', 'Sessions', 'Files', 'Directories', 'Reading', 'Results', 'Agent', 'Permissions', 'Commands', 'Azure', 'AzureApproval', 'AzureCli', 'KeyVault', 'AzureCancellation', 'Retry', 'Model', 'WorkerStartup', 'Process', 'Cancellation', 'ApprovalCancellation', 'ModelCancellation', 'Cli', 'Exit', 'IdleExit', 'CompletedExit', 'RetryCancellation')) {
    $arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot ($suite + '.Tests.ps1')))
    $ErrorActionPreference = 'Continue'
    $output = & $powerShell @arguments 2>&1
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { $output | Write-Host; throw "$suite (ConstrainedLanguage) failed." }
    $passed++
    Write-Host ("PASS {0} (ConstrainedLanguage)" -f $suite)
}
Write-Host ("All {0} suites passed on Windows PowerShell 5.1." -f $passed)
