function Get-FlintFailureDetails {
    param([hashtable]$Session, $Record)
    # Read properties only: exception reflection is unavailable in ConstrainedLanguage.
    $details = @{
        message = [string]$Record.Exception.Message
        error_id = [string]$Record.FullyQualifiedErrorId
        exception_type = [string]$Record.Exception.PSObject.TypeNames[0]
        category = [string]$Record.CategoryInfo.Category
        script_stack_trace = [string]$Record.ScriptStackTrace
    }
    foreach ($name in @($details.Keys)) {
        if ($details[$name].Length -gt 4096) { $details[$name] = $details[$name].Substring(0, 4096) + ' [truncated]' }
    }
    return Protect-FlintValue $Session $details
}

function Write-FlintEvent {
    param([hashtable]$Session, [string]$Type, $Data, [switch]$BestEffort, $Timing, [switch]$Redacted)
    if (-not $Session -or -not $Session.TrajectoryPath) { return }
    try {
        $Session.EventSequence++
        # One clock reading keeps timestamp - elapsed_ms equal to the session start for resume.
        $now = [datetime]::UtcNow
        $safeData = $Data
        # Redacted data was redacted when it entered the session, such as history items.
        if (-not $Redacted) { $safeData = Protect-FlintValue $Session $Data }
        $record = [ordered]@{
            timestamp = $now.ToString('o'); session_id = $Session.Id; sequence = $Session.EventSequence
            elapsed_ms = [long](($now - $Session.Started).TotalMilliseconds)
            event = $Type; data = $safeData
        }
        # Timings are numbers Flint measured itself, so they skip redaction.
        if ($Timing) { $record.timing = $Timing }
        $json = ConvertTo-Json -InputObject $record -Depth 64 -Compress
        # Flint's own credentials are still checked; finding one redacts the data after all.
        if ($Redacted -and (Test-FlintSecretInJson $Session $json)) {
            $record.data = Protect-FlintValue $Session $Data
            $json = ConvertTo-Json -InputObject $record -Depth 64 -Compress
        }
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

function ConvertFrom-FlintTiming {
    param([AllowEmptyString()][string]$Output)
    # A worker reports its own timings as one JSON line on standard output; other output is ignored.
    $timing = [ordered]@{}
    foreach ($line in @($Output -split "`r?`n")) {
        if ($line -notmatch '^\{.*\}$') { continue }
        try { $value = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
        foreach ($property in @($value.PSObject.Properties)) {
            $milliseconds = $property.Value -as [long]
            if ($property.Name -match '^[a-z_]+_ms$' -and $null -ne $milliseconds) { $timing[$property.Name] = $milliseconds }
        }
    }
    return $timing
}
