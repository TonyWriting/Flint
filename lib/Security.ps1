function Get-FlintSessionSecrets {
    param([hashtable]$Session)
    # Flint knows its own credentials exactly, so matching them never guesses.
    if (-not $Session) { return @() }
    return @(@($Session.ApiKey, $Session.Azure.AccessToken, $Session.Azure.KeyVault.AccessToken) | Where-Object { $_ })
}

function Test-FlintSecretInJson {
    param([hashtable]$Session, [AllowEmptyString()][string]$Json)
    # Checks serialized data that was redacted when it entered the session. A credential inside a JSON string
    # appears as ConvertTo-Json escapes it, once more for each level of JSON embedded in a string.
    foreach ($secret in @(Get-FlintSessionSecrets $Session)) {
        $form = $secret
        for ($level = 0; $level -lt 4; $level++) {
            if ($Json.Contains($form)) { return $true }
            $escaped = ConvertTo-Json -InputObject $form -Compress
            $escaped = $escaped.Substring(1, $escaped.Length - 2)
            if ($escaped -ceq $form) { break }
            $form = $escaped
        }
    }
    return $false
}

function Test-FlintJsonKeysKept {
    param([AllowEmptyString()][string]$Text, [AllowEmptyString()][string]$Decoded)
    # ConvertFrom-Json keeps only the last of duplicate keys, so text that spells out more keys than its compact
    # decoded form holds values redaction never saw. Each colon outside a string literal follows one key.
    $literal = '"(?>(?:[^"\\]|\\.)*)"'
    return (($Text -replace $literal, '') -split ':').Count -eq (($Decoded -replace $literal, '') -split ':').Count
}

function Get-FlintJsonStrings {
    param($Value)
    # Every string value and property name of decoded JSON: the text a tool actually receives.
    if ($Value -is [string]) { $Value }
    elseif ($Value -is [array]) { foreach ($item in $Value) { Get-FlintJsonStrings $item } }
    elseif ($Value -is [pscustomobject]) { foreach ($property in $Value.PSObject.Properties) { $property.Name; Get-FlintJsonStrings $property.Value } }
}

function Test-FlintUnsafeArguments {
    param([hashtable]$Session, [AllowEmptyString()][string]$Arguments)
    # Tools run the arguments exactly as the model wrote them. Field names that look like credentials are
    # often configuration, so only Flint's own credentials and control characters are refused, in the raw
    # arguments and in every decoded string, where JSON escapes no longer hide them.
    $texts = @($Arguments)
    try { $texts += @(Get-FlintJsonStrings (ConvertFrom-Json -InputObject $Arguments -ErrorAction Stop)) } catch { }
    $secrets = @(Get-FlintSessionSecrets $Session)
    foreach ($text in $texts) {
        # Tabs and line breaks are ordinary text; other control characters could drive the terminal.
        if ($text -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') { return $true }
        foreach ($secret in $secrets) { if ($text.Contains($secret)) { return $true } }
    }
    return $false
}

function Protect-FlintText {
    param([hashtable]$Session, [AllowEmptyString()][string]$Text, [object[]]$Secrets)
    # Protect-FlintValue looks up the session credentials once for a whole value instead of once per string.
    if ($null -eq $Secrets) { $Secrets = @(Get-FlintSessionSecrets $Session) }
    foreach ($secret in $Secrets) { $Text = $Text.Replace($secret, '[redacted]') }
    # Every pattern below needs one of these markers. Most text has none, and one check costs less than every replacement.
    if ($Text -notmatch '(?i)[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]|PRIVATE KEY|Bearer|Basic|://|api[-_]?key|token|passw|secret|accountkey|sig|authorization|eyJ|sk-|gh[pousr]_|github_pat_') { return $Text }
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
    param([hashtable]$Session, $Value, [switch]$Untrusted, [object[]]$Secrets)
    # Untrusted values come from tools or were decoded from text. They never count as Flint's own
    # conversation items, whatever type they declare.
    if ($null -eq $Value) { return $null }
    if ($null -eq $Secrets) { $Secrets = @(Get-FlintSessionSecrets $Session) }
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
                $safeJson = ConvertTo-Json -InputObject (Protect-FlintValue $Session $decoded -Untrusted -Secrets $Secrets) -Depth 64 -Compress
                if ($originalJson -ceq $safeJson -and (Test-FlintJsonKeysKept $Value $originalJson)) { return $Value }
                return $safeJson
            } catch { }
        }
        return Protect-FlintText $Session $Value $Secrets
    }
    # ConvertFrom-Json can decorate arrays with PSObject metadata in Windows PowerShell.
    # Preserve their array shape before inspecting object properties.
    if ($Value -is [array]) {
        $safeItems = @(foreach ($item in $Value) { Protect-FlintValue $Session $item -Untrusted:$Untrusted -Secrets $Secrets })
        return ,$safeItems
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $safe = [ordered]@{}
        $names = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
        if ($Value -is [System.Collections.IDictionary]) { $names = @($Value.Keys) }
        foreach ($name in $names) {
            $safeName = Protect-FlintText $Session $name $Secrets
            if (-not $Untrusted -and $name -ceq 'encrypted_content' -and $Value.type -ceq 'reasoning') {
                # Service-issued reasoning state goes back unchanged; a pattern match inside it would break every later request.
                $safe[$safeName] = $Value.$name
            } elseif ($name -match '(?i)(?:^|[_-])(?:api[-_]?key|access[-_]?token|refresh[-_]?token|id[-_]?token|token|password|passwd|client[-_]?secret|secret|accountkey|sig|signature|authorization)$') {
                $safe[$safeName] = '[redacted]'
            } else { $safe[$safeName] = Protect-FlintValue $Session $Value.$name -Untrusted:$Untrusted -Secrets $Secrets }
        }
        return $safe
    }
    return $Value
}

function Assert-FlintFilePathText {
    param([string]$Path, [switch]$AllowInternalNames)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 240) { throw 'Provide a literal local path of at most 240 characters.' }
    $partsPath = $Path
    if ($Path -match '^[A-Za-z]:[\\/]') { $partsPath = $Path.Substring(3) }
    elseif ($Path -match '^[\\/]') { throw 'Use a relative path or an absolute local drive path.' }
    if ($partsPath -match '[:*?"<>|\x00-\x1f]') { throw 'Unsupported literal file path.' }
    foreach ($part in ($partsPath -split '[\\/]')) {
        if ($part -in @('', '.', '..')) { continue }
        if ($part -match '[ .]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Unsupported Windows path.' }
        # Credential files stay protected everywhere; readable locations only open Flint's internal directories.
        if ($part -match '^(?i:\.env(?:\..*)?|\.ssh|\.kube|\.azure|credentials(?:\..*)?|id_rsa|id_ed25519)$' -or $part -match '\.(?i:pem|pfx|p12|key)$' -or
            (-not $AllowInternalNames -and $part -match '^(?i:\.git|\.flint)$')) { throw 'Credential files and internal directories are protected.' }
    }
}

function Get-FlintCanonicalPath {
    param([string]$Path)
    $current = $Path; $missing = @()
    while (-not (Test-Path -LiteralPath $current)) {
        $parent = Split-Path $current -Parent
        if (-not $parent -or $parent -eq $current) { return $Path }
        $missing = @((Split-Path $current -Leaf)) + $missing
        $current = $parent
    }
    $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if ($item.PSProvider.Name -ne 'FileSystem') { throw 'Only filesystem paths are supported.' }
    # Resolve-Path preserves 8.3 aliases; FileSystemInfo.FullName expands them.
    $canonical = $item.FullName
    foreach ($part in $missing) { $canonical = Join-Path $canonical $part }
    return $canonical
}

function Test-FlintPathWithinDirectory {
    param([string]$Path, [string]$Directory)
    if (-not $Path -or -not $Directory) { return $false }
    $Path = Get-FlintCanonicalPath $Path
    $Directory = Get-FlintCanonicalPath $Directory
    return $Path.TrimEnd('\') -ieq $Directory.TrimEnd('\') -or $Path.StartsWith($Directory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-FlintNoLinkInPath {
    param([string]$Path, [string]$Message)
    # Every existing component, up to the drive root, must be a plain filesystem entry rather than a symlink or junction.
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.PSProvider.Name -ne 'FileSystem' -or ($item.Attributes -band 1024)) { throw $Message }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Resolve-AgentPath {
    param([string]$Root, [string]$Path, [string[]]$ProtectedPaths = @(), [string[]]$ReadDirectories = @())
    if ([string]::IsNullOrWhiteSpace($Root)) { throw 'The working directory is required.' }
    Assert-FlintFilePathText $Path -AllowInternalNames:($ReadDirectories.Count -gt 0)
    $candidate = $Path.Replace('/', '\')
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { $candidate = Join-Path $Root $candidate }
    if (-not (Test-Path -LiteralPath $candidate)) {
        $parentPath = Split-Path $candidate -Parent
        if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) { throw 'The parent directory must exist.' }
    }
    $resolved = Get-FlintCanonicalPath $candidate
    $allowedRead = $false
    foreach ($directory in $ReadDirectories) {
        if (Test-FlintPathWithinDirectory $resolved $directory) { $allowedRead = $true; break }
    }
    Assert-FlintFilePathText $resolved -AllowInternalNames:$allowedRead
    if (-not $allowedRead) {
        Assert-FlintFilePathText $Path
        foreach ($protected in $ProtectedPaths) {
            if (Test-FlintPathWithinDirectory $resolved $protected) {
                throw 'This path is protected for the requested operation.'
            }
        }
    }
    Assert-FlintNoLinkInPath $resolved 'Symlinks and junctions are not supported.'
    return $resolved
}
