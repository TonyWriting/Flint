function Resolve-FlintCommandProgram {
    param([string]$Executor)
    if ($Executor -cne 'kubectl') { throw 'Unsupported command executor. Use azure_request for Azure.' }
    $command = Get-Command $Executor -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "$Executor was not found on PATH. Install an allowed local copy before using this tool." }
    $path = $command.Source
    if (-not $path.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { throw 'Command executors must be native executables; shell wrappers are not supported.' }
    return [ordered]@{ path = $path }
}

function ConvertTo-FlintNativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows native argv quoting: double backslashes before quotes and the closing quote.
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Get-FlintKubectlOption {
    param([string[]]$Arguments, [string]$Name)
    $found = $false; $value = $null
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $parts = $Arguments[$i] -split '=', 2
        if ($parts[0] -cne $Name) { continue }
        if ($found) { throw ('Duplicate kubectl option: ' + $Name) }
        $found = $true
        if ($parts.Count -eq 2) { $value = $parts[1] }
        else {
            $i++
            if ($i -ge $Arguments.Count) { throw ('Missing kubectl option value: ' + $Name) }
            $value = $Arguments[$i]
        }
        if (-not $value -or $value.StartsWith('-')) { throw ('Invalid kubectl option value: ' + $Name) }
    }
    return $value
}

function Assert-FlintKubectlMutation {
    param([string[]]$Arguments)
    if ($Arguments[0].StartsWith('-')) { throw 'Put the kubectl command path before options.' }
    if ($Arguments[0] -ceq 'patch' -and ($Arguments.Count -lt 3 -or $Arguments[1].StartsWith('-'))) { throw 'Put the patch resource type and name before options.' }
    if ($Arguments[0] -ceq 'rollout' -and $Arguments[1] -cin @('status', 'history')) { return }
    if ($Arguments[0] -cnotin @('patch', 'scale', 'rollout', 'delete', 'apply', 'replace', 'create', 'annotate', 'label', 'edit')) { return }
    $context = Get-FlintKubectlOption $Arguments '--context'
    if (-not $context) { throw 'Resource changes require an explicit --context.' }
    $namespace = Get-FlintKubectlOption $Arguments '--namespace'
    if (-not $namespace -and $Arguments[1] -cnotin @('node', 'nodes', 'namespace', 'namespaces')) {
        throw 'Namespaced resource changes require an explicit --namespace.'
    }
    if ($Arguments[0] -ceq 'edit') { throw 'Interactive kubectl edit is unavailable. Read the resource, then submit an explicit patch.' }
    $resource = (($Arguments[1] -split '/', 2)[0]).ToLowerInvariant()
    if ($Arguments[0] -cne 'patch' -or $resource -cnotin @(
        'app', 'apps', 'application', 'applications', 'application.apis.clusterfleet.io', 'applications.apis.clusterfleet.io',
        'cdd', 'crossclusterdatadeployment', 'crossclusterdatadeployments', 'crossclusterdatadeployment.data.falcon.io', 'crossclusterdatadeployments.data.falcon.io'
    )) { return }
    if ($Arguments[1].Contains('/') -or $Arguments.Count -lt 3 -or $Arguments[2] -cnotmatch '^[a-z0-9][a-z0-9.-]{0,252}$') {
        throw 'Falcon patches require a resource type followed by one explicit resource name.'
    }
    # Keep the reviewed target and patch unambiguous; selectors and files cannot replace either.
    $options = @{}
    for ($i = 3; $i -lt $Arguments.Count; $i++) {
        $parts = $Arguments[$i] -split '=', 2
        if ($parts[0] -cnotin @('--context', '--namespace', '--type', '--patch', '--request-timeout') -or $options.ContainsKey($parts[0])) {
            throw 'Falcon patches accept only --context, --namespace, --type, --patch and --request-timeout.'
        }
        $options[$parts[0]] = $true
        if ($parts.Count -eq 1) { $i++; if ($i -ge $Arguments.Count) { throw 'Missing Falcon patch option value.' } }
    }
    if ((Get-FlintKubectlOption $Arguments '--type') -cne 'json') { throw 'Use --type=json for Falcon patches, with a resourceVersion test followed by explicit spec changes.' }
    $patch = Get-FlintKubectlOption $Arguments '--patch'
    if (-not $patch -or -not $patch.TrimStart().StartsWith('[')) { throw 'Supply a JSON Patch array through --patch.' }
    $operations = (ConvertFrom-Json -InputObject ('{"patch":' + $patch + '}') -ErrorAction Stop).patch
    if ($operations -isnot [array] -or $operations.Count -lt 2 -or $operations[0].op -cne 'test' -or
        $operations[0].path -cne '/metadata/resourceVersion' -or $operations[0].value -isnot [string] -or -not $operations[0].value) {
        throw 'Read the resource first. The first patch operation must test its current /metadata/resourceVersion.'
    }
    foreach ($operation in @($operations | Select-Object -Skip 1)) {
        if ($operation.op -cnotin @('test', 'add', 'replace', 'remove') -or $operation.path -isnot [string] -or
            -not $operation.path.StartsWith('/spec/') -or $operation.path -match '[\x00-\x1f\x7f]') {
            throw 'Falcon patches may only test, add, replace or remove fields below /spec/. Status is maintained by controllers.'
        }
    }
}

function New-FlintCommandInvocation {
    param([hashtable]$Session, $ToolArguments)
    Assert-FlintKubectlMutation $ToolArguments.arguments
    $environment = [ordered]@{}
    foreach ($name in @('KUBECONFIG', 'KUBERNETES_MASTER')) {
        $environment[$name] = [string](Get-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue).Value
    }
    return [ordered]@{
        executor = $ToolArguments.executor
        arguments = @($ToolArguments.arguments)
        program = Resolve-FlintCommandProgram $ToolArguments.executor
        working_directory = $Session.Root
        environment = $environment
    }
}

function Invoke-FlintCommand {
    param([string]$Root, $ToolArguments, $Invocation, [double]$TimeoutSec, [string]$SessionId)
    if (-not $Invocation -or $Invocation.executor -cne $ToolArguments.executor -or $Invocation.working_directory -cne $Root -or
        (ConvertTo-Json -InputObject @($Invocation.arguments) -Depth 8 -Compress) -cne (ConvertTo-Json -InputObject @($ToolArguments.arguments) -Depth 8 -Compress)) {
        throw 'Missing or inconsistent approved command invocation.'
    }
    Assert-FlintKubectlMutation $ToolArguments.arguments
    $program = Resolve-FlintCommandProgram $ToolArguments.executor
    if ((ConvertTo-Json -InputObject $program -Depth 8 -Compress) -cne (ConvertTo-Json -InputObject $Invocation.program -Depth 8 -Compress)) {
        throw 'The command executable changed after authorization. Submit the command again.'
    }
    $arguments = @(foreach ($value in $ToolArguments.arguments) { ConvertTo-FlintNativeArgument $value })
    $native = Invoke-FlintProcess -FilePath $program.path -ArgumentList $arguments -TimeoutSec $TimeoutSec -WorkingDirectory $Root
    $output = (@($native.stdout.TrimEnd("`r", "`n"), $native.stderr.TrimEnd("`r", "`n")) | Where-Object { $_ -ne '' }) -join [Environment]::NewLine
    $retryable = $native.status -eq 'error' -and $output -match '(?i)connection reset|temporarily unavailable|ServiceUnavailable|TLS handshake timeout|i/o timeout|TooManyRequests'
    $result = @{ status = $native.status; exit_code = $native.exit_code; output = $output; retryable = [bool]$retryable; duration_ms = $native.duration_ms }
    $result.capture_incomplete = $native.status -notin @('ok', 'error')
    $mutating = $ToolArguments.arguments[0] -cin @('patch', 'scale', 'rollout', 'delete', 'apply', 'replace', 'create', 'annotate', 'label')
    if ($ToolArguments.arguments[0] -ceq 'rollout' -and $ToolArguments.arguments[1] -cin @('status', 'history')) { $mutating = $false }
    if ($mutating) {
        $result.verification_required = $true
        $result.outcome_unknown = $native.status -ne 'ok'
    }
    if ($SessionId -and $output) {
        $resultSession = @{ Root = $Root; Id = $SessionId }
        try {
            $content = $native.stdout
            if (-not $content) { $content = $native.stderr }
            $saved = Save-FlintResult $resultSession $content -Kubernetes
            foreach ($key in $saved.Keys) { if ($key -cne 'output') { $result[$key] = $saved[$key] } }
            if ($native.stdout -and $native.stderr) {
                $errors = Save-FlintResult $resultSession $native.stderr
                $result.stderr_result_path = $errors.result_path
                $result.stderr = $errors.output
                $result.stderr_preview_truncated = $errors.preview_truncated
            }
            # Keep short native output unchanged, including compact JSON and both streams.
            $result.output = Protect-FlintValue $resultSession $output
            if ($result.output.Length -gt 2048) {
                $previewLength = 2048
                $last = [int][char]$result.output[$previewLength - 1]
                if ($last -ge 55296 -and $last -le 56319) { $previewLength-- }
                $result.output = $result.output.Substring(0, $previewLength)
                $result.preview_truncated = $true
            }
        } catch {
            $result.status = 'error'; $result.retryable = $false
            $result.output = 'kubectl exited with code ' + $native.exit_code + ', but its output could not be saved: ' + $_.Exception.Message + ' Query actual state before repeating a change.'
            $result.failure = Get-FlintFailureDetails $resultSession $_
        }
    }
    if ($result.capture_incomplete) { $result.truncated = $true }
    return $result
}
