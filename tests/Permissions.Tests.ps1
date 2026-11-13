#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:Answers = @(); $script:Prompts = 0; $script:Executions = @(); $script:ApprovalDelay = 0
$script:NativeFailure = $false; $script:ProgramSuffix = ''
function Resolve-FlintCommandProgram {
    param($Executor)
    return [ordered]@{ path = (Join-Path $TestRoot ($Executor + $script:ProgramSuffix + '.exe')) }
}
function Read-FlintCommandApproval {
    param($Session, $Invocation)
    $script:Prompts++
    if ($script:ApprovalDelay) { Start-Sleep -Milliseconds $script:ApprovalDelay }
    if ($script:Answers.Count -eq 0) { return $null }
    $answer = $script:Answers[0]; $script:Answers = @($script:Answers | Select-Object -Skip 1)
    return $answer
}
function Invoke-FlintWorker {
    param($Session, $Name, $ToolArguments, $TimeoutSec, $CommandInvocation)
    $script:Executions += @{ arguments = $ToolArguments; timeout = $TimeoutSec; invocation = $CommandInvocation }
    if ($script:NativeFailure) { return @{ status = 'error'; exit_code = 1; output = 'ServiceUnavailable'; retryable = $true } }
    return @{ status = 'ok'; exit_code = 0; output = 'Executed'; retryable = $false }
}
function Invoke-CommandFixture { param([string[]]$Tokens, [string]$Executor = 'kubectl'); Invoke-TestTool run_command @{ executor = $Executor; arguments = $Tokens } }
try {
    $showA = @('get', 'pods', 'a', '--context', 'cluster', '--namespace', 'ns')
    $showB = @('get', 'pods', 'b', '--context', 'cluster', '--namespace', 'ns')
    Assert-True ((Invoke-CommandFixture $showA).status -eq 'ok') 'Execute a known read without approval.'
    Assert-True ((Invoke-CommandFixture $showB).status -eq 'ok') 'Allow resource-name variation in fixed read rules.'
    Assert-True ((Invoke-CommandFixture @('get', 'pods', 'b', '--namespace=ns', '--context=cluster')).status -eq 'ok') 'Match reordered options and equals syntax after the command path.'
    Assert-True ($Prompts -eq 0) 'Never ask for fixed reads.'
    $script:Answers = @('n', 'n', 'n', 'n', 'n')
    foreach ($tokens in @(
        @{ a = @('get', 'pods', 'a', 'b', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = @('get', 'secrets', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = ($showA + @('--debug')) },
        @{ a = ($showA + @('--context', 'other')) },
        @{ a = @('get', '--context', 'delete', 'pods', '--namespace', 'ns') }
    )) { Assert-True ((Invoke-CommandFixture $tokens.a).status -eq 'denied') 'Do not infer safety from a prefix, verb, extra flag, or duplicate option.' }
    Assert-True ($Executions.Count -eq 3) 'Denied commands never reach the worker.'
    Assert-True (-not (Test-Path -LiteralPath $Session.PermissionSessionDirectory)) 'Declining commands never creates an approval file.'

    $script:Answers = @('n')
    Assert-True ((Invoke-CommandFixture @('get', 'pods', '--context', 'cluster', '--namespace', 'ns') kubectl).status -eq 'ok') 'Query configured Kubernetes resource kinds without fixed cluster targets.'
    Assert-True ((Invoke-CommandFixture @('get', 'secrets', '--context', 'cluster', '--namespace', 'ns') kubectl).status -eq 'denied') 'Different resource kinds do not share permission.'
    $unknown = @('new-command', '--foo', 'A', '--bar', 'B')
    $script:Answers = @('y')
    Assert-True ((Invoke-CommandFixture $unknown).status -eq 'ok') 'Approve an unknown invocation.'
    $file = Get-FlintApprovalFile $Session kubectl
    Assert-True (Test-Path -LiteralPath $file) 'Save exact approval under the session and executor.'
    $count = $Prompts
    Assert-True ((Invoke-CommandFixture $unknown).status -eq 'ok' -and $Prompts -eq $count) 'Reuse only an identical approved invocation.'
    $script:Answers = @('n', 'n')
    Assert-True ((Invoke-CommandFixture @('new-command', '--foo', 'C', '--bar', 'B')).status -eq 'denied') 'Changed parameter values require new approval.'
    Assert-True ((Invoke-CommandFixture @('new-command', '--bar', 'B', '--foo', 'A')).status -eq 'denied') 'Unknown argument order is significant.'
    Assert-True ((Invoke-CommandFixture $unknown az).status -eq 'error') 'Reject Azure CLI calls before native command authorization.'
    $script:ProgramSuffix = '-changed'; $script:Answers = @('n')
    Assert-True ((Invoke-CommandFixture $unknown).status -eq 'denied') 'Bind approval to the resolved executable.'
    $script:ProgramSuffix = ''
    $savedConfigDir = $env:KUBECONFIG
    try {
        $env:KUBECONFIG = 'changed-context'; $script:Answers = @('n')
        Assert-True ((Invoke-CommandFixture $unknown).status -eq 'denied') 'Changed environment selectors require approval.'
    } finally { $env:KUBECONFIG = $savedConfigDir }
    $originalId = $Session.Id; $Session.Id = [guid]::NewGuid().ToString('N'); $script:Answers = @('n')
    Assert-True ((Invoke-CommandFixture $unknown).status -eq 'denied') 'A new session never inherits approval.'
    $Session.Id = $originalId
    Assert-True ((Invoke-CommandFixture $unknown).status -eq 'ok') 'The same resumed session can reload its exact approval.'

    $write = @('delete', 'pods', 'a', '--context', 'cluster', '--namespace', 'ns')
    $script:Answers = @('y'); $count = $Prompts
    Assert-True ((Invoke-CommandFixture $write).status -eq 'ok') 'Writes outside the read-only list require confirmation.'
    Assert-True ((Invoke-CommandFixture $write).status -eq 'ok' -and $Prompts -eq ($count + 1)) 'An exact write approval can be reused in the same session.'
    $script:NativeFailure = $true; $count = $Executions.Count
    $null = Invoke-CommandFixture $unknown
    Assert-True ($Executions.Count -eq ($count + 1)) 'Never retry an unknown command, including when it returns a retryable error.'
    $script:Answers = @('y'); $count = $Executions.Count
    $null = Invoke-CommandFixture $write
    Assert-True ($Executions.Count -eq ($count + 1)) 'Never retry an approved write.'
    $script:NativeFailure = $false

    $Session.ToolTimeoutSec = 1; $script:ApprovalDelay = 1300; $script:Answers = @('y')
    Assert-True ((Invoke-CommandFixture @('slow-approval')).status -eq 'ok' -and $Executions[-1].timeout -gt 0.5) 'Human approval does not consume the worker timeout.'
    $script:ApprovalDelay = 0; $Session.ToolTimeoutSec = 30
    $approvalDirectory = $Session.PermissionSessionDirectory
    $Session.PermissionSessionDirectory = Join-Path $TestRoot 'blocked-cache'
    Set-Content -LiteralPath $Session.PermissionSessionDirectory -Value 'not a directory' -Encoding UTF8
    $script:Answers = @('y'); $count = $Executions.Count
    Assert-True ((Invoke-CommandFixture @('cannot-save')).status -eq 'error' -and $Executions.Count -eq $count) 'Do not execute when the approved invocation cannot be persisted.'
    $Session.PermissionSessionDirectory = $approvalDirectory
    $rulesDirectory = $Session.PermissionRulesDirectory
    $Session.PermissionRulesDirectory = Join-Path $TestRoot 'invalid-rules'
    New-Item -ItemType Directory -Path $Session.PermissionRulesDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $Session.PermissionRulesDirectory 'kubectl.json') -Value '{broken' -Encoding UTF8
    $count = $Executions.Count
    Assert-True ((Invoke-CommandFixture $showA).status -eq 'error' -and $Executions.Count -eq $count) 'Malformed fixed rules fail closed.'
    Set-Content -LiteralPath (Join-Path $Session.PermissionRulesDirectory 'kubectl.json') -Value '{"version":1,"executor":"kubectl","rules":[{"command":["vm","restart"],"read_only":false,"options":{}}]}' -Encoding UTF8
    Assert-True ((Invoke-CommandFixture $write).status -eq 'error') 'The Git rule directory accepts only explicitly read-only rules.'
    $Session.PermissionRulesDirectory = $rulesDirectory
    Set-Content -LiteralPath $file -Value '{"version":1,"session_id":"wrong","executor":"kubectl","calls":[]}' -Encoding UTF8
    Assert-True ((Invoke-CommandFixture $unknown).status -eq 'error') 'Reject a mismatched approval file.'
    Remove-Item -LiteralPath $file -Force

    foreach ($arguments in @(
        '{"executor":"kubectl","arguments":"vm show","purpose":"Inspect the fixture."}',
        '{"executor":"kubectl","arguments":[1],"purpose":"Inspect the fixture."}',
        '{"executor":"kubectl","arguments":[],"purpose":"Inspect the fixture."}',
        '{"executor":"cmd","arguments":["/c","echo"],"purpose":"Inspect the fixture."}',
        '{"executor":"kubectl","arguments":["version"],"approved":true,"purpose":"Inspect the fixture."}',
        '{"executor":"kubectl","arguments":["version\nother"],"purpose":"Inspect the fixture."}'
    )) { Assert-True ((Invoke-AgentTool $Session run_command $arguments).status -eq 'error') 'Validate the exact command schema before checking authorization.' }
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\Permissions.ps1')
    $Session.Ui.Live = $false; $count = $Executions.Count
    Assert-True ((Invoke-CommandFixture @('needs-interaction')).status -eq 'approval_required' -and $Executions.Count -eq $count) 'Noninteractive callers cannot manufacture consent.'
    function Read-Host { param($Prompt); return 'yes' }
    $Session.Ui.Live = $true
    Assert-True ((Invoke-CommandFixture @('needs-y')).status -eq 'denied') 'Only explicit y grants approval.'
    function Read-Host { param($Prompt); return 'y' }
    Assert-True ((Invoke-CommandFixture @('needs-y')).status -eq 'ok') 'Read consent through the main-process terminal prompt.'
    $Session.Ui.Live = $false
    $events = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    Assert-True (@($events | Where-Object { $_.event -eq 'command_approval_decided' -and $_.data.allowed }).Count -gt 0) 'Record user decisions in the trajectory.'
    Write-Host 'All permission tests passed.'
} finally { Remove-TestFixture }
