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

function Get-FlintAzureResponseMetadata {
    param($Headers)
    $kept = [ordered]@{}; $invalid = @()
    foreach ($name in @('Azure-AsyncOperation', 'Operation-Location', 'Location', 'Retry-After', 'x-ms-request-id', 'x-ms-correlation-request-id')) {
        $value = ''
        if ($Headers) { $value = [string]$Headers[$name] }
        if ($value -and $value.Trim() -and $value.Length -le 8192 -and $value -notmatch '[\x00-\x1f\x7f]') { $kept[$name] = $value.Trim() }
        elseif ($value -and $name -in @('Azure-AsyncOperation', 'Operation-Location', 'Location')) { $invalid += $name }
    }
    $delay = $null
    $retryAfter = $kept['Retry-After']
    if ($retryAfter -match '^\d{1,10}$') { $delay = $retryAfter -as [int] }
    elseif ($retryAfter) {
        $date = $retryAfter -as [datetime]
        if ($date) {
            $seconds = ($date.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds
            if ($seconds -le 0) { $delay = 0 }
            elseif ($seconds -lt 2147483646) { $delay = [int]($seconds - ($seconds % 1)) + 1 }
        }
    }
    return @{
        response_headers = $kept; retry_after_seconds = $delay; invalid_poll_headers = $invalid
        request_id = $kept['x-ms-request-id']; correlation_id = $kept['x-ms-correlation-request-id']
    }
}

function Get-FlintAzurePollPath {
    param([string]$Link)
    # Validate the original text before URI normalization, using the same ARM boundary as ordinary calls.
    $path = $Link
    if ($Link -match '(?i)^https://management\.azure\.com(?::443)?/') {
        $path = $Link -replace '(?i)^https://management\.azure\.com(?::443)?', ''
    } elseif (-not $Link.StartsWith('/') -or $Link.StartsWith('//')) { throw 'The operation polling URL must stay on the HTTPS ARM endpoint.' }
    Assert-FlintAzureRequest @{ method = 'GET'; path = $path; body = '' }
    return $path
}

function Set-FlintAzureOperationResult {
    param([hashtable]$Response, [string]$Method, [string]$Path, [string]$PollKind)
    $document = $null
    try { $document = ConvertFrom-Json -InputObject $Response.content -ErrorAction Stop } catch { }
    if ($document.error.code -is [string] -or $document.error.message -is [string]) {
        $Response.service_error = @{ code = [string]$document.error.code; message = [string]$document.error.message }
        foreach ($name in @('code', 'message')) {
            if ($Response.service_error[$name].Length -gt 2048) { $Response.service_error[$name] = $Response.service_error[$name].Substring(0, 2048) + ' [truncated; see saved response]' }
        }
    }
    if ($Response.http_status -lt 200 -or $Response.http_status -ge 300) { return }
    $headers = $Response.response_headers
    $link = ''; $kind = $PollKind
    foreach ($name in @('Azure-AsyncOperation', 'Operation-Location')) {
        if ($headers[$name]) { $link = $headers[$name]; $kind = 'status'; break }
    }
    if (-not $link -and $Response.http_status -eq 202 -and $headers['Location']) { $link = $headers['Location']; $kind = 'location' }
    $state = ''
    if ($kind -in @('status', 'location') -and $document.status -is [string]) { $state = $document.status }
    elseif (($PollKind -or $Method -in @('PUT', 'PATCH', 'POST', 'DELETE')) -and $document.properties.provisioningState -is [string]) {
        $state = $document.properties.provisioningState
    }
    if ($state -in @('Failed', 'Canceled', 'Cancelled')) {
        $Response.status = 'error'; $Response.operation_status = $state; $Response.retryable = $false
        $Response.operation_message = 'The Azure operation ended without success. Inspect service_error or the saved response before taking another action.'
        return
    }
    if ($state -eq 'Succeeded') { $Response.operation_status = $state; return }
    $invalidLink = 'Azure-AsyncOperation' -in $Response.invalid_poll_headers -or 'Operation-Location' -in $Response.invalid_poll_headers -or
        ($Response.http_status -eq 202 -and 'Location' -in $Response.invalid_poll_headers)
    $pending = $Response.http_status -eq 202 -or $link -or $state -or $invalidLink
    if (-not $pending) {
        if ($PollKind -eq 'location') { $Response.operation_status = 'Succeeded' }
        elseif ($PollKind -in @('status', 'resource')) {
            $Response.status = 'error'; $Response.operation_status = 'Unknown'
            $Response.operation_message = 'The polling response has no operation status. Completion is unconfirmed; inspect the saved response and resource state.'
        }
        return
    }
    $Response.status = 'pending'
    $Response.operation_status = 'InProgress'
    if ($state) { $Response.operation_status = $state }
    $Response.operation_message = 'Azure has accepted the operation. Completion is unconfirmed. Follow poll_path with an azure_request GET; never repeat the mutation to check progress.'
    if (-not $link -and $invalidLink) { $Response.polling_error = 'The service returned an empty, oversized or malformed polling header.' }
    elseif (-not $link) {
        if ($PollKind) { $link = $Path }
        elseif ($Method -in @('PUT', 'PATCH')) { $link = $Path; $kind = 'resource' }
    }
    if ($link) {
        try { $Response.poll_path = Get-FlintAzurePollPath $link; $Response.poll_kind = $kind }
        catch { $Response.polling_error = $_.Exception.Message }
    }
    if (-not $Response.poll_path) {
        $Response.operation_message += ' No supported polling address is available; query the target resource to verify its state.'
        return
    }
    $delay = $Response.retry_after_seconds
    if ($null -eq $delay) { $delay = 5 }
    $Response.poll_after_utc = [datetime]::UtcNow.AddSeconds($delay).ToString('o')
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
    $statusCode = $null; $content = ''; $headers = $null; $failure = $null
    try {
        $response = Invoke-WebRequest @parameters
        $statusCode = [int]$response.StatusCode
        $content = [string]$response.Content
        $headers = $response.Headers
    } catch {
        $failure = Get-FlintFailureDetails $Session $_
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode; $headers = $_.Exception.Response.Headers }
        if ($null -eq $statusCode) {
            $retryable = $readOnly -and [string]$_.Exception.Status -in @('ConnectFailure', 'ConnectionClosed', 'SendFailure', 'ReceiveFailure')
            return @{ status = 'error'; exit_code = $null; output = Protect-FlintText $Session $_.Exception.Message; retryable = $retryable; has_body = $false; failure = $failure }
        }
        # PowerShell 5.1 exposes HTTP error bodies through ErrorDetails without invoking .NET stream methods.
        if ($_.ErrorDetails.Message) { $content = [string]$_.ErrorDetails.Message }
        else {
            $status = 'error'
            if ($statusCode -eq 401) { $status = 'authentication_required' }
            $result = Get-FlintAzureResponseMetadata $headers
            $result.status = $status; $result.http_status = $statusCode; $result.exit_code = $null
            $result.output = 'HTTP error returned without a readable response body.'
            $result.retryable = $readOnly -and $statusCode -in @(429, 502, 503, 504)
            $result.has_body = $false; $result.failure = $failure
            return $result
        }
    }
    $status = 'error'
    if ($statusCode -ge 200 -and $statusCode -lt 300) { $status = 'ok' }
    if ($statusCode -eq 401) { $status = 'authentication_required' }
    $result = Get-FlintAzureResponseMetadata $headers
    $result.status = $status; $result.http_status = $statusCode; $result.exit_code = $null
    $result.content = $content; $result.has_body = $true
    $result.retryable = $readOnly -and $statusCode -in @(429, 502, 503, 504)
    if ($failure) { $result.failure = $failure }
    return $result
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
    Set-FlintAzureOperationResult $response $ToolArguments.method $ToolArguments.path $Invocation.poll_kind
    try { $result = Save-FlintAzureResult $session $response.content }
    catch {
        $response.status = 'error'; $response.retryable = $false
        $response.failure = Get-FlintFailureDetails $session $_
        $result = @{ output = ('Azure returned HTTP {0}, but the response could not be saved: {1} Verify the resource state before repeating a mutation.' -f $response.http_status, (Protect-FlintText $session $_.Exception.Message)) }
    }
    foreach ($name in $response.Keys) {
        if ($name -notin @('content', 'has_body')) { $result[$name] = $response[$name] }
    }
    return $result
}
