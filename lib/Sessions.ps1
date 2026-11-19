function New-AgentSession {
    param(
        [string]$ConfigFile, [string]$Effort = 'medium',
        [int]$RequestTimeoutSec = 180, [int]$ToolTimeoutSec = 30,
        [int]$MaxToolCalls = 40, [int]$MaxOutputTokens = 4096,
        [int]$ContextWindow = 0, [string]$TrajectoryDirectory, [string]$Resume,
        [switch]$NoAzure, [ValidateRange(1, 8)][int]$MaxParallelTools = 4, [string]$PluginDirectory
    )
    $root = Get-Item -LiteralPath (Get-Location).Path -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or $root.PSProvider.Name -ne 'FileSystem') { throw 'The current PowerShell location must be a filesystem directory.' }
    $config = Read-FlintConfig $ConfigFile
    if ($ContextWindow -gt 0 -and $ContextWindow -le $MaxOutputTokens) { throw 'ContextWindow must exceed MaxOutputTokens.' }
    # Core rules are part of the installation; plugins add reviewed reads, guarded resources and knowledge for this session.
    $installRoot = Split-Path $PSScriptRoot -Parent
    if (-not $PluginDirectory) { $PluginDirectory = Get-FlintPluginDirectory }
    $plugins = Read-FlintPlugins $PluginDirectory
    $commandRules = @(Read-FlintCommandRuleFile (Join-Path $installRoot 'tools\permissions\kubectl.json') 'kubectl' 'core')
    $guarded = @()
    foreach ($plugin in @($plugins.loaded)) {
        $commandRules += @($plugin.rules)
        foreach ($resource in @($plugin.guarded)) { if ($guarded -cnotcontains $resource) { $guarded += $resource } }
    }
    if (-not $TrajectoryDirectory) { $TrajectoryDirectory = Join-Path $root.FullName '.flint\trajectories' }
    $logDirectory = New-Item -ItemType Directory -Path $TrajectoryDirectory -Force -ErrorAction Stop
    if ($logDirectory.PSProvider.Name -ne 'FileSystem') { throw 'TrajectoryDirectory must be a filesystem directory.' }
    $check = $logDirectory.FullName
    while ($check) {
        if ((Get-Item -LiteralPath $check -Force -ErrorAction Stop).Attributes -band 1024) { throw 'Trajectory directories cannot use junctions or symlinks.' }
        $check = Split-Path $check -Parent
    }
    $saved = $null
    if ($Resume) { $saved = Read-FlintSession $Resume $logDirectory.FullName $root.FullName }
    $started = [datetime]::UtcNow; $sequence = 0; $startEvent = 'session_started'
    if ($saved) {
        $id = $saved.id; $logPath = $saved.trajectory_path
        $started = $saved.started; $sequence = $saved.event_sequence; $startEvent = 'session_resumed'
    } else {
        $id = [guid]::NewGuid().ToString('N')
        $logPath = Join-Path $logDirectory.FullName ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $id + '.jsonl')
        New-Item -ItemType File -Path $logPath -ErrorAction Stop | Out-Null
    }
    $session = @{
        Id = $id; Started = $started; Root = $root.FullName
        Model = $config.Model; Effort = $Effort
        ApiKey = $config.ApiKey; ApiEndpoint = $config.ApiEndpoint
        History = @(); Tools = @(Get-AgentTools); Instructions = Get-FlintInstructions -Plugins @($plugins.loaded)
        TrajectoryPath = $logPath; EventSequence = $sequence; LogFailed = $false
        ConfigPath = $config.ConfigPath; EntryPath = Join-Path $installRoot 'agent.ps1'
        ResumeReady = $false; ResumedFrom = $Resume
        NoAzure = [bool]$NoAzure
        Azure = @{ Initialized = $false; Status = 'unavailable'; Message = 'Azure has not been initialized. Restart Flint to initialize Azure authentication.' }
        ProtectedPaths = @($config.ConfigPath, $logDirectory.FullName)
        PluginDirectory = $PluginDirectory; Plugins = @($plugins.loaded); PluginErrors = @($plugins.errors); PluginChanges = @()
        CommandRules = @{ kubectl = $commandRules }; GuardedPatchResources = @($guarded | Sort-Object)
        PermissionSessionDirectory = Join-Path $installRoot '.flint\permissions'
        RequestTimeoutSec = $RequestTimeoutSec; ToolTimeoutSec = $ToolTimeoutSec
        TurnLimit = 20
        MaxToolCalls = $MaxToolCalls; MaxParallelTools = $MaxParallelTools; MaxOutputTokens = $MaxOutputTokens
        ContextWindow = $ContextWindow; MaxRequestChars = 2000000; RequestChars = 0
        HistoryLogged = 0; OmittedOutputs = @{}; ContextWarned = $false
        ModelCalls = 0; LastInputTokens = $null; LastOutputTokens = $null
        InputTokens = 0L; OutputTokens = 0L; CachedTokens = 0L
        ReasoningTokens = 0L; UsageReports = 0; CachedReported = $false; ReasoningReported = $false
        EstimatedTokens = 0
        WorkerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Worker.ps1'
        ModelWorkerPath = Join-Path $PSScriptRoot 'ModelWorker.ps1'
    }
    if ($saved) {
        foreach ($name in @(Get-FlintCheckpointFields)) { $session[$name] = $saved.state[$name] }
        # Current configuration and registered tools remain authoritative after restoration.
        $session.History = Protect-FlintValue $session @($saved.state.History)
        $session.HistoryLogged = @($session.History).Count
        foreach ($item in @($session.History)) {
            if ($item.type -ne 'function_call_output' -or [string]$item.call_id -cnotin $saved.omitted_call_ids) { continue }
            $placeholder = Get-FlintOmittedOutput ([string]$item.output)
            if (-not $placeholder) { throw 'The saved conversation is invalid.' }
            $session.OmittedOutputs[[string]$item.call_id] = $placeholder.output
        }
        if ($saved.model -cne $session.Model) { $session.LastInputTokens = $null; $session.LastOutputTokens = $null; $session.EstimatedTokens = 0 }
        # Installed plugins stay authoritative, like tools; the conversation learns which earlier guidance may be stale.
        $session.PluginChanges = @(Get-FlintPluginChanges $saved.plugins @(Get-FlintPluginRecords $session.Plugins))
        if ($session.PluginChanges.Count -gt 0) {
            $session.History += @{ role = 'developer'; content = ('Installed plugins changed since this conversation was saved: ' + ($session.PluginChanges -join '; ') +
                '. Guidance, documentation paths and automatic reads from earlier turns may no longer apply. Read the current plugin guide before relying on them.') }
        }
    }
    # Instructions and tools are logged once per process; model requests reference them.
    Write-FlintEvent $session $startEvent @{
        root = $session.Root; model = $session.Model; language_mode = [string]$ExecutionContext.SessionState.LanguageMode
        powershell_version = [string]$PSVersionTable.PSVersion; request_timeout_sec = $RequestTimeoutSec
        tool_timeout_sec = $ToolTimeoutSec; max_tool_calls = $MaxToolCalls; max_parallel_tools = $MaxParallelTools
        context_window = $ContextWindow; max_output_tokens = $MaxOutputTokens; reasoning_effort = $Effort
        resumed_from = $Resume; instructions = $session.Instructions; tools = $session.Tools
        plugins = @(Get-FlintPluginRecords $session.Plugins); plugin_errors = @($session.PluginErrors); plugin_changes = @($session.PluginChanges)
    }
    Write-FlintCheckpoint $session
    return $session
}

function Add-FlintUsage {
    param([hashtable]$Session, $Usage)
    if ($Usage -and $null -ne $Usage.input_tokens -and $null -ne $Usage.output_tokens) {
        $Session.UsageReports++
        $Session.LastInputTokens = $Usage.input_tokens; $Session.LastOutputTokens = $Usage.output_tokens
        $Session.InputTokens += [long]$Usage.input_tokens; $Session.OutputTokens += [long]$Usage.output_tokens
        $Session.CachedTokens += [long]$Usage.input_tokens_details.cached_tokens
        $Session.ReasoningTokens += [long]$Usage.output_tokens_details.reasoning_tokens
        if ($null -ne $Usage.input_tokens_details.cached_tokens) { $Session.CachedReported = $true }
        if ($null -ne $Usage.output_tokens_details.reasoning_tokens) { $Session.ReasoningReported = $true }
    }
}

function Get-FlintMessageText {
    param($Message)
    if ($Message.content -is [string]) { return $Message.content }
    $parts = @(foreach ($part in $Message.content) {
        if ($part.type -in @('input_text', 'output_text')) { $part.text }
        elseif ($part.type -eq 'refusal') { $part.refusal }
    })
    if ($parts.Count -gt 0) { return $parts -join [Environment]::NewLine }
}

function Get-FlintCheckpointFields {
    return @('ModelCalls', 'InputTokens', 'OutputTokens', 'CachedTokens', 'ReasoningTokens',
        'UsageReports', 'CachedReported', 'ReasoningReported', 'LastInputTokens', 'LastOutputTokens', 'EstimatedTokens')
}

function Save-FlintHistory {
    param([hashtable]$Session, [switch]$BestEffort)
    # History only grows, so each item is written once and resume concatenates the appended items.
    $history = @($Session.History)
    if ($Session.LogFailed -or $history.Count -le $Session.HistoryLogged) { return }
    $items = @($history[$Session.HistoryLogged..($history.Count - 1)])
    Write-FlintEvent $Session 'history_appended' @{ start = $Session.HistoryLogged; items = $items } -BestEffort:$BestEffort
    if (-not $Session.LogFailed) { $Session.HistoryLogged = $history.Count }
}

function Write-FlintCheckpoint {
    param([hashtable]$Session, [switch]$BestEffort)
    $Session.ResumeReady = $false
    if ($Session.LogFailed) { return }
    Save-FlintHistory $Session -BestEffort:$BestEffort
    if ($Session.LogFailed) { return }
    $state = [ordered]@{}
    foreach ($name in @(Get-FlintCheckpointFields)) { $state[$name] = $Session[$name] }
    Write-FlintEvent $Session 'session_checkpoint' @{
        version = 3; root = $Session.Root; model = $Session.Model; history_count = $Session.HistoryLogged
        omitted_call_ids = @($Session.OmittedOutputs.Keys | Sort-Object); state = $state
        plugins = @(Get-FlintPluginRecords $Session.Plugins)
    } -BestEffort:$BestEffort
    $Session.ResumeReady = -not $Session.LogFailed
}

function Read-FlintSession {
    param([string]$Id, [string]$Directory, [string]$Root)
    if ($Id -notmatch '^[a-fA-F0-9]{32}$') { throw 'Resume requires the 32-character session ID printed by Flint at exit.' }
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter ('*-' + $Id + '.jsonl') -File -ErrorAction Stop)
    if ($files.Count -ne 1) { throw "Session '$Id' was not found uniquely. Run from its original working directory, with its original -TrajectoryDirectory if configured." }
    if ($files[0].Attributes -band 1024) { throw 'Session trajectories cannot be symlinks.' }
    $checkpoint = $null; $sequence = 0; $pending = $false; $started = $null
    $logged = @(); $history = @()
    Get-Content -LiteralPath $files[0].FullName -Encoding UTF8 -ErrorAction Stop | ForEach-Object {
        try { $event = ConvertFrom-Json -InputObject $_ -ErrorAction Stop }
        catch { throw 'The session trajectory contains invalid JSON. It cannot be resumed safely.' }
        $sequence++
        if ($event.session_id -ine $Id -or $event.sequence -ne $sequence) { throw 'The session trajectory is inconsistent. It cannot be resumed safely.' }
        if ($sequence -eq 1) { $started = ([datetime]$event.timestamp).ToUniversalTime().AddMilliseconds(-[long]$event.elapsed_ms) }
        if ($event.event -eq 'history_appended') {
            if ($event.data.start -ne $logged.Count) { throw 'The session trajectory is inconsistent. It cannot be resumed safely.' }
            $logged += @($event.data.items); $pending = $true
        } elseif ($event.event -eq 'session_checkpoint') { $checkpoint = $event.data; $history = $logged; $pending = $false }
        elseif ($event.event -in @('user_input', 'model_request', 'tool_started')) { $pending = $true }
    }
    if (-not $checkpoint -or $checkpoint.version -ne 3) { throw 'This session has no supported resume checkpoint; sessions saved by earlier Flint versions cannot be resumed. Start a new conversation.' }
    if ($pending) { throw 'The last turn has no saved checkpoint. Inspect the trajectory and verify any file changes before starting a new conversation.' }
    if ($checkpoint.root.TrimEnd('\') -ine $Root.TrimEnd('\')) { throw ("Resume this session from its original working directory: '" + $checkpoint.root + "'.") }
    if ($checkpoint.history_count -ne $history.Count) { throw 'The saved conversation is invalid.' }
    foreach ($name in @('ModelCalls', 'InputTokens', 'OutputTokens', 'CachedTokens', 'ReasoningTokens', 'UsageReports', 'EstimatedTokens')) {
        if ($null -eq $checkpoint.state.$name -or [long]$checkpoint.state.$name -lt 0) { throw 'The saved token usage is invalid.' }
    }
    if ($checkpoint.state.UsageReports -gt $checkpoint.state.ModelCalls) { throw 'The saved request count is invalid.' }
    $calls = @{}; $outputs = @{}
    foreach ($item in $history) {
        if ($item.type -eq 'function_call') {
            if (-not $item.call_id -or $calls.ContainsKey($item.call_id)) { throw 'The saved conversation has invalid tool calls.' }
            $calls[$item.call_id] = $true
        } elseif ($item.type -eq 'function_call_output') {
            if (-not $item.call_id -or -not $calls.ContainsKey($item.call_id) -or $outputs.ContainsKey($item.call_id)) { throw 'The saved conversation has invalid tool results.' }
            $outputs[$item.call_id] = $true
        }
    }
    if ($calls.Count -ne $outputs.Count) { throw 'The saved conversation has unpaired tool calls.' }
    $omitted = @($checkpoint.omitted_call_ids | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    foreach ($callId in $omitted) {
        if (-not $outputs.ContainsKey($callId)) { throw 'The saved conversation has invalid omitted outputs.' }
    }
    $state = @{ History = $history }
    foreach ($name in @(Get-FlintCheckpointFields)) { $state[$name] = $checkpoint.state.$name }
    return @{
        version = $checkpoint.version; root = $checkpoint.root; model = $checkpoint.model; state = $state; omitted_call_ids = $omitted
        id = $Id.ToLowerInvariant(); trajectory_path = $files[0].FullName; event_sequence = $sequence; started = $started
        plugins = @($checkpoint.plugins | Where-Object { $null -ne $_ })
    }
}
