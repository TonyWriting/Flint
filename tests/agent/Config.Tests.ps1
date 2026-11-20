#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
if ($ExecutionContext.SessionState.LanguageMode -ne 'ConstrainedLanguage') { $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage' }
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'agent.ps1')

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

$testParent = (Get-Item -LiteralPath $env:TEMP -Force).FullName.TrimEnd('\')
$testRoot = Join-Path $testParent ('flint-config-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
Push-Location -LiteralPath $testRoot
$config = Join-Path $testRoot 'flint.ini'
$missing = Join-Path $testRoot 'missing.ini'
$endpoint = 'endpoint = https://test.services.ai.azure.com/openai/v1/responses'
$deployment = 'deployment = test-deployment'
$apiKey = 'api_key = test-key'
function Write-Config { param([string[]]$Lines) Set-Content -LiteralPath $config -Encoding UTF8 -Value $Lines }

try {
    Write-Host ('Testing config with PowerShell {0}, {1}' -f $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode)
    $rejectedLogs = Join-Path $testRoot 'rejected-logs'
    Assert-Throws { New-AgentSession -ConfigFile $missing -TrajectoryDirectory $rejectedLogs } '*Configuration file not found*'
    Assert-Throws { New-AgentSession -ConfigFile $missing } '*agent.ps1 -Setup*copy the template*flint.example.ini*set endpoint, deployment and api_key under `[model`]*'
    Assert-True (-not (Test-Path -LiteralPath $missing)) 'Explain how to create the missing configuration without generating a placeholder file.'
    Assert-Throws { New-AgentSession -ConfigFile $testRoot } '*Configuration file not found*'
    Assert-True (-not (Test-Path -LiteralPath $rejectedLogs)) 'Require a real config file before creating a session.'

    Write-Config @('[model]', $endpoint, $deployment, $apiKey)
    $settings = Read-FlintConfig $config
    Assert-True ($settings.Model -ceq 'test-deployment' -and $settings.ApiKey -ceq 'test-key') 'Read the deployment and API key.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot '.flint'))) 'Read and validate configuration without creating session files.'
    $session = New-AgentSession -ConfigFile $config
    Assert-True ($session.ApiEndpoint -ceq 'https://test.services.ai.azure.com/openai/v1/responses') 'Use the complete configured URL without adding a suffix.'
    Assert-True ($session.ApiKey -ceq 'test-key') 'Load the API key into the session.'
    Assert-True ($session.Effort -eq 'medium') 'Default reasoning effort matches the reference loop.'

    Write-Config @(
        '; Comments take whole lines.'
        '# Hash comments work as well.'
        ''
        '  [Model]  '
        'Endpoint="https://contoso-foundry.services.ai.azure.com/openai/v1/responses"'
        "deployment = 'file-deployment'"
        'API_KEY = file-key#with=characters;and;semicolons'
    )
    $session = New-AgentSession -ConfigFile $config -Effort high
    Assert-True ($session.ApiEndpoint -ceq 'https://contoso-foundry.services.ai.azure.com/openai/v1/responses' -and $session.Model -ceq 'file-deployment') 'Accept a BOM, comments, blank lines, spacing, quotes and case-insensitive names.'
    Assert-True ($session.ApiKey -ceq 'file-key#with=characters;and;semicolons') 'Keep the whole value after the equals sign.'
    Assert-True ($session.Effort -eq 'high') 'Allow an explicit reasoning effort.'

    Write-Config @('[model]', $endpoint, $deployment, 'api_key = "$(throw ''must not run'')-$VARIABLE"')
    Assert-True ((Read-FlintConfig $config).ApiKey -ceq '$(throw ''must not run'')-$VARIABLE') 'Treat configuration as literal text.'
    Write-Config @('[model]', $endpoint, $deployment, $apiKey, 'api_key_help = Get a new key from the team vault; ask #flint-help.')
    $session = New-AgentSession -ConfigFile $config
    Assert-True ($session.ApiKeyHelp -ceq 'Get a new key from the team vault; ask #flint-help.' -and (Read-FlintConfig $config).ApiKeyHelp) 'Keep the optional key help for rejected keys.'

    foreach ($case in @(
        @{ lines = @('[model]', $endpoint, $deployment); pattern = '*Set api_key under `[model`]*' },
        @{ lines = @('[model]', $endpoint, $deployment, 'api_key_help = Ask the team for the key.', 'api_key ='); pattern = '*Set api_key under `[model`]. Ask the team for the key.*' },
        @{ lines = @('[model]', $deployment, $apiKey); pattern = '*Set endpoint under `[model`]*' },
        @{ lines = @('[model]', $endpoint, $apiKey); pattern = '*Set deployment under `[model`]*' },
        @{ lines = @('[model]', $endpoint, 'deployment = ""', $apiKey); pattern = '*Set deployment under `[model`]*' },
        @{ lines = @('[model]', $endpoint, $deployment, 'auth = key', $apiKey); pattern = "*Line 4: unknown setting 'auth' in ``[model``]. Use endpoint, deployment, api_key, api_key_help.*" },
        @{ lines = @('[azure]', 'tenant = contoso.onmicrosoft.com'); pattern = '*Line 1: unknown section `[azure`]. Use `[model`].*' },
        @{ lines = @($endpoint); pattern = '*Line 1: endpoint must follow a section header*' },
        @{ lines = @('[model]', $endpoint, $endpoint); pattern = "*Line 3: 'endpoint' is set more than once*" },
        @{ lines = @('[model]', 'endpoint https://test.services.ai.azure.com/openai/v1/responses'); pattern = '*Line 2 is not a `[section`]*' },
        @{ lines = @('[model]', $endpoint, $deployment, 'api_key = "secret-without-closing-quote'); pattern = "*Line 4: the value of 'api_key' has an unmatched quote*" }
    )) {
        Write-Config $case.lines
        $message = ''
        try { $null = New-AgentSession -ConfigFile $config } catch { $message = $_.Exception.Message }
        Assert-True ($message -like $case.pattern) ("Expected '" + $case.pattern + "'; got '" + $message + "'.")
        Assert-True ($message -notlike '*secret-without*' -and $message -notlike '*environment-key*') 'Never echo configuration values or read the environment.'
    }

    foreach ($value in @(
        'http://test.services.ai.azure.com/openai/v1/responses'
        'https://test.services.ai.azure.com'
        'https://test.services.ai.azure.com/openai/v1'
        'https://test.services.ai.azure.com/openai/v1/'
        'https://test.services.ai.azure.com/openai/v1/responses/'
        'https://test.services.ai.azure.com/openai/v1/responses/responses'
        'https://test.services.ai.azure.com/openai/v1/Responses'
        'https://test.services.ai.azure.com/openai/v1/chat/completions'
        'https://user:password@test.services.ai.azure.com/openai/v1/responses'
        'https://test.services.ai.azure.com/openai/v1/responses?api-version=preview'
        'https://test.services.ai.azure.com/openai/v1/responses#fragment'
        '/openai/v1/responses'
    )) {
        Write-Config @('[model]', ('endpoint = ' + $value), $deployment, $apiKey)
        Assert-Throws { New-AgentSession -ConfigFile $config } '*complete HTTPS URL ending in /openai/v1/responses*'
    }

    Write-Host 'All config tests passed.'
} finally {
    Pop-Location
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath
    if ($resolvedTestRoot -ne $testRoot -or (Split-Path $resolvedTestRoot -Parent) -ne $testParent) {
        throw 'Refusing cleanup outside the temporary config test directory.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
