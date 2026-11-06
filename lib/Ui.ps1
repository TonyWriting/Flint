function Show-FlintSession {
    param([hashtable]$Session, [switch]$Details)
    Initialize-FlintUi $Session
    Clear-FlintProgress $Session
    Write-Host ''
    Write-FlintColoredText (Protect-FlintText $Session ('Flint  {0}  ({1})' -f $Session.Model, $Session.Effort)) $Session -Color Yellow
    Write-Host (Protect-FlintText $Session $Session.Root) -ForegroundColor DarkGray
    if ($Session.ResumedFrom) { Write-Host 'Conversation restored. Send a message to continue.' -ForegroundColor DarkGray }
    if (-not $Details) { Write-Host 'Type a message. /help for commands.' -ForegroundColor DarkGray; return }
    $limit = 'not configured'
    if ($Session.ContextWindow -gt 0) { $limit = [string]$Session.ContextWindow }
    $lastInput = 'not reported'
    if ($null -ne $Session.LastInputTokens) { $lastInput = [string]$Session.LastInputTokens }
    foreach ($line in @(
        ('Azure: ' + $Session.Azure.Status), ('Azure account: ' + $Session.Azure.Account), ('Azure tenant: ' + $Session.Azure.Tenant),
        ('Context window: ' + $limit), ('Last API input tokens: ' + $lastInput),
        ('Estimated request tokens: ' + $Session.EstimatedTokens), ('Model calls: ' + $Session.ModelCalls),
        ('Session tokens: in {0}, out {1}, cached {2}' -f $Session.InputTokens, $Session.OutputTokens, $Session.CachedTokens),
        ('Trajectory: ' + $Session.TrajectoryPath)
    )) { Write-FlintColoredText (Protect-FlintText $Session $line) $Session }
}

function Show-FlintHelp {
    param([hashtable]$Session)
    Write-Host ''
    Write-Host '  /status  Session details and trajectory path'
    Write-Host '  /clear   Start a fresh conversation'
    Write-Host '  /exit    Exit Flint'
    Write-Host '  Ctrl+C   Stop and exit; save the conversation' -ForegroundColor DarkGray
}

function Get-FlintToolLabel {
    param([string]$Name, $ToolArguments, [switch]$Completed)
    switch ($Name) {
        'read_file' { if ($Completed) { return 'Read ' + $ToolArguments.path }; return 'Reading file' }
        'read_result' { if ($Completed) { return 'Read saved Azure response ' + $ToolArguments.result_id }; return 'Reading saved Azure response' }
        'list_files' { if ($Completed) { return 'Listed files in ' + $ToolArguments.path }; return 'Listing files' }
        'write_file' { if ($Completed) { return 'Wrote ' + $ToolArguments.path }; return 'Writing file' }
        'edit_file' { if ($Completed) { return 'Edited ' + $ToolArguments.path }; return 'Editing file' }
        'create_directory' { if ($Completed) { return 'Directory ready: ' + $ToolArguments.path }; return 'Creating directory' }
        'run_command' { if ($Completed) { return 'Ran ' + $ToolArguments.executor }; return 'Running ' + $ToolArguments.executor }
        'azure_request' { if ($Completed) { return 'Azure ' + $ToolArguments.method + ' ' + $ToolArguments.path }; return 'Azure ' + $ToolArguments.method }
        'keyvault_list_secrets' { if ($Completed) { return 'Listed secret metadata in ' + $ToolArguments.vault_name }; return 'Listing Key Vault secret metadata' }
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
    } else {
        $detail = (Protect-FlintText $Session $Result.output) -replace '\s+', ' '
        if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 237) + '...' }
        $label = $Name + ': ' + $Result.status
        if ($null -ne $Result.http_status) { $label += ' (HTTP ' + $Result.http_status + ')' }
        if ($null -ne $Result.exit_code -and $Result.exit_code -ne 0) { $label += ' (exit ' + $Result.exit_code + ')' }
        Write-Host (Protect-FlintText $Session ('  ! ' + $label)) -ForegroundColor Yellow
        if ($detail) { Write-Host ('    ' + $detail) -ForegroundColor DarkGray }
    }
    if ($Result.result_path) { Write-Host (Protect-FlintText $Session ('    Saved response: ' + $Result.result_path)) -ForegroundColor DarkGray }
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
    if ($Session.AzureTenant) { $command += ' -AzureTenant ' + $Session.AzureTenant }
    $defaultConfig = Join-Path (Split-Path $Session.EntryPath -Parent) '.env'
    if ($Session.ConfigPath -ine $defaultConfig) { $command += " -EnvFile '" + $Session.ConfigPath.Replace("'", "''") + "'" }
    $directory = Split-Path $Session.TrajectoryPath -Parent
    if ($directory -ine (Join-Path $Session.Root '.flint\trajectories')) { $command += " -TrajectoryDirectory '" + $directory.Replace("'", "''") + "'" }
    foreach ($option in @(
        @{ Name = 'ReasoningEffort'; Value = $Session.Effort; Default = 'medium' },
        @{ Name = 'MaxTurns'; Value = $Session.TurnLimit; Default = 20 },
        @{ Name = 'ContextWindow'; Value = $Session.ContextWindow; Default = 0 },
        @{ Name = 'MaxOutputTokens'; Value = $Session.MaxOutputTokens; Default = 4096 },
        @{ Name = 'MaxToolCalls'; Value = $Session.MaxToolCalls; Default = 40 },
        @{ Name = 'RequestTimeoutSec'; Value = $Session.RequestTimeoutSec; Default = 180 },
        @{ Name = 'ToolTimeoutSec'; Value = $Session.ToolTimeoutSec; Default = 30 }
    )) { if ($null -ne $option.Value -and $option.Value -ne $option.Default) { $command += ' -' + $option.Name + ' ' + $option.Value } }
    Write-Host 'To continue this session from the same directory, run:' -ForegroundColor DarkGray
    Write-FlintColoredText (Protect-FlintText $Session ('  ' + $command)) $Session -Color Blue
}

function Show-FlintInterruption {
    param([hashtable]$Session)
    Clear-FlintProgress $Session
    Write-Host 'Interrupted.' -ForegroundColor Yellow
}
