function Get-AgentTools {
    $descriptions = [ordered]@{
        read_file = 'Read a text-file page automatically. Use start_line=1, start_column=1, max_lines=200 initially. Returns at most 32768 characters. When truncated, continue at next_line/next_column. Large files are streamed with LF line endings; small files retain exact endings. Relative and absolute local paths are allowed; credential files are protected.'
        read_result = 'Read a page of a saved Azure response by its result_id. Use start_line=1, start_column=1, max_lines=200 initially; continue at next_line/next_column when truncated. Returns at most 32768 characters. Only this session''s saved responses are accessible, including after resume. Does not repeat the Azure request.'
        list_files = 'List up to 200 immediate entries. Relative and absolute local paths are allowed. Use path "." for the working directory. Reads execute automatically.'
        write_file = 'Create or overwrite a local UTF-8 text file with the complete content, up to 65536 characters. The parent directory must exist. Read existing files first. Writes inside the working directory execute directly; external writes require session authorization for the target directory.'
        edit_file = 'Replace exactly one occurrence of nonempty old_str in an existing UTF-8 file. Read first. Resulting content is limited to 65536 characters. External writes require session authorization for the target directory.'
        create_directory = 'Create a local directory, or return success if it already exists. The parent directory must exist. Executes directly inside the working directory; external creation requires session authorization for the new directory and its descendants.'
    }
    foreach ($name in $descriptions.Keys) {
        $properties = [ordered]@{ path = [ordered]@{ type = 'string'; description = 'Literal relative path or absolute local drive path.' } }
        $required = @('path')
        if ($name -eq 'read_result') {
            $properties = [ordered]@{ result_id = [ordered]@{ type = 'string'; description = 'The 32-character result_id returned by azure_request.' } }
            $required = @('result_id')
        }
        if ($name -in @('read_file', 'read_result')) {
            $properties.start_line = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2147483647; description = 'First line to read, 1-based. Start with 1.' }
            $properties.start_column = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2147483647; description = 'First UTF-16 character of the first line, 1-based. Start with 1; use next_column to continue a long line.' }
            $properties.max_lines = [ordered]@{ type = 'integer'; minimum = 1; maximum = 2000; description = 'Maximum lines to return. Normally use 200.' }
            $required += @('start_line', 'start_column', 'max_lines')
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
        description = 'List Key Vault secret names and metadata only, using the current Azure user and tenant. Never reads secret contents. Supply the vault name and next_link="" for the first page; then follow the returned next_link using this same tool until has_more=false. Each page contains at most 25 base secret identifiers, including disabled secrets, excluding deleted secrets and individual versions. page_count counts this page only; total_count is set only when the first response is also the last page. For multi-page totals, collect all pages and sum page_count once per page. Returns names, counts, a bounded preview and a saved metadata file readable with read_result. Requires secrets/list permission or Key Vault Reader and network access. No arbitrary URLs, secret names, HTTP methods, bodies or credentials are accepted.'
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
        description = 'Call the Azure Resource Manager HTTPS API using the user identity selected at Flint startup. GET and reviewed Resource Graph POST queries run automatically; other requests require exact session approval. The Resource Graph POST read rule matches /providers/Microsoft.ResourceGraph/resources with a supported api-version and query body. Other POST, PUT, PATCH and DELETE requests require approval. Supply an explicit API version, resource scope and purpose. Only management.azure.com is supported; no credentials, headers, login commands or data-plane URLs. Use keyvault_list_secrets for secret names and metadata. Saves the complete redacted response body to a local file. Returns HTTP status, result_id, result_path, size, item_count, next_link and a preview of at most 2048 characters. Use read_result to inspect saved data; preview_truncated describes only the preview. HTTP 202 means accepted, not completed.'
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
        if ($Name -cin @('read_file', 'read_result') -and $key -cin @('start_line', 'start_column', 'max_lines')) {
            $maximum = 2147483647
            if ($key -ceq 'max_lines') { $maximum = 2000 }
            if (($parsed.$key -isnot [int] -and $parsed.$key -isnot [long]) -or $parsed.$key -lt 1 -or $parsed.$key -gt $maximum) { throw 'Invalid read pagination parameters.' }
        } elseif ($Name -ceq 'run_command' -and $key -ceq 'arguments') {
            if ($parsed.arguments -isnot [array] -or $parsed.arguments.Count -lt 1 -or $parsed.arguments.Count -gt 128) { throw 'Command arguments must be an array of 1 to 128 strings.' }
            foreach ($argument in $parsed.arguments) {
                if ($argument -isnot [string] -or $argument.Length -gt 16384 -or $argument -match '[\x00-\x1f\x7f]') { throw 'Command arguments must be literal single-line strings of at most 16384 characters.' }
            }
        } elseif ($parsed.$key -isnot [string]) { throw 'Tool arguments must contain the registered string properties.' }
    }
    if ($Name -ceq 'run_command' -and $parsed.executor -cne 'kubectl') { throw 'Unsupported command executor. Use azure_request for Azure.' }
    if ($Name -cin @('run_command', 'azure_request') -and
        ([string]::IsNullOrWhiteSpace($parsed.purpose) -or $parsed.purpose.Length -gt 1000 -or $parsed.purpose -match '[\x00-\x1f\x7f]')) {
        throw 'Provide a nonempty single-line purpose of at most 1000 characters describing the target and expected effect.'
    }
    if ($Name -ceq 'azure_request') { Assert-FlintAzureRequest $parsed }
    if ($Name -ceq 'keyvault_list_secrets') { $null = Get-FlintKeyVaultListUri $parsed }
    if ($Name -ceq 'read_result' -and $parsed.result_id -cnotmatch '^[a-f0-9]{32}$') { throw 'Use the result_id returned by azure_request.' }
    return $parsed
}
