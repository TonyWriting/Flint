function Show-FlintSession {
    param([hashtable]$Session, [switch]$Details)
    Initialize-FlintUi $Session
    Clear-FlintProgress $Session
    Write-Host ''
    Write-FlintColoredText (Protect-FlintText $Session ('Flint  {0}  ({1})' -f $Session.Model, $Session.Effort)) $Session -Color Yellow
    Write-Host (Protect-FlintText $Session $Session.Root) -ForegroundColor DarkGray
    $plugins = @($Session.Plugins | Where-Object { $_ } | ForEach-Object { $_.name + ' ' + $_.version })
    if ($plugins.Count -gt 0) { Write-Host ('Plugins: ' + ($plugins -join ', ')) -ForegroundColor DarkGray }
    if (-not $Details) {
        foreach ($failure in @($Session.PluginErrors | Where-Object { $_ })) { Write-Host ("Plugin '" + $failure.name + "' was not loaded. /status shows why.") -ForegroundColor Yellow }
    }
    if ($Session.ResumedFrom) { Write-Host 'Conversation restored. Send a message to continue.' -ForegroundColor DarkGray }
    if (-not $Details) { Write-Host 'Type a message. /help for commands.' -ForegroundColor DarkGray; return }
    $lastInput = 'not reported'
    if ($null -ne $Session.LastInputTokens) { $lastInput = [string]$Session.LastInputTokens }
    $signIn = ''
    if ($Session.Azure.Provider) { $signIn = Get-FlintAzureProviderName $Session }
    foreach ($line in @(
        ('Azure: ' + $Session.Azure.Status), ('Azure sign-in: ' + $signIn), ('Azure account: ' + $Session.Azure.Account), ('Azure tenant: ' + $Session.Azure.Tenant),
        ('Context: about {0:N0} of {1:N0} input tokens ({2:N0}-token window, {3:N0} reserved for the answer); omitted tool outputs: {4}' -f $Session.EstimatedTokens, ($Session.ContextWindow - $Session.MaxOutputTokens), $Session.ContextWindow, $Session.MaxOutputTokens, $Session.OmittedOutputs.Count),
        ('Last API input tokens: ' + $lastInput), ('Model calls: ' + $Session.ModelCalls),
        ('Tool concurrency: ' + $Session.MaxParallelTools),
        ('Session tokens: in {0}, out {1}, cached {2}' -f $Session.InputTokens, $Session.OutputTokens, $Session.CachedTokens),
        ('Trajectory: ' + $Session.TrajectoryPath)
    )) { Write-FlintColoredText (Protect-FlintText $Session $line) $Session }
    foreach ($plugin in @($Session.Plugins | Where-Object { $_ })) {
        $line = 'Plugin ' + $plugin.name + ' ' + $plugin.version + ': ' + @($plugin.rules).Count + ' reviewed reads, ' + @($plugin.guarded).Count + ' guarded resources'
        if ($plugin.source) {
            $line += '; source ' + $plugin.source.source
            if ($plugin.source.commit) { $line += ' at ' + $plugin.source.commit }
            if ($plugin.source.installed_at) { $line += '; installed ' + $plugin.source.installed_at }
        }
        Write-FlintColoredText (Protect-FlintText $Session $line) $Session
    }
    foreach ($failure in @($Session.PluginErrors | Where-Object { $_ })) {
        Write-Host (Protect-FlintText $Session ("Plugin '" + $failure.name + "' was not loaded: " + $failure.message)) -ForegroundColor Yellow
    }
}

function Show-FlintHelp {
    Write-Host ''
    Write-Host '  /status        Session details and trajectory path'
    Write-Host '  /c, /continue  Continue the task that was stopped'
    Write-Host '  /exit          Exit Flint'
    Write-Host '  s              While Flint works: stop the task and keep the conversation' -ForegroundColor DarkGray
    Write-Host '  Ctrl+C         Stop and exit; save the conversation' -ForegroundColor DarkGray
}

function Get-FlintToolLabel {
    param([string]$Name, $ToolArguments, [switch]$Completed)
    switch ($Name) {
        'read_file' {
            if (-not $Completed) { return 'Reading file' }
            if ($ToolArguments.json_path) { return 'Read ' + $ToolArguments.path + ' at ' + $ToolArguments.json_path }
            return 'Read ' + $ToolArguments.path
        }
        'list_files' { if ($Completed) { return 'Listed files in ' + $ToolArguments.path }; return 'Listing files' }
        'search_text' { if ($Completed) { return 'Searched ' + $ToolArguments.path }; return 'Searching text' }
        'write_file' { if ($Completed) { return 'Wrote ' + $ToolArguments.path }; return 'Writing file' }
        'edit_file' { if ($Completed) { return 'Edited ' + $ToolArguments.path }; return 'Editing file' }
        'create_directory' { if ($Completed) { return 'Directory ready: ' + $ToolArguments.path }; return 'Creating directory' }
        'run_command' { if ($Completed) { return 'Ran ' + $ToolArguments.executor }; return 'Running ' + $ToolArguments.executor }
        'azure_request' { if ($Completed) { return 'Azure ' + $ToolArguments.method + ' ' + $ToolArguments.path }; return 'Azure ' + $ToolArguments.method }
        default { return $Name }
    }
}

function Show-FlintToolResult {
    param([hashtable]$Session, [string]$Name, $ToolArguments, $Result)
    Clear-FlintProgress $Session
    if ($Result.status -eq 'ok') {
        $label = Get-FlintToolLabel $Name $ToolArguments -Completed
        if ($Result.truncated) { $label += ' (output truncated)' }
        Write-Host (Protect-FlintText $Session ('  ' + [char]0x2022 + ' ' + $label)) -ForegroundColor DarkGray
    } elseif ($Result.status -eq 'pending') {
        Write-Host (Protect-FlintText $Session ('  Azure operation pending: ' + $Result.operation_status)) -ForegroundColor Yellow
        if ($Result.poll_after_utc) { Write-Host ('    Next status check: ' + $Result.poll_after_utc) -ForegroundColor DarkGray }
        else { Write-Host '    Completion is unconfirmed. Verify the resource state.' -ForegroundColor DarkGray }
    } else {
        $detail = (Protect-FlintText $Session $Result.output) -replace '\s+', ' '
        if ($Result.stderr) { $detail = $Result.stderr }
        if ($Result.operation_message) { $detail = $Result.operation_message }
        if ($Result.service_error.message) { $detail = $Result.service_error.code + ': ' + $Result.service_error.message }
        $detail = (Protect-FlintText $Session $detail) -replace '\s+', ' '
        if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 237) + '...' }
        $label = $Name + ': ' + $Result.status
        if ($null -ne $Result.http_status) { $label += ' (HTTP ' + $Result.http_status + ')' }
        if ($null -ne $Result.exit_code -and $Result.exit_code -ne 0) { $label += ' (exit ' + $Result.exit_code + ')' }
        Write-Host (Protect-FlintText $Session ('  ! ' + $label)) -ForegroundColor Yellow
        if ($detail) { Write-Host ('    ' + $detail) -ForegroundColor DarkGray }
    }
    if ($Result.result_path) { Write-Host (Protect-FlintText $Session ('    Saved response: ' + $Result.result_path)) -ForegroundColor DarkGray }
}

function Show-FlintContextTrimmed {
    param([hashtable]$Session, [int]$Count, [long]$Before, [long]$After)
    Clear-FlintProgress $Session
    Write-Host ('  ' + [char]0x2022 + (' Context trimmed: {0} earlier tool outputs omitted' -f $Count)) -ForegroundColor DarkGray
    Write-Host ('    Request about {0:N0} to {1:N0} input tokens; saved results remain readable.' -f $Before, $After) -ForegroundColor DarkGray
}

function Show-FlintContextNearLimit {
    param([hashtable]$Session, [long]$Tokens, [long]$Budget)
    Clear-FlintProgress $Session
    Write-Host '  ! Context is nearly full even after trimming earlier tool outputs.' -ForegroundColor Yellow
    Write-Host ('    Request about {0:N0} of {1:N0} input tokens. Finish this task, then start a new Flint session for the next one.' -f $Tokens, $Budget) -ForegroundColor DarkGray
}

function Show-FlintAnswer {
    param([hashtable]$Session, [string]$Text)
    Clear-FlintProgress $Session
    Write-Host ''
    Write-FlintColoredText 'Flint' $Session -Color Yellow
    Write-FlintMarkdown $Text $Session
}

function Show-FlintHistory {
    param([hashtable]$Session)
    $calls = @{}
    foreach ($item in $Session.History) {
        if ($item.type -eq 'function_call') {
            $calls[$item.call_id] = $item
        } elseif ($item.type -eq 'function_call_output' -and $calls.ContainsKey($item.call_id)) {
            $call = $calls[$item.call_id]
            $arguments = @{}
            try { $arguments = ConvertFrom-Json -InputObject $call.arguments -ErrorAction Stop } catch { }
            try { $result = ConvertFrom-Json -InputObject $item.output -ErrorAction Stop }
            catch { $result = @{ status = 'error'; output = 'Saved tool result is unavailable.'; exit_code = $null } }
            Show-FlintToolResult $Session $call.name $arguments $result
        } elseif ($item.role -in @('user', 'assistant') -and $item.type -in @($null, 'message')) {
            $text = Get-FlintMessageText $item
            if (-not $text) { continue }
            if ($item.role -eq 'user') {
                Write-Host ''
                $prefix = '> '
                foreach ($line in ((Protect-FlintText $Session $text) -split '\r?\n')) {
                    Write-FlintColoredText ($prefix + $line) $Session -Color Green
                    $prefix = '  '
                }
            } else { Show-FlintAnswer $Session $text }
        } elseif ($item.role -eq 'developer') {
            # Flint adds developer notes only when a turn stops early.
            Write-Host '  Stopped before completion.' -ForegroundColor Yellow
        }
    }
}

function Show-FlintError {
    param([hashtable]$Session, [string]$Message)
    Clear-FlintProgress $Session
    Write-Host (Protect-FlintText $Session ('Error: ' + $Message)) -ForegroundColor Red
}

function Show-FlintExit {
    param([hashtable]$Session)
    Clear-FlintProgress $Session
    Write-Host ''
    $missing = $Session.ModelCalls - $Session.UsageReports
    if ($Session.ModelCalls -gt 0 -and $Session.UsageReports -eq 0) { $summary = 'Token usage: not reported' }
    else {
        $summary = 'Token usage: total={0:N0} input={1:N0}' -f ($Session.InputTokens + $Session.OutputTokens), $Session.InputTokens
        if ($Session.CachedReported) { $summary += ' (cached={0:N0})' -f $Session.CachedTokens }
        $summary += ' output={0:N0}' -f $Session.OutputTokens
        if ($Session.ReasoningReported) { $summary += ' (reasoning={0:N0})' -f $Session.ReasoningTokens }
    }
    if ($missing -gt 0) { $summary += '; {0} request(s) without reported usage' -f $missing }
    Write-Host $summary -ForegroundColor DarkGray
    if (-not $Session.ResumeReady -or $Session.LogFailed) {
        Write-Host 'The latest conversation could not be saved for continuation.' -ForegroundColor Yellow
        return
    }
    $command = "& '" + $Session.EntryPath.Replace("'", "''") + "' -Resume " + $Session.Id
    if ($Session.NoAzure) { $command += ' -NoAzure' }
    $directory = Split-Path $Session.TrajectoryPath -Parent
    if ($directory -ine (Join-Path $Session.Root '.flint\trajectories')) { $command += " -TrajectoryDirectory '" + $directory.Replace("'", "''") + "'" }
    foreach ($option in @(
        @{ Name = 'MaxTurns'; Value = $Session.TurnLimit; Default = 30 },
        @{ Name = 'MaxOutputTokens'; Value = $Session.MaxOutputTokens; Default = 16384 },
        @{ Name = 'MaxToolCalls'; Value = $Session.MaxToolCalls; Default = 80 },
        @{ Name = 'MaxParallelTools'; Value = $Session.MaxParallelTools; Default = 4 },
        @{ Name = 'RequestTimeoutSec'; Value = $Session.RequestTimeoutSec; Default = 300 },
        @{ Name = 'ToolTimeoutSec'; Value = $Session.ToolTimeoutSec; Default = 30 }
    )) { if ($null -ne $option.Value -and $option.Value -ne $option.Default) { $command += ' -' + $option.Name + ' ' + $option.Value } }
    Write-Host 'To continue this session from the same directory, run:' -ForegroundColor DarkGray
    Write-FlintColoredText (Protect-FlintText $Session ('  ' + $command)) $Session -Color Blue
    if ($Session.TurnInterrupted) { Write-Host 'Then send /c to continue the interrupted task.' -ForegroundColor DarkGray }
}

function Show-FlintInterruption {
    param([hashtable]$Session)
    Clear-FlintProgress $Session
    Write-Host 'Interrupted.' -ForegroundColor Yellow
}

function Show-FlintStopped {
    param([hashtable]$Session)
    Clear-FlintProgress $Session
    Write-Host 'Stopped. Completed steps are kept in the conversation.' -ForegroundColor Yellow
    Write-Host 'Send a new instruction, or /c to continue the task.' -ForegroundColor DarkGray
}
