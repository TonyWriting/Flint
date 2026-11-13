function Get-AgentTools {
    $descriptions = [ordered]@{
        read_file = 'Read a text-file page automatically. For a saved Azure response, use its result_path as path; this reads the saved file without repeating HTTP. Use start_line=1, start_column=1, max_lines=200 initially. Returns at most 32768 characters. When truncated, continue at next_line/next_column. Large files are streamed with LF line endings; small files retain exact endings. Relative and absolute local paths are allowed. All ordinary files inside the Flint installation and this session''s result directory are readable, including after resume. Other credential and internal-file protections apply. Symlinks and junctions are rejected. Existing output redaction applies.'
        list_files = 'List one directory in name order, up to 200 entries per page within the output limit. Supply name_filter="*" for all entries or a case-insensitive filename wildcard such as "*.log". Start with offset=0; when truncated, repeat the same path and filter with next_offset. Directory names end with /. Listing is not recursive; directory changes between calls can shift offsets. Relative and absolute local paths are allowed, including every directory inside the Flint installation. Reads execute automatically.'
        write_file = 'Create or overwrite a local UTF-8 text file with the complete content, up to 65536 characters. The parent directory must exist. Read existing files first. Writes inside the working directory execute directly; external writes require session authorization for the target directory.'
        edit_file = 'Replace exactly one occurrence of nonempty old_str in an existing UTF-8 file. Read first. Resulting content is limited to 65536 characters. External writes require session authorization for the target directory.'
        create_directory = 'Create a local directory, or return success if it already exists. The parent directory must exist. Executes directly inside the working directory; external creation requires session authorization for the new directory and its descendants.'
    }
    foreach ($name in $descriptions.Keys) {
        $properties = [ordered]@{ path = [ordered]@{ type = 'string'; description = 'Literal relative path or absolute local drive path.' } }
        $required = @('path')
        if ($name -eq 'read_file') {
            $properties.start_line = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2147483647; description = 'First line to read, 1-based. Start with 1.' }
            $properties.start_column = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2147483647; description = 'First UTF-16 character of the first line, 1-based. Start with 1; use next_column to continue a long line.' }
            $properties.max_lines = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2000; description = 'Maximum lines to return. Normally use 200.' }
            $required += @('start_line', 'start_column', 'max_lines')
        }
        if ($name -eq 'list_files') {
            $properties.name_filter = [ordered]@{ type = 'string'; minLength = 1; maxLength = 255; description = 'Filename wildcard, for example "*" or "*.log". No directory separators.' }
            $properties.offset = [ordered]@{ type = 'integer'; minimum = 0; maximum = 2147483647; description = 'Number of matching entries to skip. Start with 0, then use next_offset.' }
            $required += @('name_filter', 'offset')
        }
        if ($name -eq 'write_file') {
            $properties.content = [ordered]@{ type = 'string' }
            $required += 'content'
        }
        if ($name -eq 'edit_file') {
            $properties.old_str = [ordered]@{ type = 'string' }
            $properties.new_str = [ordered]@{ type = 'string' }
            $required += @('old_str', 'new_str')
        }
        [ordered]@{
            type = 'function'; name = $name; description = $descriptions[$name]; strict = $true
            parameters = [ordered]@{ type = 'object'; properties = $properties; required = $required; additionalProperties = $false }
        }
    }
    [ordered]@{
        type = 'function'; name = 'search_text'; strict = $true
        description = 'Search one text file by path for a literal, case-insensitive keyword. For a saved Azure response, use its result_path as path. Uses the same path permissions as read_file, including this session''s result directory and all files inside the Flint installation. Start at start_line=1 with max_matches=50. Each match describes one matching line and its first matching UTF-16 column, with up to 512 characters of text around the match. text_start_column locates the snippet; text_truncated means the line is longer than the snippet. When truncated, continue at next_line. At most 100 matching lines and a bounded JSON result per call. Counts apply only to this page. Use read_file at the returned line and column for more context. This search does not execute expressions or send an Azure request.'
        parameters = [ordered]@{
            type = 'object'; additionalProperties = $false; required = @('path', 'keyword', 'start_line', 'max_matches')
            properties = [ordered]@{
                path = [ordered]@{ type = 'string'; description = 'Literal relative or absolute local file path. For a saved Azure response, use result_path.' }
                keyword = [ordered]@{ type = 'string'; minLength = 1; maxLength = 256; description = 'Literal single-line text to find, without regular-expression syntax or interpretation.' }
                start_line = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2147483647; description = 'First line to search, 1-based. Follow next_line when truncated.' }
                max_matches = [ordered]@{ type = 'integer'; minimum = 1; maximum = 100; description = 'Maximum matching lines to return, normally 50.' }
            }
        }
    }
    [ordered]@{
        type = 'function'; name = 'run_command'; strict = $true
        description = 'Run kubectl with literal argument tokens, without a shell. Put the command path first, then full option names and explicit context and resource scope. Reviewed read-only rules run automatically. All other invocations, including writes, require exact session approval. Never supply a shell script or credentials. Use azure_request for Azure.'
        parameters = [ordered]@{
            type = 'object'; additionalProperties = $false; required = @('executor', 'arguments', 'purpose')
            properties = [ordered]@{
                executor = [ordered]@{ type = 'string'; enum = @('kubectl') }
                purpose = [ordered]@{ type = 'string'; minLength = 1; maxLength = 1000; description = 'A concise single-line explanation in the user language of the target, objective and expected effect. State uncertainty about effects when applicable. Shown to the user before approval; this text never grants permission.' }
                arguments = [ordered]@{ type = 'array'; items = [ordered]@{ type = 'string' }; minItems = 1; maxItems = 128; description = 'Each argument is one literal token. Preserve all values and their order. Example: ["get", "pods", "--context", "CLUSTER", "--namespace", "NAMESPACE"].' }
            }
        }
    }
    [ordered]@{
        type = 'function'; name = 'keyvault_list_secrets'; strict = $true
        description = 'List Key Vault secret names and metadata only, using the current Azure user and tenant. Never reads secret contents. Supply the vault name and next_link="" for the first page; then follow the returned next_link using this same tool until has_more=false. Each page contains at most 25 base secret identifiers, including disabled secrets, excluding deleted secrets and individual versions. page_count counts this page only; total_count is set only when the first response is also the last page. For multi-page totals, collect all pages and sum page_count once per page. Returns names, counts, a bounded preview and result_path for a saved metadata file readable with read_file. Requires secrets/list permission or Key Vault Reader and network access. No arbitrary URLs, secret names, HTTP methods, bodies or credentials are accepted.'
        parameters = [ordered]@{
            type = 'object'; additionalProperties = $false; required = @('vault_name', 'next_link')
            properties = [ordered]@{
                vault_name = [ordered]@{ type = 'string'; description = 'Azure public-cloud Key Vault name, for example demo-vault.' }
                next_link = [ordered]@{ type = 'string'; description = 'Empty string for the first page. For subsequent pages, use the exact next_link returned for the same vault.' }
            }
        }
    }
    [ordered]@{
        type = 'function'; name = 'azure_request'; strict = $true
        description = 'Call the Azure Resource Manager HTTPS API using the user identity selected at Flint startup. GET and reviewed Resource Graph POST queries run automatically; other requests require exact session approval. The Resource Graph POST read rule matches /providers/Microsoft.ResourceGraph/resources with a supported api-version and query body. Other POST, PUT, PATCH and DELETE requests require approval. Supply an explicit API version, resource scope and purpose. Only management.azure.com is supported; no credentials, headers, login commands or data-plane URLs. Use keyvault_list_secrets for secret names and metadata. Saves the complete redacted response body to a local file. Returns HTTP status, result_id, result_path, size, item_count, next_link and a preview of at most 2048 characters. Use read_file or search_text with path=result_path to inspect saved data; preview_truncated describes only the preview. Asynchronous operations return status=pending, operation_status, poll_path and poll_after_utc. Follow poll_path exactly with GET and an empty body to check progress; the harness waits before polling. Report pending if the required wait exceeds the call budget. Verify operation_status and the resource state before claiming completion; HTTP 200 can contain a terminal operation failure. Never repeat the mutation to poll. request_id, correlation_id, service_error and failure support diagnosis.'
        parameters = [ordered]@{
            type = 'object'; additionalProperties = $false; required = @('method', 'path', 'body', 'purpose')
            properties = [ordered]@{
                method = [ordered]@{ type = 'string'; enum = @('GET', 'POST', 'PUT', 'PATCH', 'DELETE') }
                purpose = [ordered]@{ type = 'string'; minLength = 1; maxLength = 1000; description = 'A concise single-line explanation in the user language of the target, objective and expected effect. Explain any expected changes or uncertainty. Shown to the user before approval; this text never grants permission.' }
                path = [ordered]@{ type = 'string'; description = 'ARM path and query with exactly one api-version, at most 8192 characters. Example: /subscriptions/SUB/resourceGroups/RG/providers/Microsoft.KeyVault/vaults/VAULT?api-version=2024-11-01. Omit the host.' }
                body = [ordered]@{ type = 'string'; description = 'JSON request body, at most 65536 characters. Use an empty string for GET, DELETE or a request without a body.' }
            }
        }
    }
}

function ConvertTo-FlintToolArguments {
    param([string]$Name, [string]$Arguments)
    $tool = @(Get-AgentTools | Where-Object { $_.name -ceq $Name })
    if ($tool.Count -ne 1) { throw "Unknown tool: $Name" }
    if ($Arguments.Length -gt 131072 -or -not $Arguments.TrimStart().StartsWith('{')) { throw 'Arguments must be a JSON object of at most 128 Ki characters.' }
    $parsed = ConvertFrom-Json -InputObject $Arguments -ErrorAction Stop
    if ($parsed -isnot [pscustomobject]) { throw 'Arguments must be a JSON object.' }
    $expected = @($tool[0].parameters.required)
    $actual = @($parsed.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $expected.Count) { throw 'Tool arguments do not match the registered schema.' }
    foreach ($key in $actual) {
        if ($key -cnotin $expected) { throw 'Tool arguments do not match the registered schema.' }
        $property = $tool[0].parameters.properties[$key]
        if ($property.type -eq 'integer') {
            if (($parsed.$key -isnot [int] -and $parsed.$key -isnot [long]) -or $parsed.$key -lt $property.minimum -or $parsed.$key -gt $property.maximum) { throw 'Invalid pagination parameters.' }
        } elseif ($Name -ceq 'run_command' -and $key -ceq 'arguments') {
            if ($parsed.arguments -isnot [array] -or $parsed.arguments.Count -lt 1 -or $parsed.arguments.Count -gt 128) { throw 'Command arguments must be an array of 1 to 128 strings.' }
            foreach ($argument in $parsed.arguments) {
                if ($argument -isnot [string] -or $argument.Length -gt 16384 -or $argument -match '[\x00-\x1f\x7f]') { throw 'Command arguments must be literal single-line strings of at most 16384 characters.' }
            }
        } elseif ($parsed.$key -isnot [string]) { throw 'Tool arguments must contain the registered string properties.' }
    }
    if ($Name -ceq 'list_files' -and ($parsed.name_filter.Length -lt 1 -or $parsed.name_filter.Length -gt 255 -or $parsed.name_filter -match '[\\/:\x00-\x1f\x7f]')) {
        throw 'Use a filename wildcard of 1 to 255 characters without directory separators or control characters.'
    }
    if ($Name -ceq 'search_text') {
        if ($parsed.keyword.Length -lt 1 -or $parsed.keyword.Length -gt 256 -or $parsed.keyword -match '[\x00-\x1f\x7f]') { throw 'Use a literal single-line keyword of 1 to 256 characters.' }
    }
    if ($Name -ceq 'run_command' -and $parsed.executor -cne 'kubectl') { throw 'Unsupported command executor. Use azure_request for Azure.' }
    if ($Name -cin @('run_command', 'azure_request') -and
        ([string]::IsNullOrWhiteSpace($parsed.purpose) -or $parsed.purpose.Length -gt 1000 -or $parsed.purpose -match '[\x00-\x1f\x7f]')) {
        throw 'Provide a nonempty single-line purpose of at most 1000 characters describing the target and expected effect.'
    }
    if ($Name -ceq 'azure_request') { Assert-FlintAzureRequest $parsed }
    if ($Name -ceq 'keyvault_list_secrets') { $null = Get-FlintKeyVaultListUri $parsed }
    return $parsed
}
