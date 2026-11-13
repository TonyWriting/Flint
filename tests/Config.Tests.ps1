#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
if ($ExecutionContext.SessionState.LanguageMode -ne 'ConstrainedLanguage') { $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage' }
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

$original = @{
    AZURE_OPENAI_ENDPOINT = $env:AZURE_OPENAI_ENDPOINT
    AZURE_OPENAI_API_KEY = $env:AZURE_OPENAI_API_KEY
    AZURE_OPENAI_DEPLOYMENT = $env:AZURE_OPENAI_DEPLOYMENT
}
$testParent = (Resolve-Path -LiteralPath $env:TEMP).ProviderPath.TrimEnd('\')
$testRoot = Join-Path $testParent ('flint-config-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
Push-Location -LiteralPath $testRoot
$config = Join-Path $testRoot '.env'
$missing = Join-Path $testRoot 'missing.env'

try {
    Write-Host ('Testing config with PowerShell {0}, {1}' -f $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode)
    $env:AZURE_OPENAI_ENDPOINT = 'https://env.services.ai.azure.com/openai/v1/responses'
    $env:AZURE_OPENAI_API_KEY = 'env-key'
    $env:AZURE_OPENAI_DEPLOYMENT = 'env-deployment'
    $rejectedLogs = Join-Path $testRoot 'rejected-logs'
    Assert-Throws { New-AgentSession -EnvFile $missing -TrajectoryDirectory $rejectedLogs } '*Configuration file not found*'
    Assert-Throws { New-AgentSession -EnvFile $missing } '*Create this file using the template*.env.example*Fill in AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_API_KEY and AZURE_OPENAI_DEPLOYMENT*'
    Assert-True (-not (Test-Path -LiteralPath $missing)) 'Explain how to create the missing configuration without generating a placeholder file.'
    Assert-Throws { New-AgentSession -EnvFile $testRoot } '*Configuration file not found*'
    Assert-True (-not (Test-Path -LiteralPath $rejectedLogs)) 'Require a real config file before creating a session, even when environment variables are set.'
    Set-Content -LiteralPath $config -Encoding UTF8 -Value '# Use environment values for omitted settings.'
    $settings = Read-FlintConfig $config
    Assert-True ($settings.Model -eq 'env-deployment' -and -not (Test-Path -LiteralPath (Join-Path $testRoot '.flint'))) 'Read and validate configuration without creating session files.'
    $session = New-AgentSession -EnvFile $config
    Assert-True ($session.ApiEndpoint -eq 'https://env.services.ai.azure.com/openai/v1/responses') 'Use the complete configured URL without adding a suffix.'
    Assert-True ($session.ApiKey -eq 'env-key' -and $session.Model -eq 'env-deployment') 'Load the key and deployment from the environment.'
    Assert-True ($session.Effort -eq 'medium') 'Default reasoning effort matches the reference loop.'

    Set-Content -LiteralPath $config -Encoding UTF8 -Value @(
        '# UTF-8 BOM and quoted values.'
        'export AZURE_OPENAI_ENDPOINT = "https://micorosft-foundry.services.ai.azure.com/openai/v1/responses" # complete request URL'
        "AZURE_OPENAI_API_KEY='file-key#with=characters'"
        'AZURE_OPENAI_DEPLOYMENT = file-deployment # deployment name'
        'IGNORED_SETTING=unused'
    )
    $session = New-AgentSession -EnvFile $config -Effort high
    Assert-True ($session.ApiEndpoint -eq 'https://micorosft-foundry.services.ai.azure.com/openai/v1/responses') 'Accept the supplied Azure endpoint with a BOM, export prefix, quotes and comments.'
    Assert-True ($session.ApiKey -ceq 'file-key#with=characters' -and $session.Model -eq 'file-deployment') 'File settings override the environment without splitting values.'
    Assert-True ($session.Effort -eq 'high') 'Allow an explicit reasoning effort.'
    Assert-True ($env:AZURE_OPENAI_API_KEY -eq 'env-key') 'Do not modify caller environment variables.'

    Set-Content -LiteralPath $config -Encoding UTF8 -Value 'AZURE_OPENAI_API_KEY="$(throw ''must not run'')-$VARIABLE"'
    $session = New-AgentSession -EnvFile $config
    Assert-True ($session.ApiKey -ceq '$(throw ''must not run'')-$VARIABLE') 'Treat configuration as literal text.'
    Assert-True ($session.Model -eq 'env-deployment') 'Fall back to the environment for omitted keys.'

    Set-Content -LiteralPath $config -Encoding UTF8 -Value 'AZURE_OPENAI_API_KEY="secret-without-closing-quote'
    $message = ''
    try { New-AgentSession -EnvFile $config | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -like '*Invalid quoted value*' -and $message -notlike '*secret-without*') 'Report invalid quotes without exposing the value.'

    foreach ($name in $original.Keys) {
        foreach ($emptyValue in @('""', ' # unset')) {
            Set-Content -LiteralPath $config -Encoding UTF8 -Value ($name + '=' + $emptyValue)
            Assert-Throws { New-AgentSession -EnvFile $config } "*Set $name*"
        }
    }

    Set-Content -LiteralPath $config -Encoding UTF8 -Value '# Validate the endpoint inherited from the environment.'
    foreach ($endpoint in @(
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
        $env:AZURE_OPENAI_ENDPOINT = $endpoint
        Assert-Throws { New-AgentSession -EnvFile $config } '*complete HTTPS URL ending in /openai/v1/responses*'
    }
    $env:AZURE_OPENAI_ENDPOINT = ''
    Assert-Throws { New-AgentSession -EnvFile $config } '*Set AZURE_OPENAI_ENDPOINT*'

    Write-Host 'All config tests passed.'
} finally {
    Pop-Location
    foreach ($name in $original.Keys) { Set-Item -LiteralPath ('Env:' + $name) -Value $original[$name] }
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath
    if ($resolvedTestRoot -ne $testRoot -or (Split-Path $resolvedTestRoot -Parent) -ne $testParent) {
        throw 'Refusing cleanup outside the temporary config test directory.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
