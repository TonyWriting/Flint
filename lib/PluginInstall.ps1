function ConvertFrom-FlintPluginUrl {
    param([string]$Url)
    $uri = $Url -as [uri]
    if (-not $uri -or -not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.Port -ne 443) { throw 'Plugin URLs must use https on the default port.' }
    $hostName = $uri.Host.ToLowerInvariant()
    $segments = @($uri.AbsolutePath.Split('/') | Where-Object { $_ })
    foreach ($segment in $segments) { if ($segment -in @('.', '..')) { throw 'Plugin URLs cannot contain relative path segments.' } }
    if ($hostName -ceq 'dev.azure.com') {
        if ($segments.Count -lt 1) { throw 'The Azure DevOps URL is missing its organization.' }
        $base = 'https://dev.azure.com/' + $segments[0]
        $rest = @($segments | Select-Object -Skip 1)
    } elseif ($hostName -cmatch '^[a-z0-9][a-z0-9-]*\.visualstudio\.com$') {
        $base = 'https://' + $hostName
        $rest = $segments
        if ($rest.Count -gt 0 -and $rest[0] -ieq 'DefaultCollection') { $base += '/' + $rest[0]; $rest = @($rest | Select-Object -Skip 1) }
    } else {
        throw 'Plugin URLs must point to an Azure DevOps Git repository on dev.azure.com or <organization>.visualstudio.com.'
    }
    # Both the project form and the project-less form name a Git repository; userinfo, query and fragment never reach git.
    if ($rest.Count -eq 3 -and $rest[1] -ceq '_git') { $repository = $base + '/' + $rest[0] + '/_git/' + $rest[2] }
    elseif ($rest.Count -eq 2 -and $rest[0] -ceq '_git') { $repository = $base + '/_git/' + $rest[1] }
    else { throw 'Use the repository folder URL form https://dev.azure.com/<organization>/<project>/_git/<repository>?path=/<plugin folder>.' }
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
    if (-not $path) { throw 'Add ?path=/<plugin folder> to the URL. Copy the URL from the plugin folder view in Azure DevOps.' }
    $folder = $path.Trim('/')
    if (-not $folder) { throw 'Point ?path= at the plugin folder, not the repository root.' }
    if ($folder.Length -gt 200) { throw 'The plugin path is longer than 200 characters.' }
    foreach ($part in $folder.Split('/')) {
        if (-not $part -or $part -in @('.', '..') -or $part.StartsWith('-') -or $part -match '[\\:*?"<>|\x00-\x1f\x7f]') { throw ('Unsupported plugin path: ' + $path) }
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

function ConvertFrom-FlintPluginSource {
    param([string]$Source)
    if ([string]::IsNullOrWhiteSpace($Source)) { throw 'Provide a plugin source: an Azure DevOps folder URL, a local folder or a .zip file.' }
    $Source = $Source.Trim()
    if ($Source -match '^[A-Za-z][A-Za-z0-9+.-]*://') { return ConvertFrom-FlintPluginUrl $Source }
    $item = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSProvider.Name -ne 'FileSystem') { throw ('Plugin source not found: ' + $Source) }
    if ($item.PSIsContainer) { return @{ kind = 'directory'; path = $item.FullName; display = $item.FullName; ref = $null; repo_path = $null } }
    if ($item.Extension -ieq '.zip') { return @{ kind = 'zip'; path = $item.FullName; display = $item.FullName; ref = $null; repo_path = $null } }
    throw 'A local plugin source must be a folder or a .zip file.'
}

function Resolve-FlintGitProgram {
    $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'git was not found on PATH. Install Git for Windows, or download the plugin folder and pass the folder or .zip to -InstallPlugin.' }
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

function Write-FlintInstallStep {
    param([string]$Text, [datetime]$Started)
    # Native output is captured, so each finished step reports itself with its duration.
    Write-Host ('  {0} ({1:N1}s)' -f $Text, ([datetime]::UtcNow - $Started).TotalSeconds) -ForegroundColor DarkGray
}

function Get-FlintGitPlugin {
    param($Source, [string]$Work)
    $git = Resolve-FlintGitProgram
    $repository = Join-Path $Work 'repository'
    $started = [datetime]::UtcNow
    # A shallow, blobless, sparse clone downloads only the plugin folder and the repository root files.
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
            throw ($message + ' Sign in to Azure DevOps first: run "git clone ' + $Source.clone_url + '" once in a terminal, or download the plugin folder as a .zip from Azure DevOps and pass that file.')
        }
        throw ($message + ' If the repository cannot be reached, download the plugin folder as a .zip from Azure DevOps and pass that file.')
    }
    Write-FlintInstallStep 'Connected and read the repository' $started
    $started = [datetime]::UtcNow
    $null = Invoke-FlintGit $git @('-C', $repository, 'sparse-checkout', 'set', $Source.repo_path) $Work
    $commit = Invoke-FlintGit $git @('-C', $repository, 'rev-parse', 'HEAD') $Work
    $short = $commit
    if ($short.Length -gt 7) { $short = $short.Substring(0, 7) }
    Write-FlintInstallStep ('Downloaded the plugin folder at commit ' + $short) $started
    $folder = Join-Path $repository $Source.repo_path.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        $branch = 'the default branch'
        if ($Source.ref) { $branch = "'" + $Source.ref + "'" }
        throw ("The repository has no folder '/" + $Source.repo_path + "' on " + $branch + '.')
    }
    return @{ folder = $folder; commit = $commit }
}

function Expand-FlintPluginZip {
    param([string]$ZipPath, [string]$Work)
    # Windows tar.exe refuses absolute and '..' entries; links are rejected later by plugin validation.
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) { throw 'Extracting a .zip plugin requires tar.exe from Windows 10 or later. Extract the archive and pass the folder instead.' }
    $destination = Join-Path $Work 'archive'
    New-Item -ItemType Directory -Path $destination -ErrorAction Stop | Out-Null
    $native = Invoke-FlintProcess -FilePath $tar -ArgumentList @('-x', '-f', (ConvertTo-FlintNativeArgument $ZipPath), '-C', (ConvertTo-FlintNativeArgument $destination)) -TimeoutSec 120 -WorkingDirectory $Work
    if ($native.status -ne 'ok') { throw ('Could not extract ' + $ZipPath + ': ' + ($native.stderr + ' ' + $native.stdout).Trim()) }
    if (Test-Path -LiteralPath (Join-Path $destination 'plugin.json') -PathType Leaf) { return $destination }
    $children = @(Get-ChildItem -LiteralPath $destination -Force)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer -and -not ($children[0].Attributes -band 1024) -and
        (Test-Path -LiteralPath (Join-Path $children[0].FullName 'plugin.json') -PathType Leaf)) { return $children[0].FullName }
    throw 'The archive must contain plugin.json at its root or inside a single top-level folder.'
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

function Install-FlintPlugin {
    param([string]$Source, [string]$PluginDirectory)
    if (-not $PluginDirectory) { $PluginDirectory = Get-FlintPluginDirectory }
    $parsed = ConvertFrom-FlintPluginSource $Source
    $workParent = (Get-Item -LiteralPath $env:TEMP -Force).FullName.TrimEnd('\')
    $work = Join-Path $workParent ('flint-plugin-' + [guid]::NewGuid().ToString('N'))
    $pluginRoot = $null; $staging = $null; $old = $null
    try {
        $commit = $null
        if ($parsed.kind -ceq 'directory') { $folder = $parsed.path }
        else {
            New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
            if ($parsed.kind -ceq 'git') {
                $branch = ''
                if ($parsed.ref) { $branch = ' (' + $parsed.ref + ')' }
                Write-Host ("Fetching '/" + $parsed.repo_path + "' from " + $parsed.clone_url + $branch + ' ...') -ForegroundColor DarkGray
                $fetched = Get-FlintGitPlugin $parsed $work
                $folder = $fetched.folder; $commit = $fetched.commit
            } else {
                $started = [datetime]::UtcNow
                $folder = Expand-FlintPluginZip $parsed.path $work
                Write-FlintInstallStep 'Extracted the archive' $started
            }
        }
        $started = [datetime]::UtcNow
        $plugin = Test-FlintPlugin $folder
        Write-FlintInstallStep ('Validated ' + $plugin.name + ' ' + $plugin.version + ': ' + $plugin.file_count + ' files, ' + @($plugin.rules).Count + ' reviewed reads') $started
        $started = [datetime]::UtcNow
        if (-not (Test-Path -LiteralPath $PluginDirectory)) { New-Item -ItemType Directory -Path $PluginDirectory -ErrorAction Stop | Out-Null }
        $directory = Get-Item -LiteralPath $PluginDirectory -Force -ErrorAction Stop
        if (-not $directory.PSIsContainer -or ($directory.Attributes -band 1024)) { throw 'The plugins directory must be a real directory, not a file or link.' }
        $pluginRoot = $directory.FullName.TrimEnd('\')
        $target = Join-Path $pluginRoot $plugin.name
        if (($target.Length + 1 + $plugin.longest_path) -gt 240) {
            throw ("Installing to '" + $target + "' would create paths longer than 240 characters. Move Flint to a shorter directory and try again.")
        }
        # Stage next to the target so the final switch is a rename on the same volume.
        $staging = Join-Path $pluginRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $plugin.root -Destination $staging -Recurse -Force -ErrorAction Stop
        $null = Test-FlintPlugin $staging
        $previous = $null
        if (Test-Path -LiteralPath $target) {
            try { $previous = (Test-FlintPlugin $target).version } catch { $previous = 'an invalid copy' }
            $old = Join-Path $pluginRoot ('.old-' + [guid]::NewGuid().ToString('N'))
            try { Move-Item -LiteralPath $target -Destination $old -ErrorAction Stop }
            catch { $old = $null; throw ("Could not replace the installed plugin '" + $plugin.name + "'. Close running Flint sessions and try again.") }
        }
        try { Move-Item -LiteralPath $staging -Destination $target -ErrorAction Stop; $staging = $null }
        catch {
            if ($old) { Move-Item -LiteralPath $old -Destination $target -ErrorAction SilentlyContinue; $old = $null }
            throw
        }
        $record = [ordered]@{
            version = 1; name = $plugin.name; plugin_version = $plugin.version; source = $parsed.display; kind = $parsed.kind
            ref = $parsed.ref; path = $parsed.repo_path; commit = $commit; installed_at = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $recordPath = Join-Path $pluginRoot ($plugin.name + '.source.json')
        $temporary = Join-Path $pluginRoot ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            Set-Content -LiteralPath $temporary -Value (ConvertTo-Json -InputObject $record -Depth 4) -Encoding UTF8 -ErrorAction Stop
            Move-Item -LiteralPath $temporary -Destination $recordPath -Force -ErrorAction Stop
        } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        $installed = Test-FlintPlugin $target
        $installed.source = Read-FlintPluginSource $pluginRoot $plugin.name
        Write-FlintInstallStep ('Installed to ' + $target) $started
        return @{ plugin = $installed; previous_version = $previous }
    } finally {
        if ($pluginRoot) {
            if ($old) { Remove-FlintDirectoryTree $old $pluginRoot }
            if ($staging) { Remove-FlintDirectoryTree $staging $pluginRoot }
        }
        Remove-FlintDirectoryTree $work $workParent
    }
}

function Show-FlintPluginSummary {
    param($Plugin)
    $guarded = 'none'
    $names = @($Plugin.guarded)
    if ($names.Count -gt 0) { $guarded = (@($names | Select-Object -First 4) -join ', ') }
    if ($names.Count -gt 4) { $guarded += ' and ' + ($names.Count - 4) + ' more' }
    Write-Host ('  ' + $Plugin.name + ' ' + $Plugin.version + ': ' + $Plugin.summary)
    Write-Host ('  Files: {0} ({1:N0} KiB); reviewed reads: {2}; guarded resources: {3}' -f $Plugin.file_count, [long]($Plugin.total_bytes / 1024), @($Plugin.rules).Count, $guarded) -ForegroundColor DarkGray
    Write-Host ('  Guide: ' + $Plugin.guide) -ForegroundColor DarkGray
    if ($Plugin.source) {
        $line = '  Source: ' + $Plugin.source.source
        if ($Plugin.source.commit) { $line += ' at ' + $Plugin.source.commit }
        Write-Host $line -ForegroundColor DarkGray
    }
}
