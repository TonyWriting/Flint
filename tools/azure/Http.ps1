# Shared request validation and worker-side HTTP execution.
function Assert-FlintAzureRequest {
    param($ToolArguments)
    if ($ToolArguments.method -cnotin @('GET', 'POST', 'PUT', 'PATCH', 'DELETE')) { throw 'Unsupported Azure HTTP method.' }
    $path = $ToolArguments.path
    if ($path.Length -gt 8192 -or $path -cnotmatch '^/(subscriptions|tenants|providers)(/|\?)' -or
        $path -match '[\\#\x00-\x20\x7f]' -or $path -match '(?i)%0[0-9a-f]|%1[0-9a-f]|%7f|%5c' -or
        $path -match '(?i)(^|/)(\.|%2e){1,2}(/|\?|$)' -or $path.Contains('//')) {
        throw 'Use an ARM resource path under /subscriptions, /tenants or /providers, with no host, fragment or relative segments.'
    }
    $uri = ('https://management.azure.com' + $path) -as [uri]
    if (-not $uri -or $uri.Host -cne 'management.azure.com' -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Fragment) { throw 'Invalid ARM request path.' }
    foreach ($pair in ($uri.Query.TrimStart('?') -split '&')) {
        $name = ($pair -split '=', 2)[0]
        if ($name -cnotmatch '^[$A-Za-z][A-Za-z0-9$_.-]*$') { throw 'Use literal ARM query parameter names; encoded names are not supported.' }
    }
    $versions = @($uri.Query.TrimStart('?') -split '&' | Where-Object { $_ -match '(?i)^api-version=' })
    if ($versions.Count -ne 1 -or $versions[0] -cnotmatch '^api-version=[A-Za-z0-9.-]+$') { throw 'The ARM path must include exactly one explicit api-version query parameter.' }
    if ($ToolArguments.body.Length -gt 65536) { throw 'Azure request bodies are limited to 65536 characters.' }
    if ($ToolArguments.method -in @('GET', 'DELETE') -and $ToolArguments.body -cne '') { throw 'GET and DELETE requests must have an empty body.' }
    if ($ToolArguments.body) {
        if ($ToolArguments.body.TrimStart() -notmatch '^[\[{]') { throw 'The Azure body must be a JSON object or array, or an empty string.' }
        $null = ConvertFrom-Json -InputObject $ToolArguments.body -ErrorAction Stop
    }
}

function Get-FlintAzureReadOnlyRule {
    param([string]$Method, [string]$Uri, [string]$Body)
    if ($Method -ceq 'GET') { return 'get' }
    # Match the query operation itself, including its API version, without URL normalization.
    if ($Method -cne 'POST' -or $Uri -inotmatch '\Ahttps://management\.azure\.com/providers/Microsoft\.ResourceGraph/resources\?api-version=(?:2021-03-01|2022-10-01|2024-04-01)\z') { return $null }
    if (-not $Body.TrimStart().StartsWith('{')) { return $null }
    try { $request = ConvertFrom-Json -InputObject $Body -ErrorAction Stop } catch { return $null }
    if ($request -isnot [pscustomobject] -or $request.query -isnot [string] -or [string]::IsNullOrWhiteSpace($request.query)) { return $null }
    foreach ($name in $request.PSObject.Properties.Name) {
        if ($name -cnotin @('query', 'subscriptions', 'managementGroups', 'options', 'facets')) { return $null }
        if ($name -cin @('subscriptions', 'managementGroups')) {
            if ($request.$name -isnot [array]) { return $null }
            foreach ($scope in $request.$name) { if ($scope -isnot [string] -or [string]::IsNullOrWhiteSpace($scope)) { return $null } }
        }
        if ($name -ceq 'options' -and $request.options -isnot [pscustomobject]) { return $null }
        if ($name -ceq 'facets' -and $request.facets -isnot [array]) { return $null }
    }
    return 'resource_graph_query'
}

function Invoke-FlintAzureHttpResponse {
    param([hashtable]$Session, [string]$Method, [string]$Uri, [string]$Body, [string]$AccessToken, [double]$TimeoutSec)
    if (-not $AccessToken) { throw 'The Azure HTTP worker did not receive authentication.' }
    $readOnly = [bool](Get-FlintAzureReadOnlyRule $Method $Uri $Body)
    $timeout = [int]($TimeoutSec - ($TimeoutSec % 1))
    if ($TimeoutSec % 1 -gt 0) { $timeout++ }
    if ($timeout -lt 1) { $timeout = 1 }
    $parameters = @{
        Method = $Method; Uri = $Uri; UseBasicParsing = $true
        Headers = @{ Authorization = 'Bearer ' + $AccessToken; Accept = 'application/json' }
        TimeoutSec = $timeout; MaximumRedirection = 0; ErrorAction = 'Stop'
    }
    if ($Body) { $parameters.Body = $Body; $parameters.ContentType = 'application/json; charset=utf-8' }
    $statusCode = $null; $content = ''
    try {
        $response = Invoke-WebRequest @parameters
        $statusCode = [int]$response.StatusCode
        $content = [string]$response.Content
    } catch {
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($null -eq $statusCode) {
            $retryable = $readOnly -and [string]$_.Exception.Status -in @('ConnectFailure', 'ConnectionClosed', 'SendFailure', 'ReceiveFailure')
            return @{ status = 'error'; exit_code = $null; output = Protect-FlintText $Session $_.Exception.Message; retryable = $retryable; has_body = $false }
        }
        # PowerShell 5.1 exposes HTTP error bodies through ErrorDetails without invoking .NET stream methods.
        if ($_.ErrorDetails.Message) { $content = [string]$_.ErrorDetails.Message }
        else {
            $status = 'error'
            if ($statusCode -eq 401) { $status = 'authentication_required' }
            return @{ status = $status; http_status = $statusCode; exit_code = $null; output = 'HTTP error returned without a readable response body.'; retryable = ($readOnly -and $statusCode -in @(429, 502, 503, 504)); has_body = $false }
        }
    }
    $status = 'error'
    if ($statusCode -ge 200 -and $statusCode -lt 300) { $status = 'ok' }
    if ($statusCode -eq 401) { $status = 'authentication_required' }
    return @{ status = $status; http_status = $statusCode; exit_code = $null; content = $content; has_body = $true; retryable = ($readOnly -and $statusCode -in @(429, 502, 503, 504)) }
}

function Invoke-FlintAzureHttpRequest {
    param([string]$Root, [string]$SessionId, $ToolArguments, $Invocation, [string]$AccessToken, [double]$TimeoutSec)
    Assert-FlintAzureRequest $ToolArguments
    $uri = 'https://management.azure.com' + $ToolArguments.path
    if (-not $Invocation -or $Invocation.executor -cne 'azure' -or $Invocation.method -cne $ToolArguments.method -or
        $Invocation.uri -cne $uri -or $Invocation.body -cne $ToolArguments.body) { throw 'Missing or inconsistent approved Azure request.' }
    $session = @{ Root = $Root; Id = $SessionId; Azure = @{ AccessToken = $AccessToken } }
    $response = Invoke-FlintAzureHttpResponse $session $ToolArguments.method $uri $ToolArguments.body $AccessToken $TimeoutSec
    if (-not $response.has_body) { return $response }
    try { $result = Save-FlintAzureResult $session $response.content }
    catch {
        return @{ status = 'error'; http_status = $response.http_status; exit_code = $null; output = ('Azure returned HTTP {0}, but the response could not be saved: {1} Verify the resource state before repeating a mutation.' -f $response.http_status, (Protect-FlintText $session $_.Exception.Message)); retryable = $false }
    }
    $result.http_status = $response.http_status
    $result.exit_code = $null
    $result.retryable = $response.retryable
    $result.status = $response.status
    return $result
}
