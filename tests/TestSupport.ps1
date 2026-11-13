$ErrorActionPreference = 'Stop'
if ($ExecutionContext.SessionState.LanguageMode -ne 'ConstrainedLanguage') {
    $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
}
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'agent.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -like $Pattern) "Expected '$Pattern'; got '$message'."
}

function Invoke-TestTool {
    param([string]$Name, [hashtable]$ToolArguments)
    if ($Name -in @('run_command', 'azure_request') -and -not $ToolArguments.ContainsKey('purpose')) { $ToolArguments.purpose = 'Execute the scoped offline test operation.' }
    if ($Name -eq 'read_file') {
        foreach ($entry in @(@{ key = 'start_line'; value = 1 }, @{ key = 'start_column'; value = 1 }, @{ key = 'max_lines'; value = 200 })) {
            if (-not $ToolArguments.ContainsKey($entry.key)) { $ToolArguments[$entry.key] = $entry.value }
        }
    }
    if ($Name -eq 'list_files') {
        if (-not $ToolArguments.ContainsKey('name_filter')) { $ToolArguments.name_filter = '*' }
        if (-not $ToolArguments.ContainsKey('offset')) { $ToolArguments.offset = 0 }
    }
    if ($Name -eq 'search_text') {
        if (-not $ToolArguments.ContainsKey('start_line')) { $ToolArguments.start_line = 1 }
        if (-not $ToolArguments.ContainsKey('max_matches')) { $ToolArguments.max_matches = 50 }
    }
    Invoke-AgentTool $script:Session $Name (ConvertTo-Json -InputObject $ToolArguments -Depth 16 -Compress) 'test-call'
}

function New-TestWorkerLauncher {
    param([string]$WorkerPath, [string]$LauncherPath)
    # A manually constrained test session does not constrain newly started processes.
    # Enter the target mode before loading the real worker, as device policy would.
    Set-Content -LiteralPath $LauncherPath -Encoding UTF8 -Value @(
        'param([string]$RequestPath)'
        '$ErrorActionPreference = ''Stop'''
        'if ($ExecutionContext.SessionState.LanguageMode -ne ''ConstrainedLanguage'') { $ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage'' }'
        ('& ''' + $WorkerPath.Replace("'", "''") + ''' -RequestPath $RequestPath')
    )
    return $LauncherPath
}

function New-TestRuntime {
    param([string]$Path)
    $source = Split-Path $PSScriptRoot -Parent
    New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    foreach ($file in @('agent.ps1', '.env.example')) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination $Path }
    foreach ($directory in @('lib', 'tools', 'docs')) { Copy-Item -LiteralPath (Join-Path $source $directory) -Destination $Path -Recurse }
    foreach ($worker in @('lib\ModelWorker.ps1', 'tools\Worker.ps1')) {
        $entry = Join-Path $Path $worker
        $implementation = $entry -replace '\.ps1$', '.Implementation.ps1'
        Copy-Item -LiteralPath $entry -Destination $implementation
        $null = New-TestWorkerLauncher $implementation $entry
    }
    return $Path
}

function Remove-TestFixture {
    $resolved = (Resolve-Path -LiteralPath $script:TestRoot).ProviderPath
    if ($resolved -ne $script:TestRoot -or (Split-Path $resolved -Parent) -ne $script:TestParent) {
        throw 'Refusing cleanup outside the temporary test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

$script:TestParent = (Resolve-Path -LiteralPath $env:TEMP).ProviderPath.TrimEnd('\')
$script:TestRoot = Join-Path $script:TestParent ('flint-tests-' + [guid]::NewGuid().ToString('N'))
$script:WorkRoot = Join-Path $script:TestRoot 'work'
New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null
$config = Join-Path $script:TestRoot '.env'
Set-Content -LiteralPath $config -Encoding UTF8 -Value @(
    'AZURE_OPENAI_ENDPOINT=https://test.services.ai.azure.com/openai/v1/responses'
    'AZURE_OPENAI_API_KEY=test-api-key'
    'AZURE_OPENAI_DEPLOYMENT=test-deployment'
)
Push-Location -LiteralPath $script:WorkRoot
try { $script:Session = New-AgentSession -EnvFile $config } finally { Pop-Location }
$script:Session.PermissionSessionDirectory = Join-Path $script:TestRoot 'permissions'
$script:Session.WorkerPath = New-TestWorkerLauncher $script:Session.WorkerPath (Join-Path $script:TestRoot 'tool-launcher.ps1')
$script:Session.ModelWorkerPath = New-TestWorkerLauncher $script:Session.ModelWorkerPath (Join-Path $script:TestRoot 'model-launcher.ps1')
Write-Host ('Testing PowerShell {0}, {1}' -f $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode)
