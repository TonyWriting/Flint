# Team setup: a folder that holds a flint.ini template without an API key and, optionally, Plugins\<name>
# plugin folders. -Setup writes flint.ini with the user's key and makes the installed plugins match the folder.

function ConvertFrom-FlintSetupUrl {
    param([string]$Url)
    $uri = $Url -as [uri]
    if (-not $uri -or -not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.Port -ne 443) { throw 'Setup URLs must use https on the default port.' }
    $hostName = $uri.Host.ToLowerInvariant()
    $segments = @($uri.AbsolutePath.Split('/') | Where-Object { $_ })
    foreach ($segment in $segments) { if ($segment -in @('.', '..')) { throw 'Setup URLs cannot contain relative path segments.' } }
    if ($hostName -ceq 'dev.azure.com') {
        if ($segments.Count -lt 1) { throw 'The Azure DevOps URL is missing its organization.' }
        $base = 'https://dev.azure.com/' + $segments[0]
        $rest = @($segments | Select-Object -Skip 1)
    } elseif ($hostName -cmatch '^[a-z0-9][a-z0-9-]*\.visualstudio\.com$') {
        $base = 'https://' + $hostName
        $rest = $segments
        if ($rest.Count -gt 0 -and $rest[0] -ieq 'DefaultCollection') { $base += '/' + $rest[0]; $rest = @($rest | Select-Object -Skip 1) }
    } else {
        throw 'Setup URLs must point to an Azure DevOps Git repository on dev.azure.com or <organization>.visualstudio.com.'
    }
    # Both the project form and the project-less form name a Git repository; userinfo, query and fragment never reach git.
    if ($rest.Count -eq 3 -and $rest[1] -ceq '_git') { $repository = $base + '/' + $rest[0] + '/_git/' + $rest[2] }
    elseif ($rest.Count -eq 2 -and $rest[0] -ceq '_git') { $repository = $base + '/_git/' + $rest[1] }
    else { throw 'Use the repository folder URL form https://dev.azure.com/<organization>/<project>/_git/<repository>?path=/<setup folder>.' }
    $query = @{}
    foreach ($pair in @($uri.Query.TrimStart('?').Split('&') | Where-Object { $_ })) {
        $parts = $pair -split '=', 2
        $value = ''
        if ($parts.Count -eq 2) { $value = [uri]::UnescapeDataString($parts[1]) }
        $query[[uri]::UnescapeDataString($parts[0])] = $value
    }
    # Quotes copied with a URL arrive encoded (%27, %22) and would become part of the folder or branch name.
    foreach ($name in @('path', 'version')) {
        if ([string]$query[$name] -match '[''"]') {
            throw ('The ' + $name + " parameter contains quote characters (%27 or %22), usually copied along with the URL. Remove them and try again: " + $query[$name])
        }
    }
    $path = [string]$query['path']
    if (-not $path) { throw 'Add ?path=/<setup folder> to the URL. Copy the URL from the setup folder view in Azure DevOps.' }
    $folder = $path.Trim('/')
    if (-not $folder) { throw 'Point ?path= at the setup folder, not the repository root.' }
    if ($folder.Length -gt 200) { throw 'The setup path is longer than 200 characters.' }
    foreach ($part in $folder.Split('/')) {
        if (-not $part -or $part -in @('.', '..') -or $part.StartsWith('-') -or $part -match '[\\:*?"<>|\x00-\x1f\x7f]') { throw ('Unsupported setup path: ' + $path) }
    }
    $ref = $null
    $version = [string]$query['version']
    if ($version) {
        if ($version -cmatch '^G[BT](.+)$') { $ref = $Matches[1] }
        elseif ($version.StartsWith('GC')) { throw 'Commit URLs (version=GC...) are not supported. Use a branch (GB) or tag (GT) URL.' }
        else { throw ('Unsupported version parameter: ' + $version) }
        if ($ref.StartsWith('-') -or $ref.Contains('..') -or $ref -match '[\x00-\x20\x7f~^:?*\[\\]') { throw ('Unsupported branch or tag name: ' + $ref) }
    }
    $display = $repository + '?path=/' + $folder
    if ($ref) { $display += '&version=' + $version }
    return @{ kind = 'git'; clone_url = $repository; repo_path = $folder; ref = $ref; display = $display; path = $null }
}

function ConvertFrom-FlintSetupSource {
    param([string]$Source)
    if ([string]::IsNullOrWhiteSpace($Source)) { throw 'Provide a setup source: an Azure DevOps folder URL, a local folder or a .zip file.' }
    $Source = $Source.Trim()
    if ($Source -match '^[A-Za-z][A-Za-z0-9+.-]*://') { return ConvertFrom-FlintSetupUrl $Source }
    $item = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSProvider.Name -ne 'FileSystem') { throw ('Setup source not found: ' + $Source) }
    if ($item.PSIsContainer) { return @{ kind = 'directory'; path = $item.FullName; display = $item.FullName; ref = $null; repo_path = $null } }
    if ($item.Extension -ieq '.zip') { return @{ kind = 'zip'; path = $item.FullName; display = $item.FullName; ref = $null; repo_path = $null } }
    throw 'A local setup source must be a folder or a .zip file.'
}

function Resolve-FlintGitProgram {
    $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'git was not found on PATH. Install Git for Windows, or download the setup folder as a .zip and pass it to -Setup.' }
    if (-not $command.Source.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { throw 'git must resolve to git.exe; shell wrappers are not supported.' }
    return $command.Source
}

function Invoke-FlintGit {
    param([string]$Program, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSec = 300)
    $quoted = @(foreach ($argument in $Arguments) { ConvertTo-FlintNativeArgument $argument })
    # Credential prompts use the Git Credential Manager window; a hidden console prompt would only wait for the timeout.
    $previous = $env:GIT_TERMINAL_PROMPT
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $native = Invoke-FlintProcess -FilePath $Program -ArgumentList $quoted -TimeoutSec $TimeoutSec -WorkingDirectory $WorkingDirectory
    } finally {
        if ($null -eq $previous) { Remove-Item -LiteralPath Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $previous }
    }
    if ($native.status -ne 'ok') {
        $detail = ($native.stderr + ' ' + $native.stdout).Trim()
        if ($detail.Length -gt 800) { $detail = $detail.Substring(0, 800) + '...' }
        throw ('git ' + $Arguments[0] + ' ended with ' + $native.status + ' (exit code ' + $native.exit_code + '). ' + $detail)
    }
    return $native.stdout.Trim()
}

function Write-FlintSetupStep {
    param([string]$Text, [datetime]$Started)
    # Native output is captured, so each finished step reports itself with its duration.
    Write-Host ('  {0} ({1:N1}s)' -f $Text, ([datetime]::UtcNow - $Started).TotalSeconds) -ForegroundColor DarkGray
}

function Get-FlintGitFolder {
    param($Source, [string]$Work)
    $git = Resolve-FlintGitProgram
    $repository = Join-Path $Work 'repository'
    $started = [datetime]::UtcNow
    # A shallow, blobless, sparse clone downloads only the setup folder and the repository root files.
    $clone = @('clone', '--quiet', '--depth', '1', '--filter=blob:none', '--sparse')
    if ($Source.ref) { $clone += @('--branch', $Source.ref) }
    $clone += @('--', $Source.clone_url, $repository)
    try { $null = Invoke-FlintGit $git $clone $Work }
    catch {
        $message = $_.Exception.Message
        # Reaching the branch list means sign-in worked; only point to sign-in for authentication failures.
        if ($Source.ref -and $message -match 'Remote branch .* not found') {
            throw ("Branch or tag '" + $Source.ref + "' was not found in " + $Source.clone_url + '. Check the version= parameter of the URL, or omit it to use the default branch.')
        }
        if ($message -match '(?i)authentication failed|could not read username|terminal prompts disabled|\b(401|403)\b|not authorized|access denied') {
            throw ($message + ' Sign in to Azure DevOps first: run "git clone ' + $Source.clone_url + '" once in a terminal, or download the setup folder as a .zip from Azure DevOps and pass that file.')
        }
        throw ($message + ' If the repository cannot be reached, download the setup folder as a .zip from Azure DevOps and pass that file.')
    }
    Write-FlintSetupStep 'Connected and read the repository' $started
    $started = [datetime]::UtcNow
    $null = Invoke-FlintGit $git @('-C', $repository, 'sparse-checkout', 'set', $Source.repo_path) $Work
    $commit = Invoke-FlintGit $git @('-C', $repository, 'rev-parse', 'HEAD') $Work
    $short = $commit
    if ($short.Length -gt 7) { $short = $short.Substring(0, 7) }
    Write-FlintSetupStep ('Downloaded the setup folder at commit ' + $short) $started
    $folder = Join-Path $repository $Source.repo_path.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        $branch = 'the default branch'
        if ($Source.ref) { $branch = "'" + $Source.ref + "'" }
        throw ("The repository has no folder '/" + $Source.repo_path + "' on " + $branch + '.')
    }
    return @{ folder = $folder; commit = $commit }
}

function Expand-FlintSetupZip {
    param([string]$ZipPath, [string]$Work)
    # Windows tar.exe refuses absolute and '..' entries; links are rejected later by validation.
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) { throw 'Extracting a .zip requires tar.exe from Windows 10 or later. Extract the archive and pass the folder instead.' }
    $destination = Join-Path $Work 'archive'
    New-Item -ItemType Directory -Path $destination -ErrorAction Stop | Out-Null
    $native = Invoke-FlintProcess -FilePath $tar -ArgumentList @('-x', '-f', (ConvertTo-FlintNativeArgument $ZipPath), '-C', (ConvertTo-FlintNativeArgument $destination)) -TimeoutSec 120 -WorkingDirectory $Work
    if ($native.status -ne 'ok') { throw ('Could not extract ' + $ZipPath + ': ' + ($native.stderr + ' ' + $native.stdout).Trim()) }
    # Azure DevOps "Download as Zip" wraps the folder in one top-level directory.
    if (Test-Path -LiteralPath (Join-Path $destination 'flint.ini') -PathType Leaf) { return $destination }
    $children = @(Get-ChildItem -LiteralPath $destination -Force)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer -and -not ($children[0].Attributes -band 1024) -and
        (Test-Path -LiteralPath (Join-Path $children[0].FullName 'flint.ini') -PathType Leaf)) { return $children[0].FullName }
    throw 'The archive must contain flint.ini at its root or inside a single top-level folder.'
}

function Remove-FlintTreeItem {
    param($Item)
    if ($Item.Attributes -band 1024) {
        # Remove only the link itself; its target may be outside Flint.
        if (-not $Item.PSIsContainer) { Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop; return }
        if ($Item.FullName -match '[%"]') { throw ('Cannot safely remove the directory link ' + $Item.FullName + '. Remove it manually.') }
        $native = Invoke-FlintProcess -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/d', '/c', 'rmdir', ('"' + $Item.FullName + '"')) -TimeoutSec 30 -WorkingDirectory $env:SystemRoot
        if ($native.status -ne 'ok') { throw ('Could not remove the directory link ' + $Item.FullName + '.') }
        return
    }
    if ($Item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction Stop)) { Remove-FlintTreeItem $child }
    }
    Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
}

function Remove-FlintDirectoryTree {
    param([string]$Path, [string]$Parent)
    # Only remove directories Flint created directly under a known parent.
    if (-not $Path -or -not $Parent -or -not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ((Split-Path $item.FullName -Parent).TrimEnd('\') -ine $Parent.TrimEnd('\')) { throw ('Refusing to remove ' + $item.FullName + ' outside ' + $Parent + '.') }
    Remove-FlintTreeItem $item
}

function Test-FlintSetup {
    param([string]$Path)
    # A setup folder holds flint.ini without api_key, an optional Plugins folder of plugin folders, and .md notes.
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Provide a setup folder.' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem') { throw ('Setup folder not found: ' + $Path) }
    if ($item.Attributes -band 1024) { throw 'Setup folders cannot be symlinks or junctions.' }
    $root = $item.FullName.TrimEnd('\')
    $template = Join-Path $root 'flint.ini'
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { throw ("No flint.ini was found in '" + $root + "'. Point the source at the setup folder itself.") }
    $errors = @(); $model = $null; $plugins = @()
    try {
        $values = Read-FlintIniFile $template (Get-FlintConfigSchema)
        if ($values.ContainsKey('model.api_key')) { throw 'remove api_key. Flint asks each user for the key during setup, so keys never live in the shared folder.' }
        $model = ConvertTo-FlintModelConfig $values -WithoutKey
    } catch { $errors += ('flint.ini: ' + $_.Exception.Message) }
    $pluginFolder = $null
    foreach ($child in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
        if ($child.Attributes -band 1024) { $errors += ($child.Name + ': symlinks and junctions are not allowed.'); continue }
        if ($child.PSIsContainer -and $child.Name -ieq 'Plugins') { $pluginFolder = $child.FullName; continue }
        if (-not $child.PSIsContainer -and ($child.Name -ieq 'flint.ini' -or $child.Extension -ieq '.md')) { continue }
        $errors += ($child.Name + ': a setup folder holds only flint.ini, a Plugins folder and .md notes.')
    }
    if ($pluginFolder) {
        foreach ($child in @(Get-ChildItem -LiteralPath $pluginFolder -Force -ErrorAction Stop | Sort-Object Name)) {
            if ($child.Attributes -band 1024) { $errors += ('Plugins\' + $child.Name + ': symlinks and junctions are not allowed.'); continue }
            if (-not $child.PSIsContainer) {
                if ($child.Extension -ieq '.md') { continue }
                $errors += ('Plugins\' + $child.Name + ': the Plugins folder holds only plugin folders and .md notes.'); continue
            }
            try {
                $plugin = Test-FlintPlugin $child.FullName
                if ($plugin.name -cne $child.Name.ToLowerInvariant()) { throw ("the folder name must match the plugin name '" + $plugin.name + "'.") }
                $plugins += $plugin
            } catch { $errors += ('Plugins\' + $child.Name + ': ' + $_.Exception.Message) }
        }
    }
    if ($errors.Count -gt 0) {
        $shown = @($errors | Select-Object -First 20 | ForEach-Object { '  - ' + $_ })
        if ($errors.Count -gt 20) { $shown += ('  - ... and ' + ($errors.Count - 20) + ' more.') }
        throw ((@("Setup at '" + $root + "' is invalid:") + $shown) -join [Environment]::NewLine)
    }
    return @{ root = $root; model = $model; plugins = $plugins }
}

function Show-FlintSetupSummary {
    param($Setup)
    Write-Host ('  Model: ' + $Setup.model.Model + ' at ' + $Setup.model.ApiEndpoint)
    $names = @($Setup.plugins | ForEach-Object { $_.name + ' ' + $_.version })
    if ($names.Count -eq 0) { $names = @('none') }
    Write-Host ('  Plugins: ' + ($names -join ', '))
}

function Show-FlintPluginSummary {
    param($Plugin)
    $guarded = 'none'
    $names = @($Plugin.guarded)
    if ($names.Count -gt 0) { $guarded = (@($names | Select-Object -First 4) -join ', ') }
    if ($names.Count -gt 4) { $guarded += ' and ' + ($names.Count - 4) + ' more' }
    Write-Host ('  ' + $Plugin.name + ' ' + $Plugin.version + ': ' + $Plugin.summary)
    Write-Host ('    Files: {0} ({1:N0} KiB); reviewed reads: {2}; guarded resources: {3}' -f $Plugin.file_count, [long]($Plugin.total_bytes / 1024), @($Plugin.rules).Count, $guarded) -ForegroundColor DarkGray
}

function Format-FlintIniValue {
    param([string]$Value)
    # The reader strips one pair of matching quotes, so values that start with a quote get wrapped in the other kind.
    if ($Value.StartsWith('"')) { return "'" + $Value + "'" }
    if ($Value.StartsWith("'")) { return '"' + $Value + '"' }
    return $Value
}

function Save-FlintStagedConfig {
    param([string]$Path, [string]$Source, $Model, [string]$ApiKey)
    $lines = @(
        ('; Written by agent.ps1 -Setup from ' + $Source + '. Run -Setup again to update. Keep this file private.')
        '[model]'
        ('endpoint = ' + (Format-FlintIniValue $Model.ApiEndpoint))
        ('deployment = ' + (Format-FlintIniValue $Model.Model))
    )
    if ($Model.ApiKeyHelp) { $lines += ('api_key_help = ' + (Format-FlintIniValue $Model.ApiKeyHelp)) }
    # The user pastes the key after the equals sign; Flint never reads it from the terminal.
    if ($ApiKey) { $lines += ('api_key = ' + (Format-FlintIniValue $ApiKey)) } else { $lines += 'api_key =' }
    # Staged next to the target, so replacing flint.ini later is a rename within one folder.
    $staged = Join-Path (Split-Path $Path -Parent) ('.flint-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { Set-Content -LiteralPath $staged -Value $lines -Encoding UTF8 -ErrorAction Stop }
    catch {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        throw ("Could not write the new configuration next to '" + $Path + "': " + $_.Exception.Message)
    }
    return $staged
}

function Install-FlintPluginCopy {
    param($Plugin, [string]$PluginRoot, $Record)
    $target = Join-Path $PluginRoot $Plugin.name
    # Stage next to the target so the final switch is a rename on the same volume.
    $staging = Join-Path $PluginRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
    $old = $null
    try {
        Copy-Item -LiteralPath $Plugin.root -Destination $staging -Recurse -Force -ErrorAction Stop
        $null = Test-FlintPlugin $staging
        $previous = $null
        if (Test-Path -LiteralPath $target) {
            try { $previous = (Test-FlintPlugin $target).version } catch { $previous = 'an invalid copy' }
            $old = Join-Path $PluginRoot ('.old-' + [guid]::NewGuid().ToString('N'))
            try { Move-Item -LiteralPath $target -Destination $old -ErrorAction Stop }
            catch { $old = $null; throw ("Could not replace the installed plugin '" + $Plugin.name + "'. Close running Flint sessions and try again.") }
        }
        try { Move-Item -LiteralPath $staging -Destination $target -ErrorAction Stop; $staging = $null }
        catch {
            if ($old) { Move-Item -LiteralPath $old -Destination $target -ErrorAction SilentlyContinue; $old = $null }
            throw
        }
        $recordPath = Join-Path $PluginRoot ($Plugin.name + '.source.json')
        $temporary = Join-Path $PluginRoot ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            Set-Content -LiteralPath $temporary -Value (ConvertTo-Json -InputObject $Record -Depth 4) -Encoding UTF8 -ErrorAction Stop
            Move-Item -LiteralPath $temporary -Destination $recordPath -Force -ErrorAction Stop
        } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        return $previous
    } finally {
        if ($old) { Remove-FlintDirectoryTree $old $PluginRoot }
        if ($staging) { Remove-FlintDirectoryTree $staging $PluginRoot }
    }
}

function Sync-FlintPlugins {
    param($Plugins, [string]$PluginDirectory, $Source, [string]$Commit)
    if (-not (Test-Path -LiteralPath $PluginDirectory)) { New-Item -ItemType Directory -Path $PluginDirectory -ErrorAction Stop | Out-Null }
    $directory = Get-Item -LiteralPath $PluginDirectory -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band 1024)) { throw 'The plugins directory must be a real directory, not a file or link.' }
    $pluginRoot = $directory.FullName.TrimEnd('\')
    foreach ($plugin in @($Plugins)) {
        $target = Join-Path $pluginRoot $plugin.name
        if (($target.Length + 1 + $plugin.longest_path) -gt 240) {
            throw ("Installing to '" + $target + "' would create paths longer than 240 characters. Move Flint to a shorter directory and try again.")
        }
    }
    $installed = @()
    foreach ($plugin in @($Plugins)) {
        $started = [datetime]::UtcNow
        $path = $null
        # Git paths are case-sensitive, so the record keeps the folder names as the repository spells them.
        if ($Source.repo_path) { $path = $Source.repo_path + '/' + (Split-Path (Split-Path $plugin.root -Parent) -Leaf) + '/' + (Split-Path $plugin.root -Leaf) }
        $record = [ordered]@{
            version = 1; name = $plugin.name; plugin_version = $plugin.version; source = $Source.display; kind = $Source.kind
            ref = $Source.ref; path = $path; commit = $Commit; installed_at = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $previous = Install-FlintPluginCopy $plugin $pluginRoot $record
        $text = 'Installed ' + $plugin.name + ' ' + $plugin.version
        if ($previous -and $previous -cne $plugin.version) { $text += ', replacing ' + $previous }
        Write-FlintSetupStep $text $started
        $installed += $plugin.name
    }
    # The setup folder is the only source of plugins, so anything it no longer lists is removed.
    $removed = @()
    foreach ($child in @(Get-ChildItem -LiteralPath $pluginRoot -Force -ErrorAction Stop | Sort-Object Name)) {
        if ($child.Name.StartsWith('.')) { continue }
        if ($child.PSIsContainer) {
            if ($installed -ccontains $child.Name) { continue }
            Remove-FlintDirectoryTree $child.FullName $pluginRoot
            Remove-Item -LiteralPath (Join-Path $pluginRoot ($child.Name + '.source.json')) -Force -ErrorAction SilentlyContinue
            Write-Host ('  Removed plugin ' + $child.Name + ', which the setup no longer includes.') -ForegroundColor DarkGray
            $removed += $child.Name
        } elseif ($child.Name.EndsWith('.source.json') -and $installed -cnotcontains $child.Name.Substring(0, $child.Name.Length - 12)) {
            Remove-Item -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $removed
}

function Install-FlintSetup {
    param([string]$Source, [string]$ConfigFile, [string]$PluginDirectory)
    if (-not $ConfigFile) { $ConfigFile = Get-FlintDefaultConfigPath }
    if (-not $PluginDirectory) { $PluginDirectory = Get-FlintPluginDirectory }
    $parsed = ConvertFrom-FlintSetupSource $Source
    $workParent = (Get-Item -LiteralPath $env:TEMP -Force).FullName.TrimEnd('\')
    $work = Join-Path $workParent ('flint-setup-' + [guid]::NewGuid().ToString('N'))
    $staged = $null
    try {
        $commit = $null
        if ($parsed.kind -ceq 'directory') { $folder = $parsed.path }
        else {
            New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
            if ($parsed.kind -ceq 'git') {
                $branch = ''
                if ($parsed.ref) { $branch = ' (' + $parsed.ref + ')' }
                Write-Host ("Fetching '/" + $parsed.repo_path + "' from " + $parsed.clone_url + $branch + ' ...') -ForegroundColor DarkGray
                $fetched = Get-FlintGitFolder $parsed $work
                $folder = $fetched.folder; $commit = $fetched.commit
            } else {
                $started = [datetime]::UtcNow
                $folder = Expand-FlintSetupZip $parsed.path $work
                Write-FlintSetupStep 'Extracted the archive' $started
            }
        }
        $started = [datetime]::UtcNow
        $setup = Test-FlintSetup $folder
        Write-FlintSetupStep ('Validated the setup with ' + @($setup.plugins).Count + ' plugin(s)') $started
        Show-FlintSetupSummary $setup
        # Running setup again keeps the key the user already pasted into flint.ini.
        $key = ''
        if (Test-Path -LiteralPath $ConfigFile -PathType Leaf) {
            try { $key = ([string](Read-FlintIniFile $ConfigFile (Get-FlintConfigSchema))['model.api_key']).Trim() } catch { $key = '' }
        }
        # Write the new flint.ini before plugins change, so a folder that cannot take it fails while nothing has
        # changed. If a plugin then fails, the previous flint.ini stays; afterwards only a rename remains.
        $staged = Save-FlintStagedConfig $ConfigFile $parsed.display $setup.model $key
        $removed = @(Sync-FlintPlugins $setup.plugins $PluginDirectory $parsed $commit)
        $started = [datetime]::UtcNow
        try { Move-Item -LiteralPath $staged -Destination $ConfigFile -Force -ErrorAction Stop; $staged = $null }
        catch { throw ("The plugins were updated, but '" + $ConfigFile + "' could not be replaced: " + $_.Exception.Message + ' Close any program that has it open and run -Setup again.') }
        Write-FlintSetupStep ('Generated ' + $ConfigFile) $started
        return @{ setup = $setup; config = $ConfigFile; removed = $removed; key_kept = [bool]$key }
    } finally {
        if ($staged) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
        Remove-FlintDirectoryTree $work $workParent
    }
}
