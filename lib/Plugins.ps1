function Get-FlintPluginDirectory {
    return Join-Path (Split-Path $PSScriptRoot -Parent) 'plugins'
}

function Get-FlintPluginLimits {
    return @{ MaxFileBytes = 1048576; MaxTotalBytes = 16777216; MaxFiles = 2000; MaxRelativePath = 120; MaxManifestBytes = 65536; MaxRuleBytes = 262144 }
}

function Get-FlintPluginInventory {
    param([string]$Root)
    # Walk without following links so every reported file is a regular file inside the plugin.
    $limits = Get-FlintPluginLimits
    $files = @{}; $errors = @(); $total = 0L; $longest = 0
    $pending = @($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending[0]
        $pending = @($pending | Select-Object -Skip 1)
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            $relative = $child.FullName.Substring($Root.Length + 1)
            if ($child.Attributes -band 1024) { $errors += ($relative + ': symlinks and junctions are not allowed.'); continue }
            if ($relative.Length -gt $limits.MaxRelativePath) { $errors += ($relative + ': relative paths are limited to ' + $limits.MaxRelativePath + ' characters.'); continue }
            try { Assert-FlintFilePathText $relative } catch { $errors += ($relative + ': ' + $_.Exception.Message); continue }
            if ($relative.Length -gt $longest) { $longest = $relative.Length }
            if ($child.PSIsContainer) { $pending += $child.FullName; continue }
            if ($child.Extension.ToLowerInvariant() -cnotin @('.md', '.json', '.txt')) { $errors += ($relative + ': only .md, .json and .txt files are allowed.'); continue }
            if ($child.Length -gt $limits.MaxFileBytes) { $errors += ($relative + ': files are limited to 1 MiB.'); continue }
            $total += $child.Length
            $files[$relative.ToLowerInvariant()] = $relative
        }
    }
    if ($files.Count -gt $limits.MaxFiles) { $errors += ('The plugin has ' + $files.Count + ' files; the limit is ' + $limits.MaxFiles + '.') }
    if ($total -gt $limits.MaxTotalBytes) { $errors += ('The plugin has ' + $total + ' bytes; the limit is 16 MiB.') }
    return @{ files = $files; errors = $errors; total_bytes = $total; longest_path = $longest }
}

function Resolve-FlintPluginReference {
    param([string]$Root, [hashtable]$Files, $Value, [string]$Field, [string]$Extension)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw ($Field + ' must be a relative file path.') }
    $relative = $Value.Replace('/', '\')
    $parts = @($relative -split '\\')
    if ($relative -match '^[A-Za-z]:' -or $relative.StartsWith('\') -or $parts -contains '..' -or $parts -contains '.' -or $parts -contains '') {
        throw ($Field + " must be a relative path inside the plugin without '.' or '..': " + $Value)
    }
    if (-not $relative.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) { throw ($Field + ' must name a ' + $Extension + ' file: ' + $Value) }
    $key = $relative.ToLowerInvariant()
    if (-not $Files.ContainsKey($key)) { throw ($Field + " refers to '" + $Value + "', which is not a valid file in the plugin.") }
    return Join-Path $Root $Files[$key]
}

function Test-FlintPlugin {
    param([string]$Path)
    # A plugin is data only: knowledge files, reviewed read-only kubectl rules and guarded patch resource names.
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Provide a plugin directory.' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem') { throw ('Plugin directory not found: ' + $Path) }
    if ($item.Attributes -band 1024) { throw 'Plugin directories cannot be symlinks or junctions.' }
    $root = $item.FullName.TrimEnd('\')
    $limits = Get-FlintPluginLimits
    $manifestPath = Join-Path $root 'plugin.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw ("No plugin.json was found in '" + $root + "'. Point the source at the plugin folder itself.") }
    if ((Get-Item -LiteralPath $manifestPath -Force).Length -gt $limits.MaxManifestBytes) { throw 'plugin.json exceeds 64 KiB.' }
    try { $manifest = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop }
    catch { throw 'plugin.json is not valid JSON.' }
    if ($manifest -isnot [pscustomobject]) { throw 'plugin.json must contain a JSON object.' }
    if (($manifest.schema_version -isnot [int] -and $manifest.schema_version -isnot [long]) -or $manifest.schema_version -ne 1) {
        throw ("Unsupported plugin schema_version '" + $manifest.schema_version + "'. This Flint supports schema_version 1.")
    }
    $inventory = Get-FlintPluginInventory $root
    $errors = @($inventory.errors)
    foreach ($field in @($manifest.PSObject.Properties.Name)) {
        if ($field -cnotin @('schema_version', 'name', 'version', 'summary', 'guide', 'kubectl')) { $errors += ("plugin.json has an unknown field '" + $field + "'.") }
    }
    $name = $manifest.name
    if ($name -isnot [string] -or $name -cnotmatch '^[a-z][a-z0-9-]{1,31}$') { $errors += 'name must be 2 to 32 lowercase letters, digits or hyphens, starting with a letter.'; $name = '' }
    if ($manifest.version -isnot [string] -or $manifest.version -cnotmatch '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$') { $errors += 'version must use the MAJOR.MINOR.PATCH form, such as 1.0.0.' }
    if ($manifest.summary -isnot [string] -or [string]::IsNullOrWhiteSpace($manifest.summary) -or $manifest.summary.Length -gt 400 -or $manifest.summary -match '[\x00-\x1f\x7f]') {
        $errors += 'summary must be a single line of 1 to 400 characters.'
    }
    $guide = $null; $rules = @(); $guarded = @()
    try { $guide = Resolve-FlintPluginReference $root $inventory.files $manifest.guide 'guide' '.md' } catch { $errors += $_.Exception.Message }
    if ($null -ne $manifest.kubectl) {
        $kubectl = $manifest.kubectl
        if ($kubectl -isnot [pscustomobject]) { $errors += 'kubectl must be an object.' }
        else {
            foreach ($field in @($kubectl.PSObject.Properties.Name)) {
                if ($field -cnotin @('rules', 'guarded_patch_resources')) { $errors += ("kubectl has an unknown field '" + $field + "'.") }
            }
            if ($null -ne $kubectl.rules) {
                try {
                    $rulePath = Resolve-FlintPluginReference $root $inventory.files $kubectl.rules 'kubectl.rules' '.json'
                    if ((Get-Item -LiteralPath $rulePath -Force).Length -gt $limits.MaxRuleBytes) { throw 'kubectl.rules exceeds 256 KiB.' }
                    try { $document = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $rulePath -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop }
                    catch { throw 'kubectl.rules is not valid JSON.' }
                    $rules = @(ConvertTo-FlintCommandRules $document 'kubectl' ('plugin:' + $name))
                } catch { $errors += ('kubectl.rules: ' + $_.Exception.Message) }
            }
            if ($null -ne $kubectl.guarded_patch_resources) {
                if ($kubectl.guarded_patch_resources -isnot [array] -or $kubectl.guarded_patch_resources.Count -gt 64) { $errors += 'kubectl.guarded_patch_resources must be an array of at most 64 resource names.' }
                else {
                    foreach ($resource in $kubectl.guarded_patch_resources) {
                        if ($resource -isnot [string] -or $resource -cnotmatch '^[a-z0-9][a-z0-9.-]{0,252}$') { $errors += ("kubectl.guarded_patch_resources has an invalid resource name '" + $resource + "'."); continue }
                        if ($guarded -ccontains $resource) { $errors += ("kubectl.guarded_patch_resources repeats '" + $resource + "'."); continue }
                        $guarded += $resource
                    }
                }
            }
        }
    }
    if ($errors.Count -gt 0) {
        $shown = @($errors | Select-Object -First 20 | ForEach-Object { '  - ' + $_ })
        if ($errors.Count -gt 20) { $shown += ('  - ... and ' + ($errors.Count - 20) + ' more.') }
        throw ((@("Plugin at '" + $root + "' is invalid:") + $shown) -join [Environment]::NewLine)
    }
    return @{
        name = $name; version = $manifest.version; summary = $manifest.summary; root = $root
        guide = $guide; rules = $rules; guarded = $guarded
        file_count = $inventory.files.Count; total_bytes = $inventory.total_bytes; longest_path = $inventory.longest_path; source = $null
    }
}

function Read-FlintPluginSource {
    param([string]$Directory, [string]$Name)
    # Install metadata is informational; a missing or damaged record never blocks the plugin itself.
    $path = Join-Path $Directory ($Name + '.source.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path -Force).Length -gt 65536) { return $null }
    try { $record = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop } catch { return $null }
    if ($record -isnot [pscustomobject] -or $record.version -ne 1 -or $record.name -cne $Name) { return $null }
    return $record
}

function Read-FlintPlugins {
    param([string]$Directory)
    $result = @{ loaded = @(); errors = @() }
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return $result }
    if ((Get-Item -LiteralPath $Directory -Force).Attributes -band 1024) {
        $result.errors += @{ name = 'plugins'; message = 'The plugins directory cannot be a symlink or junction.' }
        return $result
    }
    # Directories starting with '.' are install staging areas, never loaded.
    foreach ($child in @(Get-ChildItem -LiteralPath $Directory -Directory -Force -ErrorAction Stop | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name)) {
        try {
            if ($child.Attributes -band 1024) { throw 'Plugin directories cannot be symlinks or junctions.' }
            $plugin = Test-FlintPlugin $child.FullName
            if ($plugin.name -cne $child.Name) { throw ("The directory name must match the plugin name '" + $plugin.name + "'. Run agent.ps1 -Setup again.") }
            $plugin.source = Read-FlintPluginSource $Directory $plugin.name
            $result.loaded += $plugin
        } catch { $result.errors += @{ name = $child.Name; message = $_.Exception.Message } }
    }
    return $result
}

function Get-FlintPluginRecords {
    param($Plugins)
    $records = @()
    foreach ($plugin in @($Plugins)) {
        if (-not $plugin) { continue }
        $commit = $null
        if ($plugin.source -and $plugin.source.commit) { $commit = [string]$plugin.source.commit }
        $records += [ordered]@{ name = $plugin.name; version = $plugin.version; commit = $commit; rules = @($plugin.rules).Count; guarded = @($plugin.guarded).Count }
    }
    return $records
}

function Format-FlintPluginRecord {
    param($Record)
    $text = [string]$Record.version
    $commit = [string]$Record.commit
    if ($commit.Length -gt 7) { $commit = $commit.Substring(0, 7) }
    if ($commit) { $text += ' (' + $commit + ')' }
    return $text
}

function Get-FlintPluginChanges {
    param($Saved, $Current)
    $before = @{}; $after = @{}
    foreach ($record in @($Saved)) { if ($record -and $record.name) { $before[[string]$record.name] = $record } }
    foreach ($record in @($Current)) { if ($record -and $record.name) { $after[[string]$record.name] = $record } }
    $changes = @()
    foreach ($name in @($after.Keys | Sort-Object)) {
        if (-not $before.ContainsKey($name)) { $changes += ('added ' + $name + ' ' + (Format-FlintPluginRecord $after[$name])); continue }
        $old = Format-FlintPluginRecord $before[$name]; $new = Format-FlintPluginRecord $after[$name]
        if ($old -cne $new) { $changes += ($name + ' ' + $old + ' -> ' + $new) }
    }
    foreach ($name in @($before.Keys | Sort-Object)) {
        if (-not $after.ContainsKey($name)) { $changes += ('removed ' + $name + ' ' + (Format-FlintPluginRecord $before[$name])) }
    }
    return $changes
}
