#Requires -Version 5.1
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'TestSupport.ps1')
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
    $readCall = @{ name = 'run_command'; arguments = (ConvertTo-Json -Compress @{ executor = 'kubectl'; arguments = $showA; purpose = 'Read the scoped test pod.' }) }
    Assert-True ((Invoke-CommandFixture $showA).status -eq 'ok') 'Execute a known read without approval.'
    Assert-True ($null -ne (Get-FlintParallelCall $Session $readCall)) 'Apply the same reviewed rule to parallel reads.'
    Assert-True ((Invoke-CommandFixture $showB).status -eq 'ok') 'Allow resource-name variation in fixed read rules.'
    Assert-True ((Invoke-CommandFixture @('get', 'pods', 'b', '--namespace=ns', '--context=cluster')).status -eq 'ok') 'Match reordered options and equals syntax after the command path.'
    $logs = @('logs', 'a', '--context', 'cluster', '--namespace', 'ns', '--tail', '200', '--previous', '--container', 'app')
    Assert-True ((Invoke-CommandFixture $logs).status -eq 'ok') 'Read a bounded log tail of one pod without approval.'
    Assert-True ((Invoke-CommandFixture @('get', 'pods', 'a', 'b', '--context', 'cluster', '--namespace', 'ns')).status -eq 'ok') 'Read several named objects of one kind without approval.'
    foreach ($tokens in @(
        @{ a = @('get', 'pods,services', '--context', 'cluster', '--namespace', 'ns', '--output', 'json') },
        @{ a = @('get', 'pods,services', 'a', 'b', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = @('get', 'deployments/a', 'services/a', 'services/a-lb', '--context', 'cluster', '--namespace', 'ns', '--output', 'json') },
        @{ a = @('describe', 'pods/a', '--context', 'cluster', '--namespace', 'ns') }
    )) { Assert-True ((Invoke-CommandFixture $tokens.a).status -eq 'ok') ('Read several kinds, or TYPE/NAME pairs, when every kind matches a rule: ' + ($tokens.a -join ' ')) }
    $combinedCall = @{ name = 'run_command'; arguments = (ConvertTo-Json -Compress @{ executor = 'kubectl'; arguments = @('get', 'deployments/a', 'services/a', '--context', 'cluster', '--namespace', 'ns'); purpose = 'Read two kinds.' }) }
    Assert-True ($null -ne (Get-FlintParallelCall $Session $combinedCall)) 'Combined reads join the parallel scheduler.'
    Assert-True ($Prompts -eq 0) 'Never ask for fixed reads.'
    $pairs = @(@('get') + @(foreach ($index in 1..11) { 'pods/pod' + $index }) + @('--context', 'cluster', '--namespace', 'ns'))
    $script:Answers = @('n', 'n', 'n', 'n', 'n', 'n', 'n'); $count = $Executions.Count
    foreach ($tokens in @(
        @{ a = @('get', 'pods,secrets', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = @('get', 'pods,', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = @('get', 'pods,services', '--context', 'cluster') },
        @{ a = @('get', 'pods/a', 'b', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = @('get', 'pods/a/b', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = @('get', 'pods,services/a', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = $pairs }
    )) { Assert-True ((Invoke-CommandFixture $tokens.a).status -eq 'denied') ('A combined read needs approval unless every part matches a rule: ' + ($tokens.a -join ' ')) }
    Assert-True ($Executions.Count -eq $count -and $Prompts -eq 7) 'Combined reads outside the rules never run without approval.'
    $script:Prompts = 0
    $tooMany = @(@('get', 'pods') + @(foreach ($index in 1..11) { 'pod' + $index }) + @('--context', 'cluster', '--namespace', 'ns')); $count = $Executions.Count
    $script:Answers = @('n', 'n', 'n', 'n', 'n', 'n', 'n', 'n')
    foreach ($tokens in @(
        @{ a = ($logs + @('--follow')) },
        @{ a = @('logs', 'a', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = @('logs', 'a', '--context', 'cluster', '--namespace', 'ns', '--tail', '5000') },
        @{ a = $tooMany },
        @{ a = @('get', 'secrets', '--context', 'cluster', '--namespace', 'ns') },
        @{ a = ($showA + @('--debug')) },
        @{ a = ($showA + @('--context', 'other')) },
        @{ a = @('get', '--context', 'delete', 'pods', '--namespace', 'ns') }
    )) { Assert-True ((Invoke-CommandFixture $tokens.a).status -eq 'denied') 'Do not infer safety from a prefix, verb, extra flag, or duplicate option.' }
    Assert-True ($Executions.Count -eq $count) 'Denied commands never reach the worker.'
    Assert-True (@($Session.Approvals.kubectl).Count -eq 0) 'Declining commands never records an approval.'

    $script:Answers = @('n')
    Assert-True ((Invoke-CommandFixture @('get', 'pods', '--context', 'cluster', '--namespace', 'ns') kubectl).status -eq 'ok') 'Query configured Kubernetes resource kinds without fixed cluster targets.'
    Assert-True ((Invoke-CommandFixture @('get', 'secrets', '--context', 'cluster', '--namespace', 'ns') kubectl).status -eq 'denied') 'Different resource kinds do not share permission.'
    $unknown = @('new-command', '--foo', 'A', '--bar', 'B')
    $script:Answers = @('y')
    Assert-True ((Invoke-CommandFixture $unknown).status -eq 'ok') 'Approve an unknown invocation.'
    Assert-True (@($Session.Approvals.kubectl).Count -eq 1) 'Keep the exact approval for this session.'
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
    # Approvals live in memory, so a new Flint process, including -Resume, starts without them.
    $granted = $Session.Approvals.kubectl; $Session.Approvals.kubectl = @(); $script:Answers = @('n')
    Assert-True ((Invoke-CommandFixture $unknown).status -eq 'denied') 'A new Flint process never inherits approval.'
    $Session.Approvals.kubectl = $granted
    Assert-True ((Invoke-CommandFixture $unknown).status -eq 'ok') 'An exact approval lasts for the rest of the process.'

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
    $rulesFile = Join-Path $TestRoot 'invalid-kubectl.json'
    Set-Content -LiteralPath $rulesFile -Value '{broken' -Encoding UTF8
    Assert-Throws { Read-FlintCommandRuleFile $rulesFile kubectl core } '*not valid JSON*'
    Set-Content -LiteralPath $rulesFile -Value '{"version":1,"executor":"kubectl","rules":[{"command":["vm","restart"],"read_only":false,"options":{}}]}' -Encoding UTF8
    Assert-Throws { Read-FlintCommandRuleFile $rulesFile kubectl core } '*read-only*'
    Assert-True ((@($Session.CommandRules.kubectl) | Where-Object { $_.source -cne 'core' }).Count -eq 0) 'Without plugins, every loaded rule comes from the installation.'
    $loadedRules = $Session.CommandRules
    $Session.CommandRules = @{ kubectl = @() }
    $script:Answers = @('n'); $count = $Executions.Count
    Assert-True ((Invoke-CommandFixture $showA).status -eq 'denied' -and $Executions.Count -eq $count) 'Without loaded rules, reads need approval.'
    Assert-True ($null -eq (Get-FlintParallelCall $Session $readCall)) 'Without loaded rules, reads stay sequential.'
    $Session.CommandRules = $loadedRules
    Assert-True ($null -ne (Get-FlintParallelCall $Session $readCall)) 'Re-evaluate restored rules without retaining a stale decision.'
    $events = @(Get-TestEvents)
    Assert-True (@($events | Where-Object { $_.event -eq 'command_permission' -and $_.data.source -eq 'fixed_read' -and $_.data.rule_source -ceq 'core' }).Count -gt 0) 'Record which rule set authorized each automatic read.'


    foreach ($arguments in @(
        '{"executor":"kubectl","arguments":"vm show","purpose":"Inspect the fixture."}',
        '{"executor":"kubectl","arguments":[1],"purpose":"Inspect the fixture."}',
        '{"executor":"kubectl","arguments":[],"purpose":"Inspect the fixture."}',
        '{"executor":"cmd","arguments":["/c","echo"],"purpose":"Inspect the fixture."}',
        '{"executor":"kubectl","arguments":["version"],"approved":true,"purpose":"Inspect the fixture."}',
        '{"executor":"kubectl","arguments":["version\nother"],"purpose":"Inspect the fixture."}'
    )) { Assert-True ((Invoke-AgentTool $Session run_command $arguments).status -eq 'error') 'Validate the exact command schema before checking authorization.' }
    . (Join-Path $RepoRoot 'lib\Permissions.ps1')
    $Session.Ui.Live = $false; $count = $Executions.Count
    Assert-True ((Invoke-CommandFixture @('needs-interaction')).status -eq 'approval_required' -and $Executions.Count -eq $count) 'Noninteractive callers cannot manufacture consent.'
    $script:Replies = @(); $script:Reads = 0; $script:PromptTexts = @()
    function Read-Host {
        param($Prompt)
        $script:Reads++; $script:PromptTexts += $Prompt
        if ($script:Replies.Count -eq 0) { throw 'No reply is scripted.' }
        $reply = $script:Replies[0]; $script:Replies = @($script:Replies | Select-Object -Skip 1)
        return $reply
    }
    $Session.Ui.Live = $true
    $script:Replies = @('', 'yes', ' n ')
    $messages = @(& { Invoke-CommandFixture @('needs-y') } 6>&1)
    $screen = ($messages | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    Assert-True ($messages[-1].status -eq 'denied' -and $script:Reads -eq 3 -and $screen.Contains('Type y or n.')) 'Ask again after a bare Enter or another reply, until the answer is y or n.'
    Assert-True (@($script:PromptTexts | Where-Object { $_ -cne 'y/n' }).Count -eq 0) 'Offer no default answer.'
    $script:Replies = @('Y'); $script:Reads = 0
    Assert-True ((Invoke-CommandFixture @('needs-y')).status -eq 'ok' -and $script:Reads -eq 1) 'Read consent through the main-process terminal prompt.'
    $script:Reads = 0
    Assert-True ((Invoke-CommandFixture @('needs-z')).status -eq 'approval_required' -and $script:Reads -eq 1) 'Stop asking and take no action when the prompt cannot read.'
    $Session.Ui.Live = $false
    $events = @(Get-TestEvents)
    Assert-True (@($events | Where-Object { $_.event -eq 'command_approval_decided' -and $_.data.allowed }).Count -gt 0) 'Record user decisions in the trajectory.'
    Write-Host 'All permission tests passed.'
} finally { Remove-TestFixture }
