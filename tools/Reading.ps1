function Add-FlintReadLine {
    param([hashtable]$State, [AllowEmptyString()][string]$Line)
    $State.line++
    if ($Line.Contains([string][char]0)) { throw 'Binary files are not supported.' }
    if ($State.line -lt $State.start_line) { return $false }
    $column = 0
    if ($State.line -eq $State.start_line) { $column = $State.start_column - 1 }
    if ($column -gt $Line.Length) { throw 'start_column is beyond the selected line.' }
    if ($State.lines_returned -ge $State.max_lines -or $State.output.Length -ge 32768) {
        $State.truncated = $true; $State.next_line = $State.line; $State.next_column = $column + 1
        return $true
    }
    $available = $Line.Length - $column
    $take = $available
    $space = 32768 - $State.output.Length
    if ($take -gt $space) { $take = $space }
    if ($take -gt 0 -and $take -lt $available) {
        $last = [int][char]$Line[$column + $take - 1]
        if ($last -ge 55296 -and $last -le 56319) { $take-- }
    }
    $State.output += $Line.Substring($column, $take)
    $State.lines_returned++
    if ($take -lt $available) {
        $State.truncated = $true; $State.next_line = $State.line; $State.next_column = $column + $take + 1
        return $true
    }
    return $false
}

function Read-FlintTextFile {
    param([string]$Path, $ToolArguments)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'File does not exist or is a directory.' }
    $entry = Get-Item -LiteralPath $Path -ErrorAction Stop
    $state = @{
        output = ''; line = 0; lines_returned = 0; truncated = $false; next_line = $null; next_column = $null
        start_line = $ToolArguments.start_line; start_column = $ToolArguments.start_column; max_lines = $ToolArguments.max_lines
    }
    $normalized = $entry.Length -gt 262144
    if ($normalized) {
        # Stream large files. Select-Object stops the upstream reader as soon as the page is full.
        Get-Content -LiteralPath $Path -Encoding UTF8 -ReadCount 1 -ErrorAction Stop |
            ForEach-Object { if (Add-FlintReadLine $state ([string]$_ + "`n")) { $true } } |
            Select-Object -First 1 | Out-Null
    } else {
        # A bounded raw read preserves exact line endings for ordinary source files and edits.
        $content = [string](Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop)
        if ($null -eq $content) { $content = '' }
        if ($content.Contains([string][char]0)) { throw 'Binary files are not supported.' }
        if ($content.Length -gt 0) {
            foreach ($line in ($content -split '(?<=\n)|(?<=\r)(?!\n)')) {
                if ($line.Length -eq 0) { continue }
                if (Add-FlintReadLine $state $line) { break }
            }
        }
    }
    return @{
        status = 'ok'; exit_code = 0; output = $state.output; retryable = $false; duration_ms = 0
        truncated = $state.truncated; next_line = $state.next_line; next_column = $state.next_column
        start_line = $state.start_line; start_column = $state.start_column; lines_returned = $state.lines_returned
        size_bytes = $entry.Length; line_endings_normalized = $normalized
    }
}

function Select-FlintJsonValue {
    param($Value, [string]$JsonPath)
    # Property names separated by dots, each optionally followed by [index]; a root array starts with [index].
    $path = $JsonPath
    if (-not $path.StartsWith('[')) { $path = '.' + $path }
    if ($path -cnotmatch '^(?:\.[^.\[\]]+|\[\d{1,9}\])+$') {
        throw 'json_path must be property names separated by dots, each optionally followed by [index], such as status or items[0].status.conditions.'
    }
    $current = $Value; $at = '$'; $secretName = Get-FlintSecretNamePattern
    foreach ($token in @($path -split '(?=[.\[])' | Where-Object { $_ })) {
        if ($token.StartsWith('[')) {
            $index = [int]$token.Substring(1, $token.Length - 2)
            if ($current -isnot [array]) { throw ($at + ' is not an array.') }
            if ($index -ge $current.Count) { throw ($at + ' has ' + $current.Count + ' items.') }
            $current = $current[$index]
        } else {
            $name = $token.Substring(1)
            if ($current -isnot [pscustomobject]) { throw ($at + ' is not an object.') }
            $property = @($current.PSObject.Properties | Where-Object { $_.Name -ceq $name })
            if ($property.Count -eq 0) {
                # The available names let the model correct the path without reading the file.
                $names = @($current.PSObject.Properties | Select-Object -First 50 | ForEach-Object { $_.Name }) -join ', '
                throw ($at + ' has no property ' + $name + '. Properties: ' + $names)
            }
            # Selection drops the field names above the value, so a credential field on the path redacts it here,
            # before anything below it, such as property names in an error, can reach the output.
            if ($name -match $secretName -or (Protect-FlintText $null $name) -match $secretName) { return '[redacted]' }
            $current = $property[0].Value
        }
        $at += $token
    }
    if ($current -is [array]) { return ,$current }
    return $current
}

function Read-FlintJsonValue {
    param([string]$Path, $ToolArguments)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'File does not exist or is a directory.' }
    if ($ToolArguments.start_line -ne 1 -or $ToolArguments.start_column -ne 1) { throw 'With json_path, use start_line 1 and start_column 1; select a narrower path instead of paging.' }
    $entry = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($entry.Length -gt 8388608) { throw 'json_path reads JSON files of at most 8 MiB.' }
    $content = [string](Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop)
    # An object wrapper preserves empty and single-item root arrays in PowerShell 5.1.
    try { $document = (ConvertFrom-Json -InputObject ('{"value":' + $content + '}') -ErrorAction Stop).value }
    catch { throw 'json_path needs a JSON file. Read this file without json_path.' }
    $selected = Select-FlintJsonValue $document $ToolArguments.json_path
    Assert-FlintResultJsonDepth $selected
    # A string comes back as its text, which redaction treats like any text; other values are compact JSON.
    if ($selected -is [string]) { $text = $selected; $type = 'string' }
    else {
        $text = ConvertTo-Json -InputObject $selected -Depth 100 -Compress
        if ($null -eq $selected) { $type = 'null' }
        elseif ($selected -is [array]) { $type = 'array' }
        elseif ($selected -is [pscustomobject]) { $type = 'object' }
        elseif ($selected -is [bool]) { $type = 'boolean' }
        else { $type = 'number' }
    }
    # A value always fits one page, so redaction sees it whole: pages would cut JSON apart. Redaction can
    # lengthen a value, so a value within the page is redacted here and checked again; a longer one is not.
    if ($text.Length -le 32768) {
        if ($selected -is [string]) { $text = Protect-FlintText $null $text }
        elseif ($selected -is [array] -or $selected -is [pscustomobject]) { $text = ConvertTo-Json -InputObject (Protect-FlintValue $null $selected -Untrusted) -Depth 100 -Compress }
    }
    if ($text.Length -gt 32768) {
        # The sizes below the value lead to a narrower path; credential fields show only their names.
        $detail = ''
        if ($selected -is [array]) { $detail = ' It has ' + $selected.Count + ' items; select one with [index].' }
        elseif ($selected -is [pscustomobject]) {
            $secretName = Get-FlintSecretNamePattern
            $sizes = @($selected.PSObject.Properties | Select-Object -First 50 | ForEach-Object {
                if ($_.Name -match $secretName -or (Protect-FlintText $null $_.Name) -match $secretName) { $_.Name }
                else { $_.Name + ' (' + (ConvertTo-Json -InputObject $_.Value -Depth 100 -Compress).Length + ')' }
            })
            $detail = ' Properties with their sizes: ' + ($sizes -join ', ') + '.'
        }
        throw ('The value at ' + $ToolArguments.json_path + ' has ' + $text.Length + ' characters, more than one 32768-character page. Select a narrower json_path, or read the file without json_path.' + $detail)
    }
    return @{
        status = 'ok'; exit_code = 0; output = $text; retryable = $false; duration_ms = 0; truncated = $false
        json_path = $ToolArguments.json_path; value_type = $type; value_chars = $text.Length; size_bytes = $entry.Length
    }
}
