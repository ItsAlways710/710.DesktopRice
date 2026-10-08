#Requires -Version 7.0
<#
.SYNOPSIS
    Palette Profiles -- rendering a target's template and writing the palette's files.

.DESCRIPTION
    tools\lib\palette.ps1 loads this (its "Rendering and writing" section, moved here whole), so
    every caller of that library has it. Part of the theme stamp, like palette.ps1: what's here
    decides what the files say.
#>

function Expand-PaletteTemplate {
    <# {{name}} -> value, byte for byte everything else (line endings included -- the file as the
       clone has it, exactly what wallust did with the old templates). An unknown {{name}} throws:
       a typo in a template must not ship a broken file. #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    [regex]::Replace($Text, '\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}', {
        param($m)
        $k = $m.Groups[1].Value
        if (-not $Values.Contains($k)) { throw "template placeholder {{$k}} has no value" }
        "$($Values[$k])"
    })
}

function Write-PaletteFile {
    <# UTF-8, no BOM. Only writes when the bytes differ (watchers -- YASB's stylesheet watch --
       fire on every write), through a temp file + move so a reader never sees half a file.
       $true = written. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    if (Test-Path -LiteralPath $Path) {
        $old = [IO.File]::ReadAllBytes($Path)
        if ([System.Linq.Enumerable]::SequenceEqual($old, $bytes)) { return $false }
    } else {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    }
    $tmp = "$Path.tmp-$PID"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    # A program reading the file without letting it be replaced refuses the move while it reads
    # (YASB reading the bar's CSS: Python opens files that way). Tried again for about 2 s; if it
    # still fails, the temp file goes and the error stands.
    for ($try = 1; ; $try++) {
        try { Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop; break }
        catch {
            if ($try -ge 20) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw }
            Start-Sleep -Milliseconds 100
        }
    }
    $true
}

function Get-PaletteTemplateValues {
    <# What a target's template sees: its properties, plus _isDark / _mode. #>
    param([Parameter(Mandatory)]$Theme, [Parameter(Mandatory)][string]$TargetId)
    $v = [ordered]@{}
    foreach ($k in $Theme.Targets[$TargetId].Keys) { $v[$k] = $Theme.Targets[$TargetId][$k] }
    $v['_isDark'] = if ($Theme.AppDark) { 'True' } else { 'False' }
    $v['_mode'] = if ($Theme.AppDark) { 'dark' } else { 'light' }
    $v
}

function Get-PaletteTargetText {
    <# A file target's rendered text (no writing) -- the pipeline, the sandbox's byte-for-byte
       proof and the final Dell test all use this. #>
    param([Parameter(Mandatory)]$Theme, [Parameter(Mandatory)]$Target)
    $tpl = Join-Path (Split-Path -Parent $Target.File) $Target.Template
    Expand-PaletteTemplate -Text ([IO.File]::ReadAllText($tpl)) -Values (Get-PaletteTemplateValues -Theme $Theme -TargetId $Target.Id)
}
