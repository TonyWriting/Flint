# Main-process Azure CLI authentication and token caches.
function Test-FlintAzureAuthenticationError {
    param([string]$Message)
    return $Message -match '(?i)az login|interaction_required|login_required|invalid_grant|MsalUiRequired|AuthenticationFailed|user interaction is required|claims.challenge|AADSTS(?:50058|50076|50079|50173|65001|70043|700082)|refresh token.*expired'
}

function Assert-FlintAzureTenant {
    param([string]$Tenant)
    if ($Tenant.Length -gt 253 -or $Tenant -notmatch '^(?:[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}|[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+)$') {
        throw 'Use an Azure tenant ID or a tenant domain such as contoso.onmicrosoft.com.'
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
        foreach ($name in @('AZURE_OPENAI_API_KEY', 'FLINT_MODEL_API_KEY', 'FLINT_AZURE_ACCESS_TOKEN')) {
            $previousEnvironment[$name] = (Get-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue).Value
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        }
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
        foreach ($name in $previousEnvironment.Keys) {
            if ($null -eq $previousEnvironment[$name]) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath ('Env:' + $name) -Value $previousEnvironment[$name] }
        }
    }
}

function Set-FlintAzureCliIdentity {
    param([hashtable]$Session)
    $account = Invoke-FlintAzureCli $Session account
    if (-not $account -or $account.user.type -ne 'user' -or -not $account.user.name) { throw 'Run az login with your user account before using Azure tools.' }
    if ($account.environmentName -ne 'AzureCloud') { throw 'Flint requires an Azure public-cloud account.' }
    if ($Session.Azure.Account -and $account.user.name -ine $Session.Azure.Account) { throw 'Azure CLI account changed. Restart Flint to select an account.' }
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
        if ($state.Status -eq 'authentication_required') { throw 'Restart Flint to run az login for Key Vault authentication.' }
    }
    if ($state.AccessToken -and $state.ExpiresUtc -gt ([datetime]::UtcNow).AddMinutes(5)) { return }
    Set-FlintAzureCliIdentity $Session
    $token = Invoke-FlintAzureCli $Session token -Service $Service
    try {
        if (-not $token.accessToken -or -not $token.expires_on -or -not $token.tenant) {
            throw 'Azure CLI returned an incomplete token or a different identity. A current Azure CLI with expires_on support is required.'
        }
        Assert-FlintAzureTenant $token.tenant
        if ($token.tenant -ine $Session.Azure.Tenant -and
            ($Session.Azure.Tenant -notmatch '\.' -or $token.tenant -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')) {
            throw 'Azure CLI returned a token for a different tenant.'
        }
        $expiresUtc = ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime().AddSeconds([long]$token.expires_on)
        if ($expiresUtc -le ([datetime]::UtcNow).AddSeconds(30)) { throw 'Azure CLI token is expired. Restart Flint to run az login.' }
        $state.AccessToken = [string]$token.accessToken
        # The CLI may resolve a requested tenant domain to its canonical ID.
        $Session.Azure.Tenant = [string]$token.tenant
        $state.ExpiresUtc = $expiresUtc
        if ($Service -eq 'keyvault') { $state.Status = 'ready' }
    } finally { $token = $null }
}

function Initialize-FlintAzure {
    param([hashtable]$Session)
    if ($Session.Azure.Initialized) { return }
    $Session.Azure = @{ Initialized = $true; Status = 'unavailable'; AccessToken = $null; Account = ''; Tenant = $Session.AzureTenant; CliPath = ''; ExpiresUtc = $null; Message = ''; LoginAttempted = $false }
    if ($Session.NoAzure) { $Session.Azure.Status = 'disabled'; $Session.Azure.Message = 'Azure tools are disabled by -NoAzure.'; return }
    try {
        if ($Session.Azure.Tenant) { Assert-FlintAzureTenant $Session.Azure.Tenant }
        $command = Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1
        if (-not $command -or $command.Source -notmatch '(?i)\.(cmd|exe)$') { throw 'An approved Azure CLI az.cmd or az.exe installation is required on PATH.' }
        $Session.Azure.CliPath = $command.Source
        $ready = $false
        try {
            Update-FlintAzureToken $Session
            $ready = $true
        } catch { if (-not (Test-FlintAzureAuthenticationError $_.Exception.Message)) { throw } }
        if (-not $ready) {
            Initialize-FlintUi $Session
            if (-not $Session.Ui.Live) {
                $Session.Azure.Status = 'authentication_required'
                $Session.Azure.Message = 'No usable Azure CLI login. Start Flint in an interactive terminal to run az login.'
                return
            }
            Clear-FlintProgress $Session
            Write-Host 'Azure CLI sign-in is required. Running az login once for this Flint process.' -ForegroundColor Yellow
            $Session.Azure.LoginAttempted = $true
            Invoke-FlintAzureCli $Session login
            $Session.Azure.AccessToken = $null
            $Session.Azure.Account = ''
            Update-FlintAzureToken $Session
        }
        $Session.Azure.Status = 'ready'
    } catch {
        $Session.Azure.AccessToken = $null
        $Session.Azure.Message = 'Azure initialization failed: ' + (Protect-FlintText $Session $_.Exception.Message) + ' Restart Flint after resolving this issue.'
    } finally {
        Write-FlintEvent $Session 'azure_initialized' @{ status = $Session.Azure.Status; account = $Session.Azure.Account; tenant = $Session.Azure.Tenant; login_attempted = $Session.Azure.LoginAttempted }
        if ($Session.Azure.Status -eq 'ready') {
            Write-Host (Protect-FlintText $Session ('Azure CLI: {0} (tenant {1})' -f $Session.Azure.Account, $Session.Azure.Tenant)) -ForegroundColor DarkGray
        } else { Write-Host $Session.Azure.Message -ForegroundColor Yellow }
    }
}
