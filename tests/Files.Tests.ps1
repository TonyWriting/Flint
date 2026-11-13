#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
function Read-Host { throw 'Workspace file tools must not request interactive confirmation.' }
try {
    $unicode = ConvertFrom-Json '"\u4f60\u597d"'
    $text = "alpha`r`n$unicode`r`nalpha"
    Assert-True ((Invoke-TestTool write_file @{ path = 'note.txt'; content = $text }).status -eq 'ok') 'Create a UTF-8 file directly.'
    Assert-True ((Invoke-TestTool read_file @{ path = 'note.txt' }).output -ceq $text) 'Round-trip Unicode and line endings through the worker.'
    foreach ($example in @(
        @{ old = 'alpha'; new = 'beta'; pattern = '*more than once*' },
        @{ old = ''; new = 'overwrite'; pattern = '*nonempty*' },
        @{ old = 'ALPHA'; new = 'beta'; pattern = '*not found*' }
    )) {
        $result = Invoke-TestTool edit_file @{ path = 'note.txt'; old_str = $example.old; new_str = $example.new }
        Assert-True ($result.status -eq 'error' -and $result.output -like $example.pattern) 'Reject ambiguous or stale replacement text.'
    }
    Assert-True ((Invoke-TestTool edit_file @{ path = 'note.txt'; old_str = "alpha`r`n$unicode"; new_str = "beta`r`n$unicode" }).status -eq 'ok') 'Verify an exact multiline replacement.'
    Set-Content -LiteralPath (Join-Path $WorkRoot 'wipe.txt') -Value 'remove me' -Encoding UTF8 -NoNewline
    Assert-True ((Invoke-TestTool edit_file @{ path = 'wipe.txt'; old_str = 'remove me'; new_str = '' }).status -eq 'ok') 'Verify an edit that makes the file empty.'
    Assert-True ((Invoke-TestTool write_file @{ path = 'note.txt'; content = "replacement`n$unicode" }).status -eq 'ok') 'Overwrite a complete file without supplying its old content.'
    Assert-True ((Invoke-TestTool read_file @{ path = 'note.txt' }).output -ceq "replacement`n$unicode") 'Verify the complete replacement.'
    Assert-True ((Invoke-TestTool write_file @{ path = 'empty.txt'; content = '' }).status -eq 'ok') 'Create an empty file.'
    Assert-True ((Invoke-TestTool read_file @{ path = 'empty.txt' }).output -ceq '') 'Read empty files.'
    Assert-True ((Invoke-TestTool write_file @{ path = 'note.txt'; content = '' }).status -eq 'ok') 'Allow an explicit empty replacement.'
    Assert-True ((Invoke-TestTool read_file @{ path = 'note.txt' }).output -ceq '') 'Verify the existing file was emptied.'
    Assert-True ((Invoke-TestTool edit_file @{ path = 'missing.txt'; old_str = ''; new_str = 'content' }).output -like '*Use write_file*') 'Direct new-file creation to write_file.'
    Assert-True ((Invoke-TestTool write_file @{ path = 'missing\file.txt'; content = 'content' }).status -eq 'error') 'Require an existing parent directory.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $WorkRoot 'missing'))) 'Do not create a directory as a side effect.'
    Assert-True ((Invoke-TestTool write_file @{ path = 'note.txt'; content = ('x' * 65537) }).status -eq 'error') 'Reject oversized replacement content before writing.'
    Assert-True ((Invoke-TestTool read_file @{ path = 'note.txt' }).output -ceq '') 'Preserve the file after a rejected write.'
    New-Item -ItemType Directory -Path (Join-Path $WorkRoot 'child') | Out-Null
    $listResult = Invoke-TestTool list_files @{ path = '.' }
    Assert-True ($listResult.status -eq 'ok') ('List directory: ' + $listResult.output)
    $listing = ConvertFrom-Json $listResult.output
    Assert-True ('note.txt' -in $listing.entries -and 'child/' -in $listing.entries) 'List immediate entries.'
    $listResult = Invoke-TestTool list_files @{ path = 'child' }
    Assert-True ($listResult.status -eq 'ok') ('List empty directory: ' + $listResult.output)
    Assert-True ((ConvertFrom-Json $listResult.output).entries.Count -eq 0) 'Return an empty array for an empty directory.'

    foreach ($path in @('\\server\share', 'C:relative.txt', 'note.txt:secret', 'note*', 'NUL', 'child.\file', '.env', '.kube\config', '.azure\config', '.git\config', '.flint\trajectories', '.flint\permissions\session\azure.json', 'key.pem')) {
        $result = Invoke-TestTool read_file @{ path = $path }
        Assert-True ($result.status -eq 'error') "Reject unsafe or protected path: $path"
    }
    Set-Content -LiteralPath (Join-Path $WorkRoot 'large.txt') -Value ('x' * 262145) -Encoding ASCII -NoNewline
    $large = Invoke-TestTool read_file @{ path = 'large.txt' }
    Assert-True ($large.status -eq 'ok' -and $large.truncated -and $large.output.Length -eq 32768 -and $large.next_line -eq 1) 'Read a bounded page from a file larger than 256 KiB.'
    Set-Content -LiteralPath (Join-Path $WorkRoot 'long.txt') -Value (('x' * 40000) + ' tail-marker test-api-key') -Encoding UTF8 -NoNewline
    $longResult = Invoke-TestTool read_file @{ path = 'long.txt' }
    Assert-True ($longResult.truncated -and $longResult.output.Length -lt 33000 -and -not $longResult.output.Contains('tail-marker')) 'Mark truncated model output explicitly.'
    $trajectory = Get-Content -LiteralPath $Session.TrajectoryPath -Raw -Encoding UTF8
    Assert-True (-not $trajectory.Contains('tail-marker') -and -not $trajectory.Contains('test-api-key')) 'Log only the bounded redacted page, not unread file content.'
    $customConfig = Join-Path $WorkRoot 'custom-config.txt'
    Set-Content -LiteralPath $customConfig -Value 'protected'
    $Session.ProtectedPaths += $customConfig
    Assert-True ((Invoke-TestTool read_file @{ path = 'custom-config.txt' }).status -eq 'error') 'Protect explicitly configured paths regardless of their filename.'
    foreach ($path in @('.env', 'custom-config.txt')) {
        Assert-True ((Invoke-TestTool write_file @{ path = $path; content = 'replacement' }).status -eq 'error') 'Apply path and credential protection to direct writes.'
    }
    Assert-True ((Invoke-TestTool write_file @{ path = '..\escape.txt'; content = 'replacement' }).status -eq 'approval_required') 'Require directory consent outside the workspace.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestRoot 'escape.txt'))) 'Never write outside the workspace without authorization.'
    Assert-True ((Get-Content -LiteralPath $customConfig -Raw).Trim() -ceq 'protected') 'Do not overwrite a protected file.'
    foreach ($arguments in @('{broken', 'null', '[]', '[{}]', '"text"', '{"path":12}', '{"path":"note.txt","extra":"x"}', '{"Path":"note.txt"}')) {
        Assert-True ((Invoke-AgentTool $Session 'read_file' $arguments).status -eq 'error') 'Enforce exact structured parameters.'
    }
    Assert-True ((Invoke-AgentTool $Session 'run_shell' '{}').output -like '*Unknown tool*') 'Do not expose a shell tool.'
    foreach ($arguments in @('{"path":"note.txt"}', '{"path":"note.txt","content":null}', '{"path":"note.txt","content":23}', '{"path":"note.txt","content":"text","append":true}')) {
        Assert-True ((Invoke-AgentTool $Session 'write_file' $arguments).status -eq 'error') 'Enforce the complete write_file schema.'
    }
    $safe = Protect-FlintText $Session 'api_key="hidden-one" password=hidden-two Authorization: Bearer hidden-three https://host/?sig=hidden-four&x=1 test-api-key'
    foreach ($secret in @('hidden-one', 'hidden-two', 'hidden-three', 'hidden-four', 'test-api-key')) { Assert-True (-not $safe.Contains($secret)) "Redact $secret."
    }
    $cursorText = Protect-FlintText $Session '?$skiptoken=page2&token=hidden-token&access_token=hidden-access'
    Assert-True ($cursorText.Contains('$skiptoken=page2') -and -not $cursorText.Contains('hidden-token') -and -not $cursorText.Contains('hidden-access')) 'Preserve pagination cursors while redacting authentication tokens.'
    $json = ConvertTo-Json -InputObject (Protect-FlintValue $Session @{ items = @(@{ password = 'hidden-five'; text = 'safe' }); token = 'hidden-six' }) -Depth 16
    Assert-True (-not $json.Contains('hidden-five') -and -not $json.Contains('hidden-six')) 'Recursively redact nested credentials without corrupting JSON.'
    foreach ($arrayJson in @('[]', '[{"password":"hidden-seven"}]', '["safe",{"token":"hidden-eight"}]')) {
        $safeArray = Protect-FlintValue $Session $arrayJson
        Assert-True ($safeArray.StartsWith('[') -and $safeArray.EndsWith(']') -and -not $safeArray.Contains('hidden-')) 'Preserve JSON array shape while redacting command output.'
    }
    # Exercise runtime protection against a temporary copy, never the active source tree.
    $runtimeRoot = New-TestRuntime (Join-Path $WorkRoot 'runtime')
    $originalWorker = $Session.WorkerPath
    $Session.WorkerPath = Join-Path $runtimeRoot 'tools\Worker.ps1'
    try {
        Assert-True ((Invoke-TestTool read_file @{ path = 'runtime\agent.ps1' }).status -eq 'ok') 'Allow reading runtime code.'
        foreach ($path in @('runtime\agent.ps1', 'runtime\lib\Loop.ps1', 'runtime\tools\Worker.ps1', 'runtime\tools\permissions\kubectl.json')) {
            Assert-True ((Invoke-TestTool write_file @{ path = $path; content = 'changed' }).status -eq 'error') 'Block overwriting the running harness implementation.'
        }
        Assert-True ((Invoke-TestTool edit_file @{ path = 'runtime\agent.ps1'; old_str = '#Requires -Version 5.1'; new_str = '# Changed' }).status -eq 'error') 'Apply runtime protection to precise edits too.'
        Assert-True ((Invoke-TestTool write_file @{ path = 'runtime\notes.txt'; content = 'Workspace output' }).status -eq 'ok') 'Allow ordinary output files alongside runtime code.'
    } finally { $Session.WorkerPath = $originalWorker }
    Write-Host 'All file and security tests passed.'
} finally { Remove-TestFixture }
