function Get-AgentTools {
    $descriptions = [ordered]@{
        read_file = 'Read a local text-file page; saved Azure responses use path=result_path without repeating HTTP. Returns at most 32768 UTF-16 characters; when truncated, continue with next_line/next_column. Large-file reads normalize line endings to LF. Files inside the Flint installation, including .env, .git, .flint and configuration, and this session''s results are readable. Other credential/internal-path protections apply; symlinks and junctions are rejected. Output is redacted.'
        list_files = 'List one directory in name order, up to 200 entries per page. When truncated, continue with next_offset using the same path and name_filter. Directory names end with /. Listing is not recursive; directory changes can shift offsets. All directories inside the Flint installation are allowed.'
        write_file = 'Create or overwrite a UTF-8 text file. Read existing content first; prefer edit_file for targeted changes. The parent must exist. Writes inside the working directory run directly; external writes require session directory authorization.'
        edit_file = 'Replace exactly one occurrence in an existing UTF-8 file; read it first. The resulting file is limited to 65536 characters. External writes require session directory authorization.'
        create_directory = 'Create a directory whose parent exists; succeeds if already present. Creation inside the working directory runs directly; external creation requires session authorization for the directory and descendants.'
    }
    foreach ($name in $descriptions.Keys) {
        $properties = [ordered]@{ path = [ordered]@{ type = 'string'; description = 'Literal relative path or absolute local drive path.' } }
        $required = @('path')
        if ($name -eq 'read_file') {
            $properties.start_line = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2147483647; description = 'First line to read, 1-based. Start with 1.' }
            $properties.start_column = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2147483647; description = 'First UTF-16 character of the first line, 1-based. Start with 1.' }
            $properties.max_lines = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2000; description = 'Maximum lines to return. Normally use 200.' }
            $required += @('start_line', 'start_column', 'max_lines')
        }
        if ($name -eq 'list_files') {
            $properties.name_filter = [ordered]@{ type = 'string'; minLength = 1; maxLength = 255; description = 'Case-insensitive filename wildcard, such as "*" or "*.log". No directory separators.' }
            $properties.offset = [ordered]@{ type = 'integer'; minimum = 0; maximum = 2147483647; description = 'Number of matching entries to skip. Start with 0, then use next_offset.' }
            $required += @('name_filter', 'offset')
        }
        if ($name -eq 'write_file') {
            $properties.content = [ordered]@{ type = 'string'; description = 'Complete file content, up to 65536 characters.' }
            $required += 'content'
        }
        if ($name -eq 'edit_file') {
            $properties.old_str = [ordered]@{ type = 'string'; description = 'Exact, nonempty text to replace; must occur once.' }
            $properties.new_str = [ordered]@{ type = 'string'; description = 'Replacement text; use an empty string to delete the match.' }
            $required += @('old_str', 'new_str')
        }
        [ordered]@{
            type = 'function'; name = $name; description = $descriptions[$name]; strict = $true
            parameters = [ordered]@{ type = 'object'; properties = $properties; required = $required; additionalProperties = $false }
        }
    }
    [ordered]@{
        type = 'function'; name = 'search_text'; strict = $true
        description = 'Search one text file for a literal, case-insensitive keyword. Uses read_file permissions; saved Azure responses use path=result_path. Returns one match per line at its first matching UTF-16 column. Each text snippet has up to 512 characters; text_start_column locates it and text_truncated flags omitted text. When truncated, continue with next_line. Counts cover this page only. Use read_file at a match position for context.'
        parameters = [ordered]@{
            type = 'object'; additionalProperties = $false; required = @('path', 'keyword', 'start_line', 'max_matches')
            properties = [ordered]@{
                path = [ordered]@{ type = 'string'; description = 'Literal relative or absolute local file path. For a saved Azure response, use result_path.' }
                keyword = [ordered]@{ type = 'string'; minLength = 1; maxLength = 256; description = 'Literal single-line text to find; no regular expressions.' }
                start_line = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2147483647; description = 'First line to search, 1-based. Start with 1.' }
                max_matches = [ordered]@{ type = 'integer'; minimum = 1; maximum = 100; description = 'Maximum matching lines to return, normally 50.' }
            }
        }
    }
    [ordered]@{
        type = 'function'; name = 'run_command'; strict = $true
        description = 'Run kubectl with literal arguments. Supports Kubernetes and Falcon CRDs: query Applications/data deployments in a control cluster, then locate workload pods in standard clusters. Reviewed reads run automatically; other calls require exact session approval. Read the returned falcon_guide_path for Falcon workflows before changes. Changes require explicit --context and --namespace for namespaced resources. Falcon Application/data-deployment patches require --type=json with a leading /metadata/resourceVersion test and changes below /spec/. Read actual state after writes; exit code 0 only confirms the command completed. Nonempty output is saved at result_path with a bounded preview; stderr_result_path holds separate warnings/errors when present. capture_incomplete means capture stopped early: narrow the query. Use read_file/search_text for saved results and azure_request for Azure ARM.'
        parameters = [ordered]@{
            type = 'object'; additionalProperties = $false; required = @('executor', 'arguments', 'purpose')
            properties = [ordered]@{
                executor = [ordered]@{ type = 'string'; enum = @('kubectl') }
                purpose = [ordered]@{ type = 'string'; minLength = 1; maxLength = 1000; description = 'Single-line explanation in the user language of the target and expected effect or uncertainty, shown before approval.' }
                arguments = [ordered]@{ type = 'array'; items = [ordered]@{ type = 'string' }; minItems = 1; maxItems = 128; description = 'Command path first, then literal tokens in order. Use full option names and explicit context/resource scope. Example: ["get", "pods", "--context", "CLUSTER", "--namespace", "NAMESPACE"].' }
            }
        }
    }
    [ordered]@{
        type = 'function'; name = 'keyvault_list_secrets'; strict = $true
        description = 'List Key Vault secret names and metadata using the startup Azure identity; never reads secret values. Includes disabled secrets; excludes deleted secrets and individual versions. Follow next_link with this tool until has_more=false. page_count covers this page; total_count is available only for a single-page result. For a multi-page total, sum page_count once per page. Returns a preview and result_path for read_file. Requires secrets/list permission or Key Vault Reader and network access.'
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
        description = 'Call the Azure Resource Manager management API using the startup identity. Requests can target different subscriptions in the authenticated tenant, subject to RBAC. Tools cannot change identity; authentication_required means the user must restart Flint to authenticate. Use keyvault_list_secrets for secret metadata. Prefer API filtering and Resource Graph aggregation. Returns HTTP status, a preview of at most 2048 characters and result_path for read_file/search_text. The saved file holds the complete redacted body of one response; preview_truncated affects only the preview and item_count counts only that page. Follow next_link or saved nextLink only on management.azure.com, using its path and query for the next request. HTTP 202 or status=pending leaves completion unconfirmed. Follow poll_path exactly with GET and body="" until operation_status=Succeeded or terminal failure; the harness enforces poll_after_utc. Report pending if the required wait exceeds the call budget; without poll_path, inspect resource state and report uncertainty. Never repeat a mutation to poll. HTTP 200 can contain failed or canceled operations: inspect status, operation_status and service_error, then verify resource state after success.'
        parameters = [ordered]@{
            type = 'object'; additionalProperties = $false; required = @('method', 'path', 'body', 'purpose')
            properties = [ordered]@{
                method = [ordered]@{ type = 'string'; enum = @('GET', 'POST', 'PUT', 'PATCH', 'DELETE'); description = 'GET runs automatically. POST /providers/Microsoft.ResourceGraph/resources also runs automatically with api-version 2021-03-01, 2022-10-01 or 2024-04-01 and a valid query body. Other requests require exact session approval.' }
                purpose = [ordered]@{ type = 'string'; minLength = 1; maxLength = 1000; description = 'Single-line explanation in the user language of the target and expected effect or uncertainty, shown before approval.' }
                path = [ordered]@{ type = 'string'; description = 'ARM path and query on management.azure.com, with exactly one api-version and explicit resource scope. Omit the host; at most 8192 characters. Example: /subscriptions/SUB/resourceGroups/RG/providers/Microsoft.KeyVault/vaults/VAULT?api-version=2024-11-01.' }
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
