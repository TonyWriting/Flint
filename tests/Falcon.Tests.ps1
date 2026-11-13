#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:Consent = 'n'; $script:Prompts = 0; $script:Executions = 0; $script:CommandFailure = $false
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
    if ($script:CommandFailure) { return @{ status = 'error'; exit_code = 1; output = 'ServiceUnavailable'; retryable = $true } }
    return @{ status = 'ok'; exit_code = 0; output = 'Read fixture'; retryable = $false }
}
function Invoke-FalconFixture {
    param([string[]]$Tokens)
    return Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = $Tokens; purpose = 'Change the demo deployment from 3 to 6 replicas in cc-test/team.' }
}
try {
    foreach ($resource in @('applications', 'applications.apis.clusterfleet.io', 'cdd', 'crossclusterdatadeployments.data.falcon.io', 'fleetpods', 'fleetdeployments', 'fleetnodes', 'manifestworks')) {
        $tokens = @('get', $resource, '--context', 'cc-test', '--namespace', 'team', '--output', 'json')
        Assert-True ((Invoke-FalconFixture $tokens).status -eq 'ok') ('Read the reviewed resource: ' + $resource)
        $call = @{ name = 'run_command'; arguments = ConvertTo-Json -Compress @{ executor = 'kubectl'; arguments = $tokens; purpose = 'Inspect the scoped Falcon resource.' } }
        Assert-True ($null -ne (Get-FlintParallelCall $Session $call)) 'Falcon reads use the existing parallel scheduler.'
    }
    foreach ($case in @(
        @{ tokens = @('config', 'get-contexts') },
        @{ tokens = @('api-resources', '--context', 'cc-test', '--api-group', 'apis.clusterfleet.io') },
        @{ tokens = @('api-resources', '--context', 'cc-test', '--api-group', 'data.falcon.io') },
        @{ tokens = @('explain', 'applications.spec.workload', '--context', 'cc-test', '--api-version', 'apis.clusterfleet.io/v1alpha1') },
        @{ tokens = @('describe', 'pods', 'demo', '--context', 'sc-test', '--namespace', 'team') },
        @{ tokens = @('get', 'pods', '--context', 'sc-test', '--namespace', 'team', '--selector', 'app.kubernetes.io/instance=team.demo') },
        @{ tokens = @('get', 'events', '--context', 'sc-test', '--namespace', 'team', '--field-selector', 'involvedObject.name=demo') }
    )) { Assert-True ((Invoke-FalconFixture $case.tokens).status -eq 'ok') 'Discover resources and inspect scoped runtime state without write approval.' }
    Assert-True ($Prompts -eq 0) 'All reviewed reads execute automatically.'
    $count = $Executions
    foreach ($case in @(
        @{ tokens = @('get', 'applications', '--context', 'cc-test') },
        @{ tokens = @('get', 'applications', '--namespace', 'team') },
        @{ tokens = @('get', 'applications', '--context', 'cc-test', '--namespace', 'team', '--watch') },
        @{ tokens = @('get', 'secrets', '--context', 'cc-test', '--namespace', 'team') },
        @{ tokens = @('get', 'unreviewed.apis.clusterfleet.io', '--context', 'cc-test', '--namespace', 'team') },
        @{ tokens = @('get', 'applications', '--context', 'cc-test', '--namespace', 'team', '--server', 'https://other.invalid') }
    )) { Assert-True ((Invoke-FalconFixture $case.tokens).status -eq 'denied') 'Missing scope, extra flags and unreviewed kinds are never promoted to automatic reads.' }
    Assert-True ($Executions -eq $count) 'Denied reads never reach a worker.'

    $patch = '[{"op":"test","path":"/metadata/resourceVersion","value":"15"},{"op":"replace","path":"/spec/workload/0/manifest/spec/replicas","value":6}]'
    $valid = @('patch', 'applications', 'demo', '--context', 'cc-test', '--namespace', 'team', '--type=json', '--patch', $patch)
    $result = Invoke-FalconFixture $valid
    Assert-True ($result.status -eq 'denied' -and $Executions -eq $count) 'A valid Falcon mutation still requires user approval.'
    $guide = Invoke-FlintFileTool $Session.Root read_file @{ path = $result.falcon_guide_path; start_line = 1; start_column = 1; max_lines = 200 } $Session.ProtectedPaths -SessionId $Session.Id
    Assert-True ($guide.status -eq 'ok' -and $guide.output.Contains('resourceVersion') -and $guide.output.Contains('Standard Clusters')) 'The model can read the installed Falcon workflow from an unrelated working directory.'

    $promptsBefore = $Prompts
    foreach ($case in @(
        @{ tokens = @('patch', 'applications', 'demo', '--namespace', 'team', '--type=json', '--patch', $patch) },
        @{ tokens = @('patch', 'applications', 'demo', '--context', 'cc-test', '--type=json', '--patch', $patch) },
        @{ tokens = ($valid + @('--context', 'other')) },
        @{ tokens = ($valid + @('--server', 'https://other.invalid')) },
        @{ tokens = ($valid + @('--subresource', 'status')) },
        @{ tokens = @('patch', 'applications', 'demo', '--context', 'cc-test', '--namespace', 'team', '--type=merge', '--patch', '{"spec":{}}') },
        @{ tokens = @('patch', 'applications', 'demo', '--context', 'cc-test', '--namespace', 'team', '--type=json', '--patch-file', 'change.json') },
        @{ tokens = @('patch', 'application.apis.clusterfleet.io', 'demo', '--context', 'cc-test', '--namespace', 'team', '--type=json', '--patch', '[{"op":"replace","path":"/spec/replicas","value":6}]') },
        @{ tokens = @('patch', 'crossclusterdatadeployments.data.falcon.io', 'demo', '--context', 'cc-test', '--namespace', 'team', '--type=json', '--patch', '[{"op":"replace","path":"/spec/maxUnavailable","value":3}]') },
        @{ tokens = @('patch', 'applications', 'demo', '--context', 'cc-test', '--namespace', 'team', '--type=json', '--patch', '[{"op":"test","path":"/metadata/resourceVersion","value":"15"},{"op":"replace","path":"/status/readyReplicas","value":6}]') },
        @{ tokens = @('patch', 'applications/demo', '--context', 'cc-test', '--namespace', 'team', '--type=json', '--patch', $patch) },
        @{ tokens = @('--context', 'cc-test', 'patch', 'applications', 'demo') },
        @{ tokens = @('edit', 'applications', 'demo', '--context', 'cc-test', '--namespace', 'team') }
    )) { Assert-True ((Invoke-FalconFixture $case.tokens).status -eq 'error') 'Reject ambiguous targets, interactive edits and patches without optimistic concurrency before approval.' }
    Assert-True ($Prompts -eq $promptsBefore -and $Executions -eq $count) 'Invalid changes never prompt or execute.'

    $script:Consent = 'y'
    Assert-True ((Invoke-FalconFixture $valid).status -eq 'ok' -and $Executions -eq ($count + 1)) 'Execute the scoped patch after exact approval.'
    $call = @{ name = 'run_command'; arguments = ConvertTo-Json -Compress @{ executor = 'kubectl'; arguments = $valid; purpose = 'Set the demo deployment to 6 replicas.' } }
    Assert-True ($null -eq (Get-FlintParallelCall $Session $call)) 'Approved Falcon patches remain sequential barriers.'
    $dataPatch = '[{"op":"test","path":"/metadata/resourceVersion","value":"17"},{"op":"replace","path":"/spec/maxUnavailable","value":3}]'
    $dataChange = @('patch', 'crossclusterdatadeployments.data.falcon.io', 'demo', '--context', 'cc-test', '--namespace', 'team', '--type=json', '--patch', $dataPatch)
    $script:Consent = 'n'; $count = $Executions
    Assert-True ((Invoke-FalconFixture $dataChange).status -eq 'denied' -and $Executions -eq $count) 'Application approval never authorizes a data-deployment mutation.'
    $script:Consent = 'y'
    Assert-True ((Invoke-FalconFixture $dataChange).status -eq 'ok' -and $Executions -eq ($count + 1)) 'Approve the separately scoped data.falcon.io change.'
    $script:CommandFailure = $true; $count = $Executions
    Assert-True ((Invoke-FalconFixture $valid).status -eq 'error' -and $Executions -eq ($count + 1)) 'Never automatically retry a Falcon write after a transport failure.'
    Write-Host 'All Falcon tests passed.'
} finally { Remove-TestFixture }
