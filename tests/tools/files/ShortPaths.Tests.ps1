#Requires -Version 5.1
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'TestSupport.ps1')

function Get-TestShortPath {
    param([string]$Path)
    # Query an existing fixture path; cmd never performs file operations here.
    $short = & (Join-Path $env:SystemRoot 'System32\cmd.exe') /d /c ('for %I in ("' + $Path + '") do @echo %~sI')
    if ($LASTEXITCODE -ne 0) { throw 'Could not query the fixture short path.' }
    return ([string]$short).Trim()
}

try {
    $longWorkRoot = (Get-Item -LiteralPath $WorkRoot).FullName
    $shortWorkRoot = Get-TestShortPath $longWorkRoot
    if ($shortWorkRoot -ieq $longWorkRoot) {
        Write-Host 'Short-path tests skipped: this volume does not expose 8.3 aliases.'
        return
    }

    $protectedFile = Join-Path $longWorkRoot 'custom-config.txt'
    Set-Content -LiteralPath $protectedFile -Value 'protected-fixture'
    $shortProtectedFile = Join-Path $shortWorkRoot 'custom-config.txt'
    $Session.ProtectedPaths += $shortProtectedFile
    foreach ($path in @('custom-config.txt', $protectedFile, $shortProtectedFile)) {
        Assert-True ((Invoke-TestTool read_file @{ path = $path }).status -eq 'error') 'Protect the same configured file through long and short parent paths.'
        Assert-True ((Invoke-TestTool write_file @{ path = $path; content = 'changed' }).status -eq 'error') 'Keep short-path configured files protected from writes.'
    }
    Assert-True ((Get-Content -LiteralPath $protectedFile -Raw).Trim() -eq 'protected-fixture') 'Preserve the protected fixture contents.'

    $credentialFile = Join-Path $longWorkRoot 'credentials.backup'
    Set-Content -LiteralPath $credentialFile -Value 'credential-fixture'
    Assert-True ((Invoke-TestTool read_file @{ path = (Get-TestShortPath $credentialFile) }).status -eq 'error') 'Apply protected filename checks after expanding an 8.3 alias.'

    $result = Save-FlintResult $Session '{"value":[{"name":"saved-fixture"}]}'
    $shortResult = Get-TestShortPath $result.result_path
    $read = Invoke-TestTool read_file @{ path = $shortResult }
    Assert-True ($read.status -eq 'ok' -and $read.output.Contains('saved-fixture')) 'Recognize this session result directory through a short path.'

    $authorized = Join-Path $TestRoot 'authorized-directory'
    New-Item -ItemType Directory -Path $authorized | Out-Null
    $newFile = Join-Path (Get-TestShortPath $authorized) 'new-output.txt'
    Assert-True (Test-FlintPathWithinDirectory $newFile $authorized) 'Normalize the existing parent of a new file before checking its directory boundary.'
    Assert-True (-not (Test-FlintPathWithinDirectory ($newFile.Replace('new-output.txt', '..\outside.txt')) $authorized)) 'Do not grant access through parent traversal in a missing target.'

    Write-Host 'All short-path permission tests passed.'
} finally { Remove-TestFixture }
