#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$savedEnvironment = @{}
$secretNames = @('AZURE_OPENAI_API_KEY', 'FLINT_MODEL_API_KEY', 'FLINT_AZURE_ACCESS_TOKEN')

function New-FakeAzModule {
    param([string]$Root, [string]$Version, [string[]]$Body)
    $directory = Join-Path $Root ('Az.Accounts\' + $Version)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $directory 'Az.Accounts.psd1') -Encoding UTF8 -Value @(
        '@{'
        ("    ModuleVersion = '{0}'" -f $Version)
        "    RootModule = 'Az.Accounts.psm1'"
        "    FunctionsToExport = @('Get-AzContext', 'Get-AzAccessToken', 'Connect-AzAccount', 'Update-AzConfig', 'Set-FakeAzState', 'Get-FakeAzState')"
        '}'
    )
    Set-Content -LiteralPath (Join-Path $directory 'Az.Accounts.psm1') -Encoding UTF8 -Value $Body
    return (Join-Path $directory 'Az.Accounts.psd1')
}

function Reset-AzureSession {
    param([string]$Tenant = '')
    $Session.Azure = @{}; $Session.NoAzure = $false; $Session.AzureTenant = $Tenant
    Initialize-FlintUi $Session
    $Session.Ui.Live = $true
}

function Invoke-AzureStartup {
    # Startup status is written to the host; capture it to verify the sign-in summary.
    return ((Initialize-FlintAzure $Session 6>&1) | Out-String)
}

try {
    foreach ($name in @('PATH', 'PSModulePath') + $secretNames) {
        $savedEnvironment[$name] = (Get-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue).Value
    }
    foreach ($name in $secretNames) { Set-Item -LiteralPath ('Env:' + $name) -Value 'must-not-reach-sign-in' }
    $system32 = Join-Path $env:SystemRoot 'System32'
    $bin = Join-Path $TestRoot 'bin'
    $emptyModules = Join-Path $TestRoot 'no-modules'
    $modules = Join-Path $TestRoot 'modules'
    $brokenModules = Join-Path $TestRoot 'broken-modules'
    New-Item -ItemType Directory -Path $bin, $emptyModules -Force | Out-Null

    # This stand-in for Az.Accounts runs in ConstrainedLanguage, like the code under test.
    $fakeManifest = New-FakeAzModule $modules '9.9.9' @(
        '$script:State = @{ Context = $null; LoginCalls = 0; LoginTenant = $null; LoginFailure = $false; LoginSelectorOff = $false; LoginEnvironmentClean = $false; SelectorOff = $false; TokenCalls = @(); TokenFailure = ''''; TokenTenant = '''' }'
        '# ConstrainedLanguage rejects [pscustomobject] casts; New-Object PSObject builds the same shape.'
        'function New-FakeObject { param([hashtable]$Properties) return New-Object -TypeName PSObject -Property $Properties }'
        'function New-FakeContext { param([string]$Type = ''User'') return New-FakeObject @{ Account = (New-FakeObject @{ Id = ''ps-user@example.com''; Type = $Type }); Tenant = (New-FakeObject @{ Id = ''11111111-1111-1111-1111-111111111111'' }); Environment = (New-FakeObject @{ Name = ''AzureCloud'' }) } }'
        '$script:State.Context = New-FakeContext'
        'function Set-FakeAzState { param([hashtable]$Values) foreach ($key in @($Values.Keys)) { $script:State[$key] = $Values[$key] } }'
        'function Get-FakeAzState { param([string]$ContextType) if ($ContextType) { return New-FakeContext $ContextType }; return $script:State }'
        'function Get-AzContext { [CmdletBinding()] param() return $script:State.Context }'
        'function Update-AzConfig { [CmdletBinding()] param([string]$LoginExperienceV2, [string]$Scope) if ($LoginExperienceV2 -ceq ''Off'' -and $Scope -ceq ''Process'') { $script:State.SelectorOff = $true }; return New-FakeObject @{ Key = ''LoginExperienceV2''; Value = $LoginExperienceV2 } }'
        'function Connect-AzAccount {'
        '    [CmdletBinding()] param([string]$Tenant)'
        '    $script:State.LoginCalls++'
        '    $script:State.LoginTenant = $Tenant'
        '    $script:State.LoginSelectorOff = $script:State.SelectorOff'
        '    $script:State.LoginEnvironmentClean = -not ((Test-Path Env:AZURE_OPENAI_API_KEY) -or (Test-Path Env:FLINT_MODEL_API_KEY) -or (Test-Path Env:FLINT_AZURE_ACCESS_TOKEN))'
        '    if ($script:State.LoginFailure) { throw ''User canceled authentication.'' }'
        '    $script:State.Context = New-FakeContext'
        '    $script:State.TokenFailure = '''''
        '    return ''login-output-must-be-discarded'''
        '}'
        'function Get-AzAccessToken {'
        '    [CmdletBinding()] param([string]$ResourceUrl, [string]$TenantId, [switch]$AsSecureString)'
        '    if (-not $script:State.Context) { throw ''Run Connect-AzAccount to login.'' }'
        '    if ($script:State.TokenFailure) { throw $script:State.TokenFailure }'
        '    $script:State.TokenCalls += @{ resource = $ResourceUrl; tenant = $TenantId; secure = [bool]$AsSecureString }'
        '    $value = ''private-ps-arm-token'''
        '    if ($ResourceUrl -ceq ''https://vault.azure.net'') { $value = ''private-ps-keyvault-token'' }'
        '    $token = $value'
        '    if ($AsSecureString) { $token = ConvertTo-SecureString -String $value -AsPlainText -Force }'
        '    $tenant = $TenantId'
        '    if ($script:State.TokenTenant) { $tenant = $script:State.TokenTenant }'
        '    return New-FakeObject @{ Token = $token; ExpiresOn = (New-FakeObject @{ UtcDateTime = [datetime]::UtcNow.AddHours(1) }); TenantId = $tenant; UserId = ''ps-user@example.com'' }'
        '}'
    )
    $null = New-FakeAzModule $brokenModules '1.0.0' @('throw ''Az.Accounts is blocked by device policy.''')
    Set-Content -LiteralPath (Join-Path $bin 'az.cmd') -Encoding ASCII -Value @'
@echo off
if "%~2"=="show" (
  echo {"user":{"name":"cli-user@example.com","type":"user"},"tenantId":"11111111-1111-1111-1111-111111111111","environmentName":"AzureCloud"}
  exit /b 0
)
if "%~2"=="get-access-token" (
  echo {"accessToken":"private-cli-token","expires_on":4102444800,"tenant":"11111111-1111-1111-1111-111111111111"}
  exit /b 0
)
exit /b 1
'@

    $env:PATH = $bin + ';' + $system32
    $env:PSModulePath = $modules
    Reset-AzureSession
    $output = Invoke-AzureStartup
    Assert-True ($Session.Azure.Status -eq 'ready' -and $Session.Azure.Provider -ceq 'cli' -and $Session.Azure.Account -eq 'cli-user@example.com') 'Prefer Azure CLI when both providers are installed.'
    Assert-True (-not (Get-Module -Name Az.Accounts)) 'Do not load Azure PowerShell when Azure CLI is available.'
    Assert-True ($output.Contains('Signed in to Azure as cli-user@example.com') -and $output.Contains('via Azure CLI')) 'Report the signed-in account and the CLI provider at startup.'

    $env:PATH = $system32
    $env:PSModulePath = $emptyModules
    Reset-AzureSession
    $null = Invoke-AzureStartup
    Assert-True ($Session.Azure.Status -eq 'unavailable' -and $Session.Azure.Message.Contains('Azure CLI') -and $Session.Azure.Message.Contains('Az.Accounts')) 'Report a missing provider when neither Azure CLI nor Azure PowerShell is installed.'

    $env:PSModulePath = $brokenModules
    Reset-AzureSession
    $null = Invoke-AzureStartup
    Assert-True ($Session.Azure.Status -eq 'unavailable' -and $Session.Azure.Provider -ceq 'powershell' -and $Session.Azure.Message.Contains('could not be loaded') -and $Session.Azure.Message.Contains('blocked by device policy')) 'Report an Az.Accounts module that cannot be loaded.'

    $env:PSModulePath = $modules
    Reset-AzureSession
    $output = Invoke-AzureStartup
    $loaded = Get-Module -Name Az.Accounts | Select-Object -First 1
    Assert-True ($loaded -and $loaded.Path.StartsWith($modules) -and [string]$loaded.Version -eq '9.9.9') 'Import Az.Accounts from the module path when Azure CLI is absent.'
    $state = Get-FakeAzState
    Assert-True ($Session.Azure.Status -eq 'ready' -and $Session.Azure.Provider -ceq 'powershell' -and $state.LoginCalls -eq 0) 'Reuse the cached Azure PowerShell context without login.'
    Assert-True ($Session.Azure.Account -eq 'ps-user@example.com' -and $Session.Azure.Tenant -eq '11111111-1111-1111-1111-111111111111') 'Read the account and tenant from the Azure PowerShell context.'
    Assert-True ($Session.Azure.AccessToken -ceq 'private-ps-arm-token' -and $Session.Azure.ExpiresUtc -gt [datetime]::UtcNow.AddMinutes(50)) 'Convert the secure Azure PowerShell token in ConstrainedLanguage.'
    $call = $state.TokenCalls[-1]
    Assert-True ($call.resource -ceq 'https://management.azure.com/' -and $call.tenant -eq $Session.Azure.Tenant -and $call.secure) 'Request the ARM audience for the pinned tenant as a secure string.'
    Assert-True ($output.Contains('Signed in to Azure as ps-user@example.com') -and $output.Contains('via Azure PowerShell')) 'Report the Azure PowerShell provider at startup.'
    Assert-True (-not $output.Contains('login-output-must-be-discarded')) 'Do not print provider output.'

    Update-FlintAzureToken $Session -Service keyvault
    $state = Get-FakeAzState
    Assert-True ($Session.Azure.KeyVault.AccessToken -ceq 'private-ps-keyvault-token' -and $state.TokenCalls[-1].resource -ceq 'https://vault.azure.net') 'Request the Key Vault audience separately through Azure PowerShell.'
    $count = $state.TokenCalls.Count
    Update-FlintAzureToken $Session
    Assert-True ((Get-FakeAzState).TokenCalls.Count -eq $count) 'Cache Azure PowerShell tokens until they approach expiration.'
    $Session.Azure.ExpiresUtc = [datetime]::UtcNow
    Update-FlintAzureToken $Session
    Assert-True ((Get-FakeAzState).TokenCalls.Count -eq $count + 1 -and (Get-FakeAzState).LoginCalls -eq 0) 'Refresh silently through the Azure PowerShell context.'

    Set-FakeAzState @{ TokenFailure = 'AADSTS50076: Due to a configuration change you must use multi-factor authentication. Run Connect-AzAccount.' }
    $Session.Azure.ExpiresUtc = [datetime]::UtcNow
    $message = ''
    try { Update-FlintAzureToken $Session } catch { $message = $_.Exception.Message }
    Assert-True ((Test-FlintAzureAuthenticationError $message) -and (Get-FakeAzState).LoginCalls -eq 0) 'Classify Azure PowerShell interaction failures without signing in during a session.'
    Assert-True ((Test-FlintAzureAuthenticationError 'Restart Flint to sign in to Azure for Key Vault authentication.')) 'Classify provider-neutral restart messages as authentication failures.'

    Set-FakeAzState @{ Context = $null; TokenFailure = ''; TokenTenant = '22222222-2222-2222-2222-222222222222'; SelectorOff = $false }
    Reset-AzureSession 'contoso.onmicrosoft.com'
    $null = Invoke-AzureStartup
    $state = Get-FakeAzState
    Assert-True ($Session.Azure.Status -eq 'ready' -and $state.LoginCalls -eq 1 -and $state.LoginTenant -ceq 'contoso.onmicrosoft.com') 'Run Connect-AzAccount once for the selected tenant.'
    Assert-True ($state.LoginSelectorOff -and $state.LoginEnvironmentClean) 'Disable the subscription selector for this process and hide Flint secrets during sign-in.'
    Assert-True ($Session.Azure.Tenant -eq '22222222-2222-2222-2222-222222222222') 'Accept a tenant domain resolved to its tenant ID.'
    foreach ($name in $secretNames) {
        Assert-True ((Get-Item -LiteralPath ('Env:' + $name)).Value -ceq 'must-not-reach-sign-in') 'Restore Flint environment values after sign-in.'
    }

    Set-FakeAzState @{ Context = $null; TokenTenant = '' }
    Reset-AzureSession
    $Session.Ui.Live = $false
    $null = Invoke-AzureStartup
    Assert-True ($Session.Azure.Status -eq 'authentication_required' -and $Session.Azure.Message.Contains('Connect-AzAccount') -and (Get-FakeAzState).LoginCalls -eq 1) 'Noninteractive startup never launches Azure PowerShell sign-in.'

    Set-FakeAzState @{ LoginFailure = $true }
    Reset-AzureSession
    $null = Invoke-AzureStartup
    Assert-True ($Session.Azure.Status -eq 'unavailable' -and (Get-FakeAzState).LoginCalls -eq 2 -and $Session.Azure.Message.Contains('canceled')) 'Report a cancelled Azure PowerShell sign-in.'

    Set-FakeAzState @{ LoginFailure = $false; Context = (Get-FakeAzState -ContextType 'ServicePrincipal') }
    Reset-AzureSession
    $null = Invoke-AzureStartup
    Assert-True ($Session.Azure.Status -eq 'ready' -and $Session.Azure.Account -eq 'ps-user@example.com' -and (Get-FakeAzState).LoginCalls -eq 3) 'Sign in with a user account instead of a service principal context.'

    $status = (Show-FlintSession $Session -Details 6>&1) | Out-String
    Assert-True ($status.Contains('Azure sign-in: Azure PowerShell')) 'Show the sign-in provider in /status.'
    $trajectory = Get-Content -LiteralPath $Session.TrajectoryPath -Raw
    Assert-True ($trajectory.Contains('"provider":"powershell"') -and -not $trajectory.Contains('private-ps-')) 'Record the provider without recording tokens.'
    Write-Host 'All Azure PowerShell tests passed.'
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath ('Env:' + $name) -Value $savedEnvironment[$name] }
    }
    Remove-TestFixture
}
