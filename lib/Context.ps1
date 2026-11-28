function Get-FlintModelInput {
    param([hashtable]$Session)
    # History keeps every item; the model sees placeholders for omitted outputs.
    foreach ($item in @($Session.History)) {
        $callId = [string]$item.call_id
        if ($item.type -eq 'function_call_output' -and $Session.OmittedOutputs.ContainsKey($callId)) {
            [ordered]@{ type = 'function_call_output'; call_id = $item.call_id; output = $Session.OmittedOutputs[$callId] }
        } else { $item }
    }
}

function Get-FlintOmittedOutput {
    param([AllowEmptyString()][string]$Output)
    try { $result = ConvertFrom-Json -InputObject $Output -ErrorAction Stop } catch { return $null }
    if ($result -isnot [pscustomobject]) { return $null }
    # Keep status, cursors and result references; drop only the bulky content.
    $placeholder = [ordered]@{}
    foreach ($property in @($result.PSObject.Properties)) {
        if ($property.Name -cnotin @('output', 'matches')) { $placeholder[$property.Name] = $property.Value }
    }
    $placeholder.output_omitted = 'Omitted to fit the context budget. If needed, read result_path with read_file when present, or repeat the read-only query; regular files may have changed since.'
    $text = ConvertTo-Json -InputObject $placeholder -Depth 16 -Compress
    $saved = (ConvertTo-Json -InputObject $Output -Compress).Length - (ConvertTo-Json -InputObject $text -Compress).Length
    return @{ output = $text; saved_chars = $saved }
}

function Compress-FlintContext {
    # Returns the call IDs omitted by this pass; the caller rebuilds and records the request.
    param([hashtable]$Session, [long]$ExcessChars)
    $history = @($Session.History)
    # A later model output shows the model has already read every output before it.
    $readEnd = -1
    for ($index = $history.Count - 1; $index -ge 0; $index--) {
        $item = $history[$index]
        if ($item.type -in @('reasoning', 'function_call') -or ($item.type -eq 'message' -and $item.role -eq 'assistant')) { $readEnd = $index; break }
    }
    $excess = $ExcessChars
    $omitted = @()
    for ($index = 0; $index -lt $readEnd -and $excess -gt 0; $index++) {
        $item = $history[$index]
        $callId = [string]$item.call_id
        if ($item.type -ne 'function_call_output' -or $Session.OmittedOutputs.ContainsKey($callId)) { continue }
        $placeholder = Get-FlintOmittedOutput ([string]$item.output)
        # Only this decision applies the size threshold; recorded omissions are always rebuilt on resume.
        if (-not $placeholder -or $placeholder.saved_chars -lt 1024) { continue }
        $Session.OmittedOutputs[$callId] = $placeholder.output
        $omitted += $callId
        $excess -= $placeholder.saved_chars
    }
    return $omitted
}
