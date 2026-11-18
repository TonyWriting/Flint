#Requires -Version 5.1
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
$script:Cases = 0
function New-PluginCase {
    param([hashtable]$Manifest = @{}, [object[]]$Rules)
    $script:Cases++
    return New-TestPlugin (Join-Path $TestRoot ('case-' + $script:Cases)) -Manifest $Manifest -Rules $Rules
}
try {
    $valid = New-PluginCase
    $plugin = Test-FlintPlugin $valid
    Assert-True ($plugin.name -ceq 'example' -and $plugin.version -ceq '1.0.0' -and $plugin.file_count -eq 5) 'Accept a complete data-only plugin.'
    Assert-True (@($plugin.rules).Count -eq 2 -and $plugin.rules[0].source -ceq 'plugin:example') 'Tag plugin rules with their source.'
    Assert-True ((@($plugin.guarded) -join ',') -ceq 'widgets.example.io,widgets') 'Return guarded patch resources in declared order.'
    Assert-True ((Test-Path -LiteralPath $plugin.guide -PathType Leaf) -and $plugin.guide.EndsWith('\guide.md')) 'Resolve the guide to a file inside the plugin.'
    $minimal = New-PluginCase -Manifest @{ kubectl = $null }
    $plugin = Test-FlintPlugin $minimal
    Assert-True (@($plugin.rules).Count -eq 0 -and @($plugin.guarded).Count -eq 0) 'A knowledge-only plugin needs only a manifest and a guide.'
    Assert-True (@(Read-FlintCommandRuleFile (Join-Path $RepoRoot 'tools\permissions\kubectl.json') kubectl core).Count -gt 0) 'The installation rules satisfy the shared rule floor.'

    Assert-Throws { Test-FlintPlugin (Join-Path $TestRoot 'missing') } '*Plugin directory not found*'
    $empty = Join-Path $TestRoot 'empty'
    New-Item -ItemType Directory -Path $empty | Out-Null
    Assert-Throws { Test-FlintPlugin $empty } '*No plugin.json*'
    Assert-Throws { Test-FlintPlugin (New-PluginCase -Manifest @{ schema_version = 2 }) } '*Unsupported plugin schema_version*'
    foreach ($case in @(
        @{ manifest = @{ extra = 'x' }; pattern = "*unknown field 'extra'*" },
        @{ manifest = @{ name = 'Bad_Name' }; pattern = '*name must be*' },
        @{ manifest = @{ version = '1.0' }; pattern = '*MAJOR.MINOR.PATCH*' },
        @{ manifest = @{ summary = '' }; pattern = '*summary must be*' },
        @{ manifest = @{ guide = 'missing.md' }; pattern = '*guide refers to*' },
        @{ manifest = @{ guide = '../outside.md' }; pattern = "*without '.' or '..'*" },
        @{ manifest = @{ guide = 'C:/guide.md' }; pattern = "*relative path inside the plugin*" },
        @{ manifest = @{ guide = 'docs/index.txt' }; pattern = '*must name a .md file*' },
        @{ manifest = @{ docs_index = 'docs/index.md' }; pattern = "*unknown field 'docs_index'*" },
        @{ manifest = @{ kubectl = @{ rules = 'permissions/kubectl.json'; extra = $true } }; pattern = "*kubectl has an unknown field*" },
        @{ manifest = @{ kubectl = @{ guarded_patch_resources = @('Widgets!') } }; pattern = '*invalid resource name*' },
        @{ manifest = @{ kubectl = @{ guarded_patch_resources = @('widgets', 'widgets') } }; pattern = "*repeats 'widgets'*" }
    )) { Assert-Throws { Test-FlintPlugin (New-PluginCase -Manifest $case.manifest) } $case.pattern }

    # Every rule source shares the same floor; plugins cannot widen reads beyond it.
    $unscoped = New-TestRule @('get', 'widgets.example.io')
    $unscoped.options['--context'].required = $false
    $raw = New-TestRule @('get', 'widgets.example.io')
    $raw.options['--raw'] = [ordered]@{ pattern = '^/.*$' }
    # Cross-namespace reads are allowed only as a selector-scoped get.
    $everywhere = New-TestRule @('get', 'widgets.example.io') -ClusterScoped
    $everywhere.options['--all-namespaces'] = [ordered]@{ required = $true; switch = $true }
    $everywhere.options['--selector'] = [ordered]@{ required = $true; pattern = '^[a-z0-9./-]+=[a-z0-9.-]+$' }
    Assert-True (@((Test-FlintPlugin (New-PluginCase -Rules @($everywhere))).rules).Count -eq 1) 'Accept a selector-scoped cross-namespace get.'
    $unselected = New-TestRule @('get', 'widgets.example.io') -ClusterScoped
    $unselected.options['--all-namespaces'] = [ordered]@{ required = $true; switch = $true }
    $mixed = New-TestRule @('get', 'widgets.example.io')
    $mixed.options['--all-namespaces'] = [ordered]@{ required = $true; switch = $true }
    $mixed.options['--selector'] = [ordered]@{ required = $true; pattern = '^[a-z]+=[a-z]+$' }
    foreach ($case in @(
        @{ rules = @($unselected); pattern = '*--all-namespaces only with get*required --selector*' },
        @{ rules = @($mixed); pattern = '*--all-namespaces only with get*without --namespace*' },
        @{ rules = @((New-TestRule @('get', 'secrets'))); pattern = '*cannot read Secrets*' },
        @{ rules = @((New-TestRule @('get', 'secret.v1'))); pattern = '*cannot read Secrets*' },
        @{ rules = @((New-TestRule @('delete', 'widgets.example.io'))); pattern = '*must use get, describe*' },
        @{ rules = @((New-TestRule @('get'))); pattern = '*exactly one resource type*' },
        @{ rules = @($raw); pattern = '*cannot allow option --raw*' },
        @{ rules = @($unscoped); pattern = '*must require --context*' }
    )) { Assert-Throws { Test-FlintPlugin (New-PluginCase -Rules $case.rules) } ('*kubectl.rules*' + $case.pattern) }
    # Log rules must stay bounded to one pod's recent output.
    function New-LogsRule {
        param([string]$Tail = '^([1-9][0-9]{0,2}|1000)$', [switch]$Optional)
        $options = [ordered]@{
            '--context' = [ordered]@{ required = $true; pattern = '^[a-z0-9-]+$' }
            '--namespace' = [ordered]@{ required = $true; pattern = '^[a-z0-9-]+$' }
            '--tail' = [ordered]@{ required = (-not $Optional); pattern = $Tail }
        }
        return [ordered]@{ command = @('logs'); read_only = $true; options = $options; positionals = [ordered]@{ max = 1; pattern = '^[a-z0-9.-]+$' } }
    }
    Assert-True (@((Test-FlintPlugin (New-PluginCase -Rules @((New-LogsRule)))).rules).Count -eq 1) 'Accept a bounded log rule.'
    $follow = New-LogsRule
    $follow.options['--follow'] = [ordered]@{ switch = $true }
    $since = New-LogsRule
    $since.options['--since'] = [ordered]@{ pattern = '^[0-9]+h$' }
    foreach ($case in @(
        @{ rules = @($follow); pattern = '*cannot allow option --follow*' },
        @{ rules = @((New-LogsRule -Optional)); pattern = '*must require --tail*' },
        @{ rules = @((New-LogsRule -Tail '^[0-9]+$')); pattern = '*1 to 1000 lines only*' },
        @{ rules = @($since); pattern = '*--since only with a pattern limited to one hour*' }
    )) { Assert-Throws { Test-FlintPlugin (New-PluginCase -Rules $case.rules) } ('*kubectl.rules*' + $case.pattern) }
    $writeRule = New-TestRule @('get', 'widgets.example.io')
    $writeRule.read_only = $false
    Assert-Throws { Test-FlintPlugin (New-PluginCase -Rules @($writeRule)) } '*read-only*'

    $script = New-PluginCase
    Set-Content -LiteralPath (Join-Path $script 'tool.ps1') -Value 'Write-Host hi' -Encoding UTF8
    Assert-Throws { Test-FlintPlugin $script } '*tool.ps1: only .md, .json and .txt files are allowed*'
    $hidden = New-PluginCase
    Set-Content -LiteralPath (Join-Path $hidden '.env') -Value 'TOKEN=1' -Encoding UTF8
    Assert-Throws { Test-FlintPlugin $hidden } '*.env*protected*'
    $large = New-PluginCase
    Set-Content -LiteralPath (Join-Path $large 'docs\large.md') -Value ('x' * 1048577) -Encoding ASCII -NoNewline
    Assert-Throws { Test-FlintPlugin $large } '*large.md: files are limited to 1 MiB*'
    $deep = New-PluginCase
    $deepDirectory = Join-Path $deep ('docs\' + ('d' * 116))
    New-Item -ItemType Directory -Path $deepDirectory | Out-Null
    Assert-Throws { Test-FlintPlugin $deep } '*relative paths are limited to 120 characters*'
    $linked = New-PluginCase
    $outside = Join-Path $TestRoot 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $null = & cmd.exe /d /c mklink /J (Join-Path $linked 'docs\linked') $outside
    Assert-True ($LASTEXITCODE -eq 0) 'Create a junction fixture.'
    Assert-Throws { Test-FlintPlugin $linked } '*linked: symlinks and junctions are not allowed*'
    $null = & cmd.exe /d /c rmdir (Join-Path $linked 'docs\linked')
    $several = New-PluginCase -Manifest @{ version = 'x'; extra = 1 }
    $message = ''
    try { $null = Test-FlintPlugin $several } catch { $message = $_.Exception.Message }
    Assert-True ($message -like '*unknown field*' -and $message -like '*MAJOR.MINOR.PATCH*') 'Report every validation error at once.'
    Write-Host 'All plugin validation tests passed.'
} finally { Remove-TestFixture }
