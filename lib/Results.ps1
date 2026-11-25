function Get-FlintResultDirectory {
    param([string]$Root, [string]$SessionId)
    if ($SessionId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid result session ID.' }
    return Join-Path (Join-Path $Root '.flint\results') $SessionId
}

function Assert-FlintResultPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Length -gt 240) { throw 'Result files require a local absolute path of at most 240 characters.' }
    Assert-FlintNoLinkInPath $Path 'Result files cannot use symlinks or junctions.'
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

function Get-FlintResultPreview {
    param([AllowEmptyString()][string]$Text)
    # A result of up to 16384 characters goes to the model whole: reading it back later costs another
    # model call, which outweighs the context it takes. Longer results return this much as a preview.
    if ($Text.Length -le 16384) { return $Text }
    $length = 16384
    # Never end the preview on the first half of a surrogate pair.
    $last = [int][char]$Text[$length - 1]
    if ($last -ge 55296 -and $last -le 56319) { $length-- }
    return $Text.Substring(0, $length)
}

function Save-FlintResult {
    param([hashtable]$Session, [AllowEmptyString()][string]$Content, [switch]$Kubernetes)
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
        $safe = Protect-FlintValue $Session $decoded -Untrusted
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
    $preview = Get-FlintResultPreview $text
    $result = @{
        result_id = $id; result_path = $path; format = $format
        size_bytes = (Get-Item -LiteralPath $path -ErrorAction Stop).Length; content_chars = $text.Length
        item_count = $itemCount; next_link = $nextLink
        output = $preview; preview_truncated = ($preview.Length -lt $text.Length)
    }
    if ($Kubernetes -and $format -eq 'json' -and $safe -isnot [array]) {
        if ($safe.items -is [array]) { $result.item_count = $safe.items.Count }
        $result.next_continue = $null
        if ($safe.metadata.continue -is [string]) { $result.next_continue = $safe.metadata.continue }
    }
    return $result
}
