$ErrorActionPreference = 'Stop'
if ($ExecutionContext.SessionState.LanguageMode -ne 'ConstrainedLanguage') {
    $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
}
# Suites live in category directories; resolve the repository from this shared file.
$script:RepoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $script:RepoRoot 'agent.ps1')

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
        foreach ($entry in @(@{ key = 'start_line'; value = 1 }, @{ key = 'start_column'; value = 1 }, @{ key = 'max_lines'; value = 200 }, @{ key = 'json_path'; value = $null })) {
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
    $source = $script:RepoRoot
    New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    foreach ($file in @('agent.ps1', 'flint.example.ini')) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination $Path }
    foreach ($directory in @('lib', 'tools', 'docs')) { Copy-Item -LiteralPath (Join-Path $source $directory) -Destination $Path -Recurse }
    foreach ($worker in @('lib\ModelWorker.ps1', 'tools\Worker.ps1')) {
        $entry = Join-Path $Path $worker
        $implementation = $entry -replace '\.ps1$', '.Implementation.ps1'
        Copy-Item -LiteralPath $entry -Destination $implementation
        $null = New-TestWorkerLauncher $implementation $entry
    }
    return $Path
}

function New-TestRule {
    param([string[]]$Command, [switch]$ClusterScoped)
    $options = [ordered]@{
        '--context' = [ordered]@{ required = $true; pattern = '^[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,255}$' }
        '--output' = [ordered]@{ values = @('json', 'yaml', 'name') }
    }
    if (-not $ClusterScoped) { $options['--namespace'] = [ordered]@{ required = $true; pattern = '^[a-z0-9][a-z0-9.-]{0,62}$' } }
    return [ordered]@{ command = $Command; read_only = $true; options = $options; positionals = [ordered]@{ max = 1; pattern = '^[a-z0-9][a-z0-9.-]{0,252}$' } }
}

function New-TestPlugin {
    param([string]$Path, [string]$Name = 'example', [string]$Version = '1.0.0', [hashtable]$Manifest = @{}, [object[]]$Rules)
    # A complete fictional plugin; callers override manifest fields or rules to build invalid variants.
    foreach ($directory in @($Path, (Join-Path $Path 'permissions'), (Join-Path $Path 'docs'))) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $Path 'guide.md') -Encoding UTF8 -Value @('# Example guide', '', 'Widgets are reconciled by the example controller. Read a widget before patching its spec.')
    Set-Content -LiteralPath (Join-Path $Path 'docs\index.md') -Encoding UTF8 -Value @('# Documentation index', '', '- widgets.md | Widgets | Status; Troubleshooting')
    Set-Content -LiteralPath (Join-Path $Path 'docs\widgets.md') -Encoding UTF8 -Value @('# Widgets', '', '## Status', 'Ready widgets report Available.')
    if ($null -eq $Rules) { $Rules = @((New-TestRule @('get', 'widgets.example.io')), (New-TestRule @('describe', 'widgets.example.io'))) }
    $document = [ordered]@{ version = 1; executor = 'kubectl'; rules = @($Rules) }
    Set-Content -LiteralPath (Join-Path $Path 'permissions\kubectl.json') -Encoding UTF8 -Value (ConvertTo-Json -InputObject $document -Depth 10)
    $manifestDocument = [ordered]@{
        schema_version = 1; name = $Name; version = $Version; summary = 'Fictional widgets used by offline tests.'
        guide = 'guide.md'
        kubectl = [ordered]@{ rules = 'permissions/kubectl.json'; guarded_patch_resources = @('widgets.example.io', 'widgets') }
    }
    foreach ($key in $Manifest.Keys) { $manifestDocument[$key] = $Manifest[$key] }
    # A null override removes the field.
    $written = [ordered]@{}
    foreach ($key in $manifestDocument.Keys) { if ($null -ne $manifestDocument[$key]) { $written[$key] = $manifestDocument[$key] } }
    Set-Content -LiteralPath (Join-Path $Path 'plugin.json') -Encoding UTF8 -Value (ConvertTo-Json -InputObject $written -Depth 10)
    return $Path
}

function New-TestSetup {
    param([string]$Path, [string[]]$Template, [string[]]$Plugins = @('example'))
    # A fictional team setup folder: a flint.ini template without a key and Plugins\<name> folders.
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if ($null -eq $Template) {
        $Template = @('[model]', 'endpoint = https://contoso.services.ai.azure.com/openai/v1/responses', 'deployment = team-model', 'api_key_help = Ask the team for the key.')
    }
    Set-Content -LiteralPath (Join-Path $Path 'flint.ini') -Encoding UTF8 -Value $Template
    foreach ($name in $Plugins) { $null = New-TestPlugin (Join-Path $Path ('Plugins\' + $name)) -Name $name }
    return $Path
}

function New-TestSession {
    param([string]$Resume)
    # Sessions start in the working directory with the shared configuration, as the entry point does.
    Push-Location -LiteralPath $script:WorkRoot
    try { return New-AgentSession -ConfigFile (Join-Path $script:TestRoot 'flint.ini') -Resume $Resume } finally { Pop-Location }
}

function Get-TestEvents {
    param([string]$Path = $script:Session.TrajectoryPath)
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ })
}

function New-TestResponse {
    param([object[]]$Items)
    # A completed model response that reports cached and reasoning usage.
    return @{ status = 'completed'; output = $Items; usage = @{ input_tokens = 10; output_tokens = 5; input_tokens_details = @{ cached_tokens = 3 }; output_tokens_details = @{ reasoning_tokens = 2 } } }
}

function New-TestFunctionCall {
    param([string]$Name, [hashtable]$Arguments)
    return @{ type = 'function_call'; name = $Name; call_id = [guid]::NewGuid().ToString('N'); arguments = (ConvertTo-Json $Arguments -Depth 16 -Compress) }
}

function Remove-TestFixture {
    $resolved = (Resolve-Path -LiteralPath $script:TestRoot).ProviderPath
    if ($resolved -ne $script:TestRoot -or (Split-Path $resolved -Parent) -ne $script:TestParent) {
        throw 'Refusing cleanup outside the temporary test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

# Sessions load plugins from the test fixture, never from plugins installed in the developer's checkout.
function Get-FlintPluginDirectory { return Join-Path $script:TestRoot 'plugins' }

# Keep fixture expectations in the same long-path form as session roots.
$script:TestParent = (Get-Item -LiteralPath $env:TEMP -Force).FullName.TrimEnd('\')
$script:TestRoot = Join-Path $script:TestParent ('flint-tests-' + [guid]::NewGuid().ToString('N'))
$script:WorkRoot = Join-Path $script:TestRoot 'work'
New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null
function Get-TestConfigLines {
    # A complete configuration for offline suites.
    return @('[model]', 'endpoint = https://test.services.ai.azure.com/openai/v1/responses', 'deployment = test-deployment', 'api_key = test-api-key')
}
$config = Join-Path $script:TestRoot 'flint.ini'
Set-Content -LiteralPath $config -Encoding UTF8 -Value (Get-TestConfigLines)
$script:Session = New-TestSession
$script:Session.WorkerPath = New-TestWorkerLauncher $script:Session.WorkerPath (Join-Path $script:TestRoot 'tool-launcher.ps1')
$script:Session.ModelWorkerPath = New-TestWorkerLauncher $script:Session.ModelWorkerPath (Join-Path $script:TestRoot 'model-launcher.ps1')
Write-Host ('Testing PowerShell {0}, {1}' -f $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode)
