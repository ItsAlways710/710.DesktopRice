#Requires -Version 7.0
<#
.SYNOPSIS
  Obsidian and the palette (tools\palette\targets\obsidian.ps1): the vaults Obsidian lists, the
  710rice.css snippet the target writes into each (Get-ObsidianSnippetText) and switches on in that
  vault's own appearance.json, what uninstall puts back (Restore-ObsidianTheme, Undo-ObsidianTheme)
  and doctor's line (Test-DoctorObsidianTheme). The target dot-sources this file;
  tools\lib\activation.ps1 loads it for uninstall and doctor. Only functions.

.DESCRIPTION
  How Obsidian takes a snippet (1.14.4's own app.js, then run for real -- the Linux build of the
  same app package, read over the DevTools protocol, 2026-10-16): it watches
  <vault>\.obsidian\snippets, so a snippet that's switched on repaints the moment its file
  changes. Which snippets are on, it reads from appearance.json once, when it starts: an
  appearance.json changed while it runs updates its settings, but not the snippets it shows --
  and the next time you switch any snippet on or off in Settings > Appearance, it writes its own
  list back, without ours. So the very first switch-on shows after Obsidian restarts (the
  target's line says so), and every theme run puts ours back if it was dropped.

  The accent (the same app.js): Obsidian's colours for links, tags, buttons, checkboxes and the
  selection all come from --accent-h, --accent-s and --accent-l. An accent picked in Settings >
  Appearance > Accent color is kept in appearance.json (accentColor) and set on the page itself
  (body's own style), which beats any snippet; its restore-default arrow clears it. So the snippet
  puts the palette's accent in those three, as the default, and a picked one stays through every
  theme run: nothing here writes accentColor.

  Each machine themes its own vault copy: the snippet and appearance.json stay on the machine
  (a vault synced between machines needs both left out of the sync, or each machine's colours
  overwrite the others' -- the palette chapter says so).
#>

function Get-ObsidianSnippetName { '710rice' }

function Get-ObsidianVaults {
    <# The vaults %APPDATA%\obsidian\obsidian.json lists ({"vaults": {<id>: {path, ts, open}}})
       that are here with their .obsidian folder (Obsidian has opened them on this machine), as
       full paths. -> Listed: $false when Obsidian has never run here (no obsidian.json); Vaults.
       A file that isn't JSON throws. #>
    $file = Join-Path $env:APPDATA 'obsidian' 'obsidian.json'
    if (-not (Test-Path -LiteralPath $file)) { return [pscustomobject]@{ Listed = $false; Vaults = @() } }
    $j = [IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths = [System.Collections.Generic.List[string]]::new()
    if ($j -is [System.Collections.IDictionary] -and $j['vaults'] -is [System.Collections.IDictionary]) {
        foreach ($v in $j['vaults'].Values) {
            $p = if ($v -is [System.Collections.IDictionary]) { "$($v['path'])" } else { '' }
            if ($p -and (Test-Path -LiteralPath (Join-Path $p '.obsidian') -PathType Container) -and $seen.Add($p.TrimEnd('\', '/'))) { $paths.Add($p) }
        }
    }
    [pscustomobject]@{ Listed = $true; Vaults = @($paths) }
}

function Get-ObsidianSnippetPath {
    param([Parameter(Mandatory)][string]$Vault)
    Join-Path $Vault '.obsidian' 'snippets' "$(Get-ObsidianSnippetName).css"
}

function Get-ObsidianAppearancePath {
    param([Parameter(Mandatory)][string]$Vault)
    Join-Path $Vault '.obsidian' 'appearance.json'
}

function Get-ObsidianStateLabel {
    # The vault's original-state snapshot: one per vault, named by a hash of its path (no vault names in file names).
    param([Parameter(Mandatory)][string]$Vault)
    $h = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Vault.TrimEnd('\', '/').ToLowerInvariant())))
    "obsidian-$($h.Substring(0, 12).ToLowerInvariant())"
}

function Read-ObsidianAppearance {
    <# A vault's appearance.json: Exists, Data (its settings, in order; empty when there's no file).
       A file that isn't a JSON object throws, naming the vault (never its path). #>
    param([Parameter(Mandatory)][string]$Vault)
    $f = Get-ObsidianAppearancePath -Vault $Vault
    if (-not (Test-Path -LiteralPath $f)) { return [pscustomobject]@{ Exists = $false; Data = [ordered]@{} } }
    $text = [IO.File]::ReadAllText($f)
    $data = $null
    if ($text.Trim()) { try { $data = $text | ConvertFrom-Json -AsHashtable } catch { } } else { $data = [ordered]@{} }
    if ($data -isnot [System.Collections.IDictionary]) { throw "$(Split-Path -Leaf $Vault)'s .obsidian\appearance.json isn't readable JSON" }
    [pscustomobject]@{ Exists = $true; Data = $data }
}

function Test-ObsidianSnippetOn {
    # Ours in the vault's enabledCssSnippets (Read-ObsidianAppearance's result).
    param([Parameter(Mandatory)]$Appearance)
    @($Appearance.Data['enabledCssSnippets']) -contains (Get-ObsidianSnippetName)
}

function ConvertTo-ObsidianHsl {
    <# '#rrggbb' -> H, S, L as Obsidian sets them for an accent picked in its settings (app.js
       1.14.4: whole numbers, JavaScript's rounding -- half up, where PowerShell's rounds half to
       even), so the palette's default sits in --accent-h/s/l just as a picked one would. #>
    param([Parameter(Mandatory)][string]$Hex)
    $c = ConvertTo-PaletteRgb -Hex $Hex
    $r = $c.R / 255.0; $g = $c.G / 255.0; $b = $c.B / 255.0
    $hi = [Math]::Max($r, [Math]::Max($g, $b)); $lo = [Math]::Min($r, [Math]::Min($g, $b))
    $light = ($hi + $lo) / 2; $hue = 0.0; $sat = 0.0
    if ($hi -ne $lo) {
        $d = $hi - $lo
        $sat = if ($light -gt 0.5) { $d / (2 - $hi - $lo) } else { $d / ($hi + $lo) }
        $hue = if ($hi -eq $r) { ($g - $b) / $d + $(if ($g -lt $b) { 6 } else { 0 }) }
               elseif ($hi -eq $g) { ($b - $r) / $d + 2 }
               else { ($r - $g) / $d + 4 }
        $hue /= 6
    }
    [pscustomobject]@{
        H = [int][Math]::Floor($hue * 360 + 0.5)
        S = [int][Math]::Floor($sat * 100 + 0.5)
        L = [int][Math]::Floor($light * 100 + 0.5)
    }
}

function Get-ObsidianSnippetText {
    <# The snippet for a theme: the target's template with its colours, plus {{accentH}},
       {{accentS}} and {{accentL}} -- the accent as the numbers Obsidian's own slot for it takes
       (ConvertTo-ObsidianHsl). Uses the palette library, so it runs in the pipeline: the target
       calls it. #>
    param([Parameter(Mandatory)]$Theme)
    $t = Get-PaletteTarget -Id 'obsidian'
    $values = Get-PaletteTemplateValues -Theme $Theme -TargetId 'obsidian'
    $hsl = ConvertTo-ObsidianHsl -Hex $values['accent']
    $values['accentH'] = $hsl.H; $values['accentS'] = $hsl.S; $values['accentL'] = $hsl.L
    $tpl = Join-Path (Split-Path -Parent $t.File) $t.Template
    Expand-PaletteTemplate -Text ([IO.File]::ReadAllText($tpl)) -Values $values
}

function ConvertTo-ObsidianJson {
    # How Obsidian writes its own settings files (JSON.stringify(x, null, 2)): two-space indents, LF.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    ($Data | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
}

function Set-ObsidianVaultTheme {
    <# The palette target's work in one vault: what's there saved first (once, ever -- before the
       first change, whenever the vault first turns up), the snippet written (only when it
       changes), and switched on in appearance.json if it isn't. Palette library helpers
       (Save-PaletteOriginalStateOnce, Write-PaletteFile): the pipeline's. -> Written, Enabled. #>
    param([Parameter(Mandatory)][string]$Vault, [Parameter(Mandatory)][string]$Css)
    $snippet = Get-ObsidianSnippetPath -Vault $Vault
    $appPath = Get-ObsidianAppearancePath -Vault $Vault
    $app = Read-ObsidianAppearance -Vault $Vault          # a broken file throws here: nothing changed yet
    $bytes = { param($p) if (Test-Path -LiteralPath $p) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) } }
    Save-PaletteOriginalStateOnce -Label (Get-ObsidianStateLabel -Vault $Vault) -Data ([ordered]@{
        Vault              = $Vault
        AppearanceExisted  = $app.Exists
        AppearanceBytes    = & $bytes $appPath
        SnippetsDirExisted = Test-Path -LiteralPath (Split-Path -Parent $snippet)
        SnippetExisted     = Test-Path -LiteralPath $snippet
        SnippetBytes       = & $bytes $snippet
    })
    $written = Write-PaletteFile -Path $snippet -Text $Css
    $enabled = $false
    if (-not (Test-ObsidianSnippetOn -Appearance $app)) {
        $app.Data['enabledCssSnippets'] = @(@($app.Data['enabledCssSnippets']) | Where-Object { $_ }) + @(Get-ObsidianSnippetName)
        $null = Write-PaletteFile -Path $appPath -Text (ConvertTo-ObsidianJson -Data $app.Data)
        $enabled = $true
    }
    [pscustomobject]@{ Written = [bool]$written; Enabled = $enabled }
}

# --- uninstall ------------------------------------------------------------------------------------
function Restore-ObsidianVault {
    <# One vault back: the snippet gone (or back to what it was -- the odd 710rice.css from before
       us), the snippets folder too if we made it and it's empty, and ours out of
       enabledCssSnippets, touching nothing else in appearance.json. When nothing else in it
       changed since, the file goes back exactly as it was (or away, when there was none). #>
    param([Parameter(Mandatory)][string]$Vault, [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)
    $name = Get-ObsidianSnippetName
    $snippet = Get-ObsidianSnippetPath -Vault $Vault
    if ($Snapshot.SnippetExisted -and $Snapshot.SnippetBytes) { [IO.File]::WriteAllBytes($snippet, [Convert]::FromBase64String($Snapshot.SnippetBytes)) }
    else { Remove-Item -LiteralPath $snippet -Force -ErrorAction SilentlyContinue }
    $dir = Split-Path -Parent $snippet
    if (-not $Snapshot.SnippetsDirExisted -and (Test-Path -LiteralPath $dir) -and -not @(Get-ChildItem -LiteralPath $dir -Force).Count) {
        Remove-Item -LiteralPath $dir -Force
    }
    $appPath = Get-ObsidianAppearancePath -Vault $Vault
    $app = Read-ObsidianAppearance -Vault $Vault
    if (-not $app.Exists -or -not (Test-ObsidianSnippetOn -Appearance $app)) { return }   # ours is out already
    $origBytes = if ($Snapshot.AppearanceExisted -and $Snapshot.AppearanceBytes) { [Convert]::FromBase64String($Snapshot.AppearanceBytes) }
    $orig = if ($origBytes) { try { [Text.Encoding]::UTF8.GetString($origBytes) | ConvertFrom-Json -AsHashtable } catch { $null } } else { [ordered]@{} }
    $rest = @(@($app.Data['enabledCssSnippets']) | Where-Object { $_ -and $_ -ne $name })
    $hadKey = $orig -is [System.Collections.IDictionary] -and $orig.Contains('enabledCssSnippets')
    if ($rest.Count -or $hadKey) { $app.Data['enabledCssSnippets'] = $rest } else { $app.Data.Remove('enabledCssSnippets') }
    $utf8 = [Text.UTF8Encoding]::new($false)
    if ($orig -is [System.Collections.IDictionary] -and (ConvertTo-ObsidianJson -Data $app.Data) -ceq (ConvertTo-ObsidianJson -Data $orig)) {
        if ($origBytes) { [IO.File]::WriteAllBytes($appPath, $origBytes) } else { Remove-Item -LiteralPath $appPath -Force }
        return
    }
    [IO.File]::WriteAllText($appPath, (ConvertTo-ObsidianJson -Data $app.Data), $utf8)
}

function Restore-ObsidianTheme {
    <# Undoes the palette's Obsidian target in every vault it ever themed (one snapshot each,
       original-state\obsidian-<hash>.json); a vault that's gone since just loses its snapshot.
       Obsidian running: its colours go back at once (the snippet's gone), and it may write ours
       back into its list the next time a snippet is switched in its settings -- a name with no
       file, which loads nothing. -> how many vaults were put back. #>
    $dir = Get-OriginalStateDir
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'obsidian-*.json' -File)) {
        $snap = Get-OriginalState -Label $f.BaseName
        $vault = if ($snap -is [System.Collections.IDictionary]) { "$($snap['Vault'])" } else { '' }
        if ($vault -and (Test-Path -LiteralPath (Join-Path $vault '.obsidian') -PathType Container)) {
            Restore-ObsidianVault -Vault $vault -Snapshot $snap
            $n++
        }
        Remove-OriginalState -Label $f.BaseName
    }
    $n
}

function Undo-ObsidianTheme {
    # uninstall, section 3: Obsidian's vaults as they were (Restore-ObsidianTheme), and a line saying how that went.
    $n = Restore-ObsidianTheme
    if ($n) { Step-Ok "Obsidian: the 710rice snippet taken out of $n vault$(if ($n -ne 1) { 's' }) and their appearance settings put back" }
    else { Step-Info 'Obsidian was never themed by the palette -- nothing to restore.' }
}

# --- doctor ---------------------------------------------------------------------------------------
function Test-DoctorObsidianTheme {
    # Obsidian on the palette's colours (tools\palette\targets\obsidian.ps1): in every vault
    # Obsidian lists here, the snippet there and switched on. Skipped when the chosen profile
    # switches Obsidian off, or Obsidian has never run here. The snippet switched off in
    # Obsidian's own settings reads as [XX]: the next theme run switches it back on -- switch
    # Obsidian off in the profile to keep it off. Read-only, like all of doctor.
    $active = Resolve-ActivePaletteProfile
    if ('obsidian' -in $active.Profile.off) {
        return New-DoctorResult -Id 'obsidian-theme' -Status '..' -Text "Obsidian's colours: off in $(Get-PaletteProfileLabel -Id $active.Id -Name $active.Profile.name)"
    }
    $found = Get-ObsidianVaults
    if (-not $found.Listed -or -not $found.Vaults.Count) { return }
    $problems = @(foreach ($v in $found.Vaults) {
        $vn = Split-Path -Leaf $v
        if (-not (Test-Path -LiteralPath (Get-ObsidianSnippetPath -Vault $v))) { "$vn has no 710rice.css"; continue }
        try { if (-not (Test-ObsidianSnippetOn -Appearance (Read-ObsidianAppearance -Vault $v))) { "710rice is switched off in $vn" } }
        catch { $_.Exception.Message }
    })
    $count = "$($found.Vaults.Count) vault$(if ($found.Vaults.Count -ne 1) { 's' })"
    if ($problems.Count) {
        return New-DoctorResult -Id 'obsidian-theme' -Status 'XX' -Text "Obsidian isn't all on the palette's colours ($count)" -Detail $problems -Fix '710sRice install -Only palette' -Step 'palette'
    }
    New-DoctorResult -Id 'obsidian-theme' -Status 'OK' -Text "Obsidian themed (710rice, $count)"
}
