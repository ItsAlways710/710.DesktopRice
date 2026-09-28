#Requires -Version 7.0
<#
.SYNOPSIS
    Palette Profiles -- what only the editor needs (tools\palette-editor.ps1).

.DESCRIPTION
    wallust's theme list and the wallpaper's closest themes, a wallust config of the editor's
    own (so its palettes never touch the pipeline's files), colors as "one color plus at most
    one adjustment", where each app color sits under the roles, profile names, and deep copies.

    Kept out of tools\lib\palette.ps1 on purpose: that file is part of the theme stamp (a change
    there means "re-theme" to doctor) and is parsed on every wallpaper change. Needs palette.ps1
    dot-sourced first. Pure apart from the wallust calls -- the sandbox's units cover it.
#>

function Get-PaletteEditorDir { Join-Path (Get-PaletteStateDir) 'palette-editor' }

function Initialize-PaletteScratchConfig {
    <# A wallust config dir of the editor's own: the pipeline's dump template, its own output
       file. Rewritten (only when it changed) on every editor start. -> ConfigDir, DumpPath. #>
    param([string]$Dir = (Get-PaletteEditorDir))
    $tplDir = Join-Path $Dir 'templates'
    $null = New-Item -ItemType Directory -Force -Path $tplDir
    $src = Join-Path (Get-PaletteRoot) 'config\wallust\templates\palette.json.tpl'
    $null = Write-PaletteFile -Path (Join-Path $tplDir 'palette.json.tpl') -Text ([IO.File]::ReadAllText($src))
    $dump = Join-Path $Dir 'palette.json'
    # A TOML basic string, backslashes and quotes escaped: a Windows user name can hold a ' (the
    # pipeline's literal-string config can't -- write-wallust-config.ps1 refuses such a clone).
    $target = $dump.Replace('\', '\\').Replace('"', '\"')
    $toml = "# The palette editor's own wallust config (tools\lib\palette-edit.ps1) -- rewritten when the editor starts.`n" +
            "palette = `"kmeans`"`n`n[templates]`n" +
            "dump = { template = 'palette.json.tpl', target = `"$target`" }`n"
    $null = Write-PaletteFile -Path (Join-Path $Dir 'wallust.toml') -Text $toml
    [pscustomobject]@{ ConfigDir = $Dir; DumpPath = $dump }
}

function Get-PaletteThemeNames {
    <# wallust's built-in themes (~617), in its own order, one per output (callers: @(...)). #>
    param([string]$Exe = (Get-PaletteWallustExe))
    if (-not (Test-Path -LiteralPath $Exe)) { throw "wallust isn't installed (710sRice install -Only wallust)" }
    $r = Invoke-PaletteWallust -Arguments @('theme', 'list', '-N') -Exe $Exe -TimeoutSec 20
    if ($r.ExitCode -ne 0) { throw "wallust couldn't list its themes (exit $($r.ExitCode))" }
    $names = @(foreach ($line in $r.Output) { if ($line -match '^\s*-\s+(\S.*?)\s*$') { $Matches[1] } })
    if (-not $names.Count) { throw "wallust listed no themes" }
    $names
}

function Get-PaletteThemeMatches {
    <# The built-in themes closest to a wallpaper, best first (wallust pick without --best:
       lists, applies nothing). -> Name, Score (lower = closer), one per output. #>
    param([Parameter(Mandatory)][string]$Image, [int]$Top = 8, [string]$Exe = (Get-PaletteWallustExe))
    if (-not (Test-Path -LiteralPath $Exe)) { throw "wallust isn't installed (710sRice install -Only wallust)" }
    if (-not (Test-Path -LiteralPath $Image)) { throw "the wallpaper file isn't there" }
    $r = Invoke-PaletteWallust -Arguments @('pick', $Image, '-s', '-T', '-N', '-n', "$Top") -Exe $Exe -TimeoutSec 30
    if ($r.ExitCode -ne 0) { throw "wallust couldn't match themes to the wallpaper (exit $($r.ExitCode))" }
    foreach ($line in $r.Output) {
        if ($line -match '^\s*\d+\.\s+\(([\d.]+)\)\s+(\S.*?)\s*$') {
            [pscustomobject]@{ Name = $Matches[2]; Score = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
        }
    }
}

function Get-PaletteSchemeFiles {
    <# Scheme files a profile can use (config\palettes\schemes, gitignored): their names, one per
       output. #>
    $dir = Get-PaletteSchemesDir
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -notmatch '^\.' } | Sort-Object Name | ForEach-Object Name
}

# ------------------------------------------------------------------------------------------
# One color + at most one adjustment (what the color selector edits)
# ------------------------------------------------------------------------------------------
function Split-PaletteExpression {
    <# An expression -> Base (a name or #hex), Adjust ('none', 'lighten', 'darken', 'mix'),
       Amount (0-100), Other (mix's second color), Simple ($false: something the selector's
       controls can't show -- nested functions; the selector then offers the text as it is). #>
    param([Parameter(Mandatory)][string]$Text)
    $tree = ConvertFrom-PaletteExpression -Text $Text
    $leaf = { param($n) if ($n.Kind -eq 'hex') { $n.Value } elseif ($n.Kind -eq 'name') { $n.Name } else { $null } }
    $o = [ordered]@{ Base = $null; Adjust = 'none'; Amount = 0; Other = $null; Simple = $true }
    switch ($tree.Kind) {
        { $_ -in 'hex', 'name' } { $o.Base = & $leaf $tree }
        { $_ -in 'lighten', 'darken' } {
            $o.Base = & $leaf $tree.Arg; $o.Adjust = $tree.Kind; $o.Amount = $tree.Amount
            if (-not $o.Base) { $o.Simple = $false }
        }
        'mix' {
            $o.Base = & $leaf $tree.Arg; $o.Other = & $leaf $tree.Other; $o.Adjust = 'mix'; $o.Amount = $tree.Amount
            if (-not $o.Base -or -not $o.Other) { $o.Simple = $false }
        }
    }
    [pscustomobject]$o
}

function Join-PaletteExpression {
    <# The other way: Base + Adjust (+ Amount, Other) -> expression text. An adjustment of 0
       (or a mix with nothing to mix) is just the base. #>
    param([Parameter(Mandatory)][string]$Base, [string]$Adjust = 'none', [double]$Amount = 0, [string]$Other)
    $n = [Math]::Round([Math]::Min([Math]::Max($Amount, 0), 100))
    switch ($Adjust) {
        'lighten' { if ($n -gt 0) { return "lighten($Base, $n)" } }
        'darken'  { if ($n -gt 0) { return "darken($Base, $n)" } }
        'mix'     { if ($n -gt 0 -and $Other) { return "mix($Base, $Other, $n)" } }
    }
    $Base
}

function Get-PaletteExpressionNames {
    <# Every color name an expression uses, in order (duplicates kept once), one per output. #>
    param([Parameter(Mandatory)][string]$Text)
    $out = [System.Collections.Generic.List[string]]::new()
    $walk = $null
    $walk = {
        param($n)
        switch ($n.Kind) {
            'name' { if (-not $out.Contains($n.Name)) { $out.Add($n.Name) } }
            { $_ -in 'lighten', 'darken' } { & $walk $n.Arg }
            'mix' { & $walk $n.Arg; & $walk $n.Other }
        }
    }
    & $walk (ConvertFrom-PaletteExpression -Text $Text)
    $out.ToArray()
}

function Get-PaletteRoleHome {
    <# Where an app color sits in the editor: the first role its DEFAULT expression uses
       (komorebi's monocle border, lighten(accent, 25), sits under Accent), or 'palette' for one
       that comes straight from the palette (Terminal's sixteen colors). #>
    param([Parameter(Mandatory)][string]$Expression)
    foreach ($n in @(Get-PaletteExpressionNames -Text $Expression)) {
        if ($script:PaletteRoles.Contains($n)) { return $n }
    }
    'palette'
}

function Get-PaletteEditorLayout {
    <# The editor's roles -> app colors tree: an ordered role (plus 'palette') -> list of
       @{ Target; Prop; Label; TargetLabel } in target order. Hidden targets are left out. #>
    param([object[]]$Targets = (Get-PaletteTargets))
    $layout = [ordered]@{}
    foreach ($r in $script:PaletteRoles.Keys) { $layout[$r] = [System.Collections.Generic.List[object]]::new() }
    $layout['palette'] = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $Targets) {
        if ($t.Hidden) { continue }
        foreach ($p in $t.Properties.Keys) {
            $roleHome = Get-PaletteRoleHome -Expression $t.Properties[$p].Default
            $layout[$roleHome].Add([pscustomobject]@{ Target = $t.Id; Prop = $p; Label = $t.Properties[$p].Label; TargetLabel = $t.Label })
        }
    }
    $layout
}

# ------------------------------------------------------------------------------------------
# Profiles as the editor handles them
# ------------------------------------------------------------------------------------------
function Copy-PaletteProfile {
    <# A deep copy through the saved form -- what's edited never shares a table with what was
       read, and the copy is checked exactly as a saved file would be. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Profile)
    $json = ConvertTo-PaletteProfileJson -Profile $Profile
    $data = ConvertTo-PaletteCaseless ($json | ConvertFrom-Json -AsHashtable)
    $copy = ConvertTo-PaletteProfile -Data $data -DefaultRoles (Get-PaletteDefaultProfile).roles
    if ($Profile.Contains('name')) { $copy.name = "$($Profile.name)" }
    $copy
}

function Test-PaletteProfileName {
    <# $null when a name can be used for profile $Id, else why not. Empty is fine (the profile
       is then just "Profile 3"). Names that read as a slot or as Default would make
       `710sRice palette use <name>` mean something else; two profiles can't share one.
       -Profiles: Get-PaletteProfiles' rows, when the caller already has them. #>
    param([AllowEmptyString()][string]$Name, [Parameter(Mandatory)][string]$Id, [object[]]$Profiles)
    $n = "$Name".Trim()
    if (-not $n) { return $null }
    if ($n.Length -gt 40) { return 'Keep the name to 40 characters' }
    if ($n -match '^(?i)(default|(profile\s*)?[0-9])$') { return "'$n' would read as a profile slot -- pick another name" }
    if ($n -match '[\x00-\x1f"]') { return "The name can't hold quotes or control characters" }
    if (-not $Profiles) { $Profiles = @(Get-PaletteProfiles) }
    foreach ($p in $Profiles) {
        if ($p.Id -ne $Id -and $p.Exists -and $p.Name -and $p.Name -eq $n) { return "$($p.Label) already has that name" }
    }
    $null
}
