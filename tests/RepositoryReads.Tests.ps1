#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
try {
    # Exercise repository permissions using synthetic files in an isolated runtime copy.
    $runtime = New-TestRuntime (Join-Path $WorkRoot 'runtime')
    $Session.WorkerPath = Join-Path $runtime 'tools\Worker.ps1'
    foreach ($directory in @('.git', '.flint', '.ssh')) { New-Item -ItemType Directory -Path (Join-Path $runtime $directory) | Out-Null }
    $Session.ProtectedPaths += Join-Path $runtime 'private-config.txt'
    foreach ($relative in @('.env', '.git\config', '.flint\other-session.json', '.ssh\id_rsa', 'private-config.txt')) {
        $path = Join-Path $runtime $relative
        Set-Content -LiteralPath $path -Value 'repository-marker api_key=synthetic-private-value' -Encoding UTF8 -NoNewline
        $read = Invoke-TestTool read_file @{ path = $path }
        Assert-True ($read.status -eq 'ok' -and $read.output.Contains('repository-marker') -and -not $read.output.Contains('synthetic-private-value')) 'Allow repository reads through name and configured-path protections, with existing redaction.'
        $search = Invoke-TestTool search_text @{ path = $path; keyword = 'repository-marker' }
        Assert-True ($search.status -eq 'ok' -and $search.matches_returned -eq 1) 'Use the same repository permission boundary for text search.'
        Assert-True ((Invoke-TestTool write_file @{ path = $path; content = 'replacement' }).status -eq 'error') 'Keep protected repository files read-only.'
    }
    Assert-True ((Invoke-TestTool list_files @{ path = 'runtime\.git' }).status -eq 'ok') 'List protected-name directories inside the Flint installation.'
    Assert-True ((Invoke-TestTool read_file @{ path = 'runtime\.env' }).status -eq 'ok') 'Resolve relative repository paths against the working directory.'
    $sibling = Join-Path $WorkRoot 'runtime-other'
    New-Item -ItemType Directory -Path $sibling | Out-Null
    Set-Content -LiteralPath (Join-Path $sibling '.env') -Value 'outside-marker'
    foreach ($path in @('runtime-other\.env', 'runtime\..\runtime-other\.env', $config)) {
        Assert-True ((Invoke-TestTool read_file @{ path = $path }).status -eq 'error') 'Keep repository access inside the resolved directory boundary.'
        Assert-True ((Invoke-TestTool search_text @{ path = $path; keyword = 'marker' }).status -eq 'error') 'Apply the same outside-repository protections to search.'
    }
    Assert-True ((Invoke-TestTool read_file @{ path = 'runtime\.env:stream' }).status -eq 'error') 'Do not permit alternate data streams through repository read access.'
    Write-Host 'All repository read-permission tests passed.'
} finally { Remove-TestFixture }
