function Get-FlintResultDirectory {
    param([string]$Root, [string]$SessionId)
    if ($SessionId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid result session ID.' }
    return Join-Path (Join-Path $Root '.flint\results') $SessionId
}

function Assert-FlintResultPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Length -gt 240) { throw 'Result files require a local absolute path of at most 240 characters.' }
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.PSProvider.Name -ne 'FileSystem' -or ($item.Attributes -band 1024)) { throw 'Result files cannot use symlinks or junctions.' }
        }
        $current = Split-Path $current -Parent
    }
}

function Assert-FlintResultJsonDepth {
    param($Value, [int]$Depth = 0)
    if ($Value -is [array]) {
        if ($Depth -gt 100) { throw 'Response JSON exceeds the supported depth of 100.' }
        foreach ($item in $Value) { Assert-FlintResultJsonDepth $item ($Depth + 1) }
    } elseif ($Value -is [pscustomobject]) {
        if ($Depth -gt 100) { throw 'Response JSON exceeds the supported depth of 100.' }
        foreach ($property in $Value.PSObject.Properties) { Assert-FlintResultJsonDepth $property.Value ($Depth + 1) }
    }
}

function Save-FlintAzureResult {
    param([hashtable]$Session, [AllowEmptyString()][string]$Content)
    $directory = Get-FlintResultDirectory $Session.Root $Session.Id
    $id = [guid]::NewGuid().ToString('N')
    $format = 'text'; $extension = '.txt'; $decoded = $null; $itemCount = $null; $nextLink = $null
    if ($Content.TrimStart() -match '^[\[{]') {
        # Invalid JSON can still be a useful HTTP error body; preserve it as redacted text.
        try {
            # An object wrapper preserves empty and single-item root arrays in PowerShell 5.1.
            $decoded = (ConvertFrom-Json -InputObject ('{"response":' + $Content + '}') -ErrorAction Stop).response
            $format = 'json'; $extension = '.json'
        } catch { }
    }
    if ($format -eq 'json') {
        Assert-FlintResultJsonDepth $decoded
        $safe = Protect-FlintValue $Session $decoded
        $text = ConvertTo-Json -InputObject $safe -Depth 100
        if ($safe -is [array]) { $itemCount = $safe.Count }
        elseif ($safe.value -is [array]) { $itemCount = $safe.value.Count }
        if ($safe -isnot [array] -and $safe.nextLink -is [string] -and $safe.nextLink.Length -le 8192) { $nextLink = $safe.nextLink }
    } else { $text = Protect-FlintText $Session $Content }
    $path = Join-Path $directory ($id + $extension)
    $temporary = Join-Path $directory ($id + '.tmp')
    Assert-FlintResultPath $path
    Assert-FlintResultPath $temporary
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    try {
        Set-Content -LiteralPath $temporary -Value $text -Encoding UTF8 -NoNewline -ErrorAction Stop
        Assert-FlintResultPath $path
        Move-Item -LiteralPath $temporary -Destination $path -ErrorAction Stop
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    $previewLength = $text.Length
    if ($previewLength -gt 2048) { $previewLength = 2048 }
    if ($previewLength -gt 0 -and $previewLength -lt $text.Length) {
        $last = [int][char]$text[$previewLength - 1]
        if ($last -ge 55296 -and $last -le 56319) { $previewLength-- }
    }
    return @{
        result_id = $id; result_path = $path; format = $format
        size_bytes = (Get-Item -LiteralPath $path -ErrorAction Stop).Length; content_chars = $text.Length
        item_count = $itemCount; next_link = $nextLink
        output = $text.Substring(0, $previewLength); preview_truncated = ($previewLength -lt $text.Length)
    }
}

function Read-FlintResult {
    param([string]$Root, [string]$SessionId, $ToolArguments)
    if ($ToolArguments.result_id -cnotmatch '^[a-f0-9]{32}$') { throw 'Use the result_id returned by azure_request.' }
    $directory = Get-FlintResultDirectory $Root $SessionId
    $paths = @(foreach ($extension in @('.json', '.txt')) {
        $candidate = Join-Path $directory ($ToolArguments.result_id + $extension)
        Assert-FlintResultPath $candidate
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
    })
    if ($paths.Count -ne 1) { throw 'The saved result was not found uniquely in this session. It may have been removed from disk.' }
    return Read-FlintTextFile $paths[0] $ToolArguments
}
