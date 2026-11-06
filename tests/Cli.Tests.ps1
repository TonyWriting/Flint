#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
try {
    $cliPath = Join-Path (New-TestRuntime (Join-Path $TestRoot 'app')) 'agent.ps1'
    $launcher = Join-Path $TestRoot 'launch.ps1'
    Set-Content -LiteralPath $launcher -Encoding ASCII -Value @(
        'param($CliPath, $ConfigPath, $LogDirectory, $WorkRoot, $ResumeId, [switch]$SinglePrompt, [string]$ReportedVersion, [string]$AzureTenant)'
        'if ($ReportedVersion) { $PSVersionTable[''PSVersion''] = [version]$ReportedVersion }'
        'if ($ExecutionContext.SessionState.LanguageMode -ne ''ConstrainedLanguage'') { $ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage'' }'
        @'
if ($WorkRoot) { Set-Location -LiteralPath $WorkRoot }
$azureArguments = @{}
if ($AzureTenant) { $azureArguments.AzureTenant = $AzureTenant }
if ($SinglePrompt) {
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, $ErrorAction, $ContentType, $Body, $OutFile)
        $request = ConvertFrom-Json -InputObject $Body
        if ('function_call_output' -in $request.input.type) {
            $items = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Report created and updated.' }) })
        } else {
            $items = @(
                @{ type = 'function_call'; call_id = 'create_report'; name = 'write_file'; arguments = '{"path":"prompt-report.md","content":"# Report\n\ndraft."}' },
                @{ type = 'function_call'; call_id = 'edit_report'; name = 'edit_file'; arguments = '{"path":"prompt-report.md","old_str":"draft","new_str":"complete"}' }
            )
        }
        $response = @{ status = 'completed'; output = $items; usage = @{ input_tokens = 10; output_tokens = 5; input_tokens_details = @{ cached_tokens = 3 }; output_tokens_details = @{ reasoning_tokens = 2 } } }
        Set-Content -LiteralPath $OutFile -Value (ConvertTo-Json -InputObject $response -Depth 16 -Compress) -Encoding UTF8
    }
    & $CliPath -NoAzure -EnvFile $ConfigPath -TrajectoryDirectory $LogDirectory -Resume $ResumeId -Prompt 'Create a report and mark it complete.' @azureArguments
} else {
    & $CliPath -NoAzure -EnvFile $ConfigPath -TrajectoryDirectory $LogDirectory -Resume $ResumeId @azureArguments
}
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
'@
    )
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $logs = Join-Path $TestRoot 'cli-logs'
    $output = @('/help', '/status', '/clear', '/exit') | & $powerShell -NoProfile -File $launcher -CliPath $cliPath -ConfigPath $config -LogDirectory $logs -AzureTenant 'contoso.onmicrosoft.com'
    Assert-True ($LASTEXITCODE -eq 0) 'Run the CLI entry point with redirected interactive input.'
    $log = Get-ChildItem -LiteralPath $logs -Filter *.jsonl
    Assert-True (@($log).Count -eq 1) 'Create one trajectory per CLI session.'
    $events = @(Get-Content -LiteralPath $log.FullName -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    Assert-True ('history_cleared' -in $events.event -and 'session_stopped' -in $events.event) 'Record interactive clear and normal exit.'
    Assert-True ($events[-1].data.reason -eq 'exit') 'Record the correct session stop reason.'
    Assert-True (-not (($output -join "`n").Contains('test-api-key'))) 'Keep credentials out of startup output.'
    Assert-True (($output -join "`n").Contains('Trajectory:')) 'Allow the user to request the trajectory path with /status.'
    Assert-True (($output -join "`n").Contains('-AzureTenant contoso.onmicrosoft.com')) 'Accept tenant domains at the entry point and preserve the selector in the resume command.'
    $promptLogs = Join-Path $TestRoot 'prompt-logs'
    $output = & $powerShell -NoProfile -NonInteractive -File $launcher -CliPath $cliPath -ConfigPath $config -LogDirectory $promptLogs -WorkRoot $WorkRoot -SinglePrompt
    Assert-True ($LASTEXITCODE -eq 0) 'Complete single-prompt writes without waiting for input.'
    $transcript = $output -join "`n"
    foreach ($noise in @('Trajectory:', 'estimated tokens', 'last API input', 'unknown; set', 'tokens: in', 'stopped: completed', 'exit 0')) {
        Assert-True (-not $transcript.Contains($noise)) 'Keep routine diagnostic output out of the conversation.'
    }
    Assert-True ($transcript.Contains('Wrote prompt-report.md') -and $transcript.Contains('Edited prompt-report.md') -and $transcript.Contains('Report created and updated.')) 'Show concise action summaries and the final answer.'
    Assert-True ($transcript.Contains('Token usage: total=30 input=20 (cached=6) output=10 (reasoning=4)') -and $transcript.Contains('-Resume ')) 'Print usage and continuation instructions after a single prompt exits.'
    Assert-True (-not $transcript.Contains([string][char]27) -and -not $transcript.Contains("`r")) 'Use plain output when streams are redirected.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $WorkRoot 'prompt-report.md') -Raw -Encoding UTF8) -ceq "# Report`n`ncomplete.") 'Run write_file and edit_file through the actual -Prompt entry point.'
    $promptLog = Get-ChildItem -LiteralPath $promptLogs -Filter *.jsonl
    $promptEvents = @(Get-Content -LiteralPath $promptLog.FullName -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    Assert-True (@($promptEvents | Where-Object { $_.event -eq 'tool_finished' -and $_.data.result.status -eq 'ok' }).Count -eq 2) 'Record both successful writes in the CLI trajectory.'
    $resumeId = $promptEvents[0].session_id
    $output = & $powerShell -NoProfile -NonInteractive -File $launcher -CliPath $cliPath -ConfigPath $config -LogDirectory $promptLogs -WorkRoot $WorkRoot -ResumeId $resumeId -SinglePrompt
    Assert-True ($LASTEXITCODE -eq 0) 'Resume through the actual CLI entry point.'
    $resumedTranscript = $output -join "`n"
    Assert-True ($resumedTranscript.Contains('Conversation restored.') -and $resumedTranscript.Contains('Token usage: total=45')) 'Continue the conversation and accumulate usage across invocations.'
    Assert-True ($resumedTranscript.Contains('> Create a report and mark it complete.') -and $resumedTranscript.Contains('Wrote prompt-report.md') -and $resumedTranscript.Contains('Report created and updated.')) 'Display saved user messages, tool summaries and answers on resume.'
    Assert-True ($resumedTranscript.Contains('-Resume ' + $resumeId) -and @(Get-ChildItem -LiteralPath $promptLogs -Filter *.jsonl).Count -eq 1) 'Keep the resume command and trajectory tied to the original session ID.'
    $output = @('/exit') | & $powerShell -NoProfile -File $launcher -CliPath $cliPath -ConfigPath $config -LogDirectory $promptLogs -WorkRoot $WorkRoot -ResumeId $resumeId
    Assert-True ($LASTEXITCODE -eq 0) 'Resume and exit without sending a new message.'
    $idleTranscript = $output -join "`n"
    Assert-True ($idleTranscript.Contains('Report created and updated.') -and $idleTranscript.Contains('Token usage: total=45') -and $idleTranscript.Contains('-Resume ' + $resumeId)) 'Show history with unchanged usage and identity when no new request is sent.'
    $resumedEvents = @(Get-Content -LiteralPath $promptLog.FullName -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
    Assert-True (@($resumedEvents | Where-Object { $_.event -eq 'tool_finished' }).Count -eq 2) 'Display past tool results without executing the tools again.'
    Assert-True (@($resumedEvents | Where-Object { $_.event -eq 'model_request' }).Count -eq 3) 'Do not call the model to display restored history.'
    Assert-True (@($resumedEvents | Where-Object { $_.event -eq 'session_resumed' }).Count -eq 2) 'Record both continuations in the same trajectory.'
    for ($i = 0; $i -lt $resumedEvents.Count; $i++) { Assert-True ($resumedEvents[$i].sequence -eq ($i + 1) -and $resumedEvents[$i].session_id -ceq $resumeId) 'Append sequential events without changing session identity.' }
    $invalidConfig = Join-Path $TestRoot 'invalid.env'
    Set-Content -LiteralPath $invalidConfig -Encoding UTF8 -Value @(
        'AZURE_OPENAI_ENDPOINT=https://test.services.ai.azure.com/openai/v1'
        'AZURE_OPENAI_API_KEY=test-api-key'
        'AZURE_OPENAI_DEPLOYMENT=test-deployment'
    )
    $rejectedLogs = Join-Path $TestRoot 'rejected-logs'
    foreach ($case in @(
        @{ path = (Join-Path $TestRoot 'missing.env'); version = '5.0'; message = '*Flint requires Windows PowerShell 5.1*Current version: 5.0*Start Flint with powershell.exe*' },
        @{ path = (Join-Path $TestRoot 'missing.env'); version = '5.2'; message = '*Flint requires Windows PowerShell 5.1*Current version: 5.2*Start Flint with powershell.exe*' },
        @{ path = (Join-Path $TestRoot 'missing.env'); version = '6.0'; message = '*Flint requires Windows PowerShell 5.1*Current version: 6.0*Start Flint with powershell.exe*' },
        @{ path = (Join-Path $TestRoot 'missing.env'); version = '7.4'; message = '*Flint requires Windows PowerShell 5.1*Current version: 7.4*Start Flint with powershell.exe*' },
        @{ path = (Join-Path $TestRoot 'missing.env'); message = '*Configuration file not found*'; missing = $true },
        @{ path = $invalidConfig; message = '*complete HTTPS URL ending in /openai/v1/responses*' }
    )) {
        $versionArguments = @()
        if ($case.version) { $versionArguments = @('-ReportedVersion', $case.version) }
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $powerShell -NoProfile -NonInteractive -File $launcher -CliPath $cliPath -ConfigPath $case.path -LogDirectory $rejectedLogs -WorkRoot $WorkRoot -SinglePrompt @versionArguments 2>&1
            $startupExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = 'Stop' }
        $startupMessage = ($output -join "`n") -replace '\s+', ' '
        Assert-True ($startupExitCode -eq 1) 'Exit with failure when the runtime or configuration is invalid.'
        Assert-True ($startupMessage -like $case.message) ('Explain the startup failure. Received: ' + $startupMessage)
        Assert-True (-not (Test-Path -LiteralPath $rejectedLogs)) 'Reject an invalid runtime or configuration before starting a session or making model requests.'
        Assert-True (-not $startupMessage.Contains('test-api-key')) 'Do not expose credentials in startup validation errors.'
        if ($case.missing) {
            foreach ($part in @('Create this file using the template', '.env.example', 'AZURE_OPENAI_ENDPOINT', 'AZURE_OPENAI_API_KEY', 'AZURE_OPENAI_DEPLOYMENT')) {
                Assert-True ($startupMessage.Contains($part)) ('Missing startup guidance: ' + $part + '. Received: ' + $startupMessage)
            }
            Assert-True (-not (Test-Path -LiteralPath $case.path)) 'Leave creation of the missing configuration to the user.'
        }
    }
    Write-Host 'All CLI tests passed.'
} finally { Remove-TestFixture }
