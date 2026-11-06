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

function New-FlintCommandInvocation {
    param([hashtable]$Session, $ToolArguments)
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
    param([string]$Root, $ToolArguments, $Invocation, [double]$TimeoutSec)
    if (-not $Invocation -or $Invocation.executor -cne $ToolArguments.executor -or $Invocation.working_directory -cne $Root -or
        (ConvertTo-Json -InputObject @($Invocation.arguments) -Depth 8 -Compress) -cne (ConvertTo-Json -InputObject @($ToolArguments.arguments) -Depth 8 -Compress)) {
        throw 'Missing or inconsistent approved command invocation.'
    }
    $program = Resolve-FlintCommandProgram $ToolArguments.executor
    if ((ConvertTo-Json -InputObject $program -Depth 8 -Compress) -cne (ConvertTo-Json -InputObject $Invocation.program -Depth 8 -Compress)) {
        throw 'The command executable changed after authorization. Submit the command again.'
    }
    $arguments = @(foreach ($value in $ToolArguments.arguments) { ConvertTo-FlintNativeArgument $value })
    $native = Invoke-FlintProcess -FilePath $program.path -ArgumentList $arguments -TimeoutSec $TimeoutSec -WorkingDirectory $Root
    $output = (@($native.stdout.TrimEnd("`r", "`n"), $native.stderr.TrimEnd("`r", "`n")) | Where-Object { $_ -ne '' }) -join [Environment]::NewLine
    $retryable = $native.status -eq 'error' -and $output -match '(?i)connection reset|temporarily unavailable|ServiceUnavailable|TLS handshake timeout|i/o timeout|TooManyRequests'
    return @{ status = $native.status; exit_code = $native.exit_code; output = $output; retryable = [bool]$retryable; duration_ms = $native.duration_ms }
}
