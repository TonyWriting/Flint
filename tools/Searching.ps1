function Add-FlintSearchLine {
    param([hashtable]$State, [AllowEmptyString()][string]$Line)
    $State.line++
    if ($Line.Contains([string][char]0)) { throw 'Binary files are not supported.' }
    if ($State.line -lt $State.start_line) { return $false }
    if ($State.matches.Count -ge $State.max_matches) {
        $State.truncated = $true; $State.next_line = $State.line
        return $true
    }
    $index = $Line.IndexOf($State.keyword, [StringComparison]::OrdinalIgnoreCase)
    if ($index -lt 0) { return $false }
    $start = $index - 80
    if ($start -lt 0) { $start = 0 }
    if ($start -gt 0 -and [int][char]$Line[$start] -ge 56320 -and [int][char]$Line[$start] -le 57343) { $start-- }
    $take = $Line.Length - $start
    if ($take -gt 512) {
        $take = 512
        $last = [int][char]$Line[$start + $take - 1]
        if ($last -ge 55296 -and $last -le 56319) { $take-- }
    }
    $match = Protect-FlintValue $null @{
        line = $State.line; column = $index + 1; text = $Line.Substring($start, $take)
        text_start_column = $start + 1; text_truncated = ($start -gt 0 -or $start + $take -lt $Line.Length)
    }
    $length = (ConvertTo-Json $match -Depth 8 -Compress).Length + 1
    if ($State.characters + $length -gt 30000) {
        $State.truncated = $true; $State.next_line = $State.line
        return $true
    }
    $State.matches += $match; $State.characters += $length
    return $false
}

function Search-FlintText {
    param([string]$Root, [string]$SessionId, $ToolArguments, [string[]]$ProtectedPaths)
    $path = Resolve-FlintFileTarget $Root read_file $ToolArguments $ProtectedPaths -SessionId $SessionId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'File does not exist or is a directory.' }
    $state = @{
        line = 0; start_line = $ToolArguments.start_line; keyword = $ToolArguments.keyword
        max_matches = $ToolArguments.max_matches; matches = @(); characters = 0; truncated = $false; next_line = $null
    }
    # Stream to the next page boundary, including long files and saved HTTP results.
    Get-Content -LiteralPath $path -Encoding UTF8 -ReadCount 1 -ErrorAction Stop |
        ForEach-Object { if (Add-FlintSearchLine $state ([string]$_)) { $true } } |
        Select-Object -First 1 | Out-Null
    return @{
        status = 'ok'; exit_code = 0; retryable = $false; duration_ms = 0
        output = ('Found {0} matching line(s) on this page.' -f $state.matches.Count)
        matches = $state.matches; matches_returned = $state.matches.Count
        truncated = $state.truncated; next_line = $state.next_line; start_line = $ToolArguments.start_line
    }
}
