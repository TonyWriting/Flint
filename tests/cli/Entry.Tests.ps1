#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
try {
    $cliPath = Join-Path (New-TestRuntime (Join-Path $TestRoot 'app')) 'agent.ps1'
    # The entry point always reads flint.ini next to agent.ps1.
    $runtimeConfig = Join-Path (Split-Path $cliPath -Parent) 'flint.ini'
    Copy-Item -LiteralPath $config -Destination $runtimeConfig
    $launcher = Join-Path $TestRoot 'launch.ps1'
    Set-Content -LiteralPath $launcher -Encoding ASCII -Value @(
        'param($CliPath, $LogDirectory, $WorkRoot, $ResumeId, [switch]$SinglePrompt, [string]$ReportedVersion)'
        'if ($ReportedVersion) { $PSVersionTable[''PSVersion''] = [version]$ReportedVersion }'
        'if ($ExecutionContext.SessionState.LanguageMode -ne ''ConstrainedLanguage'') { $ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage'' }'
        @'
if ($WorkRoot) { Set-Location -LiteralPath $WorkRoot }
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
    & $CliPath -NoAzure -TrajectoryDirectory $LogDirectory -Resume $ResumeId -Prompt 'Create a report and mark it complete.'
} else {
    & $CliPath -NoAzure -TrajectoryDirectory $LogDirectory -Resume $ResumeId
}
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
'@
    )
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $logs = Join-Path $TestRoot 'cli-logs'
    $output = @('/help', '/status', '/c', '/continue', '/exit') | & $powerShell -NoProfile -File $launcher -CliPath $cliPath -LogDirectory $logs
    Assert-True ($LASTEXITCODE -eq 0) 'Run the CLI entry point with redirected interactive input.'
    $log = Get-ChildItem -LiteralPath $logs -Filter *.jsonl
    Assert-True (@($log).Count -eq 1) 'Create one trajectory per CLI session.'
    $events = @(Get-TestEvents $log.FullName)
    Assert-True ('session_stopped' -in $events.event) 'Record a normal exit.'
    Assert-True ($events[-1].data.reason -eq 'exit') 'Record the correct session stop reason.'
    Assert-True (-not (($output -join "`n").Contains('test-api-key'))) 'Keep credentials out of startup output.'
    Assert-True (($output -join "`n").Contains('Trajectory:')) 'Allow the user to request the trajectory path with /status.'
    Assert-True (@($output | Where-Object { [string]$_ -like '*Nothing to continue.*' }).Count -eq 2) 'Accept /c and /continue, and do not call the model without a conversation.'
    $promptLogs = Join-Path $TestRoot 'prompt-logs'
    $output = & $powerShell -NoProfile -NonInteractive -File $launcher -CliPath $cliPath -LogDirectory $promptLogs -WorkRoot $WorkRoot -SinglePrompt
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
    $promptEvents = @(Get-TestEvents $promptLog.FullName)
    Assert-True (@($promptEvents | Where-Object { $_.event -eq 'tool_finished' -and $_.data.result.status -eq 'ok' }).Count -eq 2) 'Record both successful writes in the CLI trajectory.'
    $promptMentions = @($promptEvents | Where-Object { (ConvertTo-Json -InputObject $_ -Depth 32 -Compress).Contains('Create a report and mark it complete.') })
    Assert-True (($promptMentions.event -join ',') -ceq 'user_input,history_appended') 'Log the prompt once as input and once as history, however many model calls follow.'
    $resumeId = $promptEvents[0].session_id
    $output = & $powerShell -NoProfile -NonInteractive -File $launcher -CliPath $cliPath -LogDirectory $promptLogs -WorkRoot $WorkRoot -ResumeId $resumeId -SinglePrompt
    Assert-True ($LASTEXITCODE -eq 0) 'Resume through the actual CLI entry point.'
    $resumedTranscript = $output -join "`n"
    Assert-True ($resumedTranscript.Contains('Conversation restored.') -and $resumedTranscript.Contains('Token usage: total=45')) 'Continue the conversation and accumulate usage across invocations.'
    Assert-True ($resumedTranscript.Contains('> Create a report and mark it complete.') -and $resumedTranscript.Contains('Wrote prompt-report.md') -and $resumedTranscript.Contains('Report created and updated.')) 'Display saved user messages, tool summaries and answers on resume.'
    Assert-True ($resumedTranscript.Contains('-Resume ' + $resumeId) -and @(Get-ChildItem -LiteralPath $promptLogs -Filter *.jsonl).Count -eq 1) 'Keep the resume command and trajectory tied to the original session ID.'
    $output = @('/exit') | & $powerShell -NoProfile -File $launcher -CliPath $cliPath -LogDirectory $promptLogs -WorkRoot $WorkRoot -ResumeId $resumeId
    Assert-True ($LASTEXITCODE -eq 0) 'Resume and exit without sending a new message.'
    $idleTranscript = $output -join "`n"
    Assert-True ($idleTranscript.Contains('Report created and updated.') -and $idleTranscript.Contains('Token usage: total=45') -and $idleTranscript.Contains('-Resume ' + $resumeId)) 'Show history with unchanged usage and identity when no new request is sent.'
    $resumedEvents = @(Get-TestEvents $promptLog.FullName)
    Assert-True (@($resumedEvents | Where-Object { $_.event -eq 'tool_finished' }).Count -eq 2) 'Display past tool results without executing the tools again.'
    Assert-True (@($resumedEvents | Where-Object { $_.event -eq 'model_request' }).Count -eq 3) 'Do not call the model to display restored history.'
    Assert-True (@($resumedEvents | Where-Object { $_.event -eq 'session_resumed' }).Count -eq 2) 'Record both continuations in the same trajectory.'
    for ($i = 0; $i -lt $resumedEvents.Count; $i++) { Assert-True ($resumedEvents[$i].sequence -eq ($i + 1) -and $resumedEvents[$i].session_id -ceq $resumeId) 'Append sequential events without changing session identity.' }
    # Configuration errors are covered in-process by agent\Config; here the entry point must fail before any session starts.
    $rejectedLogs = Join-Path $TestRoot 'rejected-logs'
    foreach ($case in @(
        @{ version = '5.0'; message = '*Flint requires Windows PowerShell 5.1*Current version: 5.0*Start Flint with powershell.exe*' },
        @{ version = '7.4'; message = '*Flint requires Windows PowerShell 5.1*Current version: 7.4*Start Flint with powershell.exe*' },
        @{ message = '*Configuration file not found*'; missing = $true }
    )) {
        Remove-Item -LiteralPath $runtimeConfig -Force -ErrorAction SilentlyContinue
        $versionArguments = @()
        if ($case.version) { $versionArguments = @('-ReportedVersion', $case.version) }
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $powerShell -NoProfile -NonInteractive -File $launcher -CliPath $cliPath -LogDirectory $rejectedLogs -WorkRoot $WorkRoot -SinglePrompt @versionArguments 2>&1
            $startupExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = 'Stop' }
        $startupMessage = ($output -join "`n") -replace '\s+', ' '
        Assert-True ($startupExitCode -eq 1) 'Exit with failure when the runtime or configuration is invalid.'
        Assert-True ($startupMessage -like $case.message) ('Explain the startup failure. Received: ' + $startupMessage)
        Assert-True (-not (Test-Path -LiteralPath $rejectedLogs)) 'Reject an invalid runtime or configuration before starting a session or making model requests.'
        if ($case.missing) {
            foreach ($part in @('agent.ps1 -Setup', 'copy the template', 'flint.example.ini', 'endpoint, deployment, context_window, reasoning_effort and api_key under [model]')) {
                Assert-True ($startupMessage.Contains($part)) ('Missing startup guidance: ' + $part + '. Received: ' + $startupMessage)
            }
            Assert-True (-not (Test-Path -LiteralPath $runtimeConfig)) 'Leave creation of the missing configuration to the user.'
        }
    }
    Remove-Item -LiteralPath $runtimeConfig -Force -ErrorAction SilentlyContinue

    # Setup runs without a configuration and without input, and installs into the runtime that was invoked.
    $setupLauncher = Join-Path $TestRoot 'setup-launch.ps1'
    Set-Content -LiteralPath $setupLauncher -Encoding ASCII -Value @(
        'param($CliPath, $Validate, $Setup)'
        'if ($ExecutionContext.SessionState.LanguageMode -ne ''ConstrainedLanguage'') { $ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage'' }'
        'if ($Validate) { & $CliPath -ValidateSetup $Validate } else { & $CliPath -Setup $Setup }'
        'if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }'
    )
    $setupSource = New-TestSetup (Join-Path $TestRoot 'setup-source')
    $invalidSetup = New-TestSetup (Join-Path $TestRoot 'setup-invalid') -Plugins @()
    $null = New-TestPlugin (Join-Path $invalidSetup 'Plugins\example') -Manifest @{ version = 'one' }
    $output = & $powerShell -NoProfile -NonInteractive -File $setupLauncher -CliPath $cliPath -Validate $setupSource
    $transcript = $output -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $transcript.Contains('The setup is valid.') -and $transcript.Contains('Model: team-model at https://contoso.services.ai.azure.com/openai/v1/responses') -and $transcript.Contains('example 1.0.0')) 'Validate a setup folder from the entry point.'
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $powerShell -NoProfile -NonInteractive -File $setupLauncher -CliPath $cliPath -Validate $invalidSetup 2>&1
        $validateExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = 'Stop' }
    Assert-True ($validateExitCode -eq 1 -and ($output -join "`n").Contains('MAJOR.MINOR.PATCH')) 'Explain why a setup is invalid and exit with failure.'
    $output = & $powerShell -NoProfile -NonInteractive -File $setupLauncher -CliPath $cliPath -Setup $setupSource
    $transcript = $output -join "`n"
    $runtimePlugin = Join-Path (Split-Path $cliPath -Parent) 'plugins\example\plugin.json'
    Assert-True ($LASTEXITCODE -eq 0 -and $transcript.Contains('Setup complete. Set the API key in flint.ini before starting Flint:') -and (Test-Path -LiteralPath $runtimePlugin)) ('Set up the invoked runtime from a team folder without reading a key: ' + $transcript)
    Assert-True ($transcript -match 'Installed example 1\.0\.0 \(\d+\.\ds\)' -and $transcript.Contains('Generated ' + $runtimeConfig)) 'Report each step with its duration.'
    Assert-True ($transcript.Contains('Ask the team for the key.') -and $transcript.Contains('Paste the key after "api_key =" in ' + $runtimeConfig) -and $transcript.Contains("& '" + $cliPath + "'")) ('Say where to get the key, where to paste it and how to start Flint: ' + $transcript)
    # The user pastes the key into flint.ini; running setup again keeps it.
    $lines = @(Get-Content -LiteralPath $runtimeConfig -Encoding UTF8)
    Set-Content -LiteralPath $runtimeConfig -Encoding UTF8 -Value ($lines -replace '^api_key =$', 'api_key = pasted-team-key')
    $output = & $powerShell -NoProfile -NonInteractive -File $setupLauncher -CliPath $cliPath -Setup $setupSource
    $transcript = $output -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $transcript.Contains('The API key in flint.ini was kept.') -and -not $transcript.Contains('Paste the key')) ('Keep the pasted key when setup runs again: ' + $transcript)
    Assert-True ((Read-FlintConfig $runtimeConfig).ApiKey -ceq 'pasted-team-key') 'flint.ini keeps the pasted key.'
    $statusLogs = Join-Path $TestRoot 'plugin-logs'
    $output = @('/status', '/exit') | & $powerShell -NoProfile -File $launcher -CliPath $cliPath -LogDirectory $statusLogs
    $transcript = $output -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $transcript.Contains('Plugins: example 1.0.0') -and $transcript.Contains('Plugin example 1.0.0: 2 reviewed reads')) 'Load the installed plugin in a new session and show it in /status.'
    Write-Host 'All CLI tests passed.'
} finally { Remove-TestFixture }
