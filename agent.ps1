#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Prompt,
    [string]$Resume,
    [ValidateSet('none', 'low', 'medium', 'high', 'xhigh', 'max')][string]$ReasoningEffort = 'medium',
    [ValidateRange(1, 1000)][int]$MaxTurns = 20,
    [ValidateRange(1, 300)][int]$RequestTimeoutSec = 180,
    [ValidateRange(1, 300)][int]$ToolTimeoutSec = 30,
    [ValidateRange(1, 200)][int]$MaxToolCalls = 40,
    [ValidateRange(1, 8)][int]$MaxParallelTools = 4,
    [ValidateRange(256, 32768)][int]$MaxOutputTokens = 4096,
    [ValidateRange(0, 2000000)][int]$ContextWindow = 0,
    [string]$TrajectoryDirectory,
    [switch]$NoAzure,
    [string]$Setup,
    [string]$ValidateSetup
)

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw ('Flint requires Windows PowerShell 5.1. Current version: {0}. Start Flint with powershell.exe -NoProfile -File "{1}".' -f $PSVersionTable.PSVersion, $PSCommandPath)
}

. (Join-Path $PSScriptRoot 'tools\Registry.ps1')
. (Join-Path $PSScriptRoot 'tools\Commands.ps1')
. (Join-Path $PSScriptRoot 'tools\Files.ps1')
. (Join-Path $PSScriptRoot 'tools\Reading.ps1')
. (Join-Path $PSScriptRoot 'tools\Searching.ps1')
foreach ($component in @('Http', 'KeyVault', 'Auth', 'Controller')) {
    . (Join-Path $PSScriptRoot ('tools\azure\' + $component + '.ps1'))
}
foreach ($component in @('Security', 'Telemetry', 'Config', 'Plugins', 'Setup', 'Sessions', 'Markdown', 'Console', 'Ui', 'Runtime', 'Permissions', 'Results', 'WorkerTransport', 'ToolExecution', 'Parallel', 'Context', 'Client', 'Loop')) {
    . (Join-Path $PSScriptRoot ('lib\' + $component + '.ps1'))
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    # Setup runs before any configuration exists and never starts a conversation.
    if ($Setup -or $ValidateSetup) {
        try {
            if ($Setup -and $ValidateSetup) { throw 'Use either -Setup or -ValidateSetup.' }
            if ($ValidateSetup) {
                $checked = Test-FlintSetup $ValidateSetup
                Write-Host 'The setup is valid.' -ForegroundColor Green
                Show-FlintSetupSummary $checked
                foreach ($plugin in @($checked.plugins)) { Show-FlintPluginSummary $plugin }
            } else {
                # Each step already reported its outcome; finish with what to do next.
                $null = Install-FlintSetup $Setup
                Write-Host 'Setup complete. Start Flint with:' -ForegroundColor Green
                Write-Host ("  & '" + $PSCommandPath.Replace("'", "''") + "'")
            }
            exit 0
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            exit 1
        }
    }
    $session = $null
    $exitReason = 'cancelled'
    try {
        $session = New-AgentSession -Resume $Resume -Effort $ReasoningEffort `
            -RequestTimeoutSec $RequestTimeoutSec -ToolTimeoutSec $ToolTimeoutSec `
            -MaxToolCalls $MaxToolCalls -MaxParallelTools $MaxParallelTools -MaxOutputTokens $MaxOutputTokens `
            -ContextWindow $ContextWindow -TrajectoryDirectory $TrajectoryDirectory `
            -NoAzure:$NoAzure
        $session.TurnLimit = $MaxTurns
        Show-FlintSession $session
        Initialize-FlintAzure $session
        if ($session.ResumedFrom) { Show-FlintHistory $session }
        if ($Prompt) {
            $answer = Invoke-AgentTurn -Session $session -UserPrompt $Prompt -TurnLimit $MaxTurns
            if ($null -ne $answer) { Show-FlintAnswer $session $answer }
        } else {
            while ($true) {
                $userPrompt = Read-FlintPrompt $session
                if ($null -eq $userPrompt -or $userPrompt -in @('exit', 'quit', '/exit')) { break }
                if ($userPrompt -eq '/help') { Show-FlintHelp $session; continue }
                if ($userPrompt -eq '/status') { Show-FlintSession $session -Details; continue }
                if ([string]::IsNullOrWhiteSpace($userPrompt)) { continue }
                if ($userPrompt -in @('/c', '/continue')) {
                    if (@($session.History).Count -eq 0) { Write-Host 'Nothing to continue.' -ForegroundColor DarkGray; continue }
                    $userPrompt = Get-FlintContinuePrompt
                } elseif ($userPrompt.StartsWith('/')) { Write-Host 'Unknown command. Use /help.' -ForegroundColor Yellow; continue }
                try {
                    $answer = Invoke-AgentTurn -Session $session -UserPrompt $userPrompt -TurnLimit $MaxTurns
                    if ($null -ne $answer) { Show-FlintAnswer $session $answer }
                } catch {
                    Show-FlintError $session $_.Exception.Message
                    if ($session.LogFailed) { throw 'Trajectory is unavailable; ending the session.' }
                }
            }
        }
        $exitReason = 'exit'
    } catch {
        $exitReason = 'error'
        Show-FlintError $session $_.Exception.Message
        exit 1
    } finally {
        if ($session) {
            Stop-FlintTurnUi $session
            Write-FlintCheckpoint $session -BestEffort
            Write-FlintEvent $session 'session_stopped' @{ reason = $exitReason; model_calls = $session.ModelCalls } -BestEffort
            Show-FlintExit $session
        }
    }
}
