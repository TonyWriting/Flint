#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
$savedPath = $env:PATH
# The key prompt is the only interactive step; tests answer it here.
$script:KeyInput = ''; $script:KeyPrompts = @()
function Read-FlintSetupApiKey { param([bool]$HasCurrent) $script:KeyPrompts += $HasCurrent; return $script:KeyInput }
function Read-TestConfig { param([string]$Path) return Read-FlintIniFile $Path (Get-FlintConfigSchema) }
try {
    foreach ($case in @(
        @{ url = 'https://contoso.visualstudio.com/Project/_git/Repo?path=/team/flint'; clone = 'https://contoso.visualstudio.com/Project/_git/Repo'; path = 'team/flint'; ref = $null },
        @{ url = 'https://contoso.visualstudio.com/DefaultCollection/Project/_git/Repo?path=%2Fteam%2Fflint&version=GBmain&_a=contents'; clone = 'https://contoso.visualstudio.com/DefaultCollection/Project/_git/Repo'; path = 'team/flint'; ref = 'main' },
        @{ url = 'https://contoso.visualstudio.com/DefaultCollection/Project_Name/_git/Repo?path=%2FTeam%2FFlint&version=GBusers%2Falias%2Ffeature'; clone = 'https://contoso.visualstudio.com/DefaultCollection/Project_Name/_git/Repo'; path = 'Team/Flint'; ref = 'users/alias/feature' },
        @{ url = 'https://user@dev.azure.com/contoso/My%20Project/_git/Repo?path=/team/flint/&version=GTv1.0'; clone = 'https://dev.azure.com/contoso/My%20Project/_git/Repo'; path = 'team/flint'; ref = 'v1.0' },
        @{ url = 'https://dev.azure.com/contoso/_git/Repo?path=/a%20b/flint'; clone = 'https://dev.azure.com/contoso/_git/Repo'; path = 'a b/flint'; ref = $null }
    )) {
        $source = ConvertFrom-FlintSetupSource $case.url
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
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=/a/../b'; pattern = '*Unsupported setup path*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=/-x'; pattern = '*Unsupported setup path*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=/x&version=GC0123abc'; pattern = '*Commit URLs*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=/x&version=GB-delete'; pattern = '*Unsupported branch*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=%2Fx&version=GBusers%2Falias%2Ffeature%27%27'; pattern = '*version parameter contains quote characters*' },
        @{ url = 'https://dev.azure.com/contoso/Project/_git/Repo?path=%2Fteam%2Fx%22'; pattern = '*path parameter contains quote characters*' }
    )) { Assert-Throws { ConvertFrom-FlintSetupSource $case.url } $case.pattern }
    Assert-Throws { ConvertFrom-FlintSetupSource (Join-Path $TestRoot 'missing') } '*Setup source not found*'
    $notArchive = Join-Path $TestRoot 'setup.txt'
    Set-Content -LiteralPath $notArchive -Value 'x' -Encoding UTF8
    Assert-Throws { ConvertFrom-FlintSetupSource $notArchive } '*folder or a .zip*'

    # A setup folder holds the shared flint.ini, plugin folders and notes, and never an API key.
    $source = New-TestSetup (Join-Path $TestRoot 'source\team')
    Set-Content -LiteralPath (Join-Path $source 'README.md') -Value '# Team setup' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $source 'Plugins\README.md') -Value '# Plugins' -Encoding UTF8
    $checked = Test-FlintSetup $source
    Assert-True ($checked.model.Model -ceq 'team-model' -and $checked.model.ApiKeyHelp -ceq 'Ask the team for the key.' -and ((@($checked.plugins) | ForEach-Object { $_.name }) -join ',') -ceq 'example') 'Accept a setup with a template, a plugin and notes.'
    $bare = New-TestSetup (Join-Path $TestRoot 'source\bare') -Plugins @()
    Assert-True (@((Test-FlintSetup $bare).plugins).Count -eq 0) 'A setup without plugins only provides the model.'
    $endpoint = 'endpoint = https://contoso.services.ai.azure.com/openai/v1/responses'
    $shared = New-TestSetup (Join-Path $TestRoot 'source\shared') -Template @('[model]', $endpoint, 'deployment = team-model', 'api_key = shared-secret-key')
    $message = ''
    try { $null = Test-FlintSetup $shared } catch { $message = $_.Exception.Message }
    Assert-True ($message -like '*flint.ini: remove api_key*' -and $message -notlike '*shared-secret-key*') 'Refuse a shared template that contains a key, without echoing it.'
    foreach ($case in @(
        @{ name = 'no-deployment'; template = @('[model]', $endpoint); pattern = '*flint.ini: Set deployment under `[model`]*' },
        @{ name = 'bad-endpoint'; template = @('[model]', 'endpoint = https://contoso.services.ai.azure.com/openai/v1', 'deployment = x'); pattern = '*flint.ini: endpoint under `[model`] must be a complete HTTPS URL*' },
        @{ name = 'unknown'; template = @('[model]', $endpoint, 'deployment = x', 'tenant = contoso'); pattern = "*flint.ini: Line 4: unknown setting 'tenant'*" },
        @{ name = 'long-help'; template = @('[model]', $endpoint, 'deployment = x', ('api_key_help = ' + ('h' * 401))); pattern = '*api_key_help*400 characters*' }
    )) { Assert-Throws { Test-FlintSetup (New-TestSetup (Join-Path $TestRoot ('source\' + $case.name)) -Template $case.template) } $case.pattern }
    $extra = New-TestSetup (Join-Path $TestRoot 'source\extra')
    Set-Content -LiteralPath (Join-Path $extra 'tool.ps1') -Value 'Write-Host hi' -Encoding UTF8
    Assert-Throws { Test-FlintSetup $extra } '*tool.ps1: a setup folder holds only flint.ini, a Plugins folder and .md notes*'
    $renamed = New-TestSetup (Join-Path $TestRoot 'source\renamed') -Plugins @()
    $null = New-TestPlugin (Join-Path $renamed 'Plugins\other') -Name 'example'
    Assert-Throws { Test-FlintSetup $renamed } "*Plugins\other: the folder name must match the plugin name 'example'*"
    $broken = New-TestSetup (Join-Path $TestRoot 'source\broken') -Plugins @()
    $null = New-TestPlugin (Join-Path $broken 'Plugins\example') -Manifest @{ guide = 'missing.md' }
    Assert-Throws { Test-FlintSetup $broken } '*Plugins\example*guide refers to*'
    $missingTemplate = Join-Path $TestRoot 'source\empty'
    New-Item -ItemType Directory -Path $missingTemplate | Out-Null
    Assert-Throws { Test-FlintSetup $missingTemplate } '*No flint.ini was found*'

    # Setup writes flint.ini with the pasted key and installs the plugins through staging.
    $configDirectory = Join-Path $TestRoot 'runtime'
    New-Item -ItemType Directory -Path $configDirectory | Out-Null
    $configPath = Join-Path $configDirectory 'flint.ini'
    $installRoot = Join-Path $configDirectory 'plugins'
    $script:KeyInput = ''
    Assert-Throws { Install-FlintSetup $source $configPath $installRoot } '*An API key is required*'
    Assert-True (-not (Test-Path -LiteralPath $configPath) -and -not (Test-Path -LiteralPath $installRoot)) 'Change nothing without a key.'
    $script:KeyInput = 'bad' + [string][char]7 + 'key'
    Assert-Throws { Install-FlintSetup $source $configPath $installRoot } '*control characters*'
    $script:KeyInput = '  first-key  '; $script:KeyPrompts = @()
    $result = Install-FlintSetup $source $configPath $installRoot
    $written = Read-TestConfig $configPath
    Assert-True ($written['model.api_key'] -ceq 'first-key' -and $written['model.deployment'] -ceq 'team-model' -and $written['model.api_key_help'] -ceq 'Ask the team for the key.') 'Write the template and the trimmed key to flint.ini.'
    Assert-True ($KeyPrompts.Count -eq 1 -and -not $KeyPrompts[0]) 'Ask for a key without offering to keep one that does not exist.'
    Assert-True ((Get-Content -LiteralPath $configPath -Encoding UTF8)[0] -like '; Written by agent.ps1 -Setup from *') 'Mark flint.ini as generated.'
    $config = Read-FlintConfig $configPath
    Assert-True ($config.ApiKey -ceq 'first-key' -and $config.ApiKeyHelp -ceq 'Ask the team for the key.') 'Flint starts from the written configuration.'
    Assert-True ((Test-Path -LiteralPath (Join-Path $installRoot 'example\plugin.json')) -and @($result.removed).Count -eq 0) 'Install the setup plugins.'
    $record = ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $installRoot 'example.source.json') -Raw -Encoding UTF8)
    Assert-True ($record.kind -ceq 'directory' -and $record.source -ceq (Get-Item -LiteralPath $source).FullName -and $record.plugin_version -ceq '1.0.0' -and $record.installed_at) 'Record where each plugin came from.'
    Assert-True (@(Get-ChildItem -LiteralPath $installRoot -Force | Where-Object { $_.Name.StartsWith('.') }).Count -eq 0) 'Leave no staging or backup directories behind.'

    $script:KeyInput = ''; $script:KeyPrompts = @()
    $null = New-TestPlugin (Join-Path $source 'Plugins\example') -Version '1.1.0'
    $null = Install-FlintSetup $source $configPath $installRoot
    Assert-True ($KeyPrompts[0] -and (Read-TestConfig $configPath)['model.api_key'] -ceq 'first-key') 'Enter keeps the current key when setup runs again.'
    Assert-True ((Test-FlintPlugin (Join-Path $installRoot 'example')).version -ceq '1.1.0') 'Running setup again updates the plugins.'
    $script:KeyInput = 'second-key'
    $null = Install-FlintSetup $source $configPath $installRoot
    Assert-True ((Read-TestConfig $configPath)['model.api_key'] -ceq 'second-key') 'A pasted key replaces the current one.'

    # The setup folder is the only source of plugins: plugins it drops are removed.
    $next = New-TestSetup (Join-Path $TestRoot 'source\next') -Plugins @('second') -Template @('[model]', $endpoint, 'deployment = next-model')
    $script:KeyInput = ''
    $result = Install-FlintSetup $next $configPath $installRoot
    $written = Read-TestConfig $configPath
    Assert-True ((@($result.removed) -join ',') -ceq 'example' -and -not (Test-Path -LiteralPath (Join-Path $installRoot 'example')) -and -not (Test-Path -LiteralPath (Join-Path $installRoot 'example.source.json'))) 'Remove plugins the setup no longer includes.'
    Assert-True ((Test-Path -LiteralPath (Join-Path $installRoot 'second\plugin.json')) -and $written['model.deployment'] -ceq 'next-model' -and -not $written.ContainsKey('model.api_key_help') -and $written['model.api_key'] -ceq 'second-key') 'Follow the new template and keep the key.'
    $before = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    Assert-Throws { Install-FlintSetup $broken $configPath $installRoot } '*guide refers to*'
    Assert-True ((Get-Content -LiteralPath $configPath -Raw -Encoding UTF8) -ceq $before -and (Test-Path -LiteralPath (Join-Path $installRoot 'second'))) 'A rejected setup changes neither flint.ini nor the plugins.'
    $longParent = Join-Path $TestRoot ('p' * (212 - $TestRoot.Length))
    $script:KeyInput = 'long-key'
    Assert-Throws { Install-FlintSetup $source (Join-Path $TestRoot 'long.ini') $longParent } '*longer than 240 characters*'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestRoot 'long.ini')) -and @(Get-ChildItem -LiteralPath $TestRoot -Filter '.flint-*' -Force).Count -eq 0) 'A failed plugin sync leaves flint.ini unchanged and removes the staged copy.'

    # ConfigFile is checked before the key prompt and before any change; a bare file name is relative to the current folder.
    $untouched = Join-Path $TestRoot 'untouched-plugins'
    $script:KeyPrompts = @()
    Assert-Throws { Install-FlintSetup $source $configDirectory $untouched } '*ConfigFile must name a file*is a folder*'
    Assert-Throws { Install-FlintSetup $source (Join-Path $TestRoot 'missing\flint.ini') $untouched } '*folder for ConfigFile does not exist*'
    Assert-True ($KeyPrompts.Count -eq 0 -and -not (Test-Path -LiteralPath $untouched)) 'Reject a folder or a missing parent before asking for the key or changing plugins.'
    $script:KeyInput = 'relative-key'
    Push-Location $configDirectory
    try { $result = Install-FlintSetup $source 'team.ini' (Join-Path $TestRoot 'relative-plugins') } finally { Pop-Location }
    $expected = Join-Path $configDirectory 'team.ini'
    Assert-True ($result.config -ieq $expected -and (Read-TestConfig $expected)['model.api_key'] -ceq 'relative-key') 'Write a bare file name to the current folder and return its full path.'

    # Archives from the Azure DevOps download button contain one top-level folder; flint.ini at the root also works.
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $nested = Join-Path $TestRoot 'nested.zip'
    & $tar -a -c -f $nested -C (Join-Path $TestRoot 'source') team
    Assert-True ($LASTEXITCODE -eq 0) 'Create a nested archive fixture.'
    $flat = Join-Path $TestRoot 'flat.zip'
    & $tar -a -c -f $flat -C $source .
    Assert-True ($LASTEXITCODE -eq 0) 'Create a flat archive fixture.'
    $twoFolders = Join-Path $TestRoot 'two.zip'
    & $tar -a -c -f $twoFolders -C (Join-Path $TestRoot 'source') team bare
    Assert-True ($LASTEXITCODE -eq 0) 'Create an ambiguous archive fixture.'
    $zipRoot = Join-Path $TestRoot 'zip-installed'
    $zipConfig = Join-Path $TestRoot 'zip.ini'
    $script:KeyInput = 'zip-key'
    $null = Install-FlintSetup $nested $zipConfig $zipRoot
    Assert-True ((Test-FlintPlugin (Join-Path $zipRoot 'example')).version -ceq '1.1.0') 'Set up from an archive with one top-level folder.'
    $null = Install-FlintSetup $flat $zipConfig $zipRoot
    Assert-True ((Read-TestConfig $zipConfig)['model.api_key'] -ceq 'zip-key') 'Set up from an archive with flint.ini at its root.'
    Assert-Throws { Install-FlintSetup $twoFolders $zipConfig $zipRoot } '*flint.ini at its root or inside a single top-level folder*'

    # A compiled stand-in for git.exe records the exact sparse fetch and serves the setup folder.
    $bin = Join-Path $TestRoot 'bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    Copy-Item -LiteralPath $source -Destination (Join-Path $bin 'remote-setup') -Recurse
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
            if (args[4] == "team/flint") CopyDirectory(Path.Combine(root, "remote-setup"), Path.Combine(args[1], "team", "flint"));
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
    $gitConfig = Join-Path $TestRoot 'git.ini'
    $url = 'https://user@dev.azure.com/contoso/Project/_git/Repo?path=/team/flint&version=GBmain'
    $script:KeyInput = 'git-key'
    $null = Install-FlintSetup $url $gitConfig $gitRoot
    $plugin = (Read-FlintPlugins $gitRoot).loaded[0]
    Assert-True ($plugin.name -ceq 'example' -and $plugin.source.commit -ceq '0123456789abcdef0123456789abcdef01234567') 'Install the setup fetched by git.'
    $calls = @(Get-Content -LiteralPath (Join-Path $bin 'git-calls.txt') -Encoding UTF8)
    Assert-True ($calls.Count -eq 3) ('Run exactly clone, sparse-checkout and rev-parse: ' + ($calls -join ' / '))
    Assert-True ($calls[0] -like 'clone|--quiet|--depth|1|--filter=blob:none|--sparse|--branch|main|--|https://dev.azure.com/contoso/Project/_git/Repo|*\repository') ('Clone shallow, blobless and sparse from the credential-free URL: ' + $calls[0])
    Assert-True ($calls[1] -like '-C|*\repository|sparse-checkout|set|team/flint') 'Check out only the setup folder.'
    Assert-True ($calls[2] -like '-C|*\repository|rev-parse|HEAD') 'Record the fetched commit.'
    $work = Split-Path (($calls[0] -split '\|')[-1]) -Parent
    Assert-True (-not (Test-Path -LiteralPath $work)) 'Remove the temporary clone after setup.'
    $record = ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $gitRoot 'example.source.json') -Raw -Encoding UTF8)
    Assert-True ($record.kind -ceq 'git' -and $record.ref -ceq 'main' -and $record.path -ceq 'team/flint/Plugins/example' -and $record.source -ceq 'https://dev.azure.com/contoso/Project/_git/Repo?path=/team/flint&version=GBmain') 'Record the repository, branch and plugin folder without credentials.'
    Assert-True ((Get-Content -LiteralPath $gitConfig -Encoding UTF8)[0] -like '*from https://dev.azure.com/contoso/Project/_git/Repo?path=/team/flint&version=GBmain.*') 'Name the setup source in flint.ini.'
    Assert-Throws { Install-FlintSetup 'https://dev.azure.com/contoso/Project/_git/Repo?path=/team/missing' $gitConfig $gitRoot } "*has no folder '/team/missing' on the default branch*"
    $message = ''
    try { $null = Install-FlintSetup 'https://dev.azure.com/contoso/Project/_git/Repo?path=/team/flint&version=GBmissing-branch' $gitConfig $gitRoot } catch { $message = $_.Exception.Message }
    Assert-True ($message -like "*Branch or tag 'missing-branch' was not found in https://dev.azure.com/contoso/Project/_git/Repo*version=*" -and $message -notlike '*Sign in*') ('Report a missing branch without suggesting a sign-in problem: ' + $message)
    Set-Content -LiteralPath (Join-Path $bin 'fail-clone.txt') -Value 'x' -Encoding UTF8
    Assert-Throws { Install-FlintSetup $url $gitConfig $gitRoot } '*git clone ended with error*Authentication failed*Sign in to Azure DevOps first: run "git clone https://dev.azure.com/contoso/Project/_git/Repo" once*'
    Assert-True ((Test-FlintPlugin (Join-Path $gitRoot 'example')).name -ceq 'example') 'A failed fetch keeps the installed plugins.'
    $env:PATH = $WorkRoot
    Assert-Throws { Install-FlintSetup $url $gitConfig $gitRoot } '*git was not found on PATH*'
    Write-Host 'All setup tests passed.'
} finally { $env:PATH = $savedPath; Remove-TestFixture }
