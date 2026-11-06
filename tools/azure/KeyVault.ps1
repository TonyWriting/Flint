# Key Vault metadata requests and response projection.
function Get-FlintKeyVaultListUri {
    param($ToolArguments)
    if ($ToolArguments.vault_name -notmatch '^[a-z][a-z0-9-]{1,22}[a-z0-9]$' -or $ToolArguments.vault_name.Contains('--')) { throw 'Use an Azure Key Vault name of 3 to 24 letters, digits or hyphens.' }
    $origin = 'https://' + $ToolArguments.vault_name.ToLowerInvariant() + '.vault.azure.net'
    if ($ToolArguments.next_link -ceq '') { return $origin + '/secrets?api-version=2025-07-01&maxresults=25' }
    $link = $ToolArguments.next_link
    $uri = $link -as [uri]
    if ($link.Length -gt 8192 -or $link -match '[\\#\x00-\x20\x7f]' -or
        -not $link.StartsWith($origin + '/secrets?', [StringComparison]::OrdinalIgnoreCase) -or
        -not $uri -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Fragment -or $uri.AbsolutePath -cne '/secrets') {
        throw 'Continuation must be a secret-list URL for the same vault. Individual secret endpoints are not allowed.'
    }
    $seen = @{}
    foreach ($pair in ($uri.Query.TrimStart('?') -split '&')) {
        $parts = $pair -split '=', 2
        $name = $parts[0]
        if ($name -ceq '$skiptoken') { $name = 'skiptoken' }
        if ($parts.Count -ne 2 -or $name -cnotin @('api-version', 'maxresults', 'skiptoken') -or $seen.ContainsKey($name) -or -not $parts[1]) { throw 'Unsupported secret-list continuation parameters.' }
        if ($name -ceq 'api-version' -and $parts[1] -cne '2025-07-01') { throw 'Unsupported Key Vault API version.' }
        if ($name -ceq 'maxresults' -and $parts[1] -notmatch '^(?:[1-9]|1[0-9]|2[0-5])$') { throw 'A secret-list page contains at most 25 items.' }
        $seen[$name] = $true
    }
    if (-not $seen.ContainsKey('api-version') -or -not $seen.ContainsKey('skiptoken')) { throw 'Continuation requires api-version and a skiptoken.' }
    return $link
}

function ConvertTo-FlintSecretMetadata {
    param([string]$Content, [string]$VaultName)
    try { $document = ConvertFrom-Json -InputObject $Content -ErrorAction Stop }
    catch { throw 'Key Vault returned invalid secret-list JSON.' }
    if ($document -isnot [pscustomobject] -or $document.value -isnot [array] -or $document.value.Count -gt 25) { throw 'Key Vault did not return a valid secret-list page.' }
    $prefix = 'https://' + $VaultName.ToLowerInvariant() + '.vault.azure.net/secrets/'
    $items = @(foreach ($item in $document.value) {
        if ($item.id -isnot [string] -or -not $item.id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Key Vault returned an invalid secret identifier.' }
        $name = $item.id.Substring($prefix.Length)
        if ($name -notmatch '^[a-z0-9-]{1,127}$') { throw 'Key Vault returned an invalid secret name.' }
        # Project only metadata fields. Never serialize the raw response or an item value.
        $metadata = [ordered]@{ name = $name; id = $prefix + $name }
        if ($item.managed -is [bool]) { $metadata.managed = $item.managed }
        if ($item.attributes.enabled -is [bool]) { $metadata.enabled = $item.attributes.enabled }
        foreach ($field in @('created', 'updated', 'exp', 'nbf')) {
            if ($item.attributes.$field -is [int] -or $item.attributes.$field -is [long]) { $metadata[$field] = $item.attributes.$field }
        }
        $metadata
    })
    $next = ''
    if ($null -ne $document.nextLink) {
        if ($document.nextLink -isnot [string]) { throw 'Key Vault returned an invalid continuation.' }
        $next = $document.nextLink
    }
    if ($next) { $null = Get-FlintKeyVaultListUri @{ vault_name = $VaultName; next_link = $next } }
    return [ordered]@{ vault_name = $VaultName.ToLowerInvariant(); value = $items; nextLink = $next }
}

function Invoke-FlintKeyVaultListSecretsHttp {
    param([string]$Root, [string]$SessionId, $ToolArguments, $Invocation, [string]$AccessToken, [double]$TimeoutSec)
    $uri = Get-FlintKeyVaultListUri $ToolArguments
    if (-not $Invocation -or $Invocation.executor -cne 'keyvault' -or $Invocation.method -cne 'GET' -or $Invocation.uri -cne $uri -or $Invocation.body -cne '') { throw 'Missing or inconsistent approved Key Vault metadata request.' }
    $session = @{ Root = $Root; Id = $SessionId; Azure = @{ AccessToken = $AccessToken } }
    $response = Invoke-FlintAzureHttpResponse $session GET $uri '' $AccessToken $TimeoutSec
    if ($response.http_status -ne 200) {
        $message = 'Key Vault metadata listing failed.'
        if ($response.http_status -eq 403) { $message += ' Check secrets/list permission (or Key Vault Reader for RBAC) and vault network access.' }
        # Error bodies are not metadata and may contain sensitive or unexpected fields.
        return @{ status = 'error'; http_status = $response.http_status; exit_code = $null; output = $message; retryable = [bool]$response.retryable }
    }
    $metadata = ConvertTo-FlintSecretMetadata $response.content $ToolArguments.vault_name
    $result = Save-FlintAzureResult $session (ConvertTo-Json -InputObject $metadata -Depth 8)
    $result.status = 'ok'; $result.http_status = 200; $result.exit_code = $null; $result.retryable = $false
    $result.names = @($metadata.value | ForEach-Object { $_.name })
    $result.page_count = $metadata.value.Count
    $result.has_more = [bool]$metadata.nextLink
    $result.total_count = $null
    if (-not $ToolArguments.next_link -and -not $metadata.nextLink) { $result.total_count = $metadata.value.Count }
    return $result
}
