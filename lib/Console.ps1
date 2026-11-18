function Initialize-FlintUi {
    param([hashtable]$Session)
    if ($Session.Ui) { return }
    $live = $false; $ansi = $false
    try {
        $live = $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected
        $ansi = $live -and [bool]$Host.UI.SupportsVirtualTerminal
    } catch { }
    $Session.Ui = @{
        Live = $live; Ansi = $ansi; Active = $false; Started = [datetime]::UtcNow; Stage = ''; Frame = ''; Width = 0
    }
}

function Get-FlintTerminalWidth {
    $width = 80
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $width = $Host.UI.RawUI.WindowSize.Width } } catch { }
    if ($width -lt 12) { $width = 12 }
    return $width
}

function Write-FlintColoredText {
    param([string]$Text, [hashtable]$Session, [string]$Color = 'Gray', [switch]$NoNewline, [switch]$KeepColor)
    if ($Session) { Initialize-FlintUi $Session }
    $rgb = @{ Green = '163;211;174'; Blue = '153;195;245'; Gray = '230;230;230'; White = '250;250;250'; Yellow = '242;198;109' }[$Color]
    if ($rgb -and $Session -and $Session.Ui.Live -and $Session.Ui.Ansi) {
        $output = [string][char]27 + '[38;2;' + $rgb + 'm' + $Text
        if (-not $KeepColor) { $output += [string][char]27 + '[39m' }
        Write-Host $output -NoNewline:$NoNewline
    } else { Write-Host $Text -NoNewline:$NoNewline -ForegroundColor $Color }
}

function Clear-FlintProgress {
    param([hashtable]$Session)
    if (-not $Session -or -not $Session.Ui -or $Session.Ui.Width -eq 0) { return }
    if ($Session.Ui.Ansi) { Write-Host ("`r" + [char]27 + '[2K') -NoNewline }
    else {
        $width = $Session.Ui.Width
        $available = (Get-FlintTerminalWidth) - 1
        if ($width -gt $available) { $width = $available }
        Write-Host ("`r" + (' ' * $width) + "`r") -NoNewline
    }
    $Session.Ui.Width = 0; $Session.Ui.Frame = ''
}

function Update-FlintProgress {
    param([hashtable]$Session)
    if (-not $Session -or -not $Session.Ui -or -not $Session.Ui.Live -or -not $Session.Ui.Active) { return }
    $elapsed = ([datetime]::UtcNow - $Session.Ui.Started).TotalSeconds
    $seconds = [int]($elapsed - ($elapsed % 1))
    if ($seconds -lt 0) { $seconds = 0 }
    if ($Session.StopRequested) { $frame = '  Stopping after the current step ({0}s)' -f $seconds }
    else {
        $frame = '  Working ({0}s {1} s to stop {1} Ctrl+C to exit)' -f $seconds, [char]0x00b7
        if ($Session.Ui.Stage -and $Session.Ui.Stage -ne 'Thinking') { $frame += '  ' + $Session.Ui.Stage }
    }
    $available = (Get-FlintTerminalWidth) - 1
    if ($frame.Length -gt $available) { $frame = $frame.Substring(0, $available - 3) + '...' }
    if ($frame -ceq $Session.Ui.Frame) { return }
    Clear-FlintProgress $Session
    Write-Host $frame -NoNewline -ForegroundColor DarkGray
    $Session.Ui.Frame = $frame; $Session.Ui.Width = $frame.Length
}

function Test-FlintStopKey {
    param([hashtable]$Session)
    if (-not $Session -or -not $Session.Ui -or -not $Session.Ui.Live) { return $false }
    if ($Session.StopRequested) { return $true }
    $pending = $false
    try { $pending = [Console]::KeyAvailable } catch { return $false }
    if (-not $pending) { return $false }
    # ConstrainedLanguage cannot read key values, so choice.exe consumes one key and reports it.
    # Listing letters and digits discards ordinary keys without a warning beep.
    $code = $null
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & (Join-Path $env:SystemRoot 'System32\choice.exe') /C sabcdefghijklmnopqrtuvwxyz0123456789 /N /T 1 /D a 2>$null
        $code = $LASTEXITCODE
    } catch { return $false }
    finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 1) { return $false }
    $Session.StopRequested = $true
    Write-FlintEvent $Session 'stop_requested' @{ deferred = [bool]$Session.StopDeferred } -BestEffort
    Update-FlintProgress $Session
    return $true
}

function Start-FlintTurnUi {
    param([hashtable]$Session)
    Initialize-FlintUi $Session
    Clear-FlintProgress $Session
    $Session.Ui.Started = [datetime]::UtcNow; $Session.Ui.Active = $true; $Session.Ui.Stage = ''
}

function Stop-FlintTurnUi {
    param([hashtable]$Session)
    Clear-FlintProgress $Session
    if ($Session -and $Session.Ui) { $Session.Ui.Active = $false; $Session.Ui.Stage = '' }
}

function Show-FlintActivity {
    param([hashtable]$Session, [string]$Stage)
    Initialize-FlintUi $Session
    $safe = Protect-FlintText $Session $Stage
    if ($Session.Ui.Live) { $Session.Ui.Stage = $safe; Update-FlintProgress $Session }
    elseif ($Session.Ui.Stage -cne $safe) { Write-Host ('  ' + $safe + '...') -ForegroundColor DarkGray; $Session.Ui.Stage = $safe }
}

function Read-FlintPrompt {
    param([hashtable]$Session)
    Initialize-FlintUi $Session
    Clear-FlintProgress $Session
    Write-Host ''
    Write-FlintColoredText '> ' $Session -Color Green -NoNewline -KeepColor
    $readCompleted = $false
    try {
        while ($true) {
            $promptText = Read-Host
            # Redirected input keeps its blank lines; the caller skips them.
            if ($null -eq $promptText -or -not [string]::IsNullOrWhiteSpace($promptText) -or -not $Session.Ui.Live) { break }
            # A blank entry reuses the prompt line. Moving the cursor needs ANSI, because
            # ConstrainedLanguage cannot set RawUI.CursorPosition; otherwise skip only the spacer line.
            if ($Session.Ui.Ansi) { Write-Host ([string][char]27 + '[1A' + [char]27 + '[2K' + "`r") -NoNewline }
            Write-FlintColoredText '> ' $Session -Color Green -NoNewline -KeepColor
        }
        $readCompleted = $true
        return $promptText
    } finally {
        try {
            if ($Session.Ui.Live -and $Session.Ui.Ansi) { Write-Host ([string][char]27 + '[39m') -NoNewline }
        } finally {
            # Read-Host can unwind before ConsoleHost finishes stopping the pipeline.
            # Absorb that late stop here so the outer session finalizer can run.
            # https://github.com/PowerShell/PowerShell/issues/19987
            if (-not $readCompleted) { Start-Sleep -Milliseconds 100 }
        }
    }
}
