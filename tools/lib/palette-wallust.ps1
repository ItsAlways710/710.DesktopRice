#Requires -Version 7.0
<#
.SYNOPSIS
    Palette Profiles -- running wallust: its arguments for a source, the run itself, and reading
    the palette it dumps.

.DESCRIPTION
    tools\lib\palette.ps1 loads this (the wallust half of its "Sources -> wallust" section, moved
    here whole), so every caller of that library has it. Part of the theme stamp, like
    palette.ps1: what's here decides the colours.
#>

function Get-PaletteWallustArgs {
    <# wallust's arguments for a source. Always -s (never touch Windows Terminal) and the dump
       config dir; templates stay on (the dump IS a template). #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Source, [string]$Image,
          [Parameter(Mandatory)][string]$ConfigDir)
    switch ($Source.kind) {
        'wallpaper' {
            $a = @('run', $Image, '--config-dir', $ConfigDir, '-s', '-p', $Source.method)
            # -S only means something to salience and ansi (the notes' test: kmeans ignores it).
            if ($Source.method -ne 'kmeans') { $a += @('-S', $Source.style) }
            if ($Source.saturation) { $a += @('--saturation', "$([int]$Source.saturation)") }
            if ($Source.colors16) { $a += '--use16cols' }
            return , $a
        }
        'match'  { return , @('pick', $Image, '--config-dir', $ConfigDir, '-s', '-b') }
        'theme'  { return , @('theme', $Source.name, '--config-dir', $ConfigDir, '-s') }
        'random' { return , @('theme', 'random', '--config-dir', $ConfigDir, '-s') }
        'scheme' { return , @('cs', (Join-Path (Get-PaletteSchemesDir) $Source.file), '--config-dir', $ConfigDir, '-s') }
    }
}

function Invoke-PaletteWallust {
    <# Runs wallust with the given arguments (no shell, no console window), UTF-8 output, a time
       limit. -> ExitCode, Output (lines, escape codes stripped), TimedOut. #>
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSec = 30, [string]$Exe = (Get-PaletteWallustExe))
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.Environment['RUST_BACKTRACE'] = '0'   # a failure's reason is its Error: line, never a backtrace
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { try { $p.Kill($true) } catch { } ; $null = $p.WaitForExit(5000) }
    $text = ''
    try { $text = $out.GetAwaiter().GetResult() + "`n" + $err.GetAwaiter().GetResult() } catch { }
    $lines = @($text -split "`r?`n" | ForEach-Object { ($_ -replace '\x1b\[[0-9;]*[A-Za-z]', '' -replace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)?', '').TrimEnd() } | Where-Object { $_.Trim() })
    [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $p.ExitCode }); Output = $lines; TimedOut = $timedOut }
}

function Read-PaletteDump {
    <# The dump template's JSON -> an ordered palette of 19 '#RRGGBB' slots, or a throw. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "wallust didn't write its palette" }
    try { $d = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable }
    catch { throw "wallust's palette isn't readable JSON" }
    $pal = [ordered]@{}
    foreach ($k in $script:PaletteSlots) {
        if (-not (Test-PaletteHex "$($d[$k])")) { throw "wallust's palette has no usable $k ('$($d[$k])')" }
        $pal[$k] = "$($d[$k])"
    }
    $pal
}

# salience on a wallpaper with very little colour in it. Before salience picks, wallust 4.1.0-alpha
# merges look-alike colours at a threshold of its own choosing; on a nearly black wallpaper, or one
# that's nearly all one blue, that leaves it 3-4 colours, and salience reads past the end of its
# list: a crash, not an error (exit 101, "panicked at src/histogram/salience.rs:115:51: index out of
# bounds: the len is 3 but the index is 4"; :109 and :124 on other settings). Every sampling,
# intensity, backend, saturation and style crashed the same; a fixed threshold didn't: 10 and 5
# made palettes from both wallpapers in under 2 s, 20 still crashed on one (2026-10-16, the pinned
# wallust under wine). A fixed threshold makes a different palette on every wallpaper (all 21
# shipped ones changed), so it's only the second try, after a salience crash -- his call, 10-16.
$script:PaletteSalienceRetryThresholds = @(10, 5)

function Get-PaletteWallustFailure {
    <# A failed run's reason, short: wallust's own Error: line; for a crash, its panic message and
       where (Rust prints "thread 'main' panicked at <file:line:col>:" with the message on the next
       line -- the RUST_BACKTRACE note and the spinner's last frame come after, and were all the
       old "last two lines" kept); else the last two lines it printed; else the exit code. #>
    param([Parameter(Mandatory)]$Run)
    $lines = @($Run.Output)
    $err = @($lines | Where-Object { $_ -match '^\s*Error:' } | Select-Object -First 1)
    if ($err.Count) { return $err[0].Trim() }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch 'panicked at (\S+?):?\s*$') { continue }
        $where = $Matches[1]
        $msg = @($lines | Select-Object -Skip ($i + 1) | Where-Object {
            $_ -notmatch '^\s*(note:|stack backtrace:|\[I\])' -and $_ -notmatch 'Generating color scheme' } | Select-Object -First 1)
        return "crashed -- $(if ($msg.Count) { $msg[0].Trim() } else { 'no message' }) ($where)"
    }
    $why = @($lines | Where-Object { $_ -notmatch '^\s*\[I\]' } | Select-Object -Last 2) -join ' / '
    if ($why) { $why } else { "exit $($Run.ExitCode)" }
}

function Test-PaletteSalienceCrash {
    # The crash above: a wallpaper source on salience, exit 101 (Rust's panic exit), panicking in salience's own code.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Source, [Parameter(Mandatory)]$Run)
    $Source.kind -eq 'wallpaper' -and $Source.method -eq 'salience' -and $Run.ExitCode -eq 101 -and
        [bool](@($Run.Output) -match 'panicked at \S*salience\.rs')
}

function Get-PaletteFromSource {
    <# Runs wallust for a source and returns its palette, or throws with a short reason
       (Get-PaletteWallustFailure). $DumpPath is deleted first, so an old dump can never pass for
       a new one. A salience crash is tried again at fixed thresholds (above); a palette made that
       way says so in palette.log. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Source, [string]$Image,
          [Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)][string]$DumpPath,
          [string]$Exe = (Get-PaletteWallustExe))
    if (-not (Test-Path -LiteralPath $Exe)) { throw "wallust isn't installed (710sRice install -Only wallust)" }
    if ((Test-PaletteSourceUsesImage $Source) -and (-not $Image -or -not (Test-Path -LiteralPath $Image))) { throw "the wallpaper file isn't there" }
    if ($Source.kind -eq 'scheme' -and -not (Test-Path -LiteralPath (Join-Path (Get-PaletteSchemesDir) $Source.file))) {
        throw "scheme file $($Source.file) isn't in config\palettes\schemes"
    }
    if (Test-Path -LiteralPath $DumpPath) { Remove-Item -LiteralPath $DumpPath -Force }
    $args2 = Get-PaletteWallustArgs -Source $Source -Image $Image -ConfigDir $ConfigDir
    $r = Invoke-PaletteWallust -Arguments $args2 -Exe $Exe
    if ($r.TimedOut) { throw 'wallust took longer than 30 s and was stopped' }
    if ($r.ExitCode -ne 0 -and (Test-PaletteSalienceCrash -Source $Source -Run $r)) {
        $first = Get-PaletteWallustFailure -Run $r
        foreach ($t in $script:PaletteSalienceRetryThresholds) {
            if (Test-Path -LiteralPath $DumpPath) { Remove-Item -LiteralPath $DumpPath -Force }
            $r = Invoke-PaletteWallust -Arguments ($args2 + @('-t', "$t")) -Exe $Exe
            if ($r.TimedOut) { throw "wallust took longer than 30 s and was stopped (salience again, at threshold $t)" }
            if ($r.ExitCode -eq 0) {
                Write-PaletteLog "salience crashed on $(Split-Path -Leaf $Image) at wallust's own threshold ($first) -- made at threshold $t instead"
                break
            }
        }
        if ($r.ExitCode -ne 0) { throw "wallust failed: $first; and again at thresholds $($script:PaletteSalienceRetryThresholds -join ' and ')" }
    }
    if ($r.ExitCode -ne 0) { throw "wallust failed: $(Get-PaletteWallustFailure -Run $r)" }
    Read-PaletteDump -Path $DumpPath
}
