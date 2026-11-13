#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$savedEnvironment = @{}
try {
    # A local launcher exercises the real native invocation without using a cloud account.
    $launcher = Join-Path $TestRoot 'az.cmd'
    Set-Content -LiteralPath $launcher -Encoding ASCII -Value @'
@echo off
if not "%AZURE_CORE_NO_COLOR%"=="true" (
  echo ModuleNotFoundError: No module named 'ctypes' 1>&2
  exit /b 90
)
if defined AZURE_OPENAI_API_KEY exit /b 91
if defined FLINT_MODEL_API_KEY exit /b 92
if defined FLINT_AZURE_ACCESS_TOKEN exit /b 93
if "%~1"=="login" (
  if not "%AZURE_CORE_LOGIN_EXPERIENCE_V2%"=="off" exit /b 94
  if not "%~2"=="--allow-no-subscriptions" exit /b 95
  if not "%~3"=="--tenant" exit /b 96
  if not "%~4"=="contoso.onmicrosoft.com" exit /b 97
  exit /b 0
)
if "%~2"=="show" (
  if not "%~3"=="--output" exit /b 98
  echo {"user":{"name":"user@example.com","type":"user"},"tenantId":"11111111-1111-1111-1111-111111111111","environmentName":"AzureCloud"}
  exit /b 0
)
if "%~2"=="get-access-token" (
  if not "%~3"=="--tenant" exit /b 99
  if not "%~4"=="contoso.onmicrosoft.com" exit /b 100
  echo {"accessToken":"private-cli-fixture-token","expires_on":4102444800,"resource":"%~6"}
  exit /b 0
)
echo ERROR: Please run az login. 1>&2
exit /b 1
'@
    $Session.Azure = @{ CliPath = $launcher; Tenant = 'contoso.onmicrosoft.com' }
    foreach ($name in @('AZURE_OPENAI_API_KEY', 'FLINT_MODEL_API_KEY', 'FLINT_AZURE_ACCESS_TOKEN')) {
        $savedEnvironment[$name] = (Get-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue).Value
        Set-Item -LiteralPath ('Env:' + $name) -Value 'must-not-reach-cli'
    }
    $savedEnvironment.AZURE_CORE_LOGIN_EXPERIENCE_V2 = (Get-Item -LiteralPath Env:AZURE_CORE_LOGIN_EXPERIENCE_V2 -ErrorAction SilentlyContinue).Value
    $savedEnvironment.AZURE_CORE_NO_COLOR = (Get-Item -LiteralPath Env:AZURE_CORE_NO_COLOR -ErrorAction SilentlyContinue).Value
    $env:AZURE_CORE_LOGIN_EXPERIENCE_V2 = 'on'
    $env:AZURE_CORE_NO_COLOR = 'false'
    $account = Invoke-FlintAzureCli $Session account
    Assert-True ($account.user.name -eq 'user@example.com') 'Read the CLI user identity without selecting a subscription.'
    Assert-True ($env:AZURE_CORE_NO_COLOR -ceq 'false') 'Disable CLI colors only during invocation and restore the caller setting.'
    $token = Invoke-FlintAzureCli $Session token
    Assert-True ($token.accessToken -ceq 'private-cli-fixture-token' -and $token.expires_on -eq 4102444800) 'Capture CLI token JSON directly into memory.'
    Assert-True ($token.resource -ceq 'https://management.azure.com/') 'Request the ARM audience by default.'
    $keyVaultToken = Invoke-FlintAzureCli $Session token -Service keyvault
    Assert-True ($keyVaultToken.resource -ceq 'https://vault.azure.net') 'Request the Key Vault audience separately using the same tenant login.'
    Invoke-FlintAzureCli $Session login
    Assert-True ($env:AZURE_CORE_LOGIN_EXPERIENCE_V2 -ceq 'on') 'Restore the subscription-selector setting after tenant login.'
    Assert-True ($env:AZURE_CORE_NO_COLOR -ceq 'false') 'Restore color preferences after a successful login.'
    $failedLauncher = Join-Path $TestRoot 'failed-az.cmd'
    Set-Content -LiteralPath $failedLauncher -Encoding ASCII -Value @('@echo off', 'if not "%AZURE_CORE_NO_COLOR%"=="true" exit /b 90', 'echo ERROR: Please run az login. 1>&2', 'exit /b 1')
    $Session.Azure.CliPath = $failedLauncher
    Assert-Throws { Invoke-FlintAzureCli $Session token } '*az login*'
    Assert-Throws { Invoke-FlintAzureCli $Session login } '*az login failed*'
    Assert-True ($env:AZURE_CORE_LOGIN_EXPERIENCE_V2 -ceq 'on') 'Restore login settings after a failed login as well.'
    Assert-True ($env:AZURE_CORE_NO_COLOR -ceq 'false') 'Restore color preferences after CLI errors.'
    $Session.Azure.CliPath = $launcher
    Remove-Item -LiteralPath Env:AZURE_CORE_NO_COLOR -ErrorAction SilentlyContinue
    $null = Invoke-FlintAzureCli $Session account
    Assert-True (-not (Test-Path -LiteralPath Env:AZURE_CORE_NO_COLOR)) 'Keep an initially absent color variable absent after invocation.'
    foreach ($name in @('AZURE_OPENAI_API_KEY', 'FLINT_MODEL_API_KEY', 'FLINT_AZURE_ACCESS_TOKEN')) {
        Assert-True ((Get-Item -LiteralPath ('Env:' + $name)).Value -ceq 'must-not-reach-cli') 'Restore parent environment values after native invocation.'
    }
    Assert-True (@(Get-ChildItem -LiteralPath $TestRoot -Filter '*stdout*' -Recurse).Count -eq 0) 'Never create a CLI token capture file.'
    Assert-True (-not (Get-Content -LiteralPath $Session.TrajectoryPath -Raw).Contains('private-cli-fixture-token')) 'Keep CLI token output out of the trajectory.'
    $Session.Azure.Tenant = 'tenant&unexpected-command'
    Assert-Throws { Invoke-FlintAzureCli $Session token } '*tenant ID or a tenant domain*'
    Write-Host 'All Azure CLI tests passed.'
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath ('Env:' + $name) -Value $savedEnvironment[$name] }
    }
    Remove-TestFixture
}
