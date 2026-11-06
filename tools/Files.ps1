function Resolve-FlintFileTarget {
    param([string]$Root, [string]$Name, $ToolArguments, [string[]]$ProtectedPaths)
    if ($Name -in @('write_file', 'edit_file', 'create_directory')) {
        # Keep the implementation that validates and executes tools read-only to the agent.
        $runtimeRoot = Split-Path $PSScriptRoot -Parent
        $ProtectedPaths = @($ProtectedPaths) + @(
            (Join-Path $runtimeRoot 'agent.ps1'),
            (Join-Path $runtimeRoot 'lib'),
            (Join-Path $runtimeRoot 'tools')
        )
    }
    return Resolve-AgentPath $Root $ToolArguments.path $ProtectedPaths
}

function Invoke-FlintFileTool {
    param([string]$Root, [string]$Name, $ToolArguments, [string[]]$ProtectedPaths, [string]$WriteDirectory)
    $path = Resolve-FlintFileTarget $Root $Name $ToolArguments $ProtectedPaths
    if ($Name -eq 'read_file') { return Read-FlintTextFile $path $ToolArguments }
    if ($Name -in @('write_file', 'edit_file', 'create_directory') -and
        -not (Test-FlintPathWithinDirectory $path $Root) -and -not (Test-FlintPathWithinDirectory $path $WriteDirectory)) {
        throw 'Writing outside the working directory requires directory authorization.'
    }
    $output = ''
    if ($Name -eq 'list_files') {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Directory does not exist.' }
        $entries = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Select-Object -First 201)
        $names = @($entries | Select-Object -First 200 | ForEach-Object { if ($_.PSIsContainer) { $_.Name + '/' } else { $_.Name } })
        $output = ConvertTo-Json -InputObject @{ entries = $names; truncated = ($entries.Count -gt 200) } -Depth 8 -Compress
    } elseif ($Name -eq 'create_directory') {
        if (Test-Path -LiteralPath $path) {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'The requested directory path is a file.' }
        } else { New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null }
        $null = Resolve-FlintFileTarget $Root $Name $ToolArguments $ProtectedPaths
        $output = 'Directory ready: ' + $ToolArguments.path
    } else {
        $exists = Test-Path -LiteralPath $path
        $content = ''
        if ($exists) {
            $entry = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($entry.PSIsContainer) { throw 'Path is not a file.' }
            if ($entry.Length -gt 262144) { throw 'File exceeds 256 KiB. Use a smaller diagnostic extract.' }
            $content = [string](Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop)
            if ($null -eq $content) { $content = '' }
            if ($content.Contains([string][char]0)) { throw 'Binary files are not supported.' }
        }
        switch ($Name) {
            'write_file' {
                $updated = $ToolArguments.content
            }
            'edit_file' {
                if (-not $exists) { throw 'File does not exist. Use write_file to create it.' }
                $old = $ToolArguments.old_str; $new = $ToolArguments.new_str
                if ($old -ceq $new) { throw 'old_str and new_str must differ.' }
                if ($old -eq '') { throw 'Use a unique nonempty old_str to edit an existing file.' }
                $index = $content.IndexOf($old, [StringComparison]::Ordinal)
                if ($index -lt 0) { throw 'old_str was not found. Read the file before editing.' }
                if ($content.IndexOf($old, $index + 1, [StringComparison]::Ordinal) -ge 0) { throw 'old_str appears more than once. Include more surrounding text.' }
                $updated = $content.Substring(0, $index) + $new + $content.Substring($index + $old.Length)
            }
            default { throw 'Unknown file tool.' }
        }
        if ($Name -in @('write_file', 'edit_file')) {
            if ($updated.Length -gt 65536) { throw 'Written content exceeds 64 Ki characters.' }
            if ($updated.Contains([string][char]0)) { throw 'Binary content is not supported.' }
            $null = Resolve-FlintFileTarget $Root $Name $ToolArguments $ProtectedPaths
            try {
                Set-Content -LiteralPath $path -Value $updated -Encoding UTF8 -NoNewline -ErrorAction Stop
                $verified = [string](Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop)
                if ($null -eq $verified) { $verified = '' }
            } catch { throw ('Write could not be verified. Read the actual file before another edit. ' + $_.Exception.Message) }
            if ($verified -cne $updated) { throw 'Write verification failed. Read the actual file before proposing another edit.' }
            $output = 'File written and verified: ' + $ToolArguments.path
        }
    }
    return @{ status = 'ok'; exit_code = 0; output = $output; retryable = $false; duration_ms = 0 }
}
