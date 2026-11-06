#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
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
        if (Environment.GetEnvironmentVariable("AZURE_OPENAI_API_KEY") != null || Environment.GetEnvironmentVariable("FLINT_MODEL_API_KEY") != null) return 98;
        if (args.Length > 0 && args[0] == "fail") { Console.Write("partial"); Console.Error.Write("failure"); return 7; }
        if (args.Length > 0 && args[0] == "empty") return 0;
        if (args.Length > 0 && args[0] == "sleep") Thread.Sleep(30000);
        if (args.Length > 0 && args[0] == "large") { Console.Write(new string('x', 1100000)); return 0; }
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
    $savedKey = $env:AZURE_OPENAI_API_KEY; $env:AZURE_OPENAI_API_KEY = 'must-not-reach-command'
    try { $result = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('version', '--client') } } finally { $env:AZURE_OPENAI_API_KEY = $savedKey }
    Assert-True ($result.status -eq 'ok' -and $result.output -ceq '["version","--client"]') ('Execute validated arguments in a constrained worker without inherited credentials. ' + $result.output)
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
    $Session.ToolTimeoutSec = 2
    Assert-True ((Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('sleep') }).status -eq 'timeout') 'Bound the entire worker and native process tree.'
    $Session.ToolTimeoutSec = 30
    Assert-True ((Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('large') }).status -eq 'output_limit') 'Bound native output collection.'
    Assert-True ((Invoke-TestTool run_command @{ executor = 'az'; arguments = @('version') }).status -eq 'error') 'Azure CLI cannot be used to bypass session authentication.'
    $env:PATH = $WorkRoot
    Assert-True ((Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('version', '--client') }).output -like '*kubectl*not found*') 'Report unavailable executors without launching anything.'
    Write-Host 'All command tests passed.'
} finally { $env:PATH = $savedPath; Remove-TestFixture }
