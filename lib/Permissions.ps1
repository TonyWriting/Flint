function Assert-FlintPermissionPath {
    param([string]$Path)
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.PSProvider.Name -ne 'FileSystem' -or ($item.Attributes -band 1024)) { throw 'Permission files cannot use symlinks or junctions.' }
        }
        $current = Split-Path $current -Parent
    }
}

function Read-FlintPermissionRules {
    param([hashtable]$Session, [string]$Executor)
    $path = Join-Path $Session.PermissionRulesDirectory ($Executor + '.json')
    Assert-FlintPermissionPath $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    if ((Get-Item -LiteralPath $path).Length -gt 262144) { throw 'Permission rules exceed 256 KiB.' }
    $document = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
    if ($document.version -ne 1 -or $document.executor -cne $Executor -or $document.rules -isnot [array]) { throw "Invalid permission rules: $path" }
    foreach ($rule in $document.rules) {
        $fields = @($rule.PSObject.Properties.Name)
        if (@($fields | Where-Object { $_ -cnotin @('command', 'read_only', 'options', 'positionals') }).Count -gt 0 -or
            $rule.read_only -isnot [bool] -or -not $rule.read_only -or $rule.command -isnot [array] -or $rule.command.Count -eq 0 -or $rule.options -isnot [pscustomobject]) { throw 'Fixed permission rules must describe read-only commands.' }
        foreach ($word in $rule.command) { if ($word -isnot [string] -or $word -cnotmatch '^[a-z0-9][a-z0-9-]*$') { throw 'Invalid rule command.' } }
        foreach ($property in $rule.options.PSObject.Properties) {
            $option = $property.Value
            if ($property.Name -cnotmatch '^--?[a-zA-Z][a-zA-Z0-9-]*$' -or $option -isnot [pscustomobject] -or
                @($option.PSObject.Properties.Name | Where-Object { $_ -cnotin @('required', 'values', 'pattern', 'switch') }).Count -gt 0) { throw 'Invalid rule option.' }
            foreach ($flag in @('required', 'switch')) { if ($flag -cin $option.PSObject.Properties.Name -and $option.$flag -isnot [bool]) { throw 'Rule flags must be boolean.' } }
            if ('values' -cin $option.PSObject.Properties.Name) {
                if ($option.values -isnot [array] -or $option.values.Count -eq 0) { throw 'Rule values must be a nonempty string array.' }
                foreach ($value in $option.values) { if ($value -isnot [string]) { throw 'Rule values must be strings.' } }
            }
            if ('pattern' -cin $option.PSObject.Properties.Name) {
                if ($option.pattern -isnot [string] -or -not $option.pattern.StartsWith('^') -or -not $option.pattern.EndsWith('$')) { throw 'Rule patterns must be anchored strings.' }
                $null = '' -cmatch $option.pattern
            }
        }
        if ($null -ne $rule.positionals) {
            if ($rule.positionals -isnot [pscustomobject] -or ($rule.positionals.max -isnot [int] -and $rule.positionals.max -isnot [long]) -or $rule.positionals.max -lt 0 -or $rule.positionals.max -gt 32 -or
                $rule.positionals.pattern -isnot [string] -or -not $rule.positionals.pattern.StartsWith('^') -or -not $rule.positionals.pattern.EndsWith('$') -or
                @($rule.positionals.PSObject.Properties.Name | Where-Object { $_ -cnotin @('max', 'pattern') }).Count -gt 0) { throw 'Invalid positional argument rule.' }
            $null = '' -cmatch $rule.positionals.pattern
        }
    }
    return @($document.rules)
}

function Test-FlintCommandRule {
    param($Rule, [string[]]$Arguments)
    # Match the actual leading command path before interpreting any option values.
    if ($Arguments.Count -lt $Rule.command.Count) { return $false }
    for ($i = 0; $i -lt $Rule.command.Count; $i++) { if ($Arguments[$i] -cne $Rule.command[$i]) { return $false } }
    $words = @(); $seen = @{}
    for ($i = $Rule.command.Count; $i -lt $Arguments.Count; $i++) {
        $token = $Arguments[$i]
        if ($token.StartsWith('-')) {
            $split = $token -split '=', 2
            $name = $split[0]
            if ($name -cnotin $Rule.options.PSObject.Properties.Name -or $seen.ContainsKey($name)) { return $false }
            $option = $Rule.options.$name
            $seen[$name] = $true
            if ($option.switch) {
                if ($split.Count -ne 1) { return $false }
                continue
            }
            if ($split.Count -eq 2) { $value = $split[1] }
            else { $i++; if ($i -ge $Arguments.Count) { return $false }; $value = $Arguments[$i] }
            if ($value.StartsWith('-')) { return $false }
            if ($null -ne $option.values -and $value -cnotin $option.values) { return $false }
            if ($option.pattern -and $value -cnotmatch $option.pattern) { return $false }
        } else { $words += $token }
    }
    foreach ($property in $Rule.options.PSObject.Properties) { if ($property.Value.required -and -not $seen.ContainsKey($property.Name)) { return $false } }
    $extra = $words.Count
    if ($extra -gt 0) {
        if (-not $Rule.positionals -or $extra -gt $Rule.positionals.max) { return $false }
        foreach ($word in $words) { if ($word -cnotmatch $Rule.positionals.pattern) { return $false } }
    }
    return $true
}

function Get-FlintApprovalFile {
    param([hashtable]$Session, [string]$Executor)
    if ($Session.Id -cnotmatch '^[a-f0-9]{32}$' -or $Executor -cnotin @('azure', 'kubectl', 'files')) { throw 'Invalid session authorization identity.' }
    $path = Join-Path (Join-Path $Session.PermissionSessionDirectory $Session.Id) ($Executor + '.json')
    Assert-FlintPermissionPath $path
    return $path
}

function Read-FlintCommandApprovals {
    param([hashtable]$Session, [string]$Executor)
    $path = Get-FlintApprovalFile $Session $Executor
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'Session authorizations exceed 1 MiB.' }
    $document = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
    if ($document.version -ne 1 -or $document.session_id -cne $Session.Id -or $document.executor -cne $Executor -or $document.calls -isnot [array]) {
        throw 'Invalid session authorization file.'
    }
    return @($document.calls)
}

function Save-FlintCommandApproval {
    param([hashtable]$Session, $Invocation)
    $calls = @(Read-FlintCommandApprovals $Session $Invocation.executor)
    $calls += $Invocation
    Write-FlintPermissionFile $Session $Invocation.executor ([ordered]@{ version = 1; session_id = $Session.Id; executor = $Invocation.executor; calls = $calls })
}

function Write-FlintPermissionFile {
    param([hashtable]$Session, [string]$Executor, $Document)
    $json = ConvertTo-Json -InputObject $Document -Depth 16
    if ($json.Length -gt 131072) { throw 'Session authorization limit reached.' }
    $path = Get-FlintApprovalFile $Session $Executor
    $directory = Split-Path $path -Parent
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    Assert-FlintPermissionPath $path
    $temporary = Join-Path $directory ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Set-Content -LiteralPath $temporary -Value $json -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Read-FlintDirectoryApprovals {
    param([hashtable]$Session)
    $path = Get-FlintApprovalFile $Session files
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'Directory authorizations exceed 1 MiB.' }
    $document = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
    if ($document.version -ne 1 -or $document.session_id -cne $Session.Id -or $document.directories -isnot [array]) { throw 'Invalid directory authorization file.' }
    foreach ($directory in $document.directories) {
        if ($directory -isnot [string] -or $directory -notmatch '^[A-Za-z]:\\') { throw 'Directory authorizations must use absolute local paths.' }
        Assert-FlintFilePathText $directory
    }
    return @($document.directories)
}

function Read-FlintDirectoryApproval {
    param([hashtable]$Session, [string]$Directory, [string]$Target, [string]$Operation)
    Initialize-FlintUi $Session
    if (-not $Session.Ui.Live) { return $null }
    Clear-FlintProgress $Session
    Write-Host ''
    Write-Host (Protect-FlintText $Session ('Operation: ' + $Operation + ' ' + $Target)) -ForegroundColor Yellow
    Write-Host (Protect-FlintText $Session ('Allow writes in this directory and its descendants for this session: ' + $Directory)) -ForegroundColor Yellow
    try { return Read-Host 'y/n (default n)' } catch { return $null }
}

function Resolve-FlintFilePermission {
    param([hashtable]$Session, [string]$Name, $ToolArguments, [string]$CallId)
    $target = Resolve-FlintFileTarget $Session.Root $Name $ToolArguments $Session.ProtectedPaths
    if (Test-FlintPathWithinDirectory $target $Session.Root) {
        return @{ allowed = $true; read_only = $false; directory = $Session.Root }
    }
    $directories = @(Read-FlintDirectoryApprovals $Session)
    foreach ($directory in $directories) {
        if (Test-FlintPathWithinDirectory $target $directory) {
            Write-FlintEvent $Session 'directory_permission' @{ call_id = $CallId; directory = $directory; target = $target }
            return @{ allowed = $true; read_only = $false; directory = $directory }
        }
    }
    $directory = Split-Path $target -Parent
    if ($Name -ceq 'create_directory') { $directory = $target }
    Write-FlintEvent $Session 'directory_approval_requested' @{ call_id = $CallId; directory = $directory; target = $target; operation = $Name }
    $answer = Read-FlintDirectoryApproval $Session $directory $target $Name
    $allowed = $null -ne $answer -and $answer.Trim() -ceq 'y'
    Write-FlintEvent $Session 'directory_approval_decided' @{ call_id = $CallId; directory = $directory; allowed = $allowed }
    if ($allowed) {
        $directories += $directory
        Write-FlintPermissionFile $Session files ([ordered]@{ version = 1; session_id = $Session.Id; directories = $directories })
    }
    $status = 'denied'
    if ($null -eq $answer) { $status = 'approval_required' }
    return @{ allowed = $allowed; read_only = $false; directory = $directory; status = $status }
}

function Read-FlintCommandApproval {
    param([hashtable]$Session, $Invocation, [string]$Purpose)
    Initialize-FlintUi $Session
    if (-not $Session.Ui.Live) { return $null }
    Clear-FlintProgress $Session
    Write-Host ''
    Write-Host (Protect-FlintText $Session ('Purpose (model-provided): ' + $Purpose)) -ForegroundColor Yellow
    Write-Host ('Command: ' + $Invocation.executor) -ForegroundColor Yellow
    Write-Host (Protect-FlintText $Session ('Arguments: ' + (ConvertTo-Json -InputObject @($Invocation.arguments) -Depth 8 -Compress))) -ForegroundColor Yellow
    Write-Host (Protect-FlintText $Session ('Working directory: ' + $Invocation.working_directory))
    Write-Host (Protect-FlintText $Session ('Executable: ' + $Invocation.program.path))
    foreach ($name in $Invocation.environment.Keys) {
        if ($Invocation.environment[$name]) { Write-Host (Protect-FlintText $Session ($name + ': ' + $Invocation.environment[$name])) }
    }
    Write-Host 'This command is not on the read-only list and may make changes. Allow this exact invocation for this session?' -ForegroundColor Yellow
    try { return Read-Host 'y/n (default n)' } catch { return $null }
}

function Resolve-FlintCommandPermission {
    param([hashtable]$Session, $Invocation, [string]$CallId, [string]$Purpose)
    foreach ($rule in @(Read-FlintPermissionRules $Session $Invocation.executor)) {
        if (Test-FlintCommandRule $rule $Invocation.arguments) {
            Write-FlintEvent $Session 'command_permission' @{ call_id = $CallId; source = 'fixed_read'; invocation = $Invocation }
            return @{ allowed = $true; read_only = $true; source = 'fixed_read' }
        }
    }
    $signature = ConvertTo-Json -InputObject $Invocation -Depth 16 -Compress
    foreach ($approved in @(Read-FlintCommandApprovals $Session $Invocation.executor)) {
        if ((ConvertTo-Json -InputObject $approved -Depth 16 -Compress) -ceq $signature) {
            Write-FlintEvent $Session 'command_permission' @{ call_id = $CallId; source = 'session_exact'; invocation = $Invocation }
            return @{ allowed = $true; read_only = $false; source = 'session_exact' }
        }
    }
    Write-FlintEvent $Session 'command_approval_requested' @{ call_id = $CallId; invocation = $Invocation; purpose = $Purpose }
    $answer = Read-FlintCommandApproval $Session $Invocation -Purpose $Purpose
    $allowed = $null -ne $answer -and $answer.Trim() -ceq 'y'
    Write-FlintEvent $Session 'command_approval_decided' @{ call_id = $CallId; allowed = $allowed }
    if ($allowed) { Save-FlintCommandApproval $Session $Invocation }
    $status = 'denied'
    if ($null -eq $answer) { $status = 'approval_required' }
    return @{ allowed = $allowed; read_only = $false; source = 'user'; status = $status }
}
