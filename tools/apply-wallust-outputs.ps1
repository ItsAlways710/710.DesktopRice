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
[CmdletBinding()]
param(
    # Re-push only the komorebi border colors from the current palette, then stop --
    # no Windows accent, no Terminal merge, no lock-screen fire, no snapshots. For callers
    # that just (re)started or reloaded komorebi and need its borders back, because
    # `komorebic border-colour` is runtime-only state: every komorebi start comes up on
    # its own default (blue) borders, and nothing in base.json can carry wallust's live
    # palette. Callers: tools\reload-stack.ps1 (SUPER+Shift+R) and scripts\Start-Komorebi.ps1
    # (boot). Exits 1 if komorebi isn't running, since then there was nothing to apply.
    [switch]$BordersOnly
)

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

function Save-OriginalStateOnce {
    <# Self-contained one-time snapshot -- this script stays dependency-free by design (see
       its own header above), so this duplicates tools\lib\activation.ps1's Save-
       OriginalState rather than dot-sourcing it. Same path convention
       (%LOCALAPPDATA%\710.DesktopRice\original-state\<label>.json), so uninstall.ps1's
       Restore-* functions (which DO dot-source that file) can read what this writes. Keep
       both copies in sync if this shape ever changes. #>
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)]$Data)
    $dir = Join-Path $env:LOCALAPPDATA '710.DesktopRice\original-state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir "$Label.json"
    if (Test-Path $file) { return }
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
}

function Get-RegValueSnapshotLocal {
    <# Same shape as activation.ps1's Get-RegValueSnapshot (single named value, never a
       whole key -- see that function's own comment for why) -- duplicated here for the
       same dependency-free reason as Save-OriginalStateOnce above. #>
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if (-not $item) { return [ordered]@{ Existed = $false; Value = $null; Type = $null } }
    $kind = 'String'
    try { $kind = (Get-Item -Path $Path).GetValueKind($Name).ToString() } catch { }
    [ordered]@{ Existed = $true; Value = $item.$Name; Type = $kind }
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

# -BordersOnly: borders were the whole job. Everything below (accent, Terminal, lock-screen
# task) is wallpaper-change work that a plain komorebi (re)start has no reason to redo.
if ($BordersOnly) {
    if ($komorebiRunning) { Write-Host 'wallust borders re-applied to komorebi.'; exit 0 }
    exit 1
}

# --- Windows accent color ----------------------------------------------------
# Ported from winarchy's Set-WinarchyWindowsAppearance / Send-WinarchyColorSetChange.
# Always dark mode -- no light-mode path exists anywhere in this project.
$personalize = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$dwm = 'HKCU:\SOFTWARE\Microsoft\Windows\DWM'
# One-time snapshot of whatever these values were before this script ever ran -- only the
# very first run (across the life of the install, not just this process) actually writes
# the file; every later wallpaper change finds it already there and skips. Restored by
# uninstall.ps1's Restore-WindowsAccent (tools\lib\activation.ps1).
Save-OriginalStateOnce -Label 'windows-accent' -Data @{
    Personalize_AppsUseLightTheme    = Get-RegValueSnapshotLocal -Path $personalize -Name 'AppsUseLightTheme'
    Personalize_SystemUsesLightTheme = Get-RegValueSnapshotLocal -Path $personalize -Name 'SystemUsesLightTheme'
    Personalize_ColorPrevalence      = Get-RegValueSnapshotLocal -Path $personalize -Name 'ColorPrevalence'
    Dwm_ColorPrevalence              = Get-RegValueSnapshotLocal -Path $dwm -Name 'ColorPrevalence'
    Dwm_AccentColor                  = Get-RegValueSnapshotLocal -Path $dwm -Name 'AccentColor'
    Dwm_ColorizationColor            = Get-RegValueSnapshotLocal -Path $dwm -Name 'ColorizationColor'
}
Set-ItemProperty -Path $personalize -Name 'AppsUseLightTheme' -Value 0 -Type DWord
Set-ItemProperty -Path $personalize -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
Set-ItemProperty -Path $personalize -Name 'ColorPrevalence' -Value 1 -Type DWord
Set-ItemProperty -Path $dwm -Name 'ColorPrevalence' -Value 1 -Type DWord

$accentApplied = $false
try {
    $accentRgb = ConvertTo-Rgb -Hex $accent
    $abgr = (0xFF -shl 24) -bor ($accentRgb.B -shl 16) -bor ($accentRgb.G -shl 8) -bor $accentRgb.R
    Set-ItemProperty -Path $dwm -Name 'AccentColor' -Value $abgr -Type DWord
    Set-ItemProperty -Path $dwm -Name 'ColorizationColor' -Value $abgr -Type DWord
    $accentApplied = $true
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

# Only name the legs that actually ran -- this used to claim komorebi borders even right
# after printing "komorebi isn't running -- skipped border colors."
$applied = @()
if ($komorebiRunning) { $applied += 'komorebi borders' }
if ($accentApplied)   { $applied += "Windows accent ($accent)" }
if ($applied.Count) { Write-Host ('wallust outputs applied: ' + ($applied -join ' + ')) }
else { Write-Host 'wallust outputs: neither komorebi borders nor Windows accent applied (see above).' }

# --- Terminal readability: WCAG contrast + hue-preserving lightening --------
# wallust fills Terminal's 16 ANSI slots straight from the wallpaper's own colors, so a
# dark wallpaper can hand PowerShell near-black text on a near-black background -- e.g.
# brightBlack #1C1C1C (PSReadLine's "DarkGray": -Parameters, operators) and green #191034
# (PSReadLine's "Green": $variables) on #010102. Found 2026-09-23 from the user's
# screenshot. Fix, agreed with the user: only for Terminal's copy of the scheme, raise any
# slot below a readable contrast against the background by lifting its HSL lightness --
# hue and saturation kept, so a too-dark purple becomes a readable purple, not gray.
# Background, black and foreground are never touched, and nothing else (YASB, borders,
# accent) sees this. Revert = revert the commit that added this block.
$TerminalMinContrast       = 4.5   # WCAG AA for normal text
$TerminalMinContrastDimmed = 3.0   # brightBlack + cursor: meant to stay dimmer than real text

function Get-RelLuminance([string]$Hex) {
    $c = ConvertTo-Rgb -Hex $Hex
    $lin = foreach ($v in $c.R, $c.G, $c.B) {
        $x = $v / 255.0
        if ($x -le 0.03928) { $x / 12.92 } else { [Math]::Pow(($x + 0.055) / 1.055, 2.4) }
    }
    0.2126 * $lin[0] + 0.7152 * $lin[1] + 0.0722 * $lin[2]
}

function Get-Contrast([string]$A, [string]$B) {
    $la = Get-RelLuminance $A; $lb = Get-RelLuminance $B
    ([Math]::Max($la, $lb) + 0.05) / ([Math]::Min($la, $lb) + 0.05)
}

function Get-ReadableHex([string]$Hex, [string]$Background, [double]$Min) {
    if ((Get-Contrast $Hex $Background) -ge $Min) { return $Hex }
    $c = ConvertTo-Rgb -Hex $Hex
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
    for ($L = $l; $L -le 1.0001; $L += 0.01) {
        $LL = [Math]::Min($L, 1.0)
        if ($s -eq 0) { $nr = $ng = $nb = $LL }
        else {
            $q = if ($LL -lt 0.5) { $LL * (1 + $s) } else { $LL + $s - $LL * $s }
            $p = 2 * $LL - $q
            $nr = & $toRgb $p $q ($h + 1/3); $ng = & $toRgb $p $q $h; $nb = & $toRgb $p $q ($h - 1/3)
        }
        $cand = '#{0:X2}{1:X2}{2:X2}' -f [int][Math]::Round($nr * 255), [int][Math]::Round($ng * 255), [int][Math]::Round($nb * 255)
        if ((Get-Contrast $cand $Background) -ge $Min) { return $cand }
    }
    '#FFFFFF'
}

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

    # One-time snapshot of whatever these fields were before this script ever ran -- same
    # reasoning as the 'windows-accent' snapshot above, captured from the raw parsed
    # settings before any of the "ensure structure exists" defensive lines below touch
    # anything. Restored by uninstall.ps1's Restore-WindowsTerminalSettings (tools\lib\
    # activation.ps1), alongside install.ps1 Section 8's separate 'terminal-defaultprofile'
    # snapshot -- see that function's own comment for why this is two labels, not one.
    $colorSchemeExisted = $wt['profiles'] -is [hashtable] -and $wt['profiles']['defaults'] -is [hashtable] -and $wt['profiles']['defaults'].ContainsKey('colorScheme')
    $existingWallustTheme = if ($wt['themes'] -is [array]) { @($wt['themes']) | Where-Object { $_['name'] -eq 'wallust' } | Select-Object -First 1 } else { $null }
    Save-OriginalStateOnce -Label 'terminal-colorscheme' -Data @{
        ColorSchemeExisted       = $colorSchemeExisted
        ColorScheme              = if ($colorSchemeExisted) { $wt['profiles']['defaults']['colorScheme'] } else { $null }
        ThemeKeyExisted          = $wt.ContainsKey('theme')
        Theme                    = $wt['theme']
        WallustThemeEntryExisted = $null -ne $existingWallustTheme
    }

    if (-not $wt.ContainsKey('profiles') -or $wt['profiles'] -isnot [hashtable]) { $wt['profiles'] = @{} }
    if (-not $wt['profiles'].ContainsKey('defaults') -or $wt['profiles']['defaults'] -isnot [hashtable]) {
        $wt['profiles']['defaults'] = @{}
    }
    $wt['profiles']['defaults']['colorScheme'] = 'wallust'

    # Readability pass over wallust's own scheme entry (see the helper block above).
    $raised = @()
    $scheme = @($wt['schemes']) | Where-Object { $_ -is [hashtable] -and $_['name'] -eq 'wallust' } | Select-Object -First 1
    if ($scheme -and $scheme['background']) {
        $slots = 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
                 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite',
                 'brightBlack', 'cursorColor'
        foreach ($slot in $slots) {
            if (-not $scheme[$slot]) { continue }
            $need = if ($slot -in 'brightBlack', 'cursorColor') { $TerminalMinContrastDimmed } else { $TerminalMinContrast }
            $fixed = Get-ReadableHex -Hex $scheme[$slot] -Background $scheme['background'] -Min $need
            if ($fixed -ne $scheme[$slot]) { $raised += "$slot $($scheme[$slot])->$fixed"; $scheme[$slot] = $fixed }
        }
    }

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
    if ($raised.Count) { Write-Host "Windows Terminal: raised contrast on $($raised.Count) color(s): $($raised -join ', ')" }
} else {
    Write-Host "Windows Terminal settings.json not found -- skipped."
}

# --- Fire the lock-screen-sync task -------------------------------------------------
# tools\lib\activation.ps1's Register-LockScreenSyncTask docstring promises this script
# fires the task "every time the wallpaper (and so the wallust palette) changes" -- it
# never actually did. Confirmed by testing: border colors/accent/Terminal colorscheme all
# updated correctly on a real wallpaper change, but the lock screen didn't budge. The one
# time it ever fired was install.ps1 -Activate's own one-time kickstart call (Section 11).
# Same Test-Task/schtasks pattern as that call, just inlined -- this script stays
# dependency-free by design (same reasoning as Save-OriginalStateOnce above; doesn't
# dot-source activation.ps1), so the task's full path is hardcoded rather than resolved
# via Get-TaskFullName. Best-effort: if the task was never registered (install.ps1 never
# run elevated, or without PS7 present), the /Query probe fails and this is a silent
# no-op, same as everywhere else in this repo that checks Test-Task first. Firing it from
# here doesn't need elevation itself -- that's the whole point of it being registered as
# an on-demand *elevated* task (New-OnDemandElevatedTaskXml): Task Scheduler elevates the
# task's own run, regardless of whether this script (running as YASB's widget click) is.
$lockScreenTask = '\710.DesktopRice\lock-screen-sync'
# $null = ... 2>&1, not *> $null -- the latter doesn't fully suppress schtasks.exe's own
# "ERROR: ..." text when the task genuinely doesn't exist yet (confirmed live: leaked to
# the console during a fresh install's first-run theme, which runs before -Activate ever
# registers this task). Same fix applied to activation.ps1's Test-Task, which has the
# identical pattern.
$null = & schtasks.exe /Query /TN $lockScreenTask 2>&1
if ($LASTEXITCODE -eq 0) {
    $null = & schtasks.exe /Run /TN $lockScreenTask 2>&1
}
