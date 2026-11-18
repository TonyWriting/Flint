function Get-FlintInlineRuns {
    param([string]$Text, [string]$Color = 'Gray')
    # Keep code spans opaque. URLs may contain escaped or one level of balanced parentheses.
    $token = '(?<ticks>`+)(?<code>.+?)\k<ticks>(?!`)|\*\*(?<bold>.+?)\*\*|' +
        '(?<image>!)?\[(?<label>(?:\\.|[^\]\\])*)\]\(\s*(?<url><[^<>]+>|(?:\\.|[^()\s\\]|\([^()\s]*\))+)(?:\s+"[^"]*"|\s+''[^'']*'')?\s*\)|' +
        '<(?<auto>https?://[^<>\s]+)>|\\(?<escaped>[\\`*{}\[\]()#+.!_|>-])'
    while ($Text -match ('^(?<before>.*?)(?:' + $token + ')(?<after>.*)$')) {
        $match = $Matches
        if ($match.before) { @{ Text = $match.before; Color = $Color; Link = '' } }
        if ($match.ticks) { @{ Text = $match.code; Color = 'Blue'; Link = '' } }
        elseif ($match.bold) { Get-FlintInlineRuns $match.bold 'White' }
        elseif ($match.escaped) { @{ Text = $match.escaped; Color = $Color; Link = '' } }
        else {
            $target = $match.url
            $label = $match.label
            if ($match.auto) { $target = $match.auto; $label = $target }
            $target = $target.Trim('<', '>') -replace '\\([\\()])', '$1'
            $link = ''
            $uri = $target -as [uri]
            if ($uri -and $uri.IsAbsoluteUri -and $uri.Scheme -in @('http', 'https') -and
                -not $uri.UserInfo -and $target -notmatch '[\x00-\x20\x7f-\x9f]') { $link = $target }
            if ($match.image) { @{ Text = 'Image: '; Color = 'DarkGray'; Link = '' } }
            if (-not $label) { $label = $target }
            $labelRuns = @(Get-FlintInlineRuns $label 'Cyan')
            $visibleLabel = ($labelRuns | ForEach-Object { $_.Text }) -join ''
            foreach ($run in $labelRuns) {
                $run.Link = $link
                $run
            }
            if ($visibleLabel -cne $target) { @{ Text = ' (' + $target + ')'; Color = 'DarkGray'; Link = '' } }
        }
        $Text = $match.after
    }
    if ($Text) { @{ Text = $Text; Color = $Color; Link = '' } }
}

function Write-FlintRuns {
    param([object[]]$Runs, [hashtable]$Session, [switch]$NoNewline)
    foreach ($run in $Runs) {
        $text = $run.Text
        # Generate OSC 8 only after sanitization, for validated web URLs in a live VT terminal.
        if ($run.Link -and $Session -and $Session.Ui -and $Session.Ui.Live -and $Session.Ui.Ansi) {
            $escape = [string][char]27
            $text = $escape + ']8;;' + $run.Link + $escape + '\' + $text + $escape + ']8;;' + $escape + '\'
        }
        Write-FlintColoredText $text $Session -Color $run.Color -NoNewline
    }
    if (-not $NoNewline) { Write-Host '' }
}

function Write-FlintInline {
    param([string]$Text, [string]$Color = 'Gray', [hashtable]$Session)
    Write-FlintRuns @(Get-FlintInlineRuns $Text $Color) $Session
}

function Get-FlintDisplayUnits {
    param([string]$Text)
    # PS 5.1 has no modern grapheme enumerator. Keep marks, emoji modifiers, flags and ZWJ sequences together.
    $scalar = '(?:[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\uD800-\uDFFF])'
    $marks = '(?:\p{M}|\uD83C[\uDFFB-\uDFFF]|\uDB40[\uDC20-\uDC7F])*'
    $cluster = '(?:\uD83C[\uDDE6-\uDDFF]){2}|' + $scalar + $marks + '(?:\u200D' + $scalar + $marks + ')*'
    foreach ($unit in ($Text.Replace("`t", '    ') -split ('(' + $cluster + ')'))) {
        if (-not $unit) { continue }
        $code = [int][char]$unit[0]
        if ($code -ge 0xd800 -and $code -le 0xdbff -and $unit.Length -gt 1) {
            $code = 0x10000 + ($code - 0xd800) * 0x400 + [int][char]$unit[1] - 0xdc00
        }
        $width = 1
        if ($unit -match '^[\p{M}\p{Cf}]+$') { $width = 0 }
        elseif ($unit -match '[\uFE0F\u20E3]' -or
            ($code -ge 0x1100 -and $code -le 0x115f) -or $code -in @(0x2329, 0x232a) -or
            ($code -ge 0x2e80 -and $code -le 0xa4cf -and $code -ne 0x303f) -or
            ($code -ge 0xac00 -and $code -le 0xd7a3) -or ($code -ge 0xf900 -and $code -le 0xfaff) -or
            ($code -ge 0xfe10 -and $code -le 0xfe19) -or ($code -ge 0xfe30 -and $code -le 0xfe6f) -or
            ($code -ge 0xff01 -and $code -le 0xff60) -or ($code -ge 0xffe0 -and $code -le 0xffe6) -or
            ($code -ge 0x20000 -and $code -le 0x3fffd) -or
            ($unit -notmatch '\uFE0E' -and (($code -ge 0x1f000 -and $code -le 0x1faff) -or
                $unit -match '^[\u231A\u231B\u23E9-\u23EC\u23F0\u23F3\u25FD\u25FE\u2614\u2615\u2648-\u2653\u267F\u2693\u26A1\u26AA\u26AB\u26BD\u26BE\u26C4\u26C5\u26CE\u26D4\u26EA\u26F2\u26F3\u26F5\u26FA\u26FD\u2705\u270A\u270B\u2728\u274C\u274E\u2753-\u2755\u2757\u2795-\u2797\u27B0\u27BF]'))) { $width = 2 }
        @{ Text = $unit; Width = $width }
    }
}

function Get-FlintDisplayWidth {
    param([string]$Text)
    $width = 0
    foreach ($unit in @(Get-FlintDisplayUnits $Text)) { $width += $unit.Width }
    return $width
}

function Split-FlintRuns {
    param([object[]]$Runs, [int]$Width)
    $line = @{ Runs = @(); Width = 0 }
    foreach ($run in $Runs) {
        $buffer = ''
        foreach ($unit in @(Get-FlintDisplayUnits $run.Text)) {
            if ($line.Width + $unit.Width -gt $Width -and $line.Width -gt 0) {
                if ($buffer) { $line.Runs += @{ Text = $buffer; Color = $run.Color; Link = $run.Link }; $buffer = '' }
                $line
                $line = @{ Runs = @(); Width = 0 }
            }
            $buffer += $unit.Text; $line.Width += $unit.Width
        }
        if ($buffer) { $line.Runs += @{ Text = $buffer; Color = $run.Color; Link = $run.Link } }
    }
    $line
}

function Get-FlintTableRow {
    param([string]$Line)
    $text = $Line.Trim(); $cells = @(); $cell = ''; $ticks = 0; $separator = $false; $trailing = $false
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]; $trailing = $false
        if ($ch -eq '\' -and $i + 1 -lt $text.Length) {
            $cell += $text.Substring($i, 2); $i++; continue
        }
        if ($ch -eq '`') {
            $start = $i
            while ($i + 1 -lt $text.Length -and $text[$i + 1] -eq '`') { $i++ }
            $count = $i - $start + 1
            if ($ticks -eq $count) { $ticks = 0 }
            elseif ($ticks -eq 0 -and $text.Substring($i + 1) -match ('(?<!`)`{' + $count + '}(?!`)')) { $ticks = $count }
            $cell += $text.Substring($start, $count); continue
        }
        if ($ch -eq '|' -and $ticks -eq 0) {
            $separator = $true; $trailing = $true
            if ($i -gt 0) { $cells += $cell.Trim() }
            $cell = ''
        } else { $cell += $ch }
    }
    if (-not $trailing) { $cells += $cell.Trim() }
    return @{ Cells = $cells; HasSeparator = $separator }
}

function Write-FlintTableRule {
    param([int[]]$Widths, [string]$Position)
    $corners = @(0x251c, 0x253c, 0x2524)
    if ($Position -eq 'top') { $corners = @(0x250c, 0x252c, 0x2510) }
    if ($Position -eq 'bottom') { $corners = @(0x2514, 0x2534, 0x2518) }
    $parts = @(foreach ($width in $Widths) { ([string][char]0x2500) * ($width + 2) })
    Write-Host ([string][char]$corners[0] + ($parts -join [string][char]$corners[1]) + [char]$corners[2]) -ForegroundColor DarkGray
}

function Write-FlintTable {
    param([object[]]$Rows, [string[]]$Alignments, [hashtable]$Session)
    $columns = $Rows[0].Cells.Count; $widths = @(2) * $columns; $prepared = @()
    for ($r = 0; $r -lt $Rows.Count; $r++) {
        $cells = @(); $color = 'Gray'
        if ($r -eq 0) { $color = 'Cyan' }
        for ($c = 0; $c -lt $columns; $c++) {
            $text = ''
            if ($c -lt $Rows[$r].Cells.Count) { $text = $Rows[$r].Cells[$c] }
            # Preserve extra cells in the final column instead of silently losing content.
            if ($c -eq $columns - 1 -and $Rows[$r].Cells.Count -gt $columns) { $text = $Rows[$r].Cells[$c..($Rows[$r].Cells.Count - 1)] -join ' | ' }
            $runs = @(Get-FlintInlineRuns $text $color)
            $width = Get-FlintDisplayWidth (($runs | ForEach-Object { $_.Text }) -join '')
            if ($width -gt $widths[$c]) { $widths[$c] = $width }
            $cells += @{ Runs = $runs }
        }
        $prepared += @{ Cells = $cells }
    }
    $available = (Get-FlintTerminalWidth) - 1
    if ($available -lt 5 * $columns + 1) {
        # A vertical layout keeps every value readable when even two cells per column cannot fit.
        for ($r = 1; $r -lt $prepared.Count; $r++) {
            for ($c = 0; $c -lt $columns; $c++) {
                foreach ($line in @(Split-FlintRuns $prepared[0].Cells[$c].Runs $available)) { Write-FlintRuns $line.Runs $Session }
                foreach ($line in @(Split-FlintRuns $prepared[$r].Cells[$c].Runs ($available - 2))) {
                    Write-Host '  ' -NoNewline
                    Write-FlintRuns $line.Runs $Session
                }
            }
            Write-Host ''
        }
        if ($prepared.Count -eq 1) {
            foreach ($cell in $prepared[0].Cells) {
                foreach ($line in @(Split-FlintRuns $cell.Runs $available)) { Write-FlintRuns $line.Runs $Session }
            }
        }
        return
    }
    $total = 3 * $columns + 1
    foreach ($width in $widths) { $total += $width }
    while ($total -gt $available) {
        $widest = 0
        for ($c = 1; $c -lt $columns; $c++) { if ($widths[$c] -gt $widths[$widest]) { $widest = $c } }
        $widths[$widest]--; $total--
    }
    Write-FlintTableRule $widths 'top'
    for ($r = 0; $r -lt $prepared.Count; $r++) {
        $wrapped = @(); $height = 1
        for ($c = 0; $c -lt $columns; $c++) {
            $lines = @(Split-FlintRuns $prepared[$r].Cells[$c].Runs $widths[$c])
            if ($lines.Count -gt $height) { $height = $lines.Count }
            $wrapped += @{ Lines = $lines }
        }
        for ($l = 0; $l -lt $height; $l++) {
            Write-Host ([string][char]0x2502) -NoNewline -ForegroundColor DarkGray
            for ($c = 0; $c -lt $columns; $c++) {
                $line = @{ Runs = @(); Width = 0 }
                if ($l -lt $wrapped[$c].Lines.Count) { $line = $wrapped[$c].Lines[$l] }
                $padding = $widths[$c] - $line.Width; $left = 0
                if ($Alignments[$c] -eq 'right') { $left = $padding }
                if ($Alignments[$c] -eq 'center') { $left = [int](($padding - ($padding % 2)) / 2) }
                Write-Host (' ' * (1 + $left)) -NoNewline
                Write-FlintRuns $line.Runs $Session -NoNewline
                Write-Host ((' ' * (1 + $padding - $left)) + [char]0x2502) -NoNewline -ForegroundColor DarkGray
            }
            Write-Host ''
        }
        if ($r -eq 0) { Write-FlintTableRule $widths 'middle' }
    }
    Write-FlintTableRule $widths 'bottom'
}

function Write-FlintMarkdown {
    param([string]$Text, [hashtable]$Session)
    $fence = ''; $fenceLength = 0
    $lines = (Protect-FlintText $Session $Text) -split '\r?\n'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($fence) {
            if ($line -match '^\s{0,3}(`{3,}|~{3,})\s*$' -and $Matches[1].Substring(0, 1) -ceq $fence -and $Matches[1].Length -ge $fenceLength) {
                $fence = ''; Write-Host ''
            } else { Write-FlintColoredText $line $Session -Color Blue }
            continue
        }
        if ($line -match '^\s{0,3}(`{3,}|~{3,})(.*)$') {
            $fence = $Matches[1].Substring(0, 1); $fenceLength = $Matches[1].Length
            Write-Host $Matches[2].Trim() -ForegroundColor DarkGray
            continue
        }
        if ($line -match '^(?: {4}|\t)') { Write-FlintColoredText $line $Session -Color Blue; continue }
        if ($line.Contains('|') -and $i + 1 -lt $lines.Count -and $lines[$i + 1] -notmatch '^(?: {4}|\t)') {
            $header = Get-FlintTableRow $line
            $delimiter = Get-FlintTableRow $lines[$i + 1]
            $valid = $header.HasSeparator -and $header.Cells.Count -gt 0 -and $header.Cells.Count -eq $delimiter.Cells.Count
            $alignments = @()
            foreach ($cell in $delimiter.Cells) {
                if ($cell -notmatch '^:?-+:?$') { $valid = $false; break }
                $align = 'left'
                if ($cell.EndsWith(':')) { $align = 'right'; if ($cell.StartsWith(':')) { $align = 'center' } }
                $alignments += $align
            }
            if ($valid) {
                $rows = @($header); $i++
                while ($i + 1 -lt $lines.Count -and $lines[$i + 1] -notmatch '^\s*$|^(?: {4}|\t)|^\s{0,3}(?:`{3,}|~{3,}|#|>|[-+*]\s)') {
                    $row = Get-FlintTableRow $lines[$i + 1]
                    if (-not $row.HasSeparator) { break }
                    $rows += $row; $i++
                }
                Write-FlintTable $rows $alignments $Session
                continue
            }
        }
        if ($line -match '^\s{0,3}#{1,6}\s+(.+)$') { Write-FlintInline $Matches[1] 'Cyan' $Session }
        elseif ($line -match '^(\s*)[-+*]\s+(.*)$') {
            Write-Host ($Matches[1] + [char]0x2022 + ' ') -NoNewline -ForegroundColor DarkGray
            Write-FlintInline $Matches[2] -Session $Session
        } elseif ($line -match '^\s*>\s?(.*)$') {
            Write-Host '| ' -NoNewline -ForegroundColor DarkGray
            Write-FlintInline $Matches[1] 'DarkGray' $Session
        } else { Write-FlintInline $line -Session $Session }
    }
}
