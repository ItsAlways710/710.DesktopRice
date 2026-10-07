<#
.SYNOPSIS
  Where the stack's apps are installed: komorebi and komorebic, yasbc, AutoHotkey (the UI Access
  build first), ShareX. $null for one that isn't. Loaded by tools\lib\activation.ps1. Only
  functions.
#>

# --- Component discovery (shared by Defender exclusions + autostart) ----------------
function Get-KomorebiExe {
    $found = (Get-Command komorebi.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $found) {
        $found = @("$env:ProgramFiles\komorebi\bin\komorebi.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    $found
}

function Get-KomorebicExe {
    <# komorebic.exe: next to the installed komorebi.exe first, then PATH; $null when neither.
       A window opened before the install doesn't have komorebi on its PATH, and uninstall never
       re-read it -- so `komorebic stop` was skipped and komorebi only force-killed, which leaves
       the windows it had cloaked on other workspaces invisible (base.json's
       window_hiding_behaviour Cloak; its own stop is what restores them). winarchy ca66652,
       Group 1 W6. Used by Stop-RunningComponents and Stop-PinnedApp. #>
    $komorebi = Get-KomorebiExe
    if ($komorebi) {
        $next = Join-Path (Split-Path -Parent $komorebi) 'komorebic.exe'
        if (Test-Path -LiteralPath $next) { return $next }
    }
    (Get-Command komorebic.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}

function Get-YasbcExe {
    <# yasbc.exe (YASB's CLI): next to the installed yasb.exe first (winget puts both in
       Program Files\YASB), then PATH; $null when neither. Same reason as Get-KomorebicExe. #>
    $next = Join-Path "$env:ProgramFiles" 'YASB\yasbc.exe'
    if ($env:ProgramFiles -and (Test-Path -LiteralPath $next)) { return $next }
    (Get-Command yasbc.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}

function Get-AhkExe {
    <# AutoHotkey v2, per-machine or per-user; $null if not installed. Prefers the UI Access
       build (AutoHotkey64_UIA.exe) so 710.ahk's hotkeys still reach an admin window that has
       focus -- without running AHK itself elevated, which would make everything it launches
       elevated too (plan doc, Open item 36). The UIA exe only exists (and only works) in a
       Program Files install -- AutoHotkey's installer creates and signs it there -- so a
       per-user install falls through to the plain exe, same as before. #>
    $found = @(
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64_UIA.exe",
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { $found = (Get-Command AutoHotkey64.exe -ErrorAction SilentlyContinue)?.Source }
    $found
}

function Get-ShareXExe {
    @("$env:ProgramFiles\ShareX\ShareX.exe", "${env:ProgramFiles(x86)}\ShareX\ShareX.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
