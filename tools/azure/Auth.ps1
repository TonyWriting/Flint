# Main-process Azure authentication and token caches.
# Azure CLI is preferred. Without an installed CLI launcher, the Az.Accounts module
# of Azure PowerShell authenticates inside this process instead.
function Test-FlintAzureAuthenticationError {
    param([string]$Message)
    return $Message -match '(?i)az login|Connect-AzAccount|Restart Flint to sign in|interaction_required|login_required|invalid_grant|MsalUiRequired|AuthenticationFailed|user interaction is required|claims.challenge|AADSTS(?:50058|50076|50079|50173|65001|70043|700082)|refresh token.*expired'
}

function Assert-FlintAzureTenant {
    param([string]$Tenant)
    if ($Tenant.Length -gt 253 -or $Tenant -notmatch '^(?:[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}|[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+)$') {
        throw 'Use an Azure tenant ID or a tenant domain such as contoso.onmicrosoft.com.'
    }
}

function Get-FlintAzureProviderName {
    param([hashtable]$Session)
    if ($Session.Azure.Provider -ceq 'powershell') { return 'Azure PowerShell' }
    return 'Azure CLI'
}

function Get-FlintAzureLoginCommand {
    param([hashtable]$Session)
    if ($Session.Azure.Provider -ceq 'powershell') { return 'Connect-AzAccount' }
    return 'az login'
}

function Hide-FlintAzureSecretEnvironment {
    param([hashtable]$Saved)
    # Sign-in processes, including browsers they open, must not inherit Flint secrets.
    foreach ($name in @('AZURE_OPENAI_API_KEY', 'FLINT_MODEL_API_KEY', 'FLINT_AZURE_ACCESS_TOKEN')) {
        $Saved[$name] = (Get-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue).Value
        Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
    }
}

function Restore-FlintAzureEnvironment {
    param([hashtable]$Saved)
    foreach ($name in $Saved.Keys) {
        if ($null -eq $Saved[$name]) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath ('Env:' + $name) -Value $Saved[$name] }
    }
}

function Select-FlintAzureProvider {
    param([hashtable]$Session)
    $command = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        if ($command.Source -notmatch '(?i)\.(cmd|exe)$') { throw 'An approved Azure CLI az.cmd or az.exe installation is required on PATH.' }
        $Session.Azure.Provider = 'cli'
        $Session.Azure.CliPath = $command.Source
        return
    }
    # Import directly: module discovery with -ListAvailable is unreliable in ConstrainedLanguage.
    # A loaded module is reused because importing it again from ConstrainedLanguage can fail.
    try { if (-not (Get-Module -Name Az.Accounts)) { Import-Module -Name Az.Accounts -Global -ErrorAction Stop -WarningAction SilentlyContinue } }
    catch {
        if ([string]$_.FullyQualifiedErrorId -like 'Modules_ModuleNotFound,*') {
            throw 'Azure tools require Azure CLI (az.cmd or az.exe on PATH) or Azure PowerShell (the Az.Accounts module). Neither was found.'
        }
        $Session.Azure.Provider = 'powershell'
        throw ('Azure PowerShell module Az.Accounts could not be loaded: ' + $_.Exception.Message)
    }
    $Session.Azure.Provider = 'powershell'
    $version = [string](Get-Module -Name Az.Accounts | Sort-Object -Property Version -Descending | Select-Object -First 1).Version
    $tokenCommand = Get-Command -Name Get-AzAccessToken -ErrorAction SilentlyContinue
    if (-not $tokenCommand -or $tokenCommand.Parameters.Keys -notcontains 'TenantId' -or $tokenCommand.Parameters.Keys -notcontains 'ResourceUrl') {
        throw ('Az.Accounts {0} does not support Get-AzAccessToken -TenantId -ResourceUrl. Update Azure PowerShell.' -f $version)
    }
}

function Invoke-FlintAzureCli {
    param([hashtable]$Session, [ValidateSet('account', 'login', 'token')][string]$Operation, [ValidateSet('arm', 'keyvault')][string]$Service = 'arm')
    $arguments = @()
    switch ($Operation) {
        'account' { $arguments = @('account', 'show') }
        'token' {
            Assert-FlintAzureTenant $Session.Azure.Tenant
            $resource = 'https://management.azure.com/'
            if ($Service -eq 'keyvault') { $resource = 'https://vault.azure.net' }
            $arguments = @('account', 'get-access-token', '--tenant', $Session.Azure.Tenant, '--resource', $resource)
        }
        'login' {
            $arguments = @('login', '--allow-no-subscriptions')
            if ($Session.Azure.Tenant) {
                Assert-FlintAzureTenant $Session.Azure.Tenant
                $arguments += @('--tenant', $Session.Azure.Tenant)
            }
        }
    }
    $format = 'json'
    if ($Operation -eq 'login') { $format = 'none' }
    $arguments += @('--output', $format, '--only-show-errors')
    $previousPreference = $ErrorActionPreference
    $previousEnvironment = @{}
    try {
        Hide-FlintAzureSecretEnvironment $previousEnvironment
        if ($Operation -eq 'login') {
            $previousEnvironment.AZURE_CORE_LOGIN_EXPERIENCE_V2 = (Get-Item -LiteralPath Env:AZURE_CORE_LOGIN_EXPERIENCE_V2 -ErrorAction SilentlyContinue).Value
            $env:AZURE_CORE_LOGIN_EXPERIENCE_V2 = 'off'
        }
        # Only fixed flags and validated tenant identifiers reach the installed az launcher.
        # Access-token output stays in memory; no capture files or command-line tokens are used.
        $ErrorActionPreference = 'Continue'
        if ($Operation -eq 'login') {
            & $Session.Azure.CliPath @arguments
            $nativeExitCode = $LASTEXITCODE
            if ($nativeExitCode -ne 0) { throw ('az login failed (exit {0}).' -f $nativeExitCode) }
            return
        }
        $output = @(& $Session.Azure.CliPath @arguments 2>&1)
        $nativeExitCode = $LASTEXITCODE
        $json = ($output | ForEach-Object { [string]$_ }) -join "`n"
        if ($nativeExitCode -ne 0) { throw ('Azure CLI {0} failed (exit {1}): {2}' -f $Operation, $nativeExitCode, (Protect-FlintText $Session $json)) }
        try { return (ConvertFrom-Json -InputObject ('{"result":' + $json + '}') -ErrorAction Stop).result }
        catch { throw ('Azure CLI {0} did not return valid JSON.' -f $Operation) }
    } finally {
        $ErrorActionPreference = $previousPreference
        Restore-FlintAzureEnvironment $previousEnvironment
    }
}

function Invoke-FlintAzurePowerShell {
    param([hashtable]$Session, [ValidateSet('account', 'login', 'token')][string]$Operation, [ValidateSet('arm', 'keyvault')][string]$Service = 'arm')
    # Results use the same shape as Azure CLI JSON so identity and token checks are shared.
    switch ($Operation) {
        'account' {
            $context = Get-AzContext -ErrorAction Stop -WarningAction SilentlyContinue
            if (-not $context -or -not $context.Account) { return $null }
            $type = [string]$context.Account.Type
            if ($type -ceq 'User') { $type = 'user' }
            return @{ user = @{ name = [string]$context.Account.Id; type = $type }; tenantId = [string]$context.Tenant.Id; environmentName = [string]$context.Environment.Name }
        }
        'token' {
            Assert-FlintAzureTenant $Session.Azure.Tenant
            $resource = 'https://management.azure.com/'
            if ($Service -eq 'keyvault') { $resource = 'https://vault.azure.net' }
            $parameters = @{ ResourceUrl = $resource; TenantId = $Session.Azure.Tenant; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
            if ((Get-Command -Name Get-AzAccessToken -ErrorAction Stop).Parameters.Keys -contains 'AsSecureString') { $parameters.AsSecureString = $true }
            $token = $null; $secret = $null
            try {
                $token = Get-AzAccessToken @parameters
                $secret = $token.Token
                if ($secret -is [securestring]) {
                    # PSCredential is a core type, so this conversion also works in ConstrainedLanguage.
                    $secret = (New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'flint', $secret).GetNetworkCredential().Password
                }
                $expiresOn = $null
                if ($token.ExpiresOn -and $token.ExpiresOn.UtcDateTime) {
                    $expiresOn = [long](($token.ExpiresOn.UtcDateTime - ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime()).TotalSeconds)
                }
                return @{ accessToken = [string]$secret; expires_on = $expiresOn; tenant = [string]$token.TenantId }
            } finally { $token = $null; $secret = $null }
        }
        'login' {
            $parameters = @{ ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
            if ($Session.Azure.Tenant) {
                Assert-FlintAzureTenant $Session.Azure.Tenant
                $parameters.Tenant = $Session.Azure.Tenant
            }
            $configCommand = Get-Command -Name Update-AzConfig -ErrorAction SilentlyContinue
            $previousEnvironment = @{}
            try {
                Hide-FlintAzureSecretEnvironment $previousEnvironment
                # Process scope turns off the subscription selector for this Flint process only.
                if ($configCommand -and $configCommand.Parameters.Keys -contains 'LoginExperienceV2') {
                    Update-AzConfig -LoginExperienceV2 Off -Scope Process -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
                }
                Connect-AzAccount @parameters | Out-Null
            } finally { Restore-FlintAzureEnvironment $previousEnvironment }
        }
    }
}

function Invoke-FlintAzureAuth {
    param([hashtable]$Session, [ValidateSet('account', 'login', 'token')][string]$Operation, [ValidateSet('arm', 'keyvault')][string]$Service = 'arm')
    if ($Session.Azure.Provider -ceq 'powershell') { return Invoke-FlintAzurePowerShell $Session $Operation -Service $Service }
    return Invoke-FlintAzureCli $Session $Operation -Service $Service
}

function Set-FlintAzureIdentity {
    param([hashtable]$Session)
    $provider = Get-FlintAzureProviderName $Session
    $account = Invoke-FlintAzureAuth $Session account
    if (-not $account -or $account.user.type -ne 'user' -or -not $account.user.name) {
        throw ('Run {0} with your user account before using Azure tools.' -f (Get-FlintAzureLoginCommand $Session))
    }
    if ($account.environmentName -ne 'AzureCloud') { throw 'Flint requires an Azure public-cloud account.' }
    if ($Session.Azure.Account -and $account.user.name -ine $Session.Azure.Account) { throw ('{0} account changed. Restart Flint to select an account.' -f $provider) }
    $Session.Azure.Account = [string]$account.user.name
    if (-not $Session.Azure.Tenant) { $Session.Azure.Tenant = [string]$account.tenantId }
    Assert-FlintAzureTenant $Session.Azure.Tenant
}

function Update-FlintAzureToken {
    param([hashtable]$Session, [ValidateSet('arm', 'keyvault')][string]$Service = 'arm')
    $state = $Session.Azure
    if ($Service -eq 'keyvault') {
        if (-not $Session.Azure.KeyVault) { $Session.Azure.KeyVault = @{ Status = 'unavailable'; AccessToken = $null; ExpiresUtc = $null } }
        $state = $Session.Azure.KeyVault
        if ($state.Status -eq 'authentication_required') { throw 'Restart Flint to sign in to Azure for Key Vault authentication.' }
    }
    if ($state.AccessToken -and $state.ExpiresUtc -gt ([datetime]::UtcNow).AddMinutes(5)) { return }
    $provider = Get-FlintAzureProviderName $Session
    Set-FlintAzureIdentity $Session
    $token = Invoke-FlintAzureAuth $Session token -Service $Service
    try {
        if (-not $token.accessToken -or -not $token.expires_on -or -not $token.tenant) {
            if ($Session.Azure.Provider -ceq 'powershell') { throw 'Azure PowerShell returned an incomplete token. Update the Az.Accounts module.' }
            throw 'Azure CLI returned an incomplete token or a different identity. A current Azure CLI with expires_on support is required.'
        }
        Assert-FlintAzureTenant $token.tenant
        if ($token.tenant -ine $Session.Azure.Tenant -and
            ($Session.Azure.Tenant -notmatch '\.' -or $token.tenant -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')) {
            throw ('{0} returned a token for a different tenant.' -f $provider)
        }
        $expiresUtc = ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime().AddSeconds([long]$token.expires_on)
        if ($expiresUtc -le ([datetime]::UtcNow).AddSeconds(30)) { throw ('{0} returned an expired token. Restart Flint to sign in to Azure.' -f $provider) }
        $state.AccessToken = [string]$token.accessToken
        # The provider may resolve a requested tenant domain to its canonical ID.
        $Session.Azure.Tenant = [string]$token.tenant
        $state.ExpiresUtc = $expiresUtc
        if ($Service -eq 'keyvault') { $state.Status = 'ready' }
    } finally { $token = $null }
}

function Initialize-FlintAzure {
    param([hashtable]$Session)
    if ($Session.Azure.Initialized) { return }
    $Session.Azure = @{ Initialized = $true; Status = 'unavailable'; AccessToken = $null; Account = ''; Tenant = $Session.AzureTenant; Provider = ''; CliPath = ''; ExpiresUtc = $null; Message = ''; LoginAttempted = $false }
    if ($Session.NoAzure) { $Session.Azure.Status = 'disabled'; $Session.Azure.Message = 'Azure tools are disabled by -NoAzure.'; return }
    $failure = $null
    try {
        if ($Session.Azure.Tenant) { Assert-FlintAzureTenant $Session.Azure.Tenant }
        Select-FlintAzureProvider $Session
        $provider = Get-FlintAzureProviderName $Session
        $login = Get-FlintAzureLoginCommand $Session
        $ready = $false
        try {
            Update-FlintAzureToken $Session
            $ready = $true
        } catch {
            $failure = Get-FlintFailureDetails $Session $_
            if (-not (Test-FlintAzureAuthenticationError $_.Exception.Message)) { throw }
        }
        if (-not $ready) {
            Initialize-FlintUi $Session
            if (-not $Session.Ui.Live) {
                $Session.Azure.Status = 'authentication_required'
                $Session.Azure.Message = ('No usable {0} sign-in. Start Flint in an interactive terminal to run {1}.' -f $provider, $login)
                return
            }
            Clear-FlintProgress $Session
            Write-Host ('Azure sign-in is required. Running {0} once for this Flint process.' -f $login) -ForegroundColor Yellow
            $Session.Azure.LoginAttempted = $true
            Invoke-FlintAzureAuth $Session login
            $Session.Azure.AccessToken = $null
            $Session.Azure.Account = ''
            Update-FlintAzureToken $Session
        }
        $Session.Azure.Status = 'ready'
    } catch {
        $failure = Get-FlintFailureDetails $Session $_
        $Session.Azure.AccessToken = $null
        $Session.Azure.Message = 'Azure initialization failed: ' + (Protect-FlintText $Session $_.Exception.Message) + ' Restart Flint after resolving this issue.'
    } finally {
        Write-FlintEvent $Session 'azure_initialized' @{
            status = $Session.Azure.Status; provider = $Session.Azure.Provider; account = $Session.Azure.Account
            tenant = $Session.Azure.Tenant; login_attempted = $Session.Azure.LoginAttempted
            message = $Session.Azure.Message; failure = $failure
        }
        if ($Session.Azure.Status -eq 'ready') {
            Write-Host (Protect-FlintText $Session ('Signed in to Azure as {0} (tenant {1}, via {2})' -f $Session.Azure.Account, $Session.Azure.Tenant, (Get-FlintAzureProviderName $Session))) -ForegroundColor DarkGray
        } else { Write-Host $Session.Azure.Message -ForegroundColor Yellow }
    }
}
