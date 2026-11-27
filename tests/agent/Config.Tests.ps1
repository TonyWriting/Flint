#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
# Configuration cases use their own directory, so session files from the shared fixture do not interfere.
$configRoot = Join-Path $TestRoot 'config'
New-Item -ItemType Directory -Path $configRoot | Out-Null
Push-Location -LiteralPath $configRoot
$config = Join-Path $configRoot 'flint.ini'
$missing = Join-Path $configRoot 'missing.ini'
$endpoint = 'endpoint = https://test.services.ai.azure.com/openai/v1/responses'
$deployment = 'deployment = test-deployment'
$effort = 'reasoning_effort = medium'
$apiKey = 'api_key = test-key'
function Write-Config { param([string[]]$Lines) Set-Content -LiteralPath $config -Encoding UTF8 -Value $Lines }

try {
    $rejectedLogs = Join-Path $configRoot 'rejected-logs'
    Assert-Throws { New-AgentSession -ConfigFile $missing -TrajectoryDirectory $rejectedLogs } '*Configuration file not found*'
    Assert-Throws { New-AgentSession -ConfigFile $missing } '*agent.ps1 -Setup*copy the template*flint.example.ini*set endpoint, deployment, reasoning_effort and api_key under `[model`]*'
    Assert-True (-not (Test-Path -LiteralPath $missing)) 'Explain how to create the missing configuration without generating a placeholder file.'
    Assert-Throws { New-AgentSession -ConfigFile $configRoot } '*Configuration file not found*'
    Assert-True (-not (Test-Path -LiteralPath $rejectedLogs)) 'Require a real config file before creating a session.'

    Write-Config @('[model]', $endpoint, $deployment, $effort, $apiKey)
    $settings = Read-FlintConfig $config
    Assert-True ($settings.Model -ceq 'test-deployment' -and $settings.ApiKey -ceq 'test-key') 'Read the deployment and API key.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $configRoot '.flint'))) 'Read and validate configuration without creating session files.'
    $session = New-AgentSession -ConfigFile $config
    Assert-True ($session.ApiEndpoint -ceq 'https://test.services.ai.azure.com/openai/v1/responses') 'Use the complete configured URL without adding a suffix.'
    Assert-True ($session.ApiKey -ceq 'test-key') 'Load the API key into the session.'
    Assert-True ($session.Effort -ceq 'medium') 'Read the reasoning effort.'

    Write-Config @(
        '; Comments take whole lines.'
        '# Hash comments work as well.'
        ''
        '  [Model]  '
        'Endpoint="https://contoso-foundry.services.ai.azure.com/openai/v1/responses"'
        "deployment = 'file-deployment'"
        'Reasoning_Effort = HIGH'
        'API_KEY = file-key#with=characters;and;semicolons'
    )
    $session = New-AgentSession -ConfigFile $config
    Assert-True ($session.ApiEndpoint -ceq 'https://contoso-foundry.services.ai.azure.com/openai/v1/responses' -and $session.Model -ceq 'file-deployment') 'Accept a BOM, comments, blank lines, spacing, quotes and case-insensitive names.'
    Assert-True ($session.ApiKey -ceq 'file-key#with=characters;and;semicolons') 'Keep the whole value after the equals sign.'
    Assert-True ($session.Effort -ceq 'high') 'Accept a reasoning effort in any letter case.'

    Write-Config @('[model]', $endpoint, $deployment, $effort, 'api_key = "$(throw ''must not run'')-$VARIABLE"')
    Assert-True ((Read-FlintConfig $config).ApiKey -ceq '$(throw ''must not run'')-$VARIABLE') 'Treat configuration as literal text.'
    Write-Config @('[model]', $endpoint, $deployment, $effort, $apiKey, 'api_key_help = Get a new key from the team vault; ask #flint-help.')
    $session = New-AgentSession -ConfigFile $config
    Assert-True ($session.ApiKeyHelp -ceq 'Get a new key from the team vault; ask #flint-help.' -and (Read-FlintConfig $config).ApiKeyHelp) 'Keep the optional key help for rejected keys.'

    foreach ($case in @(
        @{ lines = @('[model]', $endpoint, $deployment, $effort); pattern = '*Set api_key under `[model`]*' },
        @{ lines = @('[model]', $endpoint, $deployment, $effort, 'api_key_help = Ask the team for the key.', 'api_key ='); pattern = '*Set api_key under `[model`]. Ask the team for the key.*' },
        @{ lines = @('[model]', $deployment, $effort, $apiKey); pattern = '*Set endpoint under `[model`]*' },
        @{ lines = @('[model]', $endpoint, $effort, $apiKey); pattern = '*Set deployment under `[model`]*' },
        @{ lines = @('[model]', $endpoint, 'deployment = ""', $effort, $apiKey); pattern = '*Set deployment under `[model`]*' },
        @{ lines = @('[model]', $endpoint, $deployment, 'auth = key', $apiKey); pattern = "*Line 4: unknown setting 'auth' in ``[model``]. Use endpoint, deployment, reasoning_effort, api_key, api_key_help.*" },
        @{ lines = @('[model]', $endpoint, $deployment, $apiKey); pattern = '*Set reasoning_effort under `[model`]. Use one of: none, low, medium, high, xhigh, max.*' },
        @{ lines = @('[model]', $endpoint, $deployment, 'reasoning_effort = secret-without-level', $apiKey); pattern = '*reasoning_effort under `[model`] must be one of: none, low, medium, high, xhigh, max.*' },
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
        Assert-True ($message -notlike '*secret-without*') 'Never echo configuration values.'
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
        Write-Config @('[model]', ('endpoint = ' + $value), $deployment, $effort, $apiKey)
        Assert-Throws { New-AgentSession -ConfigFile $config } '*complete HTTPS URL ending in /openai/v1/responses*'
    }

    Write-Host 'All config tests passed.'
} finally { Pop-Location; Remove-TestFixture }
