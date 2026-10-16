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

function Get-PaletteFromSource {
    <# Runs wallust for a source and returns its palette, or throws with a short reason (the
       last line wallust printed). $DumpPath is deleted first, so an old dump can never pass for
       a new one. #>
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
    if ($r.ExitCode -ne 0) {
        $why = @($r.Output | Where-Object { $_ -match '^\s*Error:' } | Select-Object -First 1) -join ''
        if (-not $why) { $why = @($r.Output | Where-Object { $_ -notmatch '^\s*\[I\]' } | Select-Object -Last 2) -join ' / ' }
        if (-not $why) { $why = "exit $($r.ExitCode)" }
        throw "wallust failed: $why"
    }
    Read-PaletteDump -Path $DumpPath
}
