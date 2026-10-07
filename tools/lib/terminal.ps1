<#
.SYNOPSIS
  Windows Terminal's font faces, in its settings.json: where each one is set (the defaults and
  each profile that sets its own), setting or clearing one, and the Nerd Font cleared from every
  profile before uninstall removes it. Shared by the terminal component (tools\components\
  terminal.ps1: its step, its revert, doctor's font line) and uninstall's packages section.
  Loaded by tools\lib\activation.ps1. Only functions.
#>

function Get-TerminalFontFaces {
    <# Every place Windows Terminal's settings name a font face: profiles.defaults (every profile),
       and each profile in profiles.list that sets its own -- a profile's own face wins over the
       defaults, so those are the faces Terminal draws with. [pscustomobject] Key ('defaults', or
       the profile's guid -- 'name:<name>' without one), Name, Face ($null: the defaults set none). #>
    param($Settings)
    $p = $Settings['profiles']
    if ($p -isnot [System.Collections.IDictionary]) { return }
    $d = $p['defaults']
    $face = if ($d -is [System.Collections.IDictionary] -and $d['font'] -is [System.Collections.IDictionary] -and $d['font'].Contains('face')) { "$($d['font']['face'])" } else { $null }
    [pscustomobject]@{ Key = 'defaults'; Name = 'every profile'; Face = $face }
    foreach ($x in @($p['list'])) {
        if ($x -isnot [System.Collections.IDictionary] -or $x['font'] -isnot [System.Collections.IDictionary] -or -not $x['font'].Contains('face')) { continue }
        $key = if ($x['guid']) { "$($x['guid'])" } else { "name:$($x['name'])" }
        [pscustomobject]@{ Key = $key; Name = "$($x['name'])"; Face = "$($x['font']['face'])" }
    }
}

function Set-TerminalFontFace {
    <# Sets (or, $Face = $null, removes) the font face at one Get-TerminalFontFaces Key in the
       settings hashtable; a font object left empty is removed with it. Leaves size / weight alone. #>
    param($Settings, [string]$Key, [AllowNull()][string]$Face)
    if ($Settings['profiles'] -isnot [System.Collections.IDictionary]) { $Settings['profiles'] = @{} }
    $p = $Settings['profiles']
    $target = if ($Key -eq 'defaults') {
        if ($p['defaults'] -isnot [System.Collections.IDictionary]) { $p['defaults'] = @{} }
        $p['defaults']
    } else {
        @($p['list']) | Where-Object { $_ -is [System.Collections.IDictionary] -and ($(if ($Key.StartsWith('name:')) { "name:$($_['name'])" } else { "$($_['guid'])" }) -eq $Key) } | Select-Object -First 1
    }
    if (-not $target) { return }
    if ($null -eq $Face -or $Face -eq '') {
        if ($target['font'] -is [System.Collections.IDictionary]) {
            $target['font'].Remove('face')
            if (-not $target['font'].Count) { $target.Remove('font') }
        }
    } else {
        if ($target['font'] -isnot [System.Collections.IDictionary]) { $target['font'] = @{} }
        $target['font']['face'] = $Face
    }
}

function Clear-TerminalNerdFontFaces {
    <# uninstall -Force, right before it removes the JetBrainsMono Nerd Font package: any Windows
       Terminal face that still names it (after uninstall put Terminal's own "before" back -- a
       "before" that was already the Nerd Font, winarchy's on the Dell, or yours) goes back to
       Terminal's own font, so no profile names a font that's gone. (B2's and T5's vanished
       window, 2026-10-01, turned out to be Windows Installer's Restart Manager closing Terminal
       during the font's MSI uninstall -- uninstall.ps1 now removes it with that off: see
       Invoke-MsiUninstall in tools\lib\packages.ps1.) Returns the names of the places changed
       (empty: nothing to do; $null: no settings). #>
    $path = @("$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
              "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $path) { return $null }
    $wt = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    $hits = @(Get-TerminalFontFaces $wt | Where-Object { "$($_.Face)" -match '^JetBrainsMono (NF|NFM|NFP|Nerd Font)\b' })
    foreach ($h in $hits) { Set-TerminalFontFace -Settings $wt -Key "$($h.Key)" -Face $null }
    if ($hits.Count) { $wt | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding UTF8 }
    @($hits | ForEach-Object Name)
}
