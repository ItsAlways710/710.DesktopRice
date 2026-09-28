#Requires -Version 7.0
<#
.SYNOPSIS
    Palette Profiles -- the one place that turns a wallpaper into every themed colour.

.DESCRIPTION
    Dot-sourced by tools\apply-wallust-outputs.ps1 (the wallpaper pipeline), tools\palette-profiles.ps1
    (choose / list / save), tools\palette-editor.ps1 (the editor's live preview), tools\lib\doctor.ps1
    and install / uninstall. Three layers (claude/palette-profiles-plan.md, "Design"):

      1. SOURCE -> PALETTE. A profile names one colour source (the wallpaper through one of
         wallust's methods, the built-in theme that best matches the wallpaper, a fixed or random
         built-in theme, or a scheme file). wallust runs with -s (it never touches Windows
         Terminal) and one dump template, and hands back background / foreground / cursor /
         color0-15 as JSON.
      2. ROLES. Eight named colours (base, panel, accent, hover, subtext, text, bright, alert),
         each an expression over the palette -- "what gets what".
      3. TARGETS. Every app we theme (tools\palette\targets\<id>.ps1) has named properties, each
         defaulting to an expression over roles / the palette; a profile can override any one.

    Expressions: color0..color15, background, foreground, cursor (the palette) | a role name |
    #rrggbb (kept exactly as written) | lighten(x, n) / darken(x, n) (x moved n% toward white /
    black -- winarchy's Get-WinarchyShadedHex, our border shading since day one) |
    mix(x, y, n) (x moved n% toward y).

    Everything here is PS7-only and free of tools\lib\activation.ps1 (the wallpaper pipeline runs
    on every wallpaper change and stays light).
#>

$script:PaletteLibRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# ------------------------------------------------------------------------------------------
# Names
# ------------------------------------------------------------------------------------------
$script:PaletteSlots = @('background', 'foreground', 'cursor') + (0..15 | ForEach-Object { "color$_" })

# The roles, in the editor's order. Default = today's map (the slots the old templates used).
$script:PaletteRoles = [ordered]@{
    base    = @{ Label = 'Background';  About = 'The bar, menus, Flow and stack tabs; unfocused borders; Terminal''s tab row' }
    panel   = @{ Label = 'Panel';       About = 'Second background: the bar''s panels and borders' }
    accent  = @{ Label = 'Accent';      About = 'Focused border, Windows accent, highlights, the prompt' }
    hover   = @{ Label = 'Hover';       About = 'The bar''s hover colour' }
    subtext = @{ Label = 'Subtext';     About = 'Secondary text: hints, stack-tab labels, prompt status' }
    text    = @{ Label = 'Text';        About = 'Text everywhere' }
    bright  = @{ Label = 'Bright text'; About = 'Text on the accent; git branch; Flow''s match highlight' }
    alert   = @{ Label = 'Alert';       About = 'Errors -- fixed red by default, whatever the wallpaper' }
}

$script:PaletteProfileIds = @('default') + (0..9 | ForEach-Object { "profile$_" })
$script:PaletteMethods    = @('kmeans', 'salience', 'ansi')
$script:PaletteSourceKinds = [ordered]@{
    wallpaper = 'Wallpaper'
    match     = 'Best-matching built-in theme'
    theme     = 'Built-in theme'
    random    = 'Random built-in theme'
    scheme    = 'Scheme file'
}

function Get-PaletteRoot        { $script:PaletteLibRoot }
function Get-PaletteStateDir    { Join-Path $env:LOCALAPPDATA '710.DesktopRice' }
function Get-PaletteProfilesDir { Join-Path $script:PaletteLibRoot 'config\palettes' }
function Get-PaletteSchemesDir  { Join-Path $script:PaletteLibRoot 'config\palettes\schemes' }
function Get-PaletteTargetsDir  { Join-Path $script:PaletteLibRoot 'tools\palette\targets' }
function Get-PaletteGeneratedDir { Join-Path $script:PaletteLibRoot 'config\wallust\generated' }
function Get-PaletteWallustExe  { Join-Path $script:PaletteLibRoot 'tools\bin\wallust\wallust.exe' }
function Get-PaletteChoicePath  { Join-Path (Get-PaletteStateDir) 'palette-profile.txt' }
function Get-PaletteStatusPath  { Join-Path (Get-PaletteStateDir) 'palette-status.json' }
function Get-PaletteLastGoodPath { Join-Path (Get-PaletteGeneratedDir) 'palette.json' }

# ------------------------------------------------------------------------------------------
# Hex / colour maths
# ------------------------------------------------------------------------------------------
function Test-PaletteHex { param([string]$Hex) [bool]($Hex -match '^#[0-9A-Fa-f]{6}$') }

function ConvertTo-PaletteRgb {
    param([Parameter(Mandatory)][string]$Hex)
    $h = $Hex.TrimStart('#')
    [pscustomobject]@{
        R = [Convert]::ToInt32($h.Substring(0, 2), 16)
        G = [Convert]::ToInt32($h.Substring(2, 2), 16)
        B = [Convert]::ToInt32($h.Substring(4, 2), 16)
    }
}

function Get-PaletteShadedHex {
    <# Lerp '#rrggbb' toward white (Factor > 0) or black (Factor < 0) -- winarchy's
       Get-WinarchyShadedHex, the komorebi monocle/stack shading since the first theme. Lower-case
       output, as it always was. #>
    param([Parameter(Mandatory)][string]$Hex, [Parameter(Mandatory)][double]$Factor)
    $h = $Hex.TrimStart('#')
    $target = if ($Factor -ge 0) { 255 } else { 0 }
    $f = [Math]::Abs($Factor)
    $rgb = foreach ($i in @(0, 2, 4)) {
        $c = [Convert]::ToInt32($h.Substring($i, 2), 16)
        [int][Math]::Round($c + ($target - $c) * $f)
    }
    '#{0:x2}{1:x2}{2:x2}' -f $rgb[0], $rgb[1], $rgb[2]
}

function Get-PaletteMixedHex {
    <# A moved Weight (0..1) of the way toward B -- winarchy's Get-WinarchyMixedHex. #>
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B, [Parameter(Mandatory)][double]$Weight)
    $ha = $A.TrimStart('#'); $hb = $B.TrimStart('#')
    $parts = foreach ($i in @(0, 2, 4)) {
        $x = [Convert]::ToInt32($ha.Substring($i, 2), 16)
        $y = [Convert]::ToInt32($hb.Substring($i, 2), 16)
        '{0:x2}' -f [int][Math]::Round($x + ($y - $x) * $Weight)
    }
    '#' + ($parts -join '')
}

function Get-PaletteLuminance {
    # WCAG relative luminance.
    param([Parameter(Mandatory)][string]$Hex)
    $c = ConvertTo-PaletteRgb -Hex $Hex
    $lin = foreach ($v in $c.R, $c.G, $c.B) {
        $x = $v / 255.0
        if ($x -le 0.03928) { $x / 12.92 } else { [Math]::Pow(($x + 0.055) / 1.055, 2.4) }
    }
    0.2126 * $lin[0] + 0.7152 * $lin[1] + 0.0722 * $lin[2]
}

function Get-PaletteContrast {
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    $la = Get-PaletteLuminance $A; $lb = Get-PaletteLuminance $B
    ([Math]::Max($la, $lb) + 0.05) / ([Math]::Min($la, $lb) + 0.05)
}

function Test-PaletteIsLight {
    # Lighter than the point where black and white text read equally well (~#767676).
    param([Parameter(Mandatory)][string]$Hex)
    (Get-PaletteLuminance $Hex) -ge 0.179
}

function Get-PaletteReadableHex {
    <# $Hex moved (hue and saturation kept, HSL lightness only) until it reaches $Min contrast
       against $Background. -Direction lighten is EXACTLY the Windows Terminal lift that shipped in
       a69fc6c (Default keeps it, byte for byte: 1% steps up, '#FFFFFF' when nothing reaches it);
       auto lightens on a dark background and darkens on a light one. #>
    param([Parameter(Mandatory)][string]$Hex, [Parameter(Mandatory)][string]$Background,
          [Parameter(Mandatory)][double]$Min, [ValidateSet('lighten', 'auto')][string]$Direction = 'lighten')
    if ((Get-PaletteContrast $Hex $Background) -ge $Min) { return $Hex }
    $down = ($Direction -eq 'auto') -and (Test-PaletteIsLight $Background)
    $c = ConvertTo-PaletteRgb -Hex $Hex
    $r = $c.R / 255.0; $g = $c.G / 255.0; $b = $c.B / 255.0
    # NB: not $max/$min -- PowerShell names are case-insensitive, and $min would silently
    # overwrite the $Min threshold parameter (caught in the sandbox, 2026-09-23).
    $chHi = [Math]::Max($r, [Math]::Max($g, $b)); $chLo = [Math]::Min($r, [Math]::Min($g, $b))
    $l = ($chHi + $chLo) / 2; $h = 0.0; $s = 0.0
    if ($chHi -ne $chLo) {
        $d = $chHi - $chLo
        $s = if ($l -gt 0.5) { $d / (2 - $chHi - $chLo) } else { $d / ($chHi + $chLo) }
        $h = if ($chHi -eq $r) { (($g - $b) / $d) + $(if ($g -lt $b) { 6 } else { 0 }) }
             elseif ($chHi -eq $g) { (($b - $r) / $d) + 2 }
             else { (($r - $g) / $d) + 4 }
        $h /= 6
    }
    $toRgb = {
        param($p, $q, $t)
        if ($t -lt 0) { $t += 1 }; if ($t -gt 1) { $t -= 1 }
        if ($t -lt 1/6) { return $p + ($q - $p) * 6 * $t }
        if ($t -lt 1/2) { return $q }
        if ($t -lt 2/3) { return $p + ($q - $p) * (2/3 - $t) * 6 }
        $p
    }
    $toHex = {
        param($LL)
        if ($s -eq 0) { $nr = $ng = $nb = $LL }
        else {
            $q = if ($LL -lt 0.5) { $LL * (1 + $s) } else { $LL + $s - $LL * $s }
            $p = 2 * $LL - $q
            $nr = & $toRgb $p $q ($h + 1/3); $ng = & $toRgb $p $q $h; $nb = & $toRgb $p $q ($h - 1/3)
        }
        '#{0:X2}{1:X2}{2:X2}' -f [int][Math]::Round($nr * 255), [int][Math]::Round($ng * 255), [int][Math]::Round($nb * 255)
    }
    if (-not $down) {
        for ($L = $l; $L -le 1.0001; $L += 0.01) {
            $cand = & $toHex ([Math]::Min($L, 1.0))
            if ((Get-PaletteContrast $cand $Background) -ge $Min) { return $cand }
        }
        return '#FFFFFF'
    }
    for ($L = $l; $L -ge -0.0001; $L -= 0.01) {
        $cand = & $toHex ([Math]::Max($L, 0.0))
        if ((Get-PaletteContrast $cand $Background) -ge $Min) { return $cand }
    }
    '#000000'
}

# ------------------------------------------------------------------------------------------
# Expressions
# ------------------------------------------------------------------------------------------
function ConvertFrom-PaletteExpression {
    <# Parses one expression into a small tree: @{Kind='hex'; Value} | @{Kind='name'; Name} |
       @{Kind='lighten'|'darken'; Arg; Amount} | @{Kind='mix'; Arg; Other; Amount}. Throws a
       readable message on anything else (the editor and doctor show it). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $state = @{ s = $Text; i = 0 }
    $skip = { while ($state.i -lt $state.s.Length -and [char]::IsWhiteSpace($state.s[$state.i])) { $state.i++ } }
    $parse = $null
    $parse = {
        & $skip
        $rest = $state.s.Substring($state.i)
        if ($rest -match '^#[0-9A-Fa-f]{6}(?![0-9A-Za-z])') {
            $state.i += 7
            return @{ Kind = 'hex'; Value = $Matches[0] }
        }
        if ($rest -notmatch '^[A-Za-z][A-Za-z0-9]*') { throw "expected a colour at '$rest'" }
        $word = $Matches[0]
        $state.i += $word.Length
        & $skip
        if ($state.i -lt $state.s.Length -and $state.s[$state.i] -eq '(') {
            $fn = $word.ToLowerInvariant()
            if ($fn -notin 'lighten', 'darken', 'mix') { throw "unknown function '$word' (lighten, darken or mix)" }
            $state.i++
            $arg = & $parse
            $other = $null
            & $skip
            if ($state.i -ge $state.s.Length -or $state.s[$state.i] -ne ',') { throw "$fn(...) needs a comma after its colour" }
            $state.i++
            if ($fn -eq 'mix') {
                $other = & $parse
                & $skip
                if ($state.i -ge $state.s.Length -or $state.s[$state.i] -ne ',') { throw 'mix(a, b, n) needs three parts' }
                $state.i++
            }
            & $skip
            $num = $state.s.Substring($state.i)
            if ($num -notmatch '^\d+(\.\d+)?') { throw "$fn(...) needs an amount from 0 to 100" }
            $amount = [double]$Matches[0]
            if ($amount -lt 0 -or $amount -gt 100) { throw "$fn(...) amount $amount isn't between 0 and 100" }
            $state.i += $Matches[0].Length
            & $skip
            if ($state.i -ge $state.s.Length -or $state.s[$state.i] -ne ')') { throw "$fn(...) is missing its ')'" }
            $state.i++
            $node = @{ Kind = $fn; Arg = $arg; Amount = $amount }
            if ($fn -eq 'mix') { $node.Other = $other }
            return $node
        }
        @{ Kind = 'name'; Name = $word }
    }
    if (-not $Text.Trim()) { throw 'empty colour' }
    $tree = & $parse
    & $skip
    if ($state.i -lt $state.s.Length) { throw "unexpected '$($state.s.Substring($state.i))'" }
    $tree
}

function Resolve-PaletteExpression {
    <# An expression -> '#rrggbb'. Names: the palette's 19 slots, then roles -- $Roles holds
       either finished hex values or, while roles are being resolved, their expressions
       ($RoleDefs + $Visiting catch a role that refers back to itself). #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][System.Collections.IDictionary]$Palette,
          [System.Collections.IDictionary]$Roles = @{}, [System.Collections.IDictionary]$RoleDefs = @{},
          [System.Collections.Generic.HashSet[string]]$Visiting)
    if ($null -eq $Visiting) { $Visiting = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    $tree = ConvertFrom-PaletteExpression -Text $Text
    Resolve-PaletteTree -Tree $tree -Palette $Palette -Roles $Roles -RoleDefs $RoleDefs -Visiting $Visiting
}

function Resolve-PaletteTree {
    param($Tree, $Palette, $Roles, $RoleDefs, $Visiting)
    switch ($Tree.Kind) {
        'hex'  { return $Tree.Value }
        'name' {
            $n = $Tree.Name
            if ($Palette.Contains($n)) { return $Palette[$n] }
            if ($Roles.Contains($n)) { return $Roles[$n] }
            if ($RoleDefs.Contains($n)) {
                if (-not $Visiting.Add($n)) { throw "role '$n' refers back to itself" }
                $v = Resolve-PaletteExpression -Text $RoleDefs[$n] -Palette $Palette -Roles $Roles -RoleDefs $RoleDefs -Visiting $Visiting
                $null = $Visiting.Remove($n)
                $Roles[$n] = $v
                return $v
            }
            throw "unknown colour '$n'"
        }
        'lighten' { return Get-PaletteShadedHex -Hex (Resolve-PaletteTree $Tree.Arg $Palette $Roles $RoleDefs $Visiting) -Factor ($Tree.Amount / 100) }
        'darken'  { return Get-PaletteShadedHex -Hex (Resolve-PaletteTree $Tree.Arg $Palette $Roles $RoleDefs $Visiting) -Factor (-$Tree.Amount / 100) }
        'mix' {
            return Get-PaletteMixedHex -A (Resolve-PaletteTree $Tree.Arg $Palette $Roles $RoleDefs $Visiting) `
                                       -B (Resolve-PaletteTree $Tree.Other $Palette $Roles $RoleDefs $Visiting) -Weight ($Tree.Amount / 100)
        }
    }
    throw "can't read that colour"
}

# ------------------------------------------------------------------------------------------
# Targets (tools\palette\targets\<id>.ps1)
# ------------------------------------------------------------------------------------------
$script:PaletteTargetCache = $null

function Get-PaletteTargets {
    <# Every target definition, in apply order. Each file returns one hashtable -- see
       tools\palette\targets\README.md for the fields. A broken file throws here (the pipeline
       stops before anything is written). #>
    param([switch]$Refresh)
    if ($script:PaletteTargetCache -and -not $Refresh) { return $script:PaletteTargetCache }
    $list = foreach ($f in @(Get-ChildItem -LiteralPath (Get-PaletteTargetsDir) -Filter '*.ps1' -File | Sort-Object Name)) {
        $def = & $f.FullName
        if ($def -isnot [System.Collections.IDictionary] -or -not $def.Id -or -not $def.Properties) {
            throw "palette target $($f.Name) doesn't return a target definition"
        }
        if ($def.Id -ne $f.BaseName) { throw "palette target $($f.Name) says its Id is '$($def.Id)'" }
        $def.File = $f.FullName
        if (-not $def.Contains('Order')) { $def.Order = 50 }
        $def
    }
    $script:PaletteTargetCache = @($list | Sort-Object { $_.Order }, { $_.Id })
    $script:PaletteTargetCache
}

function Get-PaletteTarget {
    param([Parameter(Mandatory)][string]$Id)
    Get-PaletteTargets | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

# ------------------------------------------------------------------------------------------
# Profiles
# ------------------------------------------------------------------------------------------
function Get-PaletteProfilePath {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notin $script:PaletteProfileIds) { throw "'$Id' isn't a palette profile (default, profile0 ... profile9)" }
    Join-Path (Get-PaletteProfilesDir) "$Id.json"
}

function ConvertTo-PaletteProfileId {
    <# What people type -> an Id: 'default', '3', 'profile3', 'Profile 3', or a profile's name. #>
    param([Parameter(Mandatory)][string]$Text)
    $t = $Text.Trim()
    if ($t -match '^(?i)default$') { return 'default' }
    if ($t -match '^(?i)(profile\s*)?([0-9])$') { return "profile$($Matches[2])" }
    foreach ($p in Get-PaletteProfiles) {
        if ($p.Exists -and $p.Name -and $p.Name -eq $t) { return $p.Id }
    }
    $null
}

function New-PaletteProfileDefaults {
    # What a field a profile leaves out means.
    [ordered]@{
        schema    = 1
        name      = ''
        source    = [ordered]@{ kind = 'wallpaper'; method = 'kmeans'; style = 'dark'; saturation = 0; colors16 = $false }
        roles     = [ordered]@{}
        overrides = [ordered]@{}
        off       = @()
        readable  = [ordered]@{ terminal = 'auto'; ui = $true }
        appMode   = 'dark'
    }
}

function ConvertTo-PaletteProfile {
    <# A parsed profile (hashtable) -> the full shape, missing fields filled, roles missing from it
       taken from Default's. Throws on anything malformed, naming it. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data, [System.Collections.IDictionary]$DefaultRoles)
    $p = New-PaletteProfileDefaults
    foreach ($k in @($Data.Keys)) {
        if ($k -notin 'schema', 'name', 'source', 'roles', 'overrides', 'off', 'readable', 'appMode', 'note') { throw "unknown field '$k'" }
    }
    if ($Data.Contains('name')) { $p.name = "$($Data.name)".Trim() }
    if ($Data.Contains('note')) { $p.note = "$($Data.note)" }
    if ($Data.Contains('source')) {
        $s = $Data.source
        if ($s -isnot [System.Collections.IDictionary]) { throw 'source must be an object' }
        $kind = "$($s.kind)"
        if ($kind -notin $script:PaletteSourceKinds.Keys) { throw "source kind '$kind' isn't one of: $($script:PaletteSourceKinds.Keys -join ', ')" }
        $src = [ordered]@{ kind = $kind }
        switch ($kind) {
            'wallpaper' {
                $m = if ($s.Contains('method')) { "$($s.method)" } else { 'kmeans' }
                if ($m -notin $script:PaletteMethods) { throw "method '$m' isn't kmeans, salience or ansi" }
                $st = if ($s.Contains('style')) { "$($s.style)" } else { 'dark' }
                if ($st -notin 'dark', 'light') { throw "style '$st' isn't dark or light" }
                $sat = 0
                if ($s.Contains('saturation') -and $null -ne $s.saturation) {
                    $sat = [int]$s.saturation
                    if ($sat -lt 0 -or $sat -gt 100) { throw "saturation $sat isn't 0 (off) to 100" }
                }
                $src.method = $m; $src.style = $st; $src.saturation = $sat; $src.colors16 = [bool]$s.colors16
            }
            'theme' {
                $n = "$($s.name)".Trim()
                if (-not $n) { throw 'a theme source needs a theme name' }
                if ($n -match '["\r\n]') { throw "theme name '$n' has characters a theme name can't" }
                $src.name = $n
            }
            'scheme' {
                $f = "$($s.file)".Trim()
                if (-not $f -or $f -match '[\\/:*?"<>|]') { throw "scheme file '$f' must be a file name inside config\palettes\schemes" }
                $src.file = $f
            }
        }
        $p.source = $src
    }
    $roleDefs = [ordered]@{}
    foreach ($r in $script:PaletteRoles.Keys) {
        if ($Data.Contains('roles') -and $Data.roles.Contains($r)) { $roleDefs[$r] = "$($Data.roles[$r])" }
        elseif ($DefaultRoles -and $DefaultRoles.Contains($r)) { $roleDefs[$r] = $DefaultRoles[$r] }
        else { throw "role '$r' has no colour" }
    }
    if ($Data.Contains('roles')) {
        foreach ($r in @($Data.roles.Keys)) { if (-not $script:PaletteRoles.Contains($r)) { throw "unknown role '$r'" } }
    }
    foreach ($r in $roleDefs.Keys) {
        try { $null = ConvertFrom-PaletteExpression -Text $roleDefs[$r] } catch { throw "role '$r': $($_.Exception.Message)" }
    }
    $p.roles = $roleDefs
    if ($Data.Contains('overrides')) {
        if ($Data.overrides -isnot [System.Collections.IDictionary]) { throw 'overrides must be an object' }
        $ov = [ordered]@{}
        foreach ($t in @($Data.overrides.Keys)) {
            $props = $Data.overrides[$t]
            if ($props -isnot [System.Collections.IDictionary]) { throw "overrides.$t must be an object" }
            $ov[$t] = [ordered]@{}
            foreach ($k in @($props.Keys)) {
                try { $null = ConvertFrom-PaletteExpression -Text "$($props[$k])" } catch { throw "overrides.$t.${k}: $($_.Exception.Message)" }
                $ov[$t][$k] = "$($props[$k])"
            }
        }
        $p.overrides = $ov
    }
    if ($Data.Contains('off')) { $p.off = @($Data.off | ForEach-Object { "$_" } | Where-Object { $_ }) }
    if ($Data.Contains('readable')) {
        $rd = $Data.readable
        if ($rd -isnot [System.Collections.IDictionary]) { throw 'readable must be an object' }
        if ($rd.Contains('terminal')) {
            $v = "$($rd.terminal)"
            if ($v -notin 'lighten', 'auto', 'off') { throw "readable.terminal '$v' isn't lighten, auto or off" }
            $p.readable.terminal = $v
        }
        if ($rd.Contains('ui')) { $p.readable.ui = [bool]$rd.ui }
    }
    if ($Data.Contains('appMode')) {
        $am = "$($Data.appMode)"
        if ($am -notin 'dark', 'light', 'auto') { throw "appMode '$am' isn't dark, light or auto" }
        $p.appMode = $am
    }
    # Every colour name has to mean something, and no role may lean on itself -- checked now,
    # against a stand-in palette, so a broken profile is caught when it's loaded (the pipeline
    # then falls back to Default) instead of halfway through a theme run.
    $dummy = [ordered]@{}; foreach ($k in $script:PaletteSlots) { $dummy[$k] = '#808080' }
    $roles = [ordered]@{}
    $visiting = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $roleDefs.Keys) {
        if ($roles.Contains($r)) { continue }
        try {
            $null = $visiting.Add($r)
            $roles[$r] = Resolve-PaletteExpression -Text $roleDefs[$r] -Palette $dummy -Roles $roles -RoleDefs $roleDefs -Visiting $visiting
            $null = $visiting.Remove($r)
        } catch { throw "role '$r': $($_.Exception.Message)" }
    }
    foreach ($t in $p.overrides.Keys) {
        foreach ($k in $p.overrides[$t].Keys) {
            try { $null = Resolve-PaletteExpression -Text $p.overrides[$t][$k] -Palette $dummy -Roles $roles }
            catch { throw "overrides.$t.${k}: $($_.Exception.Message)" }
        }
    }
    $p
}

$script:PaletteDefaultCache = $null

function ConvertTo-PaletteCaseless {
    <# ConvertFrom-Json -AsHashtable hands back case-SENSITIVE tables (OrderedHashtable, PS 7.3+);
       everything else here is PowerShell's usual case-insensitive [ordered]. Recursive. #>
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $Value.Keys) { $o[$k] = ConvertTo-PaletteCaseless $Value[$k] }
        return $o
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        return , @(foreach ($v in $Value) { ConvertTo-PaletteCaseless $v })
    }
    $Value
}

function Read-PaletteProfile {
    <# The profile's full shape (ConvertTo-PaletteProfile). Throws "Profile 3: <what's wrong>". #>
    param([Parameter(Mandatory)][string]$Id)
    $path = Get-PaletteProfilePath -Id $Id
    if (-not (Test-Path -LiteralPath $path)) { throw "$(Get-PaletteProfileLabel -Id $Id) doesn't exist" }
    try {
        $data = ConvertTo-PaletteCaseless ([IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable)
    } catch { throw "$(Get-PaletteProfileLabel -Id $Id) isn't valid JSON: $($_.Exception.Message)" }
    if ($data -isnot [System.Collections.IDictionary]) { throw "$(Get-PaletteProfileLabel -Id $Id) isn't a profile" }
    $defRoles = $null
    if ($Id -ne 'default') { $defRoles = (Get-PaletteDefaultProfile).roles }
    try { $p = ConvertTo-PaletteProfile -Data $data -DefaultRoles $defRoles }
    catch { throw "$(Get-PaletteProfileLabel -Id $Id): $($_.Exception.Message)" }
    $p
}

function Get-PaletteDefaultProfile {
    if (-not $script:PaletteDefaultCache) { $script:PaletteDefaultCache = Read-PaletteProfile -Id 'default' }
    $script:PaletteDefaultCache
}

function Get-PaletteProfileLabel {
    <# "Default", "Profile 3", "Profile 3 · Night". #>
    param([Parameter(Mandatory)][string]$Id, [string]$Name)
    $base = if ($Id -eq 'default') { 'Default' } else { 'Profile ' + $Id.Substring(7) }
    if ($Name -and $Id -ne 'default') { "$base $([char]0xB7) $Name" } else { $base }
}

function Get-PaletteProfiles {
    <# Every slot: Id, Exists, Name, Label, Error (a broken file), Active. #>
    $active = Get-ActivePaletteProfileId
    foreach ($id in $script:PaletteProfileIds) {
        $path = Get-PaletteProfilePath -Id $id
        $exists = Test-Path -LiteralPath $path
        $name = ''; $err = $null; $summary = ''
        if ($exists) {
            try { $p = Read-PaletteProfile -Id $id; $name = $p.name; $summary = Get-PaletteSourceSummary -Source $p.source }
            catch { $err = $_.Exception.Message }
        }
        [pscustomobject]@{
            Id = $id; Exists = $exists; Name = $name; Label = (Get-PaletteProfileLabel -Id $id -Name $name)
            Error = $err; Active = ($id -eq $active); Summary = $summary
        }
    }
}

function ConvertTo-PaletteProfileJson {
    <# The profile as it's saved: only what differs from the defaults is left out where that's
       unambiguous; always pretty-printed, LF, trailing newline. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Profile)
    $out = [ordered]@{ schema = 1 }
    if ($Profile.name) { $out.name = $Profile.name }
    $out.source = $Profile.source
    $out.roles = $Profile.roles
    $ov = [ordered]@{}
    foreach ($t in $Profile.overrides.Keys) { if ($Profile.overrides[$t].Count) { $ov[$t] = $Profile.overrides[$t] } }
    $out.overrides = $ov
    $out.off = @($Profile.off)
    $out.readable = $Profile.readable
    $out.appMode = $Profile.appMode
    (($out | ConvertTo-Json -Depth 6) -replace "`r`n", "`n") + "`n"
}

function Save-PaletteProfile {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][System.Collections.IDictionary]$Profile)
    if ($Id -eq 'default') { throw "Default can't be changed -- save it as a new profile instead" }
    $json = ConvertTo-PaletteProfileJson -Profile $Profile
    $defRoles = (Get-PaletteDefaultProfile).roles
    $null = ConvertTo-PaletteProfile -Data (ConvertTo-PaletteCaseless ($json | ConvertFrom-Json -AsHashtable)) -DefaultRoles $defRoles   # round trip must read back
    $path = Get-PaletteProfilePath -Id $Id
    $null = Write-PaletteFile -Path $path -Text $json
}

function Remove-PaletteProfile {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq 'default') { throw "Default can't be deleted" }
    $path = Get-PaletteProfilePath -Id $Id
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Get-FreePaletteProfileId {
    foreach ($id in $script:PaletteProfileIds) {
        if ($id -ne 'default' -and -not (Test-Path -LiteralPath (Get-PaletteProfilePath -Id $id))) { return $id }
    }
    $null
}

function Get-ActivePaletteProfileId {
    <# The chosen profile -- 'default' when nothing's chosen (a fresh install) or the file says
       something that isn't a profile Id. Whether that profile still exists is the caller's
       question (Resolve-ActivePaletteProfile). #>
    $f = Get-PaletteChoicePath
    if (-not (Test-Path -LiteralPath $f)) { return 'default' }
    $id = ([IO.File]::ReadAllText($f)).Trim().ToLowerInvariant()
    if ($id -in $script:PaletteProfileIds) { return $id }
    'default'
}

function Set-ActivePaletteProfileId {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notin $script:PaletteProfileIds) { throw "'$Id' isn't a palette profile" }
    $null = New-Item -ItemType Directory -Force -Path (Get-PaletteStateDir)
    $null = Write-PaletteFile -Path (Get-PaletteChoicePath) -Text "$Id`n"
}

function Resolve-ActivePaletteProfile {
    <# The profile the pipeline uses: the chosen one, or Default (with a Warning saying why) when
       the chosen one is gone or broken. #>
    $id = Get-ActivePaletteProfileId
    if ($id -ne 'default') {
        try { return [pscustomobject]@{ Id = $id; Profile = (Read-PaletteProfile -Id $id); Warning = $null } }
        catch { return [pscustomobject]@{ Id = 'default'; Profile = (Get-PaletteDefaultProfile); Warning = "$($_.Exception.Message) -- using Default" } }
    }
    [pscustomobject]@{ Id = 'default'; Profile = (Get-PaletteDefaultProfile); Warning = $null }
}

# ------------------------------------------------------------------------------------------
# Sources -> wallust
# ------------------------------------------------------------------------------------------
function Get-PaletteSourceSummary {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Source)
    switch ($Source.kind) {
        'wallpaper' {
            $bits = @($Source.method)
            if ($Source.method -ne 'kmeans') { $bits += $Source.style }
            if ($Source.saturation) { $bits += "saturation $($Source.saturation)" }
            if ($Source.colors16) { $bits += '16 colours' }
            "wallpaper $([char]0xB7) $($bits -join ', ')"
        }
        'match'  { 'best-matching built-in theme' }
        'theme'  { "built-in theme $($Source.name)" }
        'random' { 'random built-in theme' }
        'scheme' { "scheme file $($Source.file)" }
    }
}

function Test-PaletteSourceUsesImage {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Source)
    $Source.kind -in 'wallpaper', 'match'
}

function Get-PaletteSourceKey {
    <# One string per distinct palette recipe -- two profiles with the same key get the same
       palette from the same wallpaper, so a switch between them never re-runs wallust. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Source)
    switch ($Source.kind) {
        'wallpaper' {
            $style = if ($Source.method -eq 'kmeans') { '-' } else { $Source.style }
            "wallpaper|$($Source.method)|$style|$([int]$Source.saturation)|$([bool]$Source.colors16)"
        }
        'theme'  { "theme|$($Source.name)" }
        'scheme' {
            $f = Join-Path (Get-PaletteSchemesDir) $Source.file
            $h = if (Test-Path -LiteralPath $f) { Get-PaletteLfSha256 -Path $f } else { 'missing' }
            "scheme|$($Source.file)|$h"
        }
        default { $Source.kind }
    }
}

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
        $why = @($r.Output | Where-Object { $_ -notmatch '^\s*\[I\]' } | Select-Object -Last 2) -join ' / '
        if (-not $why) { $why = "exit $($r.ExitCode)" }
        throw "wallust failed: $why"
    }
    Read-PaletteDump -Path $DumpPath
}

# ------------------------------------------------------------------------------------------
# Resolution: profile + palette -> roles + every target's properties
# ------------------------------------------------------------------------------------------
function Resolve-PaletteTheme {
    <# Pure: nothing is read from disk but the target definitions, nothing written. Returns
       Roles (role -> hex), Targets (id -> ordered prop -> hex), Off (ids), AppDark (bool),
       Raised (what the readability guard moved: "target.prop old->new"). Throws on a bad
       expression, naming where it is. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
          [Parameter(Mandatory)][System.Collections.IDictionary]$Palette,
          [object[]]$Targets = (Get-PaletteTargets))
    $roles = [ordered]@{}
    $visiting = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $Profile.roles.Keys) {
        if ($roles.Contains($r)) { continue }
        try {
            $null = $visiting.Add($r)
            $roles[$r] = Resolve-PaletteExpression -Text $Profile.roles[$r] -Palette $Palette -Roles $roles -RoleDefs $Profile.roles -Visiting $visiting
            $null = $visiting.Remove($r)
        } catch { throw "role '$r': $($_.Exception.Message)" }
    }
    # Keep the editor's order (roles resolved on demand land out of order above).
    $ordered = [ordered]@{}
    foreach ($r in $Profile.roles.Keys) { $ordered[$r] = $roles[$r] }
    $roles = $ordered

    $appDark = switch ($Profile.appMode) {
        'light' { $false }
        'auto'  { -not (Test-PaletteIsLight $roles['base']) }
        default { $true }
    }
    $out = [ordered]@{}
    $raised = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $Targets) {
        $vals = [ordered]@{}
        $ov = if ($Profile.overrides.Contains($t.Id)) { $Profile.overrides[$t.Id] } else { @{} }
        foreach ($prop in $t.Properties.Keys) {
            $expr = if ($ov.Contains($prop)) { $ov[$prop] } else { $t.Properties[$prop].Default }
            try { $vals[$prop] = Resolve-PaletteExpression -Text $expr -Palette $Palette -Roles $roles }
            catch { throw "$($t.Label) $([char]0x203A) $($t.Properties[$prop].Label): $($_.Exception.Message)" }
        }
        $out[$t.Id] = $vals
    }
    # Second pass: the readability guard. Only the foreground of a pair moves, so a pair may name
    # another target's colour as its background ('terminal.background' for the prompt).
    foreach ($t in $Targets) {
        $vals = $out[$t.Id]
        foreach ($pair in @($t.Readable)) {
            if (-not $pair) { continue }
            $mode = if ($pair.Guard -eq 'terminal') { $Profile.readable.terminal } else { $(if ($Profile.readable.ui) { 'auto' } else { 'off' }) }
            if ($mode -eq 'off') { continue }
            $fg = $vals[$pair.Fg]
            $bg = if ($pair.Bg -match '^(\w+)\.(\w+)$') { $out[$Matches[1]][$Matches[2]] } else { $vals[$pair.Bg] }
            if (-not $fg -or -not $bg) { continue }
            $fixed = Get-PaletteReadableHex -Hex $fg -Background $bg -Min $pair.Min -Direction $mode
            if ($fixed -ne $fg) { $raised.Add("$($t.Id).$($pair.Fg) $fg->$fixed"); $vals[$pair.Fg] = $fixed }
        }
    }
    [pscustomobject]@{
        Roles = $roles; Targets = $out; Off = @($Profile.off); AppDark = [bool]$appDark; Raised = @($raised)
    }
}

# ------------------------------------------------------------------------------------------
# Rendering and writing
# ------------------------------------------------------------------------------------------
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
    Move-Item -LiteralPath $tmp -Destination $Path -Force
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

# ------------------------------------------------------------------------------------------
# Small shared helpers the targets use
# ------------------------------------------------------------------------------------------
function Get-PaletteLfSha256 {
    <# sha256 of a text file with CRLF turned into LF -- the file as the repo stores it (doctor's
       Get-DoctorLfSha256, the same bytes). #>
    param([Parameter(Mandatory)][string]$Path)
    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)) -replace "`r`n", "`n"
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
}

function Save-PaletteOriginalStateOnce {
    <# The true-uninstall snapshot (tools\lib\activation.ps1's Save-OriginalState, same path and
       shape: %LOCALAPPDATA%\710.DesktopRice\original-state\<label>.json, written once ever) --
       uninstall's Restore-* functions read these. #>
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)]$Data)
    $dir = Join-Path (Get-PaletteStateDir) 'original-state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir "$Label.json"
    if (Test-Path $file) { return }
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
}

function Get-PaletteRegValueSnapshot {
    # One named value, never a whole key (activation.ps1's Get-RegValueSnapshot, same shape).
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if (-not $item) { return [ordered]@{ Existed = $false; Value = $null; Type = $null } }
    $kind = 'String'
    try { $kind = (Get-Item -Path $Path).GetValueKind($Name).ToString() } catch { }
    [ordered]@{ Existed = $true; Value = $item.$Name; Type = $kind }
}

function Send-PaletteSettingChange {
    # WM_SETTINGCHANGE 'ImmersiveColorSet' to every window -- the accent / dark-mode change lands live.
    if (-not ('Palette.Native.SettingChange' -as [type])) {
        Add-Type -Namespace Palette.Native -Name SettingChange -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    [Palette.Native.SettingChange]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 1000, [ref]$result) | Out-Null
}

function Send-PaletteKomorebiMessage {
    <# One JSON line per message to komorebi's socket (%LOCALAPPDATA%\komorebi\komorebi.sock) --
       komorebi-client's send_batch, for what komorebic has no command for (the stack-tab
       colours). A normal process reaches an elevated komorebi here exactly as komorebic does. #>
    param([Parameter(Mandatory)][object[]]$Messages)
    $path = Join-Path $env:LOCALAPPDATA 'komorebi\komorebi.sock'
    $socket = [System.Net.Sockets.Socket]::new([System.Net.Sockets.AddressFamily]::Unix,
        [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Unspecified)
    try {
        $socket.SendTimeout = 1000
        $socket.Connect([System.Net.Sockets.UnixDomainSocketEndPoint]::new($path))
        $text = -join @(foreach ($m in $Messages) { ($m | ConvertTo-Json -Compress) + "`n" })
        $null = $socket.Send([System.Text.Encoding]::UTF8.GetBytes($text))
        $socket.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
    } finally { $socket.Dispose() }
}

function Get-PaletteTerminalSettingsPath {
    @((Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
      (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')) |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Test-PaletteIsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# ------------------------------------------------------------------------------------------
# The theme stamp (doctor's "Theme made from the current ...")
# ------------------------------------------------------------------------------------------
function Get-PaletteThemeInputs {
    <# Everything that decides the colours, as "repo-relative path -> LF sha256": the entry
       script, this library, every file in tools\palette\targets, and the active profile as
       "profile:<id>" (its file's hash -- Default's file when Default is active). The pipeline
       writes these lines LAST (theme-inputs.sha256); doctor recomputes them and compares. #>
    param([string]$ProfileId = (Get-ActivePaletteProfileId))
    $root = $script:PaletteLibRoot
    $inputs = [ordered]@{}
    $inputs['tools\apply-wallust-outputs.ps1'] = Get-PaletteLfSha256 -Path (Join-Path $root 'tools\apply-wallust-outputs.ps1')
    $inputs['tools\lib\palette.ps1'] = Get-PaletteLfSha256 -Path (Join-Path $root 'tools\lib\palette.ps1')
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-PaletteTargetsDir) -File | Sort-Object Name)) {
        $inputs["tools\palette\targets\$($f.Name)"] = Get-PaletteLfSha256 -Path $f.FullName
    }
    $pf = Get-PaletteProfilePath -Id $ProfileId
    $inputs["profile:$ProfileId"] = if (Test-Path -LiteralPath $pf) { Get-PaletteLfSha256 -Path $pf } else { '0' * 64 }
    $inputs
}

function Write-PaletteThemeStamp {
    param([Parameter(Mandatory)][string]$ProfileId)
    $inputs = Get-PaletteThemeInputs -ProfileId $ProfileId
    $dir = Get-PaletteStateDir
    $null = New-Item -ItemType Directory -Path $dir -Force
    Set-Content -LiteralPath (Join-Path $dir 'theme-inputs.sha256') -Encoding ascii -Value @(
        foreach ($k in $inputs.Keys) { "$($inputs[$k])  $k" })
}

# ------------------------------------------------------------------------------------------
# Log and status (what doctor and the failure toast read)
# ------------------------------------------------------------------------------------------
function Write-PaletteLog {
    param([Parameter(Mandatory)][string]$Message, [switch]$Start)
    try {
        $dir = Get-PaletteStateDir
        $null = New-Item -ItemType Directory -Force -Path $dir
        $log = Join-Path $dir 'palette.log'
        if ($Start -and (Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
            Move-Item -LiteralPath $log -Destination "$log.old" -Force   # the one rule every log of ours follows
        }
        Add-Content -LiteralPath $log -Encoding utf8 -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

function Set-PaletteStatus {
    <# The last wallpaper-change / switch outcome. Ok = $false keeps the failure's time, the
       wallpaper's file name (never its folder) and wallust's reason, for doctor. #>
    param([bool]$Ok, [string]$Reason, [string]$Image, [string]$ProfileId,
          [ValidateSet('palette', 'targets')][string]$Stage = 'palette')
    try {
        $o = [ordered]@{ ok = $Ok; time = (Get-Date -Format 's'); profile = $ProfileId }
        if (-not $Ok) { $o.stage = $Stage; $o.reason = (ConvertTo-PaletteSafeText $Reason); $o.image = if ($Image) { Split-Path -Leaf $Image } else { '' } }
        $null = New-Item -ItemType Directory -Force -Path (Get-PaletteStateDir)
        $null = Write-PaletteFile -Path (Get-PaletteStatusPath) -Text (($o | ConvertTo-Json) + "`n")
    } catch { }
}

function Get-PaletteStatus {
    $f = Get-PaletteStatusPath
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { [IO.File]::ReadAllText($f) | ConvertFrom-Json -AsHashtable } catch { $null }
}

# ------------------------------------------------------------------------------------------
# The last good palette (config\wallust\generated\palette.json)
# ------------------------------------------------------------------------------------------
function Get-PaletteImageStamp {
    param([string]$Image)
    if (-not $Image -or -not (Test-Path -LiteralPath $Image)) { return '' }
    $i = Get-Item -LiteralPath $Image
    "$($i.Length)-$($i.LastWriteTimeUtc.Ticks)"
}

function Read-PaletteLastGood {
    $f = Get-PaletteLastGoodPath
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $d = [IO.File]::ReadAllText($f) | ConvertFrom-Json -AsHashtable
        $pal = [ordered]@{}
        foreach ($k in $script:PaletteSlots) { if (-not (Test-PaletteHex "$($d.palette[$k])")) { return $null }; $pal[$k] = $d.palette[$k] }
        [pscustomobject]@{ Palette = $pal; SourceKey = "$($d.sourceKey)"; Image = "$($d.image)"; ImageStamp = "$($d.imageStamp)"; Made = "$($d.made)" }
    } catch { $null }
}

function Save-PaletteLastGood {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Palette, [Parameter(Mandatory)][string]$SourceKey, [string]$Image)
    $o = [ordered]@{
        made = (Get-Date -Format 's'); sourceKey = $SourceKey; image = "$Image"; imageStamp = (Get-PaletteImageStamp $Image)
        palette = $Palette
    }
    $null = Write-PaletteFile -Path (Get-PaletteLastGoodPath) -Text (($o | ConvertTo-Json -Depth 4) + "`n")
}

# ------------------------------------------------------------------------------------------
# One at a time (a wallpaper change and a profile switch can meet)
# ------------------------------------------------------------------------------------------
function Enter-PaletteLock {
    param([int]$TimeoutSec = 90)
    $m = [System.Threading.Mutex]::new($false, 'Local\710sRice.Palette')
    try { if (-not $m.WaitOne($TimeoutSec * 1000)) { $m.Dispose(); return $null } }
    catch [System.Threading.AbandonedMutexException] { }   # the last holder died mid-run -- ours now
    $m
}

function Exit-PaletteLock {
    param($Lock)
    if ($Lock) { try { $Lock.ReleaseMutex() } catch { } ; $Lock.Dispose() }
}

# ------------------------------------------------------------------------------------------
# Applying (the pipeline, tools\apply-wallust-outputs.ps1)
# ------------------------------------------------------------------------------------------
function Get-PaletteCurrentWallpaper {
    <# The wallpaper that's up now: HKCU\Control Panel\Desktop\WallPaper -- what both
       SystemParametersInfo and YASB's IDesktopWallpaper call keep current (activation.ps1's
       Get-CurrentWallpaper, the same read). $null when none is set. #>
    (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper' -ErrorAction SilentlyContinue).WallPaper
}

function ConvertTo-PaletteSafeText {
    # No path under the user's folders in anything printed or logged (activation.ps1's
    # ConvertTo-SafeText rule: the profile folders, either slash, whole-folder matches).
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
        $d = [Environment]::GetEnvironmentVariable($v)
        if (-not $d) { continue }
        $d = $d.TrimEnd('\', '/')
        foreach ($form in @($d, $d.Replace('\', '/'))) {
            $Text = [regex]::Replace($Text, [regex]::Escape($form) + '(?=$|[\\/])', "%$v%", 'IgnoreCase')
        }
    }
    $Text
}

function Invoke-PaletteTargets {
    <# Writes / applies the targets that are on (or only -Only), in order: a file target's
       template to its Output (only when the bytes change), then its Apply. One target failing
       never stops the rest. -> one row per target: Id, Label, Status (ok / skipped / off /
       failed), Message, Changed. #>
    param([Parameter(Mandatory)]$Theme, [ValidateSet('full', 'reapply', 'borders')][string]$Mode = 'full',
          [string[]]$Only, [object[]]$Targets = (Get-PaletteTargets))
    $isAdmin = Test-PaletteIsAdmin
    foreach ($t in $Targets) {
        if ($Only -and $t.Id -notin $Only) { continue }
        if ($t.Id -in $Theme.Off) {
            [pscustomobject]@{ Id = $t.Id; Label = $t.Label; Status = 'off'; Message = 'off in this profile'; Changed = $false }
            continue
        }
        $changed = $false
        try {
            if ($t.Template -and $t.Output) {
                $path = & $t.Output
                if ($path) { $changed = Write-PaletteFile -Path $path -Text (Get-PaletteTargetText -Theme $Theme -Target $t) }
            }
            $r = @{ Status = 'ok'; Message = $t.Label }
            if ($t.Apply) {
                $ctx = @{ Mode = $Mode; IsAdmin = $isAdmin; Changed = $changed }
                $out = & $t.Apply $Theme.Targets[$t.Id] $Theme $ctx
                $res = @($out | Where-Object { $_ -is [System.Collections.IDictionary] }) | Select-Object -Last 1
                if ($res) { $r = $res }
            } elseif (-not $changed) { $r.Message = "$($t.Label) unchanged" }
            [pscustomobject]@{ Id = $t.Id; Label = $t.Label; Status = "$($r.Status)"; Message = (ConvertTo-PaletteSafeText "$($r.Message)"); Changed = $changed }
        } catch {
            [pscustomobject]@{ Id = $t.Id; Label = $t.Label; Status = 'failed'; Message = (ConvertTo-PaletteSafeText "$($t.Label): $($_.Exception.Message)"); Changed = $changed }
        }
    }
}

function Send-PaletteAhkMessage {
    <# Posts a registered message ('710sRice.PaletteFailed', ...) to 710.ahk's hidden window,
       found by its title (activation.ps1's Find-AhkWindow, the same lookup -- this library stays
       free of activation.ps1). 710.ahk lets these through UIPI itself; before it knows a message
       the post is simply refused. $false when 710.ahk isn't there. #>
    param([Parameter(Mandatory)][string]$Name)
    try {
        if (-not ('Palette.Native.Ahk' -as [type])) {
            Add-Type -Namespace Palette.Native -Name Ahk -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern uint RegisterWindowMessage(string lpString);
[DllImport("user32.dll")]
public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
'@
        }
        $script = Join-Path $script:PaletteLibRoot 'config\ahk\710.ahk'
        $hwnd = [IntPtr]::Zero
        while ($true) {
            # [NullString]::Value, not $null: $null reaches a .NET string as "" (activation.ps1's note).
            $hwnd = [Palette.Native.Ahk]::FindWindowEx([IntPtr]::Zero, $hwnd, 'AutoHotkey', [NullString]::Value)
            if ($hwnd -eq [IntPtr]::Zero) { return $false }
            $sb = [System.Text.StringBuilder]::new(1024)
            [void][Palette.Native.Ahk]::GetWindowText($hwnd, $sb, $sb.Capacity)
            if ($sb.ToString().IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -ge 0) { break }
        }
        [Palette.Native.Ahk]::PostMessage($hwnd, [Palette.Native.Ahk]::RegisterWindowMessage($Name), [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { $false }
}
