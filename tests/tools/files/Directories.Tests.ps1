#Requires -Version 5.1
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'TestSupport.ps1')
$script:Answers = @(); $script:AskedDirectories = @()
function Read-FlintDirectoryApproval {
    param($Session, $Directory, $Target, $Operation)
    $script:AskedDirectories += $Directory
    if ($script:Answers.Count -eq 0) { return $null }
    $answer = $script:Answers[0]; $script:Answers = @($script:Answers | Select-Object -Skip 1)
    return $answer
}
try {
    $outside = Join-Path $TestRoot 'outside'
    $sibling = Join-Path $TestRoot 'outside-other'
    foreach ($directory in @($outside, $sibling)) { New-Item -ItemType Directory -Path $directory | Out-Null }
    Set-Content -LiteralPath (Join-Path $outside 'input.txt') -Value 'external input' -Encoding UTF8 -NoNewline
    Assert-True ((Invoke-TestTool read_file @{ path = (Join-Path $outside 'input.txt') }).output -ceq 'external input') 'Read an external absolute path automatically.'
    Assert-True ((Invoke-TestTool read_file @{ path = '..\outside\input.txt' }).output -ceq 'external input') 'Resolve external relative reads against the working directory.'
    Assert-True ((Invoke-TestTool list_files @{ path = $outside }).status -eq 'ok') 'List external directories automatically.'
    Assert-True ($AskedDirectories.Count -eq 0) 'Reads never request directory write permission.'
    Assert-True ((Invoke-TestTool create_directory @{ path = 'nested' }).status -eq 'ok') 'Create a directory inside the workspace directly.'
    Assert-True ((Invoke-TestTool write_file @{ path = 'nested\local.txt'; content = 'local' }).status -eq 'ok') 'Write within workspace descendants directly.'
    Assert-True ($AskedDirectories.Count -eq 0) 'Workspace mutations do not ask for consent.'

    $target = Join-Path $outside 'output.txt'
    $script:Answers = @('n')
    Assert-True ((Invoke-TestTool write_file @{ path = $target; content = 'denied' }).status -eq 'denied') 'Decline external writes before worker execution.'
    Assert-True (-not (Test-Path -LiteralPath $target) -and @($Session.Approvals.files).Count -eq 0) 'Declining neither modifies files nor saves authorization.'
    $script:Answers = @('y')
    Assert-True ((Invoke-TestTool write_file @{ path = $target; content = 'first' }).status -eq 'ok') 'Authorize and perform an external write.'
    Assert-True ($AskedDirectories[-1] -ceq $outside) 'Request permission for the containing directory, not the whole drive.'
    $count = $AskedDirectories.Count
    Assert-True ((Invoke-TestTool write_file @{ path = (Join-Path $outside 'second.txt'); content = 'second' }).status -eq 'ok') 'Directory consent covers another file in the directory.'
    Assert-True ((Invoke-TestTool edit_file @{ path = $target; old_str = 'first'; new_str = 'updated' }).status -eq 'ok') 'Directory consent covers edits.'
    Assert-True ((Invoke-TestTool create_directory @{ path = (Join-Path $outside 'child') }).status -eq 'ok') 'Directory consent covers creating descendants.'
    Assert-True ((Invoke-TestTool write_file @{ path = (Join-Path $outside 'child\nested.txt'); content = 'nested' }).status -eq 'ok') 'Directory consent covers descendant files.'
    Assert-True ($AskedDirectories.Count -eq $count) 'Reuse directory authorization throughout the same session.'
    $script:Answers = @('n')
    Assert-True ((Invoke-TestTool write_file @{ path = '..\outside-other\blocked.txt'; content = 'blocked' }).status -eq 'denied') 'Directory matching respects path boundaries and normalized traversal.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sibling 'blocked.txt'))) 'Do not authorize similarly prefixed sibling directories.'

    # Directory grants live in memory, so a new Flint process, including -Resume, starts without them.
    $granted = $Session.Approvals.files
    $Session.Approvals.files = @(); $script:Answers = @('n')
    Assert-True ((Invoke-TestTool write_file @{ path = $target; content = 'new session' }).status -eq 'denied') 'A new Flint process cannot reuse directory authorization.'
    Assert-True ((Get-Content -LiteralPath $target -Raw -Encoding UTF8) -ceq 'updated') 'Denied writes preserve existing content.'
    $Session.Approvals.files = $granted
    Assert-True ((Invoke-TestTool write_file @{ path = $target; content = 'resumed' }).status -eq 'ok') 'Directory authorization lasts for the rest of the process.'
    $newDirectory = Join-Path $TestRoot 'new-output'
    $script:Answers = @('y')
    Assert-True ((Invoke-TestTool create_directory @{ path = $newDirectory }).status -eq 'ok' -and $AskedDirectories[-1] -ceq $newDirectory) 'Creating an external directory authorizes that directory and its descendants.'
    Assert-True ((Invoke-TestTool write_file @{ path = (Join-Path $newDirectory 'report.txt'); content = 'report' }).status -eq 'ok') 'Reuse the newly created directory grant.'
    Assert-True ((Invoke-TestTool create_directory @{ path = 'missing-parent\child' }).status -eq 'error') 'Require an existing parent instead of creating unapproved ancestors.'
    Assert-True ((Invoke-TestTool write_file @{ path = (Join-Path $outside '.env'); content = 'forbidden' }).status -eq 'error') 'Directory consent never bypasses credential protection.'
    Assert-Throws { Invoke-FlintFileTool $WorkRoot write_file @{ path = (Join-Path $sibling 'direct.txt'); content = 'forbidden' } @() } '*requires directory authorization*'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sibling 'direct.txt'))) 'The worker also requires an external write directory.'
    . (Join-Path $RepoRoot 'lib\Permissions.ps1')
    $Session.Ui.Live = $false
    Assert-True ((Invoke-TestTool create_directory @{ path = (Join-Path $TestRoot 'no-terminal') }).status -eq 'approval_required') 'Noninteractive directory creation requires prior authorization.'
    Write-Host 'All directory authorization tests passed.'
} finally { Remove-TestFixture }
