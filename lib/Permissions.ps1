
function Assert-FlintCommandRuleScope {
    param($Rule)
    # Every rule source shares one floor: rules can only widen reviewed reads, never reach Secrets or redirect the client.
    $words = @($Rule.command)
    $label = "Rule '" + ($words -join ' ') + "'"
    if ($words[0] -cin @('get', 'describe')) {
        if ($words.Count -ne 2) { throw ($label + ' must name exactly one resource type after ' + $words[0] + '.') }
        if ($words[1] -cmatch '^secrets?(\.|$)') { throw ($label + ' cannot read Secrets.') }
    } elseif ($words[0] -cin @('explain', 'api-resources', 'version')) {
        if ($words.Count -ne 1) { throw ($label + ' must not add words after ' + $words[0] + '.') }
    } elseif ($words[0] -ceq 'config') {
        if ($words.Count -ne 2 -or $words[1] -cnotin @('get-contexts', 'current-context')) { throw ($label + ' may only use config get-contexts or config current-context.') }
    } elseif ($words[0] -ceq 'logs') {
        if ($words.Count -ne 1) { throw ($label + ' must not add words after logs.') }
    } else {
        throw ($label + ' must use get, describe, explain, api-resources, version, logs, config get-contexts or config current-context.')
    }
    $allowed = @('--context', '--namespace', '--all-namespaces', '--output', '--selector', '--field-selector', '--request-timeout', '--api-group', '--api-version', '--recursive', '--namespaced', '--client', '--chunk-size')
    # Logs read one named pod's recent output; following, selectors and all-container reads stay outside every rule.
    if ($words[0] -ceq 'logs') { $allowed = @('--context', '--namespace', '--container', '--previous', '--timestamps', '--tail', '--since', '--request-timeout') }
    foreach ($property in $Rule.options.PSObject.Properties) {
        if ($property.Name -cnotin $allowed) { throw ($label + ' cannot allow option ' + $property.Name + '.') }
    }
    if ($words[0] -cin @('get', 'describe', 'explain', 'api-resources', 'logs')) {
        $context = $Rule.options.'--context'
        if (-not $context -or $context.required -ne $true) { throw ($label + ' must require --context.') }
    }
    if ($words[0] -ceq 'logs') {
        $namespace = $Rule.options.'--namespace'; $tail = $Rule.options.'--tail'; $since = $Rule.options.'--since'
        if (-not $namespace -or $namespace.required -ne $true) { throw ($label + ' must require --namespace.') }
        if (-not $Rule.positionals -or $Rule.positionals.max -ne 1) { throw ($label + ' must name exactly one pod.') }
        # Bounds are checked against the rule's own pattern, so no rule source can allow unbounded reads.
        if (-not $tail -or $tail.required -ne $true -or -not $tail.pattern -or
            @(@('0', '-1', '1001', '5000', '100000') | Where-Object { $_ -cmatch $tail.pattern }).Count -gt 0 -or -not ('200' -cmatch $tail.pattern)) {
            throw ($label + ' must require --tail with a pattern that allows 1 to 1000 lines only.')
        }
        if ($since -and (-not $since.pattern -or @(@('61m', '2h', '1d', '3601s', '0s') | Where-Object { $_ -cmatch $since.pattern }).Count -gt 0)) {
            throw ($label + ' may allow --since only with a pattern limited to one hour.')
        }
    }
    # A cross-namespace query must stay narrow: a required label selector, never a whole-cluster listing.
    $everywhere = $Rule.options.'--all-namespaces'
    if ($everywhere) {
        $selector = $Rule.options.'--selector'
        if ($words[0] -cne 'get' -or $everywhere.switch -ne $true -or $everywhere.required -ne $true -or $Rule.options.'--namespace' -or
            -not $selector -or $selector.required -ne $true) {
            throw ($label + ' may use --all-namespaces only with get, as a required switch, with a required --selector and without --namespace.')
        }
    }
}

function ConvertTo-FlintCommandRules {
    param($Document, [string]$Executor, [string]$Source)
    if ($Document -isnot [pscustomobject] -or
        @($Document.PSObject.Properties.Name | Where-Object { $_ -cnotin @('version', 'executor', 'rules') }).Count -gt 0 -or
        $Document.version -ne 1 -or $Document.executor -cne $Executor -or $Document.rules -isnot [array]) { throw ('Invalid ' + $Executor + ' permission rules from ' + $Source + '.') }
    $entries = @()
    foreach ($rule in $Document.rules) {
        if ($rule -isnot [pscustomobject]) { throw 'Each permission rule must be an object.' }
        $fields = @($rule.PSObject.Properties.Name)
        if (@($fields | Where-Object { $_ -cnotin @('command', 'read_only', 'options', 'positionals') }).Count -gt 0 -or
            $rule.read_only -isnot [bool] -or -not $rule.read_only -or $rule.command -isnot [array] -or $rule.command.Count -eq 0 -or $rule.options -isnot [pscustomobject]) { throw 'Fixed permission rules must describe read-only commands.' }
        foreach ($word in $rule.command) { if ($word -isnot [string] -or $word -cnotmatch '^[a-z0-9][a-z0-9.-]*$') { throw 'Invalid rule command.' } }
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
        Assert-FlintCommandRuleScope $rule
        $entries += @{ rule = $rule; source = $Source }
    }
    return $entries
}

function Read-FlintCommandRuleFile {
    param([string]$Path, [string]$Executor, [string]$Source)
    Assert-FlintNoLinkInPath $Path 'Permission rules cannot use symlinks or junctions.'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Permission rules were not found: ' + $Path) }
    if ((Get-Item -LiteralPath $Path).Length -gt 262144) { throw 'Permission rules exceed 256 KiB.' }
    try { $document = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop }
    catch { throw ('Permission rules are not valid JSON: ' + $Path) }
    return @(ConvertTo-FlintCommandRules $document $Executor $Source)
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

function Get-FlintReadOnlyRuleSource {
    param([hashtable]$Session, $Invocation)
    # Rules are validated once at session start; the source names the core set or the plugin that supplied the match.
    foreach ($entry in @($Session.CommandRules[[string]$Invocation.executor])) {
        if ($entry -and (Test-FlintCommandRule $entry.rule $Invocation.arguments)) { return $entry.source }
    }
    return $null
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
    foreach ($directory in @($Session.Approvals.files)) {
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
    if ($allowed) { $Session.Approvals.files = @($Session.Approvals.files) + $directory }
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
    # The working directory and executable path still belong to the approved invocation and the trajectory.
    foreach ($name in $Invocation.environment.Keys) {
        if ($Invocation.environment[$name]) { Write-Host (Protect-FlintText $Session ($name + ': ' + $Invocation.environment[$name])) }
    }
    Write-Host 'This command is not on the read-only list and may make changes. Allow this exact invocation for this session?' -ForegroundColor Yellow
    try { return Read-Host 'y/n (default n)' } catch { return $null }
}

function Read-FlintSignInApproval {
    param([hashtable]$Session, [string[]]$Arguments)
    Initialize-FlintUi $Session
    if (-not $Session.Ui.Live) { return $null }
    Clear-FlintProgress $Session
    Write-Host ''
    Write-Host 'kubectl needs you to sign in: its kubeconfig credential plugin asked for an interactive sign-in.' -ForegroundColor Yellow
    Write-Host (Protect-FlintText $Session ('Flint can run this read here, and the plugin shows how to sign in: kubectl ' + ($Arguments -join ' '))) -ForegroundColor Yellow
    Write-Host 'Sign in now? The plugin keeps the sign-in until it expires.' -ForegroundColor Yellow
    try { return Read-Host 'y/n (default n)' } catch { return $null }
}

function Resolve-FlintCommandPermission {
    param([hashtable]$Session, $Invocation, [string]$CallId, [string]$Purpose)
    $ruleSource = Get-FlintReadOnlyRuleSource $Session $Invocation
    if ($ruleSource) {
        Write-FlintEvent $Session 'command_permission' @{ call_id = $CallId; source = 'fixed_read'; rule_source = $ruleSource; invocation = $Invocation }
        return @{ allowed = $true; read_only = $true; source = 'fixed_read'; rule_source = $ruleSource }
    }
    return Resolve-FlintSessionApproval $Session $Invocation $CallId $Purpose command Read-FlintCommandApproval
}

function Resolve-FlintSessionApproval {
    param([hashtable]$Session, $Invocation, [string]$CallId, [string]$Purpose, [string]$Kind, [string]$Prompt)
    # An approval covers one exact invocation and lasts only as long as this Flint process.
    $signature = ConvertTo-Json -InputObject $Invocation -Depth 16 -Compress
    if (@($Session.Approvals[$Invocation.executor]) -ccontains $signature) {
        Write-FlintEvent $Session ($Kind + '_permission') @{ call_id = $CallId; source = 'session_exact'; invocation = $Invocation }
        return @{ allowed = $true; read_only = $false; source = 'session_exact' }
    }
    Write-FlintEvent $Session ($Kind + '_approval_requested') @{ call_id = $CallId; invocation = $Invocation; purpose = $Purpose }
    $answer = & $Prompt $Session $Invocation -Purpose $Purpose
    $allowed = $null -ne $answer -and $answer.Trim() -ceq 'y'
    Write-FlintEvent $Session ($Kind + '_approval_decided') @{ call_id = $CallId; allowed = $allowed }
    if ($allowed) { $Session.Approvals[$Invocation.executor] = @($Session.Approvals[$Invocation.executor]) + $signature }
    $status = 'denied'
    if ($null -eq $answer) { $status = 'approval_required' }
    return @{ allowed = $allowed; read_only = $false; source = 'user'; status = $status }
}
