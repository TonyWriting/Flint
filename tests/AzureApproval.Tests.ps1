#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:ApprovalReads = 0
function Read-Host { param($Prompt); $script:ApprovalReads++; return 'n' }
function Resolve-FlintCommandProgram { param($Executor); return @{ path = (Join-Path $TestRoot ($Executor + '.exe')) } }
try {
    $app = New-TestRuntime (Join-Path $TestRoot 'app')
    Add-Content -LiteralPath (Join-Path $app 'tools\azure\Http.ps1') -Encoding UTF8 -Value @'
function Invoke-WebRequest {
    [CmdletBinding()]param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, [switch]$UseBasicParsing, $Body, $ContentType)
    if ($Method -cne 'POST' -or $Headers.Authorization -cne 'Bearer test-arg-token' -or $MaximumRedirection -ne 0) { throw 'Incorrect Resource Graph transport.' }
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'queries.txt') -Value $Body
    if ($Body.Contains('fixture_retry')) {
        $marker = Join-Path $PSScriptRoot 'retry-once.txt'
        if (-not (Test-Path -LiteralPath $marker)) {
            Set-Content -LiteralPath $marker -Value 'once'
            try { throw 'Temporarily unavailable.' } catch { $exception = $_.Exception }
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 503 } -Force
            Write-Error -Exception $exception -Message '{"error":{"code":"ServiceUnavailable"}}' -ErrorAction Stop
        }
    }
    return @{ StatusCode = 200; Content = '{"data":[],"count":0,"totalRecords":0,"resultTruncated":false}' }
}
'@
    $Session.WorkerPath = Join-Path $app 'tools\Worker.ps1'
    $Session.Azure = @{ Status = 'ready'; Account = 'user@example.com'; Tenant = '11111111-1111-1111-1111-111111111111'; AccessToken = 'test-arg-token'; ExpiresUtc = [datetime]::UtcNow.AddHours(1) }
    Initialize-FlintUi $Session
    $Session.Ui.Live = $false
    $body = '{"subscriptions":["22222222-2222-2222-2222-222222222222"],"query":"resources | where type =~ ''microsoft.network/trafficmanagerprofiles'' | summarize count()","options":{"resultFormat":"objectArray","$top":1000}}'
    $route = '/providers/Microsoft.ResourceGraph/resources?api-version='
    foreach ($version in @('2021-03-01', '2022-10-01', '2024-04-01')) {
        $result = Invoke-TestTool azure_request @{ method = 'POST'; path = $route + $version; body = $body; purpose = 'Count Traffic Manager profiles in the specified subscription.' }
        Assert-True ($result.status -eq 'ok' -and $result.http_status -eq 200 -and $result.result_id -and $result.duration_ms -gt 0) 'Execute reviewed Resource Graph queries through the real worker without approval.'
    }
    Assert-True ($ApprovalReads -eq 0 -and -not (Test-Path -LiteralPath $Session.PermissionSessionDirectory)) 'Read rules never manufacture session write approvals.'
    $trace = Join-Path $app 'tools\azure\queries.txt'
    $calls = @(Get-Content -LiteralPath $trace)
    Assert-True ($calls.Count -eq 3 -and $calls[0] -ceq $body) 'Transmit only the requested query body, without the model purpose field.'

    foreach ($case in @(
        @{ method = 'PUT'; path = $route + '2024-04-01'; body = $body },
        @{ method = 'DELETE'; path = $route + '2024-04-01'; body = '' },
        @{ method = 'POST'; path = '/providers/Microsoft.ResourceGraph/resources/delete?api-version=2024-04-01'; body = $body },
        @{ method = 'POST'; path = '/providers/Microsoft.ResourceGraph/%72esources?api-version=2024-04-01'; body = $body },
        @{ method = 'POST'; path = $route + '2024-04-01&operation=delete'; body = $body },
        @{ method = 'POST'; path = $route + '2099-01-01'; body = $body },
        @{ method = 'POST'; path = $route + '2024-04-01'; body = '{"query":"resources","operation":"delete"}' },
        @{ method = 'POST'; path = $route + '2024-04-01'; body = '[{"query":"resources"}]' },
        @{ method = 'POST'; path = $route + '2024-04-01'; body = '{"query":[]}' },
        @{ method = 'POST'; path = $route + '2024-04-01'; body = '{"query":" "}' },
        @{ method = 'PUT'; path = '/subscriptions/SUB/resourceGroups/RG/providers/Microsoft.ResourceGraph/queries/saved?api-version=2024-04-01'; body = '{"properties":{"query":"resources"}}' },
        @{ method = 'POST'; path = '/subscriptions/SUB/resourceGroups/RG/providers/Microsoft.Compute/virtualMachines/vm/restart?api-version=2024-03-01'; body = '' }
    )) {
        $case.purpose = 'This is a safe read-only operation.'
        Assert-True ((Invoke-TestTool azure_request $case).status -eq 'approval_required') 'Related paths, encoded paths, unknown versions and mutation methods still need approval regardless of the model claim.'
    }
    Assert-True (@(Get-Content -LiteralPath $trace).Count -eq 3) 'Requests requiring approval never reach HTTP without consent.'

    $retryBody = '{"query":"resources | limit 1 // fixture_retry"}'
    $result = Invoke-TestTool azure_request @{ method = 'POST'; path = $route + '2024-04-01'; body = $retryBody; purpose = 'Read one resource in the retry fixture.' }
    Assert-True ($result.status -eq 'ok' -and @(Get-Content -LiteralPath $trace).Count -eq 5) 'Reviewed POST queries use the same read-only retry pipeline as GET.'

    $request = @{ method = 'POST'; path = '/subscriptions/SUB/resourceGroups/RG/providers/Microsoft.Compute/virtualMachines/vm/restart?api-version=2024-03-01'; body = ''; purpose = 'Restart VM vm in RG; its workload may be temporarily unavailable.' }
    $Session.Ui.Live = $true
    $messages = @(& { Invoke-TestTool azure_request $request } 6>&1)
    $result = $messages[-1]
    $screen = ($messages | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    Assert-True ($result.status -eq 'denied' -and $screen.Contains('Purpose (model-provided): ' + $request.purpose) -and $screen.Contains('POST https://management.azure.com' + $request.path)) 'Show the model purpose and exact HTTP request together before approval.'
    $original = New-FlintAzureInvocation $Session $request
    $request.purpose = 'Another explanation of the same restart.'
    $reworded = New-FlintAzureInvocation $Session $request
    Assert-True ((ConvertTo-Json $original -Compress) -ceq (ConvertTo-Json $reworded -Compress)) 'Bind authorization to the actual request instead of explanatory wording.'

    $command = @{ executor = 'kubectl'; arguments = @('delete', 'pod', 'pod-a', '--context', 'cluster-a', '--namespace', 'ns-a'); purpose = 'Delete pod-a in ns-a on cluster-a; its controller may recreate it.' }
    $messages = @(& { Invoke-TestTool run_command $command } 6>&1)
    $screen = ($messages | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    Assert-True ($messages[-1].status -eq 'denied' -and $screen.Contains('Purpose (model-provided): ' + $command.purpose) -and $screen.Contains('pod-a') -and $screen.Contains('Executable:')) 'Show the same explanation for unclassified native commands.'

    $promptCount = $ApprovalReads
    foreach ($purpose in @('', ' ', ('x' * 1001), "line one`nline two", ([string][char]27 + '[31m'))) {
        Assert-True ((Invoke-TestTool azure_request @{ method = 'POST'; path = $route + '2024-04-01'; body = $body; purpose = $purpose }).status -eq 'error') 'Reject missing, excessive or terminal-controlling purpose text.'
        Assert-True ((Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('unknown'); purpose = $purpose }).status -eq 'error') 'Validate native-command purpose before approval.'
    }
    Assert-True ((Invoke-AgentTool $Session azure_request '{"method":"GET","path":"/subscriptions?api-version=2022-12-01","body":""}').status -eq 'error') 'Require the purpose field in the current Azure schema.'
    Assert-True ((Invoke-AgentTool $Session run_command '{"executor":"kubectl","arguments":["unknown"]}').status -eq 'error') 'Require the purpose field in the current native-command schema.'
    Assert-True ($ApprovalReads -eq $promptCount) 'Invalid descriptions never reach the user approval prompt.'
    $events = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    Assert-True (@($events | Where-Object { $_.event -eq 'azure_permission' -and $_.data.source -eq 'resource_graph_query' }).Count -ge 4) 'Record the concrete read rule used for automatic execution.'
    Assert-True (@($events | Where-Object { $_.event -in @('azure_approval_requested', 'command_approval_requested') -and $_.data.purpose }).Count -ge 2) 'Record the explanation alongside approval requests.'
    Write-Host 'All Azure and command approval tests passed.'
} finally { Remove-TestFixture }
