function Write-FlintEvent {
    param([hashtable]$Session, [string]$Type, $Data, [switch]$BestEffort)
    if (-not $Session -or -not $Session.TrajectoryPath) { return }
    try {
        $Session.EventSequence++
        $record = [ordered]@{
            timestamp = [datetime]::UtcNow.ToString('o'); session_id = $Session.Id; sequence = $Session.EventSequence
            elapsed_ms = [long](([datetime]::UtcNow - $Session.Started).TotalMilliseconds)
            event = $Type; data = Protect-FlintValue $Session $Data
        }
        $json = ConvertTo-Json -InputObject $record -Depth 64 -Compress
        Add-Content -LiteralPath $Session.TrajectoryPath -Value $json -Encoding UTF8 -ErrorAction Stop
    } catch {
        $Session.LogFailed = $true
        if (-not $BestEffort) { throw 'Cannot append the trajectory. Stopping before any further action.' }
        if ($Session.Ui) { Clear-FlintProgress $Session }
        Write-Warning 'Could not write the final trajectory event.'
    }
}

function Get-FlintElapsedMs {
    param([datetime]$Since)
    return [long](([datetime]::UtcNow - $Since).TotalMilliseconds)
}
