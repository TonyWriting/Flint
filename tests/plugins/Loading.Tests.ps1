#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
$script:Consent = 'n'; $script:Prompts = 0; $script:Executions = 0
function Resolve-FlintCommandProgram {
    param($Executor)
    return [ordered]@{ path = (Join-Path $TestRoot 'kubectl.exe') }
}
function Read-FlintCommandApproval {
    param($Session, $Invocation, $Purpose)
    $script:Prompts++
    return $script:Consent
}
function Invoke-FlintWorker {
    param($Session, $Name, $ToolArguments, $TimeoutSec, $CommandInvocation)
    $script:Executions++
    return @{ status = 'ok'; exit_code = 0; output = 'Executed'; retryable = $false }
}
function Invoke-WidgetCommand {
    param([string[]]$Tokens)
    return Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = $Tokens; purpose = 'Inspect or change the scoped test widget.' }
}
try {
    $plugins = Get-FlintPluginDirectory
    $null = New-TestPlugin (Join-Path $plugins 'example')
    $null = New-TestPlugin (Join-Path $plugins 'broken') -Name 'broken' -Manifest @{ guide = 'missing.md' }
    $null = New-TestPlugin (Join-Path $plugins 'renamed') -Name 'other'
    $null = New-TestPlugin (Join-Path $plugins '.staging-0123') -Name 'staged'
    $baseTools = ConvertTo-Json -InputObject $Session.Tools -Depth 16 -Compress
    $baseInstructions = $Session.Instructions
    $script:Session = New-TestSession

    Assert-True (@($Session.Plugins).Count -eq 1 -and $Session.Plugins[0].name -ceq 'example') 'Load valid plugins and skip staging directories.'
    $errors = @($Session.PluginErrors | ForEach-Object { $_.name }) -join ','
    Assert-True ($errors -ceq 'broken,renamed') ('Report invalid and misnamed plugins without loading them: ' + $errors)
    Assert-True ((@($Session.PluginErrors | Where-Object { $_.name -ceq 'renamed' })[0].message) -like "*must match the plugin name 'other'*") 'Explain a directory and manifest name mismatch.'
    Assert-True ((@($Session.CommandRules.kubectl | Where-Object { $_.source -ceq 'plugin:example' })).Count -eq 2) 'Merge plugin rules with the installation rules.'
    Assert-True ((@($Session.GuardedPatchResources) -join ',') -ceq 'widgets,widgets.example.io') 'Collect guarded resources from loaded plugins only.'
    Assert-True ((ConvertTo-Json -InputObject $Session.Tools -Depth 16 -Compress) -ceq $baseTools -and $Session.Tools.Count -eq 9) 'Plugins never change tool definitions.'
    Assert-True ($Session.Instructions.StartsWith($baseInstructions) -and $Session.Instructions.Contains('Installed plugins:') -and
        $Session.Instructions.Contains('- example 1.0.0: Fictional widgets') -and $Session.Instructions.Contains('  Guide: ' + $Session.Plugins[0].guide)) 'Describe installed plugins after the fixed instructions.'
    $events = @(Get-TestEvents)
    $start = @($events | Where-Object { $_.event -eq 'session_started' })[0]
    Assert-True ($start.data.plugins[0].name -ceq 'example' -and $start.data.plugins[0].rules -eq 2 -and @($start.data.plugin_errors).Count -eq 2) 'Record the plugin set in the trajectory.'
    $banner = (Show-FlintSession $Session 6>&1 | Out-String)
    Assert-True ($banner.Contains('Plugins: example 1.0.0') -and $banner.Contains("Plugin 'broken' was not loaded")) 'Show loaded and skipped plugins at startup.'
    $details = (Show-FlintSession $Session -Details 6>&1 | Out-String)
    Assert-True ($details.Contains('Plugin example 1.0.0: 2 reviewed reads, 2 guarded resources') -and $details.Contains('guide refers to')) 'Show plugin details and errors in /status.'

    $read = @('get', 'widgets.example.io', '--context', 'cluster', '--namespace', 'team', '--output', 'json')
    Assert-True ((Invoke-WidgetCommand $read).status -eq 'ok' -and $Prompts -eq 0) 'Plugin rules authorize reviewed reads automatically.'
    $events = @(Get-TestEvents)
    Assert-True (@($events | Where-Object { $_.event -eq 'command_permission' -and $_.data.rule_source -ceq 'plugin:example' }).Count -eq 1) 'Attribute the automatic read to the plugin.'
    $call = @{ name = 'run_command'; arguments = ConvertTo-Json -Compress @{ executor = 'kubectl'; arguments = $read; purpose = 'Inspect the scoped widget.' } }
    $plan = Get-FlintParallelCall $Session $call
    Assert-True ($null -ne $plan -and $plan.rule_source -ceq 'plugin:example') 'Plugin reads join the parallel scheduler.'
    $count = $Executions
    foreach ($tokens in @(
        @('get', 'widgets.example.io', '--namespace', 'team'),
        @('get', 'widgets.example.io', '--context', 'cluster', '--namespace', 'team', '--watch'),
        @('get', 'gadgets.example.io', '--context', 'cluster', '--namespace', 'team')
    )) { Assert-True ((Invoke-WidgetCommand $tokens).status -eq 'denied') 'Unreviewed shapes still need approval.' }
    Assert-True ($Executions -eq $count) 'Denied reads never execute.'

    $patch = '[{"op":"test","path":"/metadata/resourceVersion","value":"15"},{"op":"replace","path":"/spec/replicas","value":6}]'
    $valid = @('patch', 'widgets', 'demo', '--context', 'cluster', '--namespace', 'team', '--type=json', '--patch', $patch)
    $promptsBefore = $Prompts
    foreach ($tokens in @(
        @('patch', 'widgets.example.io', 'demo', '--context', 'cluster', '--namespace', 'team', '--type=json', '--patch', '[{"op":"replace","path":"/spec/replicas","value":6}]'),
        @('patch', 'widgets', 'demo', '--context', 'cluster', '--namespace', 'team', '--type=merge', '--patch', '{"spec":{}}'),
        @('patch', 'widgets', 'demo', '--context', 'cluster', '--namespace', 'team', '--type=json', '--patch', '[{"op":"test","path":"/metadata/resourceVersion","value":"15"},{"op":"replace","path":"/status/ready","value":true}]'),
        @('patch', 'widgets/demo', '--context', 'cluster', '--namespace', 'team', '--type=json', '--patch', $patch),
        ($valid + @('--server', 'https://other.invalid'))
    )) {
        $result = Invoke-WidgetCommand $tokens
        Assert-True ($result.status -eq 'error' -and $result.output -like '*') 'Reject guarded patches without the reviewed shape before approval.'
    }
    Assert-True ($Prompts -eq $promptsBefore -and $Executions -eq $count) 'Invalid guarded patches never prompt or execute.'
    Assert-True ((Invoke-WidgetCommand $valid).status -eq 'denied' -and $Prompts -eq ($promptsBefore + 1)) 'A valid guarded patch still needs approval.'
    $script:Consent = 'y'
    Assert-True ((Invoke-WidgetCommand $valid).status -eq 'ok' -and $Executions -eq ($count + 1)) 'Execute the guarded patch after exact approval.'
    $script:Consent = 'n'
    $merge = @('patch', 'deployments', 'demo', '--context', 'cluster', '--namespace', 'team', '--type=merge', '--patch', '{"spec":{"replicas":2}}')
    Assert-True ((Invoke-WidgetCommand $merge).status -eq 'denied') 'Resources that no plugin guards keep the normal approval path.'

    # The worker re-checks the guarded shape from its request, independently of the main process.
    $invalid = @('patch', 'widgets', 'demo', '--context', 'cluster', '--namespace', 'team', '--type=merge', '--patch', '{}')
    $parsed = @{ executor = 'kubectl'; arguments = $invalid }
    $invocation = @{ executor = 'kubectl'; arguments = $invalid; working_directory = $WorkRoot }
    Assert-Throws { Invoke-FlintCommand $WorkRoot $parsed $invocation 5 -GuardedResources @('widgets') } '*--type=json for guarded patches*'
    $worker = New-FlintWorkerRequest $Session run_command $parsed -TimeoutSec 5 -CommandInvocation $invocation
    try {
        $request = ConvertFrom-Json (Get-Content -LiteralPath $worker.request_path -Raw -Encoding UTF8)
        Assert-True ((@($request.guarded_patch_resources) -join ',') -ceq 'widgets,widgets.example.io') 'Send the session guarded resources to the worker.'
        Assert-True ($null -eq $request.command_invocation.guarded_patch_resources) 'Keep guarded resources out of the approval signature.'
    } finally { Remove-FlintWorkerRequest $worker }

    $guide = Invoke-FlintFileTool $Session.Root read_file @{ path = $Session.Plugins[0].guide; start_line = 1; start_column = 1; max_lines = 50 } $Session.ProtectedPaths -SessionId $Session.Id
    Assert-True ($guide.status -eq 'ok' -and $guide.output.Contains('reconciled by the example controller')) 'The model can read the plugin guide named in its instructions.'

    # A resumed conversation uses the plugins installed now and keeps its history as saved.
    Write-FlintCheckpoint $Session
    $historyCount = @($Session.History).Count
    $null = New-TestPlugin (Join-Path $plugins 'example') -Version '1.1.0'
    $null = New-TestPlugin (Join-Path $plugins 'extra') -Name 'extra'
    $changed = New-TestSession -Resume $Session.Id
    Assert-True ($changed.Instructions.Contains('- example 1.1.0:') -and $changed.Instructions.Contains('- extra 1.0.0:') -and @($changed.History).Count -eq $historyCount) 'Resumed sessions use the plugins installed now.'

    $old = New-TestSession
    Write-FlintEvent $old 'session_checkpoint' @{ version = 2; root = $old.Root; model = $old.Model; history_count = 0; omitted_call_ids = @(); state = @{} }
    Assert-Throws { New-TestSession -Resume $old.Id } '*earlier Flint versions*'

    # Plugin summaries reach the instructions, which requests do not redact again.
    $null = New-TestPlugin (Join-Path $plugins 'leaky') -Name 'leaky' -Manifest @{ summary = 'Leaky widgets. password=hunter2' }
    $leaky = New-TestSession
    $sent = ConvertTo-Json -InputObject (New-FlintPayload $leaky) -Depth 64 -Compress
    Assert-True ($leaky.Instructions.Contains('- leaky 1.0.0: Leaky widgets. password="[redacted]"') -and -not $sent.Contains('hunter2')) 'Redact plugin summaries in the instructions once per session.'
    Write-Host 'All plugin loading tests passed.'
} finally { Remove-TestFixture }
