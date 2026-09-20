<#
.SYNOPSIS
    Applies wallust's generated colors to everything that isn't a simple CSS
    import: komorebi's live border colors and the Windows accent color.
    (YASB gets its colors directly via config/wallust/templates/yasb-colors.css.tpl
    -- no script needed there, it's just an @import.)

.DESCRIPTION
    Chained as the second entry in YASB's Wallpapers widget run_after list
    (config/yasb/config.yaml), right after `wallust run` -- NOT wallust's own
    [hooks] feature, which is confirmed broken on this pinned 4.1.0-alpha build
    (see config/wallust/wallust.toml for the isolation test that proved it).
    So this runs every time wallust regenerates a palette, which itself is
    triggered whenever the wallpaper changes.

    Windows-accent-setting logic is ported from winarchy's own
    Set-WinarchyWindowsAppearance / Send-WinarchyColorSetChange
    (module/Winarchy/Private/ThemeEngine.ps1) -- real, already-proven-on-this-
    machine registry mechanics, reimplemented standalone with zero dependency on
    winarchy's module, per this repo's build methodology (port specific relied-on
    behavior deliberately, don't reinvent or guess).

    Border color shading (monocle = lighter, stack = darker) also mirrors
    winarchy's own Get-WinarchyShadedHex lerp-toward-white/black approach.
#>

$ErrorActionPreference = "Stop"

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ColorsJson = Join-Path $RepoRoot "config\wallust\generated\colors.json"

if (-not (Test-Path $ColorsJson)) {
    throw "Expected wallust to have generated $ColorsJson before running this hook."
}
$colors = Get-Content $ColorsJson -Raw | ConvertFrom-Json

function ConvertTo-Rgb {
    param([Parameter(Mandatory)][string]$Hex)
    $h = $Hex.TrimStart('#')
    [pscustomobject]@{
        R = [Convert]::ToInt32($h.Substring(0, 2), 16)
        G = [Convert]::ToInt32($h.Substring(2, 2), 16)
        B = [Convert]::ToInt32($h.Substring(4, 2), 16)
    }
}

function Get-ShadedHex {
    <# Lerp '#rrggbb' toward white (Factor > 0) or black (Factor < 0).
       Ported from winarchy's Get-WinarchyShadedHex. #>
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

# --- komorebi border colors -------------------------------------------------
# single (focused)  = the shared accent, direct
# monocle           = accent, lightened
# stack             = accent, darkened
# unfocused         = the same dark slot YASB uses for background -- recedes
#                      rather than drawing attention, matching winarchy's own
#                      "unfocused = darker_background" default (not accent-based)
$accent = $colors.color3
$bg     = $colors.color1

$borders = @{
    single    = $accent
    monocle   = Get-ShadedHex -Hex $accent -Factor 0.25
    stack     = Get-ShadedHex -Hex $accent -Factor -0.2
    unfocused = $bg
}

# komorebic talks to a running komorebi process over a local socket -- if
# komorebi isn't running (e.g. testing YASB/wallust standalone, per this
# project's usual testing pattern), that connection is refused. Not an error
# worth alarming over with a raw Rust panic -- check once, skip quietly if so.
$komorebiRunning = $null -ne (Get-Process -Name "komorebi" -ErrorAction SilentlyContinue)
if ($komorebiRunning) {
    foreach ($kind in $borders.Keys) {
        $rgb = ConvertTo-Rgb -Hex $borders[$kind]
        & komorebic.exe border-colour --window-kind $kind $rgb.R $rgb.G $rgb.B 2>$null
    }
} else {
    Write-Host "komorebi isn't running -- skipped border colors."
}

# --- Windows accent color ----------------------------------------------------
# Ported from winarchy's Set-WinarchyWindowsAppearance / Send-WinarchyColorSetChange.
# Always dark mode -- no light-mode path exists anywhere in this project.
$personalize = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
Set-ItemProperty -Path $personalize -Name 'AppsUseLightTheme' -Value 0 -Type DWord
Set-ItemProperty -Path $personalize -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
Set-ItemProperty -Path $personalize -Name 'ColorPrevalence' -Value 1 -Type DWord
Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -Name 'ColorPrevalence' -Value 1 -Type DWord

try {
    $accentRgb = ConvertTo-Rgb -Hex $accent
    $abgr = (0xFF -shl 24) -bor ($accentRgb.B -shl 16) -bor ($accentRgb.G -shl 8) -bor $accentRgb.R
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -Name 'AccentColor' -Value $abgr -Type DWord
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -Name 'ColorizationColor' -Value $abgr -Type DWord
}
catch {
    Write-Warning "Windows accent not applied: $($_.Exception.Message)"
}

if (-not ('Wallust.Native.SettingChange' -as [type])) {
    Add-Type -Namespace Wallust.Native -Name SettingChange -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
}
$result = [UIntPtr]::Zero
# HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG -- makes it apply live, no logoff/restart
[Wallust.Native.SettingChange]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 1000, [ref]$result) | Out-Null

Write-Host "wallust outputs applied: komorebi borders + Windows accent ($accent)"

# --- Windows Terminal: color scheme selection + tab-row theme ---------------
# wallust already writes/updates a "wallust" entry in schemes[] on every run --
# that's built-in wallust behavior (confirmed against its own docs), no
# [templates] entry needed for it. Windows Terminal just requires it to be
# selected manually the first time, so this section does the two things
# wallust itself won't:
#   1. Point profiles.defaults.colorScheme at "wallust", globally (every
#      profile -- PowerShell, cmd, Azure Cloud Shell, VS dev prompts, all of
#      it) -- same scope winarchy's own Merge-WinarchyTerminalScheme uses for
#      its "Winarchy" scheme.
#   2. Add/replace a "wallust" themes[] entry (tab row background + dark
#      window chrome) and select it as the active theme, so the tab row
#      tracks the wallpaper too. colorScheme (pane content) and theme (tab
#      row/window chrome) are two separate Windows Terminal systems -- wallust
#      only ever writes the first one.
# Strip-by-name-then-append pattern ported from winarchy's own
# Merge-WinarchyTerminalScheme (module/Winarchy/Private/ThemeEngine.ps1).
$wtSettingsCandidates = @(
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
)
$wtSettingsPath = $wtSettingsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($wtSettingsPath) {
    $wt = Get-Content $wtSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

    if (-not $wt.ContainsKey('profiles') -or $wt['profiles'] -isnot [hashtable]) { $wt['profiles'] = @{} }
    if (-not $wt['profiles'].ContainsKey('defaults') -or $wt['profiles']['defaults'] -isnot [hashtable]) {
        $wt['profiles']['defaults'] = @{}
    }
    $wt['profiles']['defaults']['colorScheme'] = 'wallust'

    $wtTheme = @{
        name   = 'wallust'
        tabRow = @{ background = $bg; unfocusedBackground = $bg }
        window = @{ applicationTheme = 'dark' }
    }
    if (-not $wt.ContainsKey('themes') -or $wt['themes'] -isnot [array]) { $wt['themes'] = @() }
    $wt['themes'] = @($wt['themes'] | Where-Object { $_['name'] -ne 'wallust' }) + @($wtTheme)
    $wt['theme'] = 'wallust'

    $wt | ConvertTo-Json -Depth 50 | Set-Content -Path $wtSettingsPath -Encoding UTF8
    Write-Host "Windows Terminal: colorScheme + theme set to 'wallust'."
} else {
    Write-Host "Windows Terminal settings.json not found -- skipped."
}
