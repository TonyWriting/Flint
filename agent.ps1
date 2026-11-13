#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Prompt,
    [string]$EnvFile,
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
    [ValidateLength(1, 253)][ValidatePattern('^(?:[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}|[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+)$')][string]$AzureTenant,
    [switch]$NoAzure
)

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw ('Flint requires Windows PowerShell 5.1. Current version: {0}. Start Flint with powershell.exe -NoProfile -File "{1}".' -f $PSVersionTable.PSVersion, $PSCommandPath)
}

if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '.env' }
. (Join-Path $PSScriptRoot 'tools\Registry.ps1')
. (Join-Path $PSScriptRoot 'tools\Commands.ps1')
. (Join-Path $PSScriptRoot 'tools\Files.ps1')
. (Join-Path $PSScriptRoot 'tools\Reading.ps1')
. (Join-Path $PSScriptRoot 'tools\Results.ps1')
. (Join-Path $PSScriptRoot 'tools\Searching.ps1')
foreach ($component in @('Http', 'KeyVault', 'Auth', 'Controller')) {
    . (Join-Path $PSScriptRoot ('tools\azure\' + $component + '.ps1'))
}
foreach ($component in @('Security', 'Telemetry', 'Config', 'Sessions', 'Markdown', 'Console', 'Ui', 'Runtime', 'Permissions', 'Tools', 'Parallel', 'Client', 'Loop')) {
    . (Join-Path $PSScriptRoot ('lib\' + $component + '.ps1'))
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $session = $null
    $exitReason = 'cancelled'
    try {
        $session = New-AgentSession -EnvFile $EnvFile -Resume $Resume -Effort $ReasoningEffort `
            -RequestTimeoutSec $RequestTimeoutSec -ToolTimeoutSec $ToolTimeoutSec `
            -MaxToolCalls $MaxToolCalls -MaxParallelTools $MaxParallelTools -MaxOutputTokens $MaxOutputTokens `
            -ContextWindow $ContextWindow -TrajectoryDirectory $TrajectoryDirectory `
            -AzureTenant $AzureTenant -NoAzure:$NoAzure
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
