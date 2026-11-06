#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:Writes = @(); $script:TerminalWidth = 100
function Write-Host {
    param($Object, [switch]$NoNewline, [string]$ForegroundColor)
    $script:Writes += @{ text = [string]$Object; inline = [bool]$NoNewline; color = $ForegroundColor }
}
function Get-FlintTerminalWidth { return $script:TerminalWidth }
function Get-UiText {
    return (@($script:Writes | ForEach-Object { if ($_.inline) { $_.text } else { $_.text + "`n" } }) -join '')
}
function Read-Host { return 'A question' }
try {
    Show-FlintSession $Session
    $startup = Get-UiText
    Assert-True ($startup.Contains($Session.Model) -and $startup.Contains('/help')) 'Show the model and a short command hint.'
    foreach ($noise in @('Trajectory:', 'tokens:', 'unknown', '-ContextWindow', 'calls:')) {
        Assert-True (-not $startup.Contains($noise)) 'Keep diagnostics out of the default header.'
    }
    $script:Writes = @()
    Show-FlintSession $Session -Details
    Assert-True ((Get-UiText).Contains($Session.TrajectoryPath) -and (Get-UiText).Contains('Model calls:')) 'Expose diagnostics only when explicitly requested.'
    $script:Writes = @()
    $prompt = Read-FlintPrompt $Session
    Assert-True ($prompt -ceq 'A question' -and (Get-UiText).Trim() -ceq '>') 'Read input with only the native prompt.'
    $Session.ContextWindow = 1000; $Session.LastInputTokens = 100
    $script:Writes = @()
    $null = Read-FlintPrompt $Session
    Assert-True ((Get-UiText).Trim() -ceq '>') 'Keep usage details out of the input area.'
    $script:Writes = @()
    Show-FlintHelp $Session
    Assert-True ((Get-UiText).Contains('Ctrl+C') -and -not (Get-UiText).Contains('Esc') -and -not (Get-UiText).Contains('Shift+Enter')) 'Advertise only supported input shortcuts.'

    $Session.Ui.Live = $true; $Session.Ui.Ansi = $false
    Start-FlintTurnUi $Session
    $Session.Ui.Started = [datetime]::UtcNow.AddSeconds(-18.1)
    $script:Writes = @()
    Show-FlintActivity $Session 'Thinking'
    $count = $script:Writes.Count
    Update-FlintProgress $Session
    Assert-True ($script:Writes.Count -eq $count) 'Do not repaint the same elapsed second.'
    $Session.Ui.Started = [datetime]::UtcNow.AddSeconds(-19.1)
    Update-FlintProgress $Session
    Assert-True ((Get-UiText).Contains('Working (18s') -and (Get-UiText).Contains('Working (19s')) 'Advance elapsed seconds in place.'
    Assert-True (@($script:Writes | Where-Object { -not $_.inline }).Count -eq 0) 'Never scroll the transcript for timer updates.'
    Assert-True (@($script:Writes | Where-Object { $_.text.StartsWith("`r") }).Count -gt 0) 'Erase the previous frame before drawing the next one.'
    $script:TerminalWidth = 30
    Show-FlintActivity $Session 'Running kubectl'
    Assert-True ($Session.Ui.Width -lt 30) 'Keep a progress frame within the terminal width.'
    Stop-FlintTurnUi $Session
    Assert-True ($Session.Ui.Width -eq 0 -and -not $Session.Ui.Active) 'Remove the timer at completion.'

    $script:Writes = @()
    Show-FlintToolResult $Session 'write_file' @{ path = 'report.md' } @{ status = 'ok'; exit_code = 0; duration_ms = 942; output = 'Repeated raw output' }
    Assert-True ((Get-UiText).Contains('Wrote report.md') -and -not (Get-UiText).Contains('942') -and -not (Get-UiText).Contains('Repeated raw output')) 'Summarize successful tools without duplicate data or timing noise.'
    $script:Writes = @()
    Show-FlintToolResult $Session 'read_file' @{ path = 'note.txt' } @{ status = 'error'; exit_code = 7; output = 'Access denied test-api-key' }
    Assert-True ((Get-UiText).Contains('exit 7') -and (Get-UiText).Contains('Access denied') -and -not (Get-UiText).Contains('test-api-key')) 'Keep failures actionable and redact credentials.'

    $script:Writes = @()
    $markdown = @'
## Summary
**Files**
- `notes.txt`
```powershell
Write-Host "**keep** `literal`"
```
    **indented code**
> A quote
'@
    Write-FlintMarkdown $markdown $Session
    $rendered = Get-UiText
    Assert-True ($rendered.Contains('Summary') -and -not $rendered.Contains('## Summary') -and -not $rendered.Contains('**Files**') -and -not $rendered.Contains('`notes.txt`')) 'Render headings, emphasis and inline code.'
    Assert-True ($rendered.Contains('Write-Host "**keep** `literal`"') -and $rendered.Contains('    **indented code**')) 'Preserve fenced and indented code literally.'
    Assert-True (-not $rendered.Contains('```')) 'Hide code fences in the presentation.'
    Assert-True (@($script:Writes | Where-Object { $_.text -eq 'notes.txt' -and $_.color -eq 'Blue' }).Count -eq 1) 'Keep reply code distinct from user input.'
    $script:Writes = @()
    Write-FlintMarkdown ('safe' + [char]27 + '[2Jtest-api-key') $Session
    Assert-True (-not (Get-UiText).Contains([string][char]27) -and -not (Get-UiText).Contains('test-api-key')) 'Do not interpret terminal controls supplied by the model.'

    $script:Writes = @(); $script:TerminalWidth = 100
    Write-FlintMarkdown '[**OpenAI**](https://www.openai.com "Visit") and [topic](https://example.com/a_(b)) and <https://example.org> and `[[raw]](url)`' $Session
    $rendered = Get-UiText
    Assert-True ($rendered.Contains('OpenAI (https://www.openai.com)') -and $rendered.Contains('topic (https://example.com/a_(b))')) 'Render link labels and complete URLs, including titles and balanced parentheses.'
    Assert-True (-not $rendered.Contains('[**OpenAI**]') -and -not $rendered.Contains('<https://example.org>') -and $rendered.Contains('[[raw]](url)')) 'Remove link markup outside code and keep inline code literal.'
    Assert-True (-not $rendered.Contains([string][char]27)) 'Keep plain link fallback free of terminal controls.'
    $script:Writes = @()
    Write-FlintMarkdown '[sample.md](sample.md) [`sample.md`](sample.md) [**sample.md**](sample.md) [sample\.md](sample.md) [sample.md](notes/sample.md)' $Session
    Assert-True ((Get-UiText).Trim() -ceq 'sample.md sample.md sample.md sample.md sample.md (notes/sample.md)') 'Compare the rendered label to the target, keeping distinct paths visible.'
    $Session.Ui.Ansi = $true
    $script:Writes = @()
    Write-FlintMarkdown ('[OpenAI](https://www.openai.com) [bad](javascript:alert) [local](README.md) ' + [char]27 + ']8;;https://injected.example' + [char]7 + 'text' + [char]27 + ']8;;' + [char]7) $Session
    $rendered = Get-UiText
    Assert-True ($rendered.Contains(([string][char]27 + ']8;;https://www.openai.com' + [char]27 + '\'))) 'Make validated web link labels clickable in live VT terminals.'
    Assert-True (-not $rendered.Contains(']8;;javascript:') -and -not $rendered.Contains(']8;;README.md') -and -not $rendered.Contains('injected.example')) 'Never promote unsafe targets or model-supplied controls to terminal links.'
    $Session.Ui.Live = $false; $script:Writes = @()
    Write-FlintMarkdown '[OpenAI](https://www.openai.com)' $Session
    Assert-True (-not (Get-UiText).Contains([string][char]27)) 'Never emit hyperlink escapes when output is redirected.'
    $Session.Ui.Ansi = $false

    $cn = ConvertFrom-Json '{"name":"\u540d\u79f0","state":"\u72b6\u6001","notes":"\u8bf4\u660e","service":"\u670d\u52a1","ok":"\u2705\u6b63\u5e38","warn":"\u26a0\ufe0f\u8b66\u544a","bad":"\u274c\u5f02\u5e38","running":"\u6b63\u5728\u8fd0\u884c","check":"\u9700\u8981\u68c0\u67e5","stopped":"\u5df2\u505c\u6b62"}'
    $table = @(
        "| $($cn.name) | $($cn.state) | $($cn.notes) |", '|---|:---:|---|',
        "| $($cn.service) A | $($cn.ok) | $($cn.running) |", "| $($cn.service) B | $($cn.warn) | $($cn.check) |", "| $($cn.service) C | $($cn.bad) | $($cn.stopped) |"
    ) -join "`n"
    $script:Writes = @(); Write-FlintMarkdown $table $Session
    $rendered = Get-UiText; $bar = [string][char]0x2502
    $expected = $bar + ' ' + $cn.service + ' A ' + $bar + ' ' + $cn.warn + ' ' + $bar + ' ' + $cn.check + ' ' + $bar
    Assert-True ($rendered.Contains($expected.Replace(' A ', ' B '))) 'Align Chinese and variation-selector emoji by terminal cells, not UTF-16 length.'
    Assert-True (-not $rendered.Contains('|---|') -and $rendered.Contains([string][char]0x250c)) 'Replace Markdown table delimiters with a formatted table.'
    foreach ($row in ($rendered.TrimEnd("`n") -split "`n")) { Assert-True ((Get-FlintDisplayWidth $row) -eq 30) 'Keep every table border and row at the same display width.' }
    foreach ($sample in @(
        @{ text = 'abc 123'; width = 7 }, @{ text = $cn.name; width = 4 }, @{ text = $cn.warn; width = 6 },
        @{ text = (ConvertFrom-Json '"e\u0301"'); width = 1 }, @{ text = (ConvertFrom-Json '"\ud83d\udc69\u200d\ud83d\udcbb"'); width = 2 },
        @{ text = (ConvertFrom-Json '"\ud83d\udc4d\ud83c\udffd"'); width = 2 }, @{ text = (ConvertFrom-Json '"1\ufe0f\u20e3"'); width = 2 },
        @{ text = (ConvertFrom-Json '"\ud83c\udde8\ud83c\uddf3"'); width = 2 }
    )) { Assert-True ((Get-FlintDisplayWidth $sample.text) -eq $sample.width) 'Measure common text and emoji without splitting a displayed character.' }

    $script:Writes = @()
    Write-FlintMarkdown @'
Name | Value | Count
:--- | :---: | ---:
**One** | `a|b` | 123
Two | a\|b | 7
Short | value
Extra | value | 8 | retained

Not | a table
still ordinary text
```markdown
[link](https://example.com)
| Raw | Table |
|---|---|
```
    [literal](https://example.com)
'@ $Session
    $rendered = Get-UiText
    Assert-True ($rendered.Contains('a|b') -and -not $rendered.Contains('**One**') -and -not $rendered.Contains('`a|b`')) 'Parse pipes in code and escaped pipes without creating extra columns.'
    Assert-True ($rendered.Contains('   7') -and $rendered.Contains('8 | retained') -and $rendered.Contains('Short')) 'Apply alignment and preserve short and extra table cells.'
    Assert-True ($rendered.Contains('Not | a table') -and $rendered.Contains('| Raw | Table |') -and $rendered.Contains('[link](https://example.com)') -and $rendered.Contains('    [literal](https://example.com)')) 'Require a delimiter row and preserve code block examples literally.'

    foreach ($terminalWidth in @(24, 12)) {
        $script:TerminalWidth = $terminalWidth; $script:Writes = @()
        Write-FlintMarkdown $table $Session
        $rendered = Get-UiText
        foreach ($row in ($rendered -split "`n")) { Assert-True ((Get-FlintDisplayWidth $row) -lt $terminalWidth) 'Wrap or stack tables within a narrow terminal.' }
        Assert-True ($rendered.Contains($cn.service) -and $rendered.Contains($cn.check.Substring(0, 2))) 'Retain table content in narrow layouts.'
    }
    $script:TerminalWidth = 100
    $Session.History = @(
        @{ role = 'user'; content = 'Please keep **literal** test-api-key.' },
        @{ type = 'reasoning'; encrypted_content = 'opaque-private-reasoning'; summary = @() },
        @{ type = 'function_call'; name = 'write_file'; call_id = 'past_write'; arguments = '{"path":"report.md","content":"Hidden raw write body"}' },
        @{ type = 'function_call_output'; call_id = 'past_write'; output = '{"status":"ok","exit_code":0,"output":"Hidden raw tool output"}' },
        @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = "## Prior answer`n**Done**. [docs](https://example.com)" }) },
        @{ role = 'user'; content = @(@{ type = 'input_text'; text = 'And then?' }) },
        @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'refusal'; refusal = 'Saved refusal.' }) }
    )
    $historyBefore = ConvertTo-Json -InputObject $Session.History -Depth 32 -Compress
    $sequenceBefore = $Session.EventSequence; $callsBefore = $Session.ModelCalls
    function Invoke-AgentResponse { throw 'History rendering must not call the model.' }
    function Invoke-AgentTool { throw 'History rendering must not execute tools.' }
    $script:Writes = @(); Show-FlintHistory $Session
    $rendered = Get-UiText
    Assert-True ($rendered.Contains('> Please keep **literal** [redacted].') -and $rendered.Contains('> And then?')) 'Restore user messages literally, with credentials redacted.'
    Assert-True ($rendered.Contains('Prior answer') -and $rendered.Contains('Done. docs (https://example.com)') -and $rendered.Contains('Saved refusal.') -and -not $rendered.Contains('## Prior answer')) 'Render saved assistant replies with the normal Markdown renderer.'
    Assert-True ($rendered.IndexOf('> Please') -lt $rendered.IndexOf('Wrote report.md') -and $rendered.IndexOf('Wrote report.md') -lt $rendered.IndexOf('Prior answer')) 'Display messages and tool results in conversation order.'
    foreach ($hidden in @('test-api-key', 'opaque-private-reasoning', 'Hidden raw write body', 'Hidden raw tool output')) {
        Assert-True (-not $rendered.Contains($hidden)) 'Keep credentials, reasoning and raw tool internals out of the restored transcript.'
    }
    Assert-True ((ConvertTo-Json -InputObject $Session.History -Depth 32 -Compress) -ceq $historyBefore -and $Session.EventSequence -eq $sequenceBefore -and $Session.ModelCalls -eq $callsBefore) 'History display must not change conversation state, usage or the trajectory.'
    $Session.History = @(); $script:Writes = @(); Show-FlintHistory $Session
    Assert-True ($script:Writes.Count -eq 0) 'Show no stale conversation after /clear.'
    $Session.ModelCalls = 3; $Session.UsageReports = 2
    $Session.InputTokens = 1234L; $Session.OutputTokens = 56L; $Session.CachedTokens = 1000L; $Session.ReasoningTokens = 20L
    $Session.CachedReported = $true; $Session.ReasoningReported = $true
    $script:Writes = @(); Show-FlintExit $Session
    $rendered = Get-UiText
    Assert-True ($rendered.Contains('total=1,290 input=1,234 (cached=1,000) output=56 (reasoning=20)')) 'Count cached input and reasoning output once in the exit total.'
    Assert-True ($rendered.Contains('1 request(s) without reported usage') -and $rendered.Contains('-Resume ' + $Session.Id) -and $rendered.Contains('-EnvFile')) 'Show partial usage honestly and print a runnable resume command with custom configuration.'
    $Session.UsageReports = 0
    $script:Writes = @(); Show-FlintExit $Session
    Assert-True ((Get-UiText).Contains('Token usage: not reported') -and -not (Get-UiText).Contains('total=')) 'Never present missing API usage as measured zero tokens.'
    $Session.LogFailed = $true
    $script:Writes = @(); Show-FlintExit $Session
    Assert-True (-not (Get-UiText).Contains('-Resume') -and (Get-UiText).Contains('could not be saved')) 'Do not promise a resumable session after a persistence failure.'
} finally { Remove-TestFixture }
Microsoft.PowerShell.Utility\Write-Host 'All UI tests passed.'
