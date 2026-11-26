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
        if (Array.Exists(args, a => a.Contains("slow-pod"))) Thread.Sleep(3000);
        if (Array.Exists(args, a => a.Contains("signin-cluster") || a.Contains("flaky-cluster"))) {
            // Mimic a credential plugin: print a device-code prompt and wait, until a sign-in leaves a cached marker.
            string marker = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "signed-in.marker");
            if (args[0] == "version") { System.IO.File.WriteAllText(marker, "signed in"); Console.Error.WriteLine("Fixture sign-in complete."); return 0; }
            if (!System.IO.File.Exists(marker)) {
                Console.Error.WriteLine("To sign in, use a web browser to open the page https://login.example.com/device and enter the code FIXTURE42 to authenticate.");
                Console.Error.Flush();
                Thread.Sleep(30000);
                return 1;
            }
            // After signing in, the flaky cluster fails once with a transient error.
            string flaky = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "flaky-once.marker");
            if (Array.Exists(args, a => a.Contains("flaky-cluster")) && !System.IO.File.Exists(flaky)) {
                System.IO.File.WriteAllText(flaky, "failed once");
                Console.Error.Write("Error from server (ServiceUnavailable): fixture transient failure");
                return 1;
            }
        }
        if (Array.Exists(args, a => a.Contains("noisy-cluster"))) {
            // A plugin that prints long diagnostics before its prompt; its sign-in never completes.
            if (args[0] == "version") return 1;
            for (int i = 0; i < 100; i++) Console.Error.WriteLine("diagnostic " + new string('d', 800));
            Console.Error.WriteLine("To sign in, use a web browser to open the page https://login.example.com/device and enter the code NOISY42 to authenticate.");
            Console.Error.Flush();
            Thread.Sleep(30000);
            return 1;
        }
        if (args.Length > 0 && args[0] == "hang") { Console.Error.WriteLine("Unable to connect to the server: fixture i/o timeout"); Console.Error.Flush(); Thread.Sleep(30000); return 1; }
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
    # A credential plugin waiting for a device-code sign-in stops at the prompt instead of running into the timeout.
    $marker = Join-Path $TestRoot 'signed-in.marker'
    $read = @('get', 'pods', '--context', 'signin-cluster', '--namespace', 'team')
    $prompted = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = $read }
    Assert-True ($prompted.status -eq 'sign_in_required' -and $prompted.duration_ms -lt 15000 -and $prompted.output.Contains('not a network or cluster failure')) ('Stop at a sign-in prompt and explain it without a terminal. ' + $prompted.output)
    $events = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json -InputObject $_ } | Where-Object { $_.event -eq 'command_sign_in' })
    Assert-True ($events.Count -eq 1 -and -not $events[0].data.approved -and -not (Test-Path -LiteralPath $marker)) 'Never sign in without an answer from the user.'
    $script:SignInAnswers = 0; $script:SignInArguments = @()
    function Read-FlintSignInApproval { param($Session, $Arguments); $script:SignInAnswers++; $script:SignInArguments = $Arguments; return 'y' }
    # The fixture exits 98 when it sees this variable, so the sign-in also proves Flint's own credentials stay hidden.
    $savedKey = $env:FLINT_MODEL_API_KEY; $env:FLINT_MODEL_API_KEY = 'must-not-reach-sign-in'
    try { $signedIn = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = $read } } finally { $env:FLINT_MODEL_API_KEY = $savedKey }
    Assert-True ($signedIn.status -eq 'ok' -and $signedIn.output.Contains('signin-cluster') -and $script:SignInAnswers -eq 1) ('Sign in when the user agrees, then run the read again. ' + $signedIn.output)
    Assert-True (($script:SignInArguments -join ' ') -ceq 'version --context=signin-cluster') 'Sign in with a harmless read for the same context.'
    Remove-Item -LiteralPath $marker -Force
    # A read that signs in starts over with the normal retries for transient errors.
    $flaky = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('get', 'pods', '--context', 'flaky-cluster', '--namespace', 'team') }
    $retries = @(Get-Content -LiteralPath $Session.TrajectoryPath -Encoding UTF8 | ForEach-Object { ConvertFrom-Json -InputObject $_ } | Where-Object { $_.event -eq 'tool_retry' })
    Assert-True ($flaky.status -eq 'ok' -and $flaky.output.Contains('flaky-cluster') -and $retries.Count -eq 1) ('Retry a transient error after signing in. ' + $flaky.output)
    Remove-Item -LiteralPath $marker -Force
    $change = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('scale', 'deployments', 'demo', '--replicas=2', '--context', 'signin-cluster', '--namespace', 'team') }
    Assert-True ($change.status -eq 'sign_in_required' -and $change.outcome_unknown -and $change.output.Contains('submit the same command again') -and (Test-Path -LiteralPath $marker)) 'Sign in for a change but leave rerunning it to the model after a state check.'
    Remove-Item -LiteralPath $marker -Force
    # Parallel reads waiting on the same sign-in ask once, after every other call has finished, then all run again.
    $script:SignInAnswers = 0; $script:SiblingDoneAtSignIn = $null
    function Read-FlintSignInApproval { param($Session, $Arguments); $script:SignInAnswers++; $script:SiblingDoneAtSignIn = $completed.ContainsKey('slow-sibling'); return 'y' }
    $calls = @(
        @{ type = 'function_call'; call_id = 'signin-a'; name = 'run_command'; arguments = (ConvertTo-Json -Compress @{ executor = 'kubectl'; arguments = @('get', 'pods', 'a', '--context', 'signin-cluster', '--namespace', 'team'); purpose = 'Read pod a.' }) },
        @{ type = 'function_call'; call_id = 'signin-b'; name = 'run_command'; arguments = (ConvertTo-Json -Compress @{ executor = 'kubectl'; arguments = @('get', 'pods', 'b', '--context', 'signin-cluster', '--namespace', 'team'); purpose = 'Read pod b.' }) },
        @{ type = 'function_call'; call_id = 'slow-sibling'; name = 'run_command'; arguments = (ConvertTo-Json -Compress @{ executor = 'kubectl'; arguments = @('get', 'pods', 'slow-pod', '--context', 'cc-test', '--namespace', 'team'); purpose = 'Read a slow pod.' }) }
    )
    Assert-True (@($calls | Where-Object { Get-FlintParallelCall $Session $_ }).Count -eq 3) 'Classify the sign-in reads and their sibling for parallel execution.'
    $completed = @{}; $progress = @{ tool_count = 0 }
    Invoke-FlintParallelTools $Session $calls $completed $progress
    $outputs = @{}
    foreach ($item in $Session.History) { if ($item.type -eq 'function_call_output') { $outputs[$item.call_id] = ConvertFrom-Json $item.output } }
    Assert-True ($outputs['signin-a'].status -eq 'ok' -and $outputs['signin-b'].status -eq 'ok' -and $outputs['slow-sibling'].status -eq 'ok' -and $script:SignInAnswers -eq 1) 'Ask once for parallel reads that wait on the same sign-in.'
    Assert-True ($script:SiblingDoneAtSignIn -eq $true) 'Sign in only after other parallel calls finish, so their deadlines stay enforced.'
    Remove-Item -LiteralPath $marker -Force
    $noisy = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('get', 'pods', '--context', 'noisy-cluster', '--namespace', 'team') }
    Assert-True ($noisy.status -eq 'sign_in_required' -and $noisy.duration_ms -lt 15000 -and $noisy.output.Contains('not a network or cluster failure')) ('Find a prompt after long stderr diagnostics, and report a failed sign-in. ' + $noisy.output)
    # Context names are case-sensitive, so a sign-in for one context never stands in for another.
    $script:SignInAnswers = 0
    function Read-FlintSignInApproval { param($Session, $Arguments); $script:SignInAnswers++; return 'n' }
    $Session.CommandSignIns = @(@{ key = '--context=Prod'; completed = [datetime]::UtcNow.AddMinutes(1); signed_in = $true })
    $before = [datetime]::UtcNow
    $other = @{ executor = 'kubectl'; arguments = @('get', 'pods', '--context', 'prod'); program = @{ path = 'unused.exe' } }
    $same = @{ executor = 'kubectl'; arguments = @('get', 'pods', '--context', 'Prod'); program = @{ path = 'unused.exe' } }
    Assert-True (-not (Invoke-FlintCommandSignIn $Session $other $before 'case-other') -and $script:SignInAnswers -eq 1) 'Ask again for a context that differs only in case.'
    Assert-True ((Invoke-FlintCommandSignIn $Session $same $before 'case-same') -and $script:SignInAnswers -eq 1) 'Reuse a sign-in for the same context.'
    # Stop kubectl before the worker deadline so its own output explains the timeout.
    $Session.ToolTimeoutSec = 10
    $hung = Invoke-TestTool run_command @{ executor = 'kubectl'; arguments = @('hang') }
    Assert-True ($hung.status -eq 'timeout' -and $hung.output.Contains('Unable to connect to the server')) ('Return what kubectl printed before a timeout. ' + $hung.output)
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
