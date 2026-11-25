#Requires -Version 5.1
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'TestSupport.ps1')
$savedPath = $env:PATH
function Read-FlintCommandApproval { param($Session, $Invocation); return 'y' }
try {
    # Compile a local argv recorder with the Windows .NET compiler. No cloud tools or network are used.
    $source = Join-Path $TestRoot 'Recorder.cs'
    Set-Content -LiteralPath $source -Encoding UTF8 -Value @'
using System;
using System.Text;
using System.Threading;
class Recorder {
    static string Quote(string value) {
        var text = new StringBuilder("\"");
        foreach (char c in value) {
            if (c == '\\' || c == '"') text.Append('\\');
            text.Append(c);
        }
        return text.Append('"').ToString();
    }
    static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        if (Environment.GetEnvironmentVariable("FLINT_MODEL_API_KEY") != null) return 98;
        if (args.Length > 0 && args[0] == "fail") { Console.Write("partial"); Console.Error.Write("failure"); return 7; }
        if (args.Length > 0 && args[0] == "empty") return 0;
        if (args.Length > 0 && args[0] == "sleep") Thread.Sleep(30000);
        if (args.Length > 0 && args[0] == "large") {
            // Bounded lines let redirected readers publish output before EOF.
            string line = new string('x', 4096);
            for (int i = 0; i < 300; i++) Console.WriteLine(line);
            return 0;
        }
        if (args.Length > 1 && args[0] == "get" && args[1] == "deployments") {
            Console.Write("{\"kind\":\"DeploymentList\",\"metadata\":{\"continue\":\"next-page\"},\"items\":[{\"name\":\"first\",\"padding\":\"" + new string('x', 600000) + "\"},{\"name\":\"last-record\",\"password\":\"private-value\"}]}");
            Console.Error.Write("Fixture warning on stderr.");
            return 0;
        }
        Console.Write("[" + string.Join(",", Array.ConvertAll(args, Quote)) + "]");
        return 0;
    }
}
'@
    $executable = Join-Path $TestRoot 'kubectl.exe'
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe ('/out:' + $executable) $source
    Assert-True ($LASTEXITCODE -eq 0) 'Compile the offline native command fixture.'
    $env:PATH = $TestRoot
    $savedKey = $env:FLINT_MODEL_API_KEY; $env:FLINT_MODEL_API_KEY = 'must-not-reach-command'
    try { $result = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('version', '--client') } } finally { $env:FLINT_MODEL_API_KEY = $savedKey }
    Assert-True ($result.status -eq 'ok' -and $result.output -ceq '["version","--client"]') ('Execute validated arguments in a constrained worker without inherited credentials. ' + $result.output)
    $finished = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json -InputObject $_ } | Where-Object { $_.event -eq 'tool_finished' })[-1]
    $timing = $finished.timing
    Assert-True ($timing.total_ms -ge $timing.process_ms -and $timing.process_ms -ge $timing.worker.run_ms -and $timing.worker.load_ms -gt 0 -and
        $timing.worker.run_ms -ge $timing.worker.call_ms -and $timing.worker.call_ms -gt 0 -and $null -ne $timing.read_ms) 'Record where a command call spends its time.'
    Assert-True ($null -eq $result.timing -and $null -eq $finished.data.result.timing -and $result.duration_ms -eq $timing.total_ms) 'Keep timings in the trajectory, out of the result the model reads.'
    $unicode = ConvertFrom-Json '"\u4f60\u597d"'
    $tokens = @('echo', '', 'a b', 'a"b', 'C:\path with spaces\', 'x\\"y', 'a&b|c>file', '%PATH%', '!value!', '$(whoami)', $unicode)
    $result = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = $tokens }
    $actual = ConvertFrom-Json -InputObject $result.output
    Assert-True ($result.status -eq 'ok' -and $actual.Count -eq $tokens.Count) ('Preserve the native argument array. ' + $result.output)
    for ($i = 0; $i -lt $tokens.Count; $i++) { Assert-True ($actual[$i] -ceq $tokens[$i]) ('Preserve literal argument ' + $i) }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $WorkRoot 'file'))) 'Metacharacters must not reach a command shell.'
    $result = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('fail') }
    Assert-True ($result.status -eq 'error' -and $result.exit_code -eq 7 -and $result.output.Contains('partial') -and $result.output.Contains('failure')) 'Keep native exit codes and both output streams.'
    Assert-True ((Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('empty') }).output -ceq '') 'Allow empty successful command output.'
    $result = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('get', 'deployments', '--context', 'cc-test', '--namespace', 'team', '--output', 'json') }
    Assert-True ($result.status -eq 'ok' -and $result.preview_truncated -and $result.output.Length -le 16384 -and -not $result.capture_incomplete) 'Save command output beyond the worker result limit before returning a bounded preview.'
    $saved = Get-Content -LiteralPath $result.result_path -Raw -Encoding UTF8
    $data = ConvertFrom-Json -InputObject $saved
    Assert-True ($data.items.Count -eq 2 -and $data.items[0].padding.Length -eq 600000 -and $data.items[1].name -ceq 'last-record') 'Preserve the complete Kubernetes JSON without mixing stderr into it.'
    Assert-True ($result.item_count -eq 2 -and $result.next_continue -ceq 'next-page') 'Expose Kubernetes list counts and continuation separately from previews.'
    Assert-True (-not $saved.Contains('private-value') -and $data.items[1].password -ceq '[redacted]') 'Apply the existing redaction before persisting command results.'
    Assert-True ((Get-Content -LiteralPath $result.stderr_result_path -Raw).Contains('Fixture warning')) 'Preserve diagnostic stderr separately.'
    $search = Invoke-TestTool search_text @{ path = $result.result_path; keyword = 'last-record' }
    Assert-True ($search.status -eq 'ok' -and $search.matches_returned -eq 1) 'Search the saved command response past the preview boundary.'
    $patch = '[{"op":"test","path":"/metadata/resourceVersion","value":"15"},{"op":"replace","path":"/spec/workload/0/manifest/spec/replicas","value":6}]'
    $result = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('patch', 'deployments', 'demo', '--context', 'cc-test', '--namespace', 'team', '--type=json', '--patch', $patch) }
    Assert-True ($result.status -eq 'ok' -and $result.verification_required -and -not $result.outcome_unknown) 'Require state verification after a successful scoped mutation.'
    $actual = ConvertFrom-Json -InputObject $result.output
    Assert-True ($actual[-1] -ceq $patch) 'Pass the reviewed JSON patch to the native process without shell interpolation.'
    $Session.ToolTimeoutSec = 2
    Assert-True ((Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('sleep') }).status -eq 'timeout') 'Bound the entire worker and native process tree.'
    $Session.ToolTimeoutSec = 30
    $oversized = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('large') }
    Assert-True ($oversized.status -eq 'output_limit') ('Bound native output collection. Got ' + $oversized.status + ': ' + $oversized.output)
    Assert-True ((Invoke-TestTool run_command @{ executor = 'az'; arguments = @('version') }).status -eq 'error') 'Azure CLI cannot be used to bypass session authentication.'
    $env:PATH = $WorkRoot
    Assert-True ((Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('version', '--client') }).output -like '*kubectl*not found*') 'Report unavailable executors without launching anything.'
    Write-Host 'All command tests passed.'
} finally { $env:PATH = $savedPath; Remove-TestFixture }
