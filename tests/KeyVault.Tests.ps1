#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:TokenServices = @()
function Invoke-FlintAzureCli {
    param($Session, $Operation, $Service = 'arm')
    if ($Operation -eq 'account') { return @{ user = @{ type = 'user'; name = 'user@example.com' }; environmentName = 'AzureCloud'; tenantId = $Session.Azure.Tenant } }
    if ($Operation -ne 'token') { throw 'Metadata tools must not launch interactive login.' }
    $script:TokenServices += $Service
    return @{ accessToken = ('private-' + $Service + '-token'); tenant = $Session.Azure.Tenant; expires_on = [long](([datetime]::UtcNow.AddHours(1) - ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime()).TotalSeconds) }
}
try {
    $app = New-TestRuntime (Join-Path $TestRoot 'app')
    Add-Content -LiteralPath (Join-Path $app 'tools\azure\Http.ps1') -Encoding UTF8 -Value @'
function Invoke-WebRequest {
    [CmdletBinding()]param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, [switch]$UseBasicParsing, $Body)
    if ($Method -cne 'GET' -or $Body -or -not $UseBasicParsing -or $MaximumRedirection -ne 0) { throw 'Unexpected metadata transport settings.' }
    if (Test-Path Env:FLINT_AZURE_ACCESS_TOKEN) { throw 'Token remains in the worker environment.' }
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'http-calls.txt') -Value $Uri
    if ($Uri.StartsWith('https://management.azure.com/')) {
        if ($Headers.Authorization -cne 'Bearer private-arm-token') { throw 'ARM received the wrong token audience.' }
        return @{ StatusCode = 200; Content = '{"value":[]}' }
    }
    if ($Headers.Authorization -cne 'Bearer private-keyvault-token') { throw 'Key Vault received the wrong token audience.' }
    $parsed = $Uri -as [uri]
    if ($parsed.AbsolutePath -cne '/secrets') { throw 'A secret value endpoint was requested.' }
    $vault = ($parsed.Host -split '\.')[0]
    if ($vault -in @('forbidden-vault', 'expired-vault', 'transient-vault')) {
        $status = 403
        if ($vault -eq 'expired-vault') { $status = 401 }
        if ($vault -eq 'transient-vault') {
            $marker = Join-Path $PSScriptRoot 'transient-once.txt'
            if (Test-Path -LiteralPath $marker) { $status = 200 }
            else { Set-Content -LiteralPath $marker -Value 'once'; $status = 429 }
        }
        if ($status -ne 200) {
            try { throw 'Key Vault fixture HTTP error.' } catch { $errorObject = $_.Exception }
            $errorObject | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $status } -Force
            Write-Error -Exception $errorObject -Message '{"error":{"message":"never-save-error-value"},"value":"never-save-error-value"}' -ErrorAction Stop
        }
    }
    if ($vault -eq 'malformed-vault') { return @{ StatusCode = 200; Content = '{"id":"unused","value":"never-save-secret-value"}' } }
    if ($vault -eq 'empty-vault') { return @{ StatusCode = 200; Content = '{"value":[]}' } }
    $origin = 'https://' + $vault + '.vault.azure.net'
    $items = @(@{ id = $origin + '/secrets/alpha'; value = 'never-save-secret-value'; tags = @{ note = 'never-save-tag-value' }; attributes = @{ enabled = $true; created = 1700000000; exp = 'never-save-attribute-value' } })
    $next = $null
    if ($vault -eq 'metadata-vault' -and -not $parsed.Query.Contains('skiptoken')) {
        $items += @{ id = $origin + '/secrets/beta'; attributes = @{ enabled = $false } }
        $next = $origin + '/secrets?api-version=2025-07-01&maxresults=25&$skiptoken=page2'
    } elseif ($vault -eq 'metadata-vault') { $items = @(@{ id = $origin + '/secrets/gamma' }) }
    if ($vault -eq 'unsafe-vault') { $next = $origin + '/secrets/alpha?api-version=2025-07-01&skiptoken=private' }
    return @{ StatusCode = 200; Content = (ConvertTo-Json -InputObject @{ value = $items; nextLink = $next } -Depth 8 -Compress) }
}
'@
    $Session.WorkerPath = Join-Path $app 'tools\Worker.ps1'
    $Session.Azure = @{ Status = 'ready'; Account = 'user@example.com'; Tenant = '11111111-1111-1111-1111-111111111111'; AccessToken = 'private-arm-token'; ExpiresUtc = [datetime]::UtcNow.AddHours(1) }
    $first = Invoke-TestTool keyvault_list_secrets @{ vault_name = 'Metadata-Vault'; next_link = '' }
    Assert-True ($first.status -eq 'ok' -and $first.duration_ms -gt 0 -and $first.page_count -eq 2 -and ($first.names -join ',') -ceq 'alpha,beta') 'Return names and page counts through the real worker and parent pipeline.'
    Assert-True ($first.has_more -and $null -eq $first.total_count -and $first.next_link.Contains('$skiptoken=page2')) 'Do not present the first page count as the vault total.'
    Assert-True (($TokenServices -join ',') -ceq 'keyvault' -and $Session.Azure.AccessToken -ceq 'private-arm-token') 'Acquire a separate Key Vault token while retaining the ARM token.'
    $second = Invoke-TestTool keyvault_list_secrets @{ vault_name = 'metadata-vault'; next_link = $first.next_link }
    Assert-True ($second.status -eq 'ok' -and -not $second.has_more -and $second.names[0] -ceq 'gamma' -and ($first.page_count + $second.page_count) -eq 3) 'Follow the list continuation to obtain all three secret names.'
    Assert-True ($null -eq $second.total_count -and $TokenServices.Count -eq 1) 'A final continuation page is not the whole listing, and reuses the service token.'
    $saved = Invoke-TestTool read_file @{ path = $first.result_path }
    $metadata = ConvertFrom-Json -InputObject $saved.output
    Assert-True ($saved.status -eq 'ok' -and $metadata.value[0].enabled -eq $true -and $metadata.value[1].enabled -eq $false) 'Read allowed metadata from the saved result.'
    Assert-True (@($metadata.value[0].PSObject.Properties.Name | Where-Object { $_ -in @('value', 'tags', 'exp') }).Count -eq 0) 'Discard content fields, free-form tags and invalid metadata types before persistence.'

    $empty = Invoke-TestTool keyvault_list_secrets @{ vault_name = 'empty-vault'; next_link = '' }
    Assert-True ($empty.status -eq 'ok' -and $empty.total_count -eq 0 -and $empty.names.Count -eq 0) 'Report a complete empty vault correctly.'
    $single = Invoke-TestTool keyvault_list_secrets @{ vault_name = 'single-vault'; next_link = '' }
    Assert-True ($single.total_count -eq 1 -and -not $single.has_more) 'Report a total only for a complete first page.'
    $Session.Azure.KeyVault.ExpiresUtc = [datetime]::UtcNow
    $null = Invoke-TestTool keyvault_list_secrets @{ vault_name = 'empty-vault'; next_link = '' }
    Assert-True ($TokenServices.Count -eq 2 -and $Session.Azure.AccessToken -ceq 'private-arm-token') 'Refresh the Key Vault audience independently.'

    $trace = Join-Path $app 'tools\azure\http-calls.txt'
    $count = @(Get-Content -LiteralPath $trace).Count
    foreach ($arguments in @(
        @{ vault_name = 'metadata-vault'; next_link = ''; method = 'GET' },
        @{ vault_name = 'metadata-vault'; next_link = ''; secret_name = 'alpha' },
        @{ vault_name = 'metadata-vault/secrets/alpha'; next_link = '' },
        @{ vault_name = 'metadata-vault'; next_link = 'https://metadata-vault.vault.azure.net/secrets/alpha?api-version=2025-07-01' },
        @{ vault_name = 'metadata-vault'; next_link = 'https://other-vault.vault.azure.net/secrets?api-version=2025-07-01&skiptoken=page2' },
        @{ vault_name = 'metadata-vault'; next_link = 'https://metadata-vault.vault.azure.net/secrets?api-version=2025-07-01&skiptoken=page2&operation=get' },
        @{ vault_name = 'metadata-vault'; next_link = 'https://metadata-vault.vault.azure.net/secrets?api-version=2025-07-01&skiptoken=a&$skiptoken=b' },
        @{ vault_name = 'metadata-vault'; next_link = 'https://metadata-vault.vault.azure.net/secrets?api-version=2025-07-01&skiptoken=a#fragment' }
    )) { Assert-True ((Invoke-TestTool keyvault_list_secrets $arguments).status -eq 'error') 'Reject attempts to turn metadata listing into arbitrary data-plane access.' }
    Assert-True (@(Get-Content -LiteralPath $trace).Count -eq $count) 'Rejected arguments never reach HTTP or token acquisition.'
    foreach ($vault in @('malformed-vault', 'unsafe-vault')) {
        $result = Invoke-TestTool keyvault_list_secrets @{ vault_name = $vault; next_link = '' }
        Assert-True ($result.status -eq 'error' -and -not $result.result_id) 'Reject unexpected response shapes and unsafe server continuations without saving raw data.'
    }
    $forbidden = Invoke-TestTool keyvault_list_secrets @{ vault_name = 'forbidden-vault'; next_link = '' }
    Assert-True ($forbidden.http_status -eq 403 -and -not $forbidden.result_id -and $Session.Azure.Status -eq 'ready') 'Report permissions separately without saving error body content.'
    $count = @(Get-Content -LiteralPath $trace).Count
    $retry = Invoke-TestTool keyvault_list_secrets @{ vault_name = 'transient-vault'; next_link = '' }
    Assert-True ($retry.status -eq 'ok' -and @(Get-Content -LiteralPath $trace).Count -eq $count + 2) 'Retry a transient metadata-list failure through the existing read-only retry pipeline.'
    $expired = Invoke-TestTool keyvault_list_secrets @{ vault_name = 'expired-vault'; next_link = '' }
    $count = @(Get-Content -LiteralPath $trace).Count
    $again = Invoke-TestTool keyvault_list_secrets @{ vault_name = 'empty-vault'; next_link = '' }
    Assert-True ($expired.status -eq 'authentication_required' -and $again.status -eq 'authentication_required' -and @(Get-Content -LiteralPath $trace).Count -eq $count) 'Never initiate an interactive sign-in from the metadata tool.'
    Assert-True ((Invoke-TestTool azure_request @{ method = 'GET'; path = '/subscriptions?api-version=2022-12-01'; body = '' }).status -eq 'ok') 'Keep ARM access available when only Key Vault authentication requires renewal.'

    $files = @(Get-ChildItem -LiteralPath (Get-FlintResultDirectory $Session.Root $Session.Id) -File) + @(Get-Item -LiteralPath $Session.TrajectoryPath)
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        foreach ($marker in @('never-save-secret-value', 'never-save-tag-value', 'never-save-attribute-value', 'never-save-error-value', 'private-keyvault-token', 'private-arm-token')) {
            Assert-True (-not $text.Contains($marker)) 'Keep secret contents and access tokens out of saved files and telemetry.'
        }
    }
    Write-Host 'All Key Vault metadata tests passed.'
} finally { Remove-TestFixture }
