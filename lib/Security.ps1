function Protect-FlintText {
    param([hashtable]$Session, [AllowEmptyString()][string]$Text)
    if ($Session -and $Session.ApiKey) { $Text = $Text.Replace($Session.ApiKey, '[redacted]') }
    if ($Session -and $Session.Azure.AccessToken) { $Text = $Text.Replace($Session.Azure.AccessToken, '[redacted]') }
    if ($Session -and $Session.Azure.KeyVault.AccessToken) { $Text = $Text.Replace($Session.Azure.KeyVault.AccessToken, '[redacted]') }
    $Text = $Text -replace '\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', ''
    $Text = $Text -replace '\x1b\[[0-?]*[ -/]*[@-~]', ''
    $Text = $Text -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', ''
    $Text = $Text -replace '(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----', '[redacted private key]'
    $Text = $Text -replace '(?i)\b(Bearer|Basic)\s+[A-Za-z0-9+/_.=~%-]+', '$1 [redacted]'
    $Text = $Text -replace '(?i)(https?://)[^\s/@]+:[^\s/@]+@', '$1[redacted]@'
    $Text = $Text -replace '(?i)(["'']?(?:api[-_]?key|access[-_]?token|refresh[-_]?token|id[-_]?token|(?<![a-z0-9])token|password|passwd|client[-_]?secret|secret|accountkey|sig|signature|authorization)["'']?\s*[:=]\s*)("[^"\r\n]*"|''[^''\r\n]*''|[^\s,;&}\r\n]+)', '$1"[redacted]"'
    $Text = $Text -replace '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '[redacted JWT]'
    $Text = $Text -replace '\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b', '[redacted token]'
    return $Text
}

function Protect-FlintValue {
    param([hashtable]$Session, $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        # Responses arguments and tool outputs contain JSON inside JSON strings.
        # Redact decoded values so quotes and backslashes stay valid on repeated passes.
        if ($Value.TrimStart().StartsWith('{') -or $Value.TrimStart().StartsWith('[')) {
            try {
                $decoded = ConvertFrom-Json -InputObject $Value -ErrorAction Stop
                if ($Value.TrimStart().StartsWith('[') -and $decoded -isnot [array]) {
                    if ($null -eq $decoded) { $decoded = @() } else { $decoded = @($decoded) }
                }
                $originalJson = ConvertTo-Json -InputObject $decoded -Depth 64 -Compress
                $safeJson = ConvertTo-Json -InputObject (Protect-FlintValue $Session $decoded) -Depth 64 -Compress
                if ($originalJson -ceq $safeJson) { return $Value }
                return $safeJson
            } catch { }
        }
        return Protect-FlintText $Session $Value
    }
    # ConvertFrom-Json can decorate arrays with PSObject metadata in Windows PowerShell.
    # Preserve their array shape before inspecting object properties.
    if ($Value -is [array]) {
        $safeItems = @(foreach ($item in $Value) { Protect-FlintValue $Session $item })
        return ,$safeItems
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $safe = [ordered]@{}
        $names = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
        if ($Value -is [System.Collections.IDictionary]) { $names = @($Value.Keys) }
        foreach ($name in $names) {
            $safeName = Protect-FlintText $Session $name
            if ($name -match '(?i)(?:^|[_-])(?:api[-_]?key|access[-_]?token|refresh[-_]?token|id[-_]?token|token|password|passwd|client[-_]?secret|secret|accountkey|sig|signature|authorization)$') {
                $safe[$safeName] = '[redacted]'
            } else { $safe[$safeName] = Protect-FlintValue $Session $Value.$name }
        }
        return $safe
    }
    return $Value
}

function Assert-FlintFilePathText {
    param([string]$Path, [switch]$AllowProtectedNames)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 240) { throw 'Provide a literal local path of at most 240 characters.' }
    $partsPath = $Path
    if ($Path -match '^[A-Za-z]:[\\/]') { $partsPath = $Path.Substring(3) }
    elseif ($Path -match '^[\\/]') { throw 'Use a relative path or an absolute local drive path.' }
    if ($partsPath -match '[:*?"<>|\x00-\x1f]') { throw 'Unsupported literal file path.' }
    foreach ($part in ($partsPath -split '[\\/]')) {
        if ($part -in @('', '.', '..')) { continue }
        if ($part -match '[ .]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Unsupported Windows path.' }
        if (-not $AllowProtectedNames -and ($part -match '^(?i:\.env(?:\..*)?|\.git|\.flint|\.ssh|\.kube|\.azure|credentials(?:\..*)?|id_rsa|id_ed25519)$' -or
            $part -match '\.(?i:pem|pfx|p12|key)$')) { throw 'Credential files and internal directories are protected.' }
    }
}

function Test-FlintPathWithinDirectory {
    param([string]$Path, [string]$Directory)
    if (-not $Directory) { return $false }
    return $Path.TrimEnd('\') -ieq $Directory.TrimEnd('\') -or $Path.StartsWith($Directory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-AgentPath {
    param([string]$Root, [string]$Path, [string[]]$ProtectedPaths = @(), [string[]]$ReadDirectories = @())
    if ([string]::IsNullOrWhiteSpace($Root)) { throw 'The working directory is required.' }
    Assert-FlintFilePathText $Path -AllowProtectedNames:($ReadDirectories.Count -gt 0)
    $candidate = $Path.Replace('/', '\')
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { $candidate = Join-Path $Root $candidate }
    if (Test-Path -LiteralPath $candidate) {
        $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath
    } else {
        $parentPath = Split-Path $candidate -Parent
        if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) { throw 'The parent directory must exist.' }
        $parent = (Resolve-Path -LiteralPath $parentPath -ErrorAction Stop).ProviderPath
        $resolved = Join-Path $parent (Split-Path $candidate -Leaf)
    }
    $allowedRead = $false
    foreach ($directory in $ReadDirectories) {
        if (Test-FlintPathWithinDirectory $resolved $directory) { $allowedRead = $true; break }
    }
    Assert-FlintFilePathText $resolved -AllowProtectedNames:$allowedRead
    if (-not $allowedRead) {
        Assert-FlintFilePathText $Path
        foreach ($protected in $ProtectedPaths) {
            if (Test-FlintPathWithinDirectory $resolved $protected) {
                throw 'This path is protected for the requested operation.'
            }
        }
    }
    $current = $resolved
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $entry = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($entry.Attributes -band 1024) { throw 'Symlinks and junctions are not supported.' }
            if ($entry.PSProvider.Name -ne 'FileSystem') { throw 'Only filesystem paths are supported.' }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $resolved
}
