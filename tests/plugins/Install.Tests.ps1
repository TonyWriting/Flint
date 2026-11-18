#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
$savedPath = $env:PATH
try {
    foreach ($case in @(
        @{ url = 'https://contoso.visualstudio.com/Project/_git/Repo?path=/plugins/example'; clone = 'https://contoso.visualstudio.com/Project/_git/Repo'; path = 'plugins/example'; ref = $null },
        @{ url = 'https://contoso.visualstudio.com/DefaultCollection/Project/_git/Repo?path=%2Fplugins%2Fexample&version=GBmain&_a=contents'; clone = 'https://contoso.visualstudio.com/DefaultCollection/Project/_git/Repo'; path = 'plugins/example'; ref = 'main' },
        @{ url = 'https://contoso.visualstudio.com/DefaultCollection/Project_Name/_git/Repo?path=%2FTeam%2FPlugins%2FExample&version=GBusers%2Falias%2Ffeature'; clone = 'https://contoso.visualstudio.com/DefaultCollection/Project_Name/_git/Repo'; path = 'Team/Plugins/Example'; ref = 'users/alias/feature' },
        @{ url = 'https://user@dev.azure.com/contoso/My%20Project/_git/Repo?path=/plugins/example/&version=GTv1.0'; clone = 'https://dev.azure.com/contoso/My%20Project/_git/Repo'; path = 'plugins/example'; ref = 'v1.0' },
        @{ url = 'https://dev.azure.com/contoso/_git/Repo?path=/a%20b/example'; clone = 'https://dev.azure.com/contoso/_git/Repo'; path = 'a b/example'; ref = $null }
    )) {
        $source = ConvertFrom-FlintPluginSource $case.url
        Assert-True ($source.kind -ceq 'git' -and $source.clone_url -ceq $case.clone -and $source.repo_path -ceq $case.path -and $source.ref -ceq $case.ref) ('Parse ' + $case.url + ' as ' + $source.clone_url + ' ' + $source.repo_path + ' ' + $source.ref)
        Assert-True (-not $source.display.Contains('user@') -and -not $source.clone_url.Contains('?')) 'Credentials and query parameters never reach git.'
    }
    foreach ($case in @(
        @{ url = 'http://dev.azure.com/contoso/Project/_git/Repo?path=/x'; pattern = '*https*' },
        @{ url = 'https://dev.azure.com:8443/contoso/Project/_git/Repo?path=/x'; pattern = '*default port*' },
        @{ url = 'https://github.com/contoso/repo?path=/x'; pattern = '*Azure DevOps*' },
        @{ url = 'https://dev.azure.com/contoso/Project/Repo?path=/x'; pattern = '*folder URL form*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo'; pattern = '*Add ?path=*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=/'; pattern = '*not the repository root*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=/a/../b'; pattern = '*Unsupported plugin path*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=/-x'; pattern = '*Unsupported plugin path*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=/x&version=GC0123abc'; pattern = '*Commit URLs*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=/x&version=GB-delete'; pattern = '*Unsupported branch*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=%2Fx&version=GBusers%2Falias%2Ffeature%27%27'; pattern = '*version parameter contains quote characters*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=%2Fplugins%2Fx%22'; pattern = '*path parameter contains quote characters*' }
    )) { Assert-Throws { ConvertFrom-FlintPluginSource $case.url } $case.pattern }
    Assert-Throws { ConvertFrom-FlintPluginSource (Join-Path $TestRoot 'missing') } '*Plugin source not found*'
    $notArchive = Join-Path $TestRoot 'plugin.txt'
    Set-Content -LiteralPath $notArchive -Value 'x' -Encoding UTF8
    Assert-Throws { ConvertFrom-FlintPluginSource $notArchive } '*folder or a .zip*'

    # Local folders install through staging; a failed install never touches the installed copy.
    $installRoot = Join-Path $TestRoot 'installed'
    $source = New-TestPlugin (Join-Path $TestRoot 'source\example')
    $result = Install-FlintPlugin $source -PluginDirectory $installRoot
    Assert-True ($result.plugin.name -ceq 'example' -and -not $result.previous_version -and (Test-Path -LiteralPath (Join-Path $installRoot 'example\plugin.json'))) 'Install a validated plugin from a local folder.'
    $record = ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $installRoot 'example.source.json') -Raw -Encoding UTF8)
    Assert-True ($record.kind -ceq 'directory' -and $record.source -ceq (Get-Item -LiteralPath $source).FullName -and $record.plugin_version -ceq '1.0.0' -and $record.installed_at) 'Record where the plugin came from.'
    $null = New-TestPlugin $source -Version '1.1.0'
    $result = Install-FlintPlugin $source -PluginDirectory $installRoot
    Assert-True ($result.previous_version -ceq '1.0.0' -and $result.plugin.version -ceq '1.1.0') 'Reinstalling replaces the previous version.'
    Assert-True (@(Get-ChildItem -LiteralPath $installRoot -Force | Where-Object { $_.Name.StartsWith('.') }).Count -eq 0) 'Leave no staging or backup directories behind.'
    $broken = New-TestPlugin (Join-Path $TestRoot 'source\broken') -Manifest @{ guide = 'missing.md' }
    Assert-Throws { Install-FlintPlugin $broken -PluginDirectory $installRoot } '*guide refers to*'
    $sameName = New-TestPlugin (Join-Path $TestRoot 'source\example-bad') -Version '2.0.0' -Rules @((New-TestRule @('get', 'secrets')))
    Assert-Throws { Install-FlintPlugin $sameName -PluginDirectory $installRoot } '*cannot read Secrets*'
    Assert-True ((Test-FlintPlugin (Join-Path $installRoot 'example')).version -ceq '1.1.0') 'A rejected source keeps the installed version.'
    $loaded = Read-FlintPlugins $installRoot
    Assert-True (@($loaded.loaded).Count -eq 1 -and $loaded.loaded[0].source.kind -ceq 'directory' -and @($loaded.errors).Count -eq 0) 'Installed plugins load with their source record.'

    $longParent = Join-Path $TestRoot ('p' * (212 - $TestRoot.Length))
    Assert-Throws { Install-FlintPlugin $source -PluginDirectory $longParent } '*longer than 240 characters*'

    # Archives from the Azure DevOps download button contain one top-level folder; plugin.json at the root also works.
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $nested = Join-Path $TestRoot 'nested.zip'
    & $tar -a -c -f $nested -C (Join-Path $TestRoot 'source') example
    Assert-True ($LASTEXITCODE -eq 0) 'Create a nested archive fixture.'
    $flat = Join-Path $TestRoot 'flat.zip'
    & $tar -a -c -f $flat -C $source .
    Assert-True ($LASTEXITCODE -eq 0) 'Create a flat archive fixture.'
    $twoFolders = Join-Path $TestRoot 'two.zip'
    & $tar -a -c -f $twoFolders -C (Join-Path $TestRoot 'source') example broken
    Assert-True ($LASTEXITCODE -eq 0) 'Create an ambiguous archive fixture.'
    $zipRoot = Join-Path $TestRoot 'zip-installed'
    Assert-True ((Install-FlintPlugin $nested -PluginDirectory $zipRoot).plugin.version -ceq '1.1.0') 'Install from an archive with one top-level folder.'
    Assert-True ((Install-FlintPlugin $flat -PluginDirectory $zipRoot).previous_version -ceq '1.1.0') 'Install from an archive with plugin.json at its root.'
    Assert-Throws { Install-FlintPlugin $twoFolders -PluginDirectory $zipRoot } '*single top-level folder*'

    # A compiled stand-in for git.exe records the exact sparse fetch and serves the plugin folder.
    $bin = Join-Path $TestRoot 'bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    Copy-Item -LiteralPath $source -Destination (Join-Path $bin 'remote-plugin') -Recurse
    $code = Join-Path $TestRoot 'FakeGit.cs'
    Set-Content -LiteralPath $code -Encoding UTF8 -Value @'
using System;
using System.IO;
class FakeGit {
    static void CopyDirectory(string source, string target) {
        Directory.CreateDirectory(target);
        foreach (var file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(target, Path.GetFileName(file)));
        foreach (var directory in Directory.GetDirectories(source)) CopyDirectory(directory, Path.Combine(target, Path.GetFileName(directory)));
    }
    static int Main(string[] args) {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        File.AppendAllText(Path.Combine(root, "git-calls.txt"), string.Join("|", args) + "\n");
        if (Environment.GetEnvironmentVariable("GIT_TERMINAL_PROMPT") != "0") return 99;
        if (args.Length > 0 && args[0] == "clone") {
            if (File.Exists(Path.Combine(root, "fail-clone.txt"))) { Console.Error.Write("fatal: Authentication failed for the repository"); return 128; }
            int branch = Array.IndexOf(args, "--branch");
            if (branch >= 0 && args[branch + 1] == "missing-branch") { Console.Error.Write("fatal: Remote branch missing-branch not found in upstream origin"); return 128; }
            Directory.CreateDirectory(args[args.Length - 1]);
            return 0;
        }
        if (args.Length == 5 && args[0] == "-C" && args[2] == "sparse-checkout" && args[3] == "set") {
            if (args[4] == "plugins/example") CopyDirectory(Path.Combine(root, "remote-plugin"), Path.Combine(args[1], "plugins", "example"));
            return 0;
        }
        if (args.Length == 4 && args[0] == "-C" && args[2] == "rev-parse") { Console.WriteLine("0123456789abcdef0123456789abcdef01234567"); return 0; }
        return 2;
    }
}
'@
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe ('/out:' + (Join-Path $bin 'git.exe')) $code
    Assert-True ($LASTEXITCODE -eq 0) 'Compile the offline git fixture.'
    $env:PATH = $bin
    $gitRoot = Join-Path $TestRoot 'git-installed'
    $url = 'https://user@dev.azure.com/contoso/Project/_git/Repo?path=/plugins/example&version=GBmain'
    $result = Install-FlintPlugin $url -PluginDirectory $gitRoot
    Assert-True ($result.plugin.name -ceq 'example' -and $result.plugin.source.commit -ceq '0123456789abcdef0123456789abcdef01234567') 'Install the plugin folder fetched by git.'
    $calls = @(Get-Content -LiteralPath (Join-Path $bin 'git-calls.txt') -Encoding UTF8)
    Assert-True ($calls.Count -eq 3) ('Run exactly clone, sparse-checkout and rev-parse: ' + ($calls -join ' / '))
    Assert-True ($calls[0] -like 'clone|--quiet|--depth|1|--filter=blob:none|--sparse|--branch|main|--|https://dev.azure.com/contoso/Project/_git/Repo|*\repository') ('Clone shallow, blobless and sparse from the credential-free URL: ' + $calls[0])
    Assert-True ($calls[1] -like '-C|*\repository|sparse-checkout|set|plugins/example') 'Check out only the plugin folder.'
    Assert-True ($calls[2] -like '-C|*\repository|rev-parse|HEAD') 'Record the fetched commit.'
    $work = Split-Path (($calls[0] -split '\|')[-1]) -Parent
    Assert-True (-not (Test-Path -LiteralPath $work)) 'Remove the temporary clone after installing.'
    $record = ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $gitRoot 'example.source.json') -Raw -Encoding UTF8)
    Assert-True ($record.kind -ceq 'git' -and $record.ref -ceq 'main' -and $record.path -ceq 'plugins/example' -and $record.source -ceq 'https://dev.azure.com/contoso/Project/_git/Repo?path=/plugins/example&version=GBmain') 'Record the repository, branch and folder without credentials.'
    Assert-Throws { Install-FlintPlugin 'https://dev.azure.com/contoso/Project/_git/Repo?path=/plugins/missing' -PluginDirectory $gitRoot } "*has no folder '/plugins/missing' on the default branch*"
    $message = ''
    try { $null = Install-FlintPlugin 'https://dev.azure.com/contoso/Project/_git/Repo?path=/plugins/example&version=GBmissing-branch' -PluginDirectory $gitRoot } catch { $message = $_.Exception.Message }
    Assert-True ($message -like "*Branch or tag 'missing-branch' was not found in https://dev.azure.com/contoso/Project/_git/Repo*version=*" -and $message -notlike '*Sign in*') ('Report a missing branch without suggesting a sign-in problem: ' + $message)
    Set-Content -LiteralPath (Join-Path $bin 'fail-clone.txt') -Value 'x' -Encoding UTF8
    Assert-Throws { Install-FlintPlugin $url -PluginDirectory $gitRoot } '*git clone ended with error*Authentication failed*Sign in to Azure DevOps first: run "git clone https://dev.azure.com/contoso/Project/_git/Repo" once*'
    Assert-True ((Test-FlintPlugin (Join-Path $gitRoot 'example')).name -ceq 'example') 'A failed fetch keeps the installed plugin.'
    $env:PATH = $WorkRoot
    Assert-Throws { Install-FlintPlugin $url -PluginDirectory $gitRoot } '*git was not found on PATH*'
    Write-Host 'All plugin install tests passed.'
} finally { $env:PATH = $savedPath; Remove-TestFixture }
