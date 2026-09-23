<#
.SYNOPSIS
  Shared functions for install.ps1's unconditional steps and its -Activate block, and
  for uninstall.ps1's matching revert steps. Dot-sourced by both -- never run directly.

.DESCRIPTION
  Ported from winarchy (module/Winarchy/Private/Identity.ps1, Hardening.ps1, Taskbar.ps1,
  Autostart.ps1, ShellProfile.ps1, Util.ps1), pinned to origin/main @ 4574fc7 (tag v1.4.0)
  -- NOT Dell's local C:\winarchy checkout, which sat on an old, unpulled commit (cbae6a3)
  plus unrelated local edits and was missing several of these files entirely (Hardening.ps1,
  Taskbar.ps1 didn't exist on disk there at all). See claude/winarchy-decoupling-plan.md for
  the full verification trail.

  Callers (install.ps1 / uninstall.ps1) must already have Step-Ok / Step-Info / Step-Warn
  defined before dot-sourcing this file -- it uses theirs rather than defining its own, to
  avoid two competing copies in the same process.

  net-icon is deliberately NOT ported (see Get-AutostartComponents below and the plan doc):
  it's a different mechanism than our YASB systray's show_network, and with the taskbar
  hidden there's currently no network status shown either way regardless of which we'd pick.

  display_index_preferences: winarchy's own newest window-slots refinement (see
  tools/lib/window-slots.ps1) writes a LIVE, device_id-keyed copy of this key into
  komorebi.json every time window placement rules are re-applied. This repo already has its
  own, older, INSTALL-TIME mechanism for the same key (install.ps1 Section 4, serial_number_id
  -keyed, via `komorebic monitor-information`) -- kept deliberately instead of winarchy's,
  documented as a design deviation in the plan doc (untested against a real multi-monitor
  reconnect/disconnect, unlike winarchy's, so worth revisiting if ours turns out not to hold
  up). komorebi's own docs (github.com/LGUG2Z/komorebi multi-monitor-setup.md) actually
  recommend serial_number_id over device_id for exactly this key, since device_id changes
  across a restart and serial_number_id doesn't -- so this deviation isn't just "different",
  it's arguably the sounder of the two, for whatever that's worth pending a real test.
#>

# --- Registry backup (reg.exe export) -----------------------------------------------
function Backup-RegistryKey {
    <# Exports one registry key (reg.exe export format) to backups/<timestamp>-<label>/.
       Ported from winarchy's Backup-WinarchyRegistryKey (module/Winarchy/Private/Util.ps1
       @ 4574fc7). Returns the backup dir, or $null if the export failed (key didn't exist,
       reg.exe not on PATH, etc.) -- callers proceed either way, this is best-effort. #>
    param([Parameter(Mandatory)][string]$Key, [string]$Label = 'registry')
    $backupsDir = Join-Path $Root 'backups'
    if (-not (Test-Path $backupsDir)) { New-Item -ItemType Directory -Path $backupsDir -Force | Out-Null }
    $dest = Join-Path $backupsDir "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$Label"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $file = Join-Path $dest (($Key -replace '[\\:]', '_') + '.reg')
    $null = reg.exe export $Key $file /y 2>&1
    if ($LASTEXITCODE -ne 0) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue; return $null }
    $dest
}

# --- Tray-icon-promotion snapshot (around the Set-TaskbarAutoHide/Set-WindowsHardening
# double Explorer restart) --------------------------------------------------------------
function Backup-TrayIconPromotions {
    <# Snapshots HKCU\Control Panel\NotifyIconSettings -- Windows' own per-app "always
       show this tray icon" preference store -- via the same reg.exe export mechanism
       Backup-RegistryKey already uses elsewhere in this file. Set-TaskbarAutoHide and
       Set-WindowsHardening both force-restart Explorer, and -- confirmed live on Dell,
       including from a genuinely clean, freshly-rebooted state, not just mid-session
       churn -- Explorer coming back from a forced kill can reset every app's
       icon-promotion preference to hidden, not just this repo's own AHK icon. Call this
       once before either kill; Restore-TrayIconPromotions puts the snapshot back
       afterward. Returns the backup .reg file's path (for Restore-TrayIconPromotions), or
       $null if the key doesn't exist yet or the export failed -- best-effort, never
       blocks the caller. #>
    $key = 'HKCU\Control Panel\NotifyIconSettings'
    if (-not (Test-Path 'HKCU:\Control Panel\NotifyIconSettings')) { return $null }
    $dir = Backup-RegistryKey -Key $key -Label 'tray-icons'
    if (-not $dir) { return $null }
    Join-Path $dir (($key -replace '[\\:]', '_') + '.reg')
}

function Restore-TrayIconPromotions {
    <# Counterpart to Backup-TrayIconPromotions -- reg.exe import of the file that
       function returned, putting back whatever Explorer's own restart(s) reset in every
       app's tray-icon-promotion preference. Call after Explorer is confirmed back up from
       the LAST of the two kills (Wait-ExplorerRunning), not right after the second
       Stop-Process call -- reg.exe import needs Explorer actually running to pick the
       change up live. Best-effort: a missing/null backup path (Backup-TrayIconPromotions
       returned $null, or was never called) is a silent no-op. #>
    param([string]$BackupFile)
    if (-not $BackupFile -or -not (Test-Path $BackupFile)) { return }
    $null = & reg.exe import $BackupFile 2>&1
}

# --- Original-state snapshots (true "restore to before 710.DesktopRice" on uninstall) --
# Different problem from Backup-RegistryKey above and from the hardening/taskbar revert
# pattern further down: those settings don't exist on a stock Windows install, so
# reverting them just means deleting the value. Wallpaper, accent color, the lock screen,
# and Windows Terminal's default shell/colorScheme are NOT like that -- something was
# already there before 710.DesktopRice ever touched it, and a real uninstall needs to put
# that exact something back, not just remove what we added. These functions snapshot
# whatever's about to change, exactly ONCE (gated on the snapshot not already existing --
# a second, third, Nth install.ps1/wallpaper-change run never overwrites an earlier
# snapshot with what is by then already OUR OWN state), into
# %LOCALAPPDATA%\710.DesktopRice\original-state\<label>.json -- machine-local, outside the
# repo entirely, same convention as this repo's autostart logs
# (%LOCALAPPDATA%\710.DesktopRice\*-autostart.log). uninstall.ps1 restores from these and
# deletes each snapshot file once it's been used, so a future re-install starts clean and
# snapshots fresh again rather than restoring an increasingly stale state.
#
# tools\apply-wallust-outputs.ps1 needs this SAME path convention and JSON shape but
# deliberately doesn't dot-source this file (stays dependency-free -- see its own header),
# so it carries a small duplicated copy of Save-OriginalState/Get-RegValueSnapshot rather
# than calling these. Keep both copies in sync if this shape ever changes.
function Get-OriginalStateDir {
    $dir = Join-Path $env:LOCALAPPDATA '710.DesktopRice\original-state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dir
}

function Save-OriginalState {
    <# One-time snapshot: writes <label>.json only if it doesn't already exist. $Data is
       whatever the caller wants restored later -- typically a small hashtable of exactly
       the field(s) about to change, not the whole surrounding file/key. #>
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)]$Data)
    $file = Join-Path (Get-OriginalStateDir) "$Label.json"
    if (Test-Path $file) { return }
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
}

function Get-OriginalState {
    <# Returns the snapshotted hashtable for $Label, or $null if it was never taken --
       callers treat $null as "nothing to restore" (this machine's install never actually
       reached the point of changing this setting), a safe no-op, not a warning. #>
    param([Parameter(Mandatory)][string]$Label)
    $file = Join-Path (Get-OriginalStateDir) "$Label.json"
    if (-not (Test-Path $file)) { return $null }
    Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
}

function Remove-OriginalState {
    param([Parameter(Mandatory)][string]$Label)
    Remove-Item (Join-Path (Get-OriginalStateDir) "$Label.json") -Force -ErrorAction SilentlyContinue
}

function Get-RegValueSnapshot {
    <# One registry value's current Existed/Value/Type (Value/Type both $null if absent) --
       the unit Save-OriginalState snapshots and Set-RegValueFromSnapshot restores, for a
       SINGLE named value, never a whole key -- so restoring never clobbers an unrelated
       sibling value under the same key that changed for some other reason in between
       (e.g. HKCU\Control Panel\Desktop holds a lot more than just WallPaper). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if (-not $item) { return [ordered]@{ Existed = $false; Value = $null; Type = $null } }
    $kind = 'String'
    try { $kind = (Get-Item -Path $Path).GetValueKind($Name).ToString() } catch { }
    [ordered]@{ Existed = $true; Value = $item.$Name; Type = $kind }
}

function Set-RegValueFromSnapshot {
    <# Restores one value from a Get-RegValueSnapshot-shaped hashtable: sets it back if it
       existed before, removes it entirely if it didn't (matching how the hardening revert
       already treats "never existed" -- hand it back to Windows' own default). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Snapshot)
    if (-not $Snapshot.Existed) {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    } else {
        if (-not (Test-Path $Path)) { $null = New-Item -Path $Path -Force }
        Set-ItemProperty -Path $Path -Name $Name -Value $Snapshot.Value -Type $Snapshot.Type -ErrorAction SilentlyContinue
    }
}

function Send-SettingChangeBroadcast {
    <# HWND_BROADCAST + WM_SETTINGCHANGE("ImmersiveColorSet"), SMTO_ABORTIFHUNG -- makes an
       accent-color change apply live, no logoff/restart. Ported inline from
       tools\apply-wallust-outputs.ps1's own copy of this P/Invoke (that script keeps its
       own -- see this file's header note above -- this copy is for Restore-WindowsAccent,
       called from uninstall.ps1, which already dot-sources this file). #>
    if (-not ('TenSeven.Native.SettingChange' -as [type])) {
        Add-Type -Namespace TenSeven.Native -Name SettingChange -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    [TenSeven.Native.SettingChange]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 1000, [ref]$result) | Out-Null
}

function Set-DesktopWallpaper {
    <# SPI_SETDESKWALLPAPER=0x0014, SPIF_UPDATEINIFILE|SPIF_SENDCHANGE=0x03 -- writes
       HKCU\Control Panel\Desktop\WallPaper and applies live, no logoff/restart needed.
       Shared by install.ps1 Section 4 (sets the first-run default) and
       Restore-OriginalWallpaper below (sets it back to whatever was there before). #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('TenSeven.Native.Wallpaper' -as [type])) {
        Add-Type -Namespace TenSeven.Native -Name Wallpaper -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
'@
    }
    $ok = [TenSeven.Native.Wallpaper]::SystemParametersInfo(0x0014, 0, $Path, 0x03)
    if (-not $ok) { throw "SystemParametersInfo returned false (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
}

function Save-OriginalWallpaper {
    <# One-time snapshot of the wallpaper as it stood before install.ps1 Section 4 ever
       set the repo's default -- called from there, right before the first Set-
       DesktopWallpaper call. #>
    Save-OriginalState -Label 'wallpaper' -Data (Get-RegValueSnapshot -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper')
}

function Restore-OriginalWallpaper {
    <# Reverts Save-OriginalWallpaper -- called from uninstall.ps1. $null from Get-
       OriginalState means install.ps1 never actually reached Section 4's wallpaper-setting
       branch on this machine (already using one of the repo's own wallpapers, or the
       default image was missing) -- safe no-op, not a warning. #>
    $snap = Get-OriginalState -Label 'wallpaper'
    if (-not $snap) { return $false }
    if ($snap.Existed -and $snap.Value) {
        Set-DesktopWallpaper -Path $snap.Value
    }
    Remove-OriginalState -Label 'wallpaper'
    return $true
}

# --- Component discovery (shared by Defender exclusions + autostart) ----------------
function Get-KomorebiExe {
    $found = (Get-Command komorebi.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $found) {
        $found = @("$env:ProgramFiles\komorebi\bin\komorebi.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    $found
}

function Get-AhkExe {
    <# AutoHotkey v2, per-machine or per-user; $null if not installed. #>
    $found = @(
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

# --- Windows Defender exclusions (unconditional -- not gated behind -Activate) ------
function Get-DefenderExclusionPaths {
    <# Ported from winarchy's Get-WinarchyDefenderExclusionPaths. Covers the same two lag
       sources: frequent I/O from ShareX/Everything, and Defender scanning komorebic.exe /
       pwsh.exe / this repo's own .ps1 files the first time they're touched per session
       (the "only the first time" lag seen on capture/window-close). Only returns paths
       that actually exist on this machine. #>
    $komorebic = Get-KomorebiExe
    @(
        (Get-ShareXExe),
        "$env:USERPROFILE\Documents\ShareX",
        "$env:ProgramFiles\Everything\Everything.exe",
        "${env:ProgramFiles(x86)}\Everything\Everything.exe",
        (Get-Command pwsh.exe -ErrorAction SilentlyContinue)?.Source,
        $komorebic,
        $Root
    ) | Where-Object { $_ -and (Test-Path $_) }
}

function Set-DefenderExclusions {
    <# Requires an elevated shell; same not-elevated fallback as the rest of this file:
       warn and skip, never fail the install. Ported from Set-WinarchyDefenderExclusions. #>
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Step-Warn 'Defender exclusions need an elevated shell -- re-run install.ps1 from an admin PowerShell to apply them.'
        return
    }
    $paths = @(Get-DefenderExclusionPaths)
    if ($paths.Count -eq 0) {
        Step-Info 'No ShareX/Everything/komorebi paths found yet to exclude.'
        return
    }
    $current = @((Get-MpPreference).ExclusionPath)
    $missing = @($paths | Where-Object { $current -notcontains $_ })
    if ($missing.Count -eq 0) {
        Step-Ok 'Defender exclusions already applied'
        return
    }
    try {
        Add-MpPreference -ExclusionPath $missing
        Step-Ok "Defender exclusions added: $($missing -join ', ')"
    } catch {
        Step-Warn "Could not add Defender exclusions: $($_.Exception.Message)"
    }
}

function Remove-DefenderExclusions {
    <# Reverts Set-DefenderExclusions -- called from uninstall.ps1. winarchy's own
       uninstall.ps1 never removes these at all (see plan doc); we go further. Removes
       exactly the paths Get-DefenderExclusionPaths would add (recomputed live, same as
       install time), never the caller's whole ExclusionPath list, so an exclusion the
       person added themselves outside this repo is left alone. Same elevation requirement
       and not-elevated fallback as Set-DefenderExclusions -- warns and skips rather than
       failing the uninstall. #>
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Step-Warn 'Defender exclusions need an elevated shell to remove -- re-run uninstall.ps1 from an admin PowerShell to revert them.'
        return
    }
    $paths = @(Get-DefenderExclusionPaths)
    if ($paths.Count -eq 0) {
        Step-Info 'No Defender exclusion paths to remove (nothing currently found to have excluded).'
        return
    }
    $current = @((Get-MpPreference).ExclusionPath)
    $toRemove = @($paths | Where-Object { $current -contains $_ })
    if ($toRemove.Count -eq 0) {
        Step-Info 'Defender exclusions already absent.'
        return
    }
    try {
        Remove-MpPreference -ExclusionPath $toRemove
        Step-Ok "Defender exclusions removed: $($toRemove -join ', ')"
    } catch {
        Step-Warn "Could not remove Defender exclusions: $($_.Exception.Message)"
    }
}

# --- Registry hardening (HKCU only, -Activate-gated) ---------------------------------
function Get-HardeningSettings {
    <# Ported verbatim (values/keys) from winarchy's Get-WinarchyHardeningSettings
       (module/Winarchy/Private/Hardening.ps1 @ 4574fc7, tag v1.4.0). HKCU only (no admin
       needed), idempotent, and reversible: reverting just deletes the values, which
       hands the setting back to Windows' own default. Turns off Bing web search in the
       Start menu, search-box ad suggestions, Copilot/Widgets/Task-View taskbar buttons,
       Start menu recommendations/account nag, spotlight/lock-screen ads, and the various
       "SubscribedContent" (ContentDeliveryManager) ad/suggestion channels. #>
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
    $cdm = "$base\ContentDeliveryManager"
    $settings = @(
        , @("$base\Search", 'BingSearchEnabled', 0)
        , @("$base\Search", 'SearchboxTaskbarMode', 0)
        , @("$base\Search", 'CortanaConsent', 0)
        , @("$base\SearchSettings", 'IsDynamicSearchBoxEnabled', 0)
        , @("$base\SearchSettings", 'IsAADCloudSearchEnabled', 0)
        , @("$base\SearchSettings", 'IsMSACloudSearchEnabled', 0)
        , @('HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 1)
        , @("$base\Explorer\Advanced", 'TaskbarDa', 0)
        , @("$base\Explorer\Advanced", 'TaskbarMn', 0)
        , @("$base\Explorer\Advanced", 'ShowTaskViewButton', 0)
        , @("$base\Explorer\Advanced", 'ShowCopilotButton', 0)
        , @("$base\Explorer\Advanced", 'Start_IrisRecommendations', 0)
        , @("$base\Explorer\Advanced", 'Start_AccountNotifications', 0)
        , @("$base\Explorer\Advanced", 'ShowSyncProviderNotifications', 0)
        , @("$base\AdvertisingInfo", 'Enabled', 0)
        , @("$base\Privacy", 'TailoredExperiencesWithDiagnosticDataEnabled', 0)
        , @("$base\UserProfileEngagement", 'ScoobeSystemSettingEnabled', 0)
        , @('HKCU:\Control Panel\International\User Profile', 'HttpAcceptLanguageOptOut', 1)
        , @('HKCU:\Software\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsSpotlightFeatures', 1)
    )
    foreach ($name in 'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled',
        'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled',
        'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled', 'RotatingLockScreenEnabled',
        'RotatingLockScreenOverlayEnabled', 'SubscribedContent-310093Enabled', 'SubscribedContent-338387Enabled',
        'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled',
        'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-353698Enabled',
        'SubscribedContent-88000326Enabled') {
        $settings += , @($cdm, $name, 0)
    }
    $settings
}

function Wait-ExplorerRunning {
    <# Waits for Explorer's real shell (the taskbar) to actually be back up before some
       other step force-kills it a second time. Exists because Set-TaskbarAutoHide and
       Set-WindowsHardening both restart Explorer when they change something, and both
       install.ps1 -Activate and uninstall.ps1 call them back-to-back (taskbar, then
       hardening) with no gap in between -- confirmed live on Dell to leave the desktop,
       taskbar and icons completely blank until a manual Explorer restart or a full
       reboot, because the second kill lands while Windows is still bringing the first
       kill's replacement process back up.
       FIRST version of this fix (commit 3b6d3f0) only checked Get-Process explorer --
       NOT enough, confirmed live on Dell a second time (uninstall-run-2, 2026-09-23): a
       process named explorer.exe shows up in the process table almost immediately after
       Windows respawns it, well before Explorer has actually finished initializing and
       created its shell windows. The second kill still landed in that gap and reproduced
       the identical blank-desktop symptom this function exists to prevent. Now checks for
       the real taskbar window (class Shell_TrayWnd, via FindWindow) instead of just the
       process -- that handle only exists once Explorer has genuinely finished standing
       the shell back up, not merely once a process object exists.
       Polls rather than a fixed sleep, same reasoning as scripts\Start-Komorebi.ps1's own
       wait-with-time-budget: however long Explorer actually takes to come back (which
       varies), never longer, never less. Falls through after the timeout even if the
       taskbar never reappears -- best-effort, same posture as every other step in this
       file; the caller's own kill still happens either way, just no longer guaranteed to
       land on an already-healthy shell. #>
    param([int]$TimeoutSeconds = 10)
    if (-not ('Win32Shell.NativeMethods' -as [type])) {
        Add-Type -Namespace Win32Shell -Name NativeMethods -MemberDefinition @'
            [DllImport("user32.dll", CharSet = CharSet.Auto)]
            public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
'@
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ([Win32Shell.NativeMethods]::FindWindow('Shell_TrayWnd', $null) -eq [IntPtr]::Zero) {
        if ((Get-Date) -ge $deadline) { return }
        Start-Sleep -Milliseconds 200
    }
}

function Set-WindowsHardening {
    <# Applies (or, with -Revert, undoes) every setting from Get-HardeningSettings.
       Backs up each touched registry key first (Backup-RegistryKey, label 'hardening').
       Restarts explorer.exe once at the end if anything actually changed -- most of these
       values are only read at Explorer startup. Returns the number of settings changed.
       Waits for Explorer to actually be back up first (Wait-ExplorerRunning) before that
       restart: this function always runs immediately after Set-TaskbarAutoHide in both
       install.ps1 -Activate and uninstall.ps1, and firing this kill before Windows has
       finished restarting Explorer from THAT kill left the desktop/taskbar/icons blank
       until a manual restart or reboot -- confirmed live on Dell, twice. #>
    param([switch]$Revert)
    $changed = 0
    if (-not $Revert) {
        foreach ($key in 'Explorer\Advanced', 'ContentDeliveryManager', 'Search', 'SearchSettings') {
            $null = Backup-RegistryKey -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\$key" -Label 'hardening'
        }
    }
    foreach ($setting in Get-HardeningSettings) {
        $path, $name, $value = $setting
        try {
            $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Ignore
            $current = if ($item) { $item.$name }
            if ($Revert) {
                if ($null -eq $current) { continue }
                Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop
            } else {
                if ($current -eq $value) { continue }
                if (-not (Test-Path $path)) { $null = New-Item -Path $path -Force }
                Set-ItemProperty -Path $path -Name $name -Value $value -Type DWord -ErrorAction Stop
            }
            $changed++
        } catch { Step-Warn "${name}: $($_.Exception.Message)" }
    }
    if ($changed -gt 0) {
        Wait-ExplorerRunning
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    }
    $changed
}

# --- Taskbar auto-hide (-Activate-gated) ----------------------------------------------
function Set-TaskbarAutoHide {
    <# Ported from winarchy's Set-WinarchyTaskbarAutoHide (Taskbar.ps1 @ 4574fc7):
       flips bit 0x01 of StuckRects3's Settings byte array (byte 8), the same bit Windows'
       own "Automatically hide the taskbar" checkbox flips. Idempotent -- returns $false
       and does nothing if the flag already matches $Enabled, so a re-run of install.ps1
       doesn't restart explorer.exe for no reason. Backs up StuckRects3 before changing it,
       and restarts explorer.exe (required for the change to take effect) only when it
       actually changed something. #>
    param([Parameter(Mandatory)][bool]$Enabled)
    $stuck = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
    $val = (Get-ItemProperty -Path $stuck -Name Settings).Settings
    $flags = if ($Enabled) { $val[8] -bor 0x01 } else { $val[8] -band (-bnot 0x01) }
    if ($flags -eq $val[8]) { return $false }
    $null = Backup-RegistryKey -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' -Label 'taskbar'
    $val[8] = $flags
    Set-ItemProperty -Path $stuck -Name Settings -Value $val
    Stop-Process -Name explorer -Force
    $true
}

# --- StartupDelayInMSec (-Activate-gated) ---------------------------------------------
function Set-StartupDelay {
    <# Windows staggers Startup-folder/logon app launches by ~10s by default (Explorer's
       own Serialize\StartupDelayInMSec, undocumented but long-established). 0 removes that
       artificial delay -- beneficial here because komorebi/YASB/AHK are all launched at
       logon and a window opened right after login should get tiled promptly rather than
       waiting out Explorer's stagger. Ported from install.ps1's own inline block @ 4574fc7
       (this one was never split into a Private/ function upstream either). #>
    $serialize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'
    if (-not (Test-Path $serialize)) { $null = New-Item $serialize -Force }
    Set-ItemProperty -Path $serialize -Name 'StartupDelayInMSec' -Value 0 -Type DWord
}

function Remove-StartupDelay {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' `
        -Name 'StartupDelayInMSec' -ErrorAction SilentlyContinue
}

# --- Autostart: Scheduled Tasks At-LogOn (-Activate-gated) ---------------------------
# schtasks.exe (native), not the ScheduledTasks module: that module's CIM/MI subsystem is
# broken on some machines ("type initializer for 'Microsoft.Management.Infrastructure.
# Native...'"). schtasks.exe never touches that layer. Ported from winarchy's Autostart.ps1
# @ 4574fc7.
$script:TaskFolder = '710.DesktopRice'

function ConvertTo-HiddenLaunch {
    <# Rewraps an Exe/Arguments pair so the Scheduled Task launches it via
       tools\lib\run-hidden.vbs (WScript.Shell.Run, windowStyle 0) instead of directly.

       Why: Task Scheduler launching a console-subsystem host (powershell.exe) directly
       with -WindowStyle Hidden still briefly flashes a console at every logon -- confirmed
       live on Dell, 3-4 flashes at boot (one per powershell-hosted autostart component
       below). Windows allocates the console as part of process creation, before
       PowerShell's own startup code has run far enough to read -WindowStyle and hide
       itself -- a well-documented Task Scheduler + PowerShell race, not specific to this
       repo. wscript.exe (unlike cscript.exe) never allocates a console at all, so there's
       nothing to flash; its WScript.Shell.Run requests the hidden window style up front,
       as part of creating the process, not as a hide-after-the-fact race. See
       run-hidden.vbs's own header for the full writeup, including why this is NOT the same
       technique winarchy tried and reverted for komorebi (`conhost --headless`, git log
       d52e515/f088211 -- that killed the child process outright when its detached host
       exited; this script doesn't host/attach the child's console at all).

       Real bug found and fixed 2026-09-23: the original version tried to carry Exe/
       Arguments on run-hidden.vbs's own command line, backslash-escaping embedded double
       quotes ("same convention Win32 command-line parsing already uses"). That assumption
       was never actually verified against WSH's real parser and was wrong -- confirmed
       live via a real run-hidden.log entry plus a byte-exact `od -c` dump: WSH's
       command-line parser does NOT support backslash-escaped quotes; `\"` comes through as
       a literal backslash plus an ORDINARY (unescaped) quote-toggle, not a literal `"`. A
       quoted -File path arrived at powershell.exe mangled
       (`\C:\710.DesktopRice\...\Start-Komorebi.ps1\` -- stray leading/trailing backslashes,
       no quotes at all), which powershell.exe can't resolve as a path -- it failed
       silently, every time this ran for real, including the very scheduled runs this
       feature was supposedly validated against. Task Scheduler still reported Last Result
       0 (that's wscript.exe's own exit code, unaffected -- see run-hidden.vbs's header) and
       the launched script never got far enough to write even its first log line, so this
       had no visible symptom other than "komorebi just isn't running" after logon.

       Fixed by not putting Exe/Arguments on run-hidden.vbs's command line at all: they're
       written to a small two-line plain-text spec file instead (line 1 = Exe, line 2 =
       Arguments, exactly as originally composed, no escaping needed), and only that file's
       own path -- a plain, quote-free, backslash-free-at-the-end Windows path -- is passed
       as run-hidden.vbs's one argument. This sidesteps WSH's command-line parsing for the
       payload entirely; nothing about it needs to be "quoted correctly" for WSH anymore.
       Written once here, at registration/-Activate time; read fresh by run-hidden.vbs on
       every actual fire, including ones long after this PowerShell process has exited (a
       reboot days later, etc.), so it has to be static/persistent, not a live variable --
       same %LOCALAPPDATA%\710.DesktopRice\ folder every other autostart log/state file
       already lives in. #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Arguments
    )
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $vbs = Join-Path $Root 'tools\lib\run-hidden.vbs'
    $specDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
    New-Item -ItemType Directory -Path $specDir -Force | Out-Null
    $spec = Join-Path $specDir "launch-$Key.txt"
    # ASCII, no BOM -- every value written here is a plain Windows path or powershell.exe
    # flag, so there's nothing here that needs Unicode; a BOM would otherwise land as a
    # stray leading character on run-hidden.vbs's own ForReading (ASCII/ANSI) ReadLine.
    Set-Content -LiteralPath $spec -Value @($Exe, $Arguments) -Encoding ASCII
    [pscustomobject]@{
        Exe       = $wscript
        Arguments = "//B `"$vbs`" `"$spec`""
    }
}

function Get-AutostartComponents {
    <# Definition of the 5 autostart components this repo actually uses (komorebi, YASB,
       window-slots, ShareX, AHK). net-icon is deliberately not ported -- see this file's
       header comment. Returns only the components whose executable is actually present.
       Each item: Key, TaskName, LnkName, Exe, Arguments, Delay (ISO-8601 duration, for the
       LogonTrigger's Delay). The 4 powershell-hosted components (all but ShareX, which
       launches its own GUI exe directly and has no console to begin with) go through
       ConvertTo-HiddenLaunch -- see that function for why. #>
    $items = [System.Collections.Generic.List[object]]::new()
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # komorebi.exe direct (not `komorebic start`, which is flaky on some machines --
    # os error 1920, retries in a loop and can hang on launch). Start-Komorebi.ps1 waits
    # for a real foreground window and retries with a time budget; see that script.
    $komorebiExe = Get-KomorebiExe
    if ($komorebiExe) {
        $launcher = Join-Path $Root 'scripts\Start-Komorebi.ps1'
        $hidden = ConvertTo-HiddenLaunch -Key 'komorebi' -Exe $ps -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
        $items.Add([pscustomobject]@{
            Key = 'komorebi'; TaskName = 'komorebi'; LnkName = '710.DesktopRice komorebi.lnk'
            Exe = $hidden.Exe
            Arguments = $hidden.Arguments
            Delay = 'PT0S'
        })
    }

    # YASB via its own resilient launcher (waits for shell ready, retries).
    $yasbc = (Get-Command yasbc -ErrorAction SilentlyContinue)?.Source
    if ($yasbc) {
        $launcher = Join-Path $Root 'scripts\Start-Yasb.ps1'
        $yasbHome = Join-Path $Root 'config\yasb'
        $hidden = ConvertTo-HiddenLaunch -Key 'yasb' -Exe $ps -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" -YasbExe `"$yasbc`" -YasbConfigHome `"$yasbHome`""
        $items.Add([pscustomobject]@{
            Key = 'yasb'; TaskName = 'yasb'; LnkName = '710.DesktopRice YASB.lnk'
            Exe = $hidden.Exe
            Arguments = $hidden.Arguments
            Delay = 'PT0S'
        })
    }

    # window-slots reconciler: same hidden-host pattern as komorebi, but the daemon itself
    # needs pwsh (PowerShell 7 syntax), so the hidden powershell.exe host just launches pwsh
    # hidden in turn. 10s delay -- give komorebi itself a head start.
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if ($komorebiExe -and $pwsh) {
        $slots = Join-Path $Root 'scripts\Start-WindowSlots.ps1'
        $inner = "Start-Process -FilePath '$pwsh' -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$slots'"
        $hidden = ConvertTo-HiddenLaunch -Key 'window-slots' -Exe $ps -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$inner`""
        $items.Add([pscustomobject]@{
            Key = 'window-slots'; TaskName = 'window-slots'; LnkName = '710.DesktopRice window slots.lnk'
            Exe = $hidden.Exe
            Arguments = $hidden.Arguments
            Delay = 'PT10S'
        })
    }

    # ShareX resident in the tray (-silent: no main window) so the first capture of the
    # day doesn't also pay for the exe's cold start.
    $sharexExe = Get-ShareXExe
    if ($sharexExe) {
        $items.Add([pscustomobject]@{
            Key = 'sharex'; TaskName = 'sharex'; LnkName = '710.DesktopRice ShareX.lnk'
            Exe = $sharexExe
            Arguments = '-silent'
            Delay = 'PT0S'
        })
    }

    # AHK dispatcher via its own resilient launcher.
    $ahkExe = Get-AhkExe
    if ($ahkExe) {
        $launcher = Join-Path $Root 'scripts\Start-Ahk.ps1'
        $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
        $hidden = ConvertTo-HiddenLaunch -Key 'ahk' -Exe $ps -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" -AhkExe `"$ahkExe`" -ScriptPath `"$ahkScript`""
        $items.Add([pscustomobject]@{
            Key = 'ahk'; TaskName = 'ahk'; LnkName = '710.DesktopRice hotkeys.lnk'
            Exe = $hidden.Exe
            Arguments = $hidden.Arguments
            Delay = 'PT0S'
        })
    }

    $items
}

function Get-TaskFullName {
    param([Parameter(Mandatory)][string]$TaskName)
    "\$script:TaskFolder\$TaskName"
}

function Test-Task {
    param([Parameter(Mandatory)][string]$TaskName)
    # $null = ... 2>&1 (capture-and-discard), not *> $null (redirect-and-discard): the
    # latter doesn't fully suppress schtasks.exe's own "ERROR: ..." text for a genuinely
    # missing task -- found live tonight when toolspply-wallust-outputs.ps1's own copy
    # of this exact check (same *> $null) leaked that text to the console the first time
    # all night it ever queried a task that truly didn't exist yet. Every earlier call to
    # this function happened to query a task that already existed, so the leak was never
    # actually exercised here until now.
    $full = Get-TaskFullName -TaskName $TaskName
    $null = & schtasks.exe /Query /TN $full 2>&1
    $LASTEXITCODE -eq 0
}

function Remove-StartupShortcuts {
    $startup = [Environment]::GetFolderPath('Startup')
    Remove-Item (Join-Path $startup '710.DesktopRice *.lnk') -Force -ErrorAction SilentlyContinue
}

function New-StartupShortcut {
    <# Fallback for a component whose Scheduled Task failed to register. #>
    param([Parameter(Mandatory)][object]$Component)
    $startup = [Environment]::GetFolderPath('Startup')
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path $startup $Component.LnkName))
    $lnk.TargetPath = $Component.Exe
    $lnk.Arguments = $Component.Arguments
    $lnk.Save()
}

function New-TaskXml {
    <# At-LogOn trigger (per-component Delay), InteractiveToken + LeastPrivilege principal
       (no elevation, interactive session only), IgnoreNew multiple-instances policy, no
       execution time limit, Normal priority. Ported from New-WinarchyTaskXml.
       <Priority>4</Priority> ported from winarchy 2d8c910 (v1.5.0): Task Scheduler's
       default is 7, which starts the task's process at BelowNormal -- and Windows hands
       BelowNormal down to child processes that don't ask for a class, so through our
       wscript -> powershell -> launcher chain komorebi/YASB/AHK all came up BelowNormal
       (winarchy saw delayed retiles under load from exactly this). 4 = Normal. #>
    param([Parameter(Mandatory)][object]$Component, [Parameter(Mandatory)][string]$User)
    $u = [System.Security.SecurityElement]::Escape($User)
    $cmd = [System.Security.SecurityElement]::Escape($Component.Exe)
    $arg = [System.Security.SecurityElement]::Escape($Component.Arguments)
    $delay = if ($Component.Delay) { $Component.Delay } else { 'PT0S' }
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>710.DesktopRice autostart: $($Component.Key)</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$u</UserId>
      <Delay>$delay</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$u</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>4</Priority>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmd</Command>
      <Arguments>$arg</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-Autostart {
    <# Registers every present component as an At-LogOn Scheduled Task, delay 0 (or per-
       component), unelevated, interactive-session-only. Deletes legacy .lnk files first
       (migration). Idempotent. Falls back to a Startup .lnk for any component whose task
       registration fails. #>
    Remove-StartupShortcuts
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $components = Get-AutostartComponents
    if ($components.Count -eq 0) {
        Step-Warn 'Autostart: no components installed.'
        return
    }
    foreach ($c in $components) {
        $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) "710-task-$($c.TaskName).xml"
        try {
            Set-Content -Path $xmlPath -Value (New-TaskXml -Component $c -User $user) -Encoding Unicode
            $full = Get-TaskFullName -TaskName $c.TaskName
            & schtasks.exe /Create /TN $full /XML $xmlPath /F *> $null
            if ($LASTEXITCODE -ne 0) { throw "schtasks /Create exited with code $LASTEXITCODE" }
        } catch {
            # The task already exists and just couldn't be UPDATED (typically: it was
            # created from an elevated shell and this run isn't) -- the old task still
            # autostarts the component, so a Startup .lnk on top would launch it twice.
            # Ported from winarchy 2d8c910 (v1.5.0).
            if (Test-Task -TaskName $c.TaskName) {
                Step-Warn "Autostart $($c.Key): couldn't update the existing task ($($_.Exception.Message)); keeping the old one. If it was created elevated: schtasks /Delete /TN `"$(Get-TaskFullName -TaskName $c.TaskName)`" /F (as admin), then re-run."
                continue
            }
            Step-Warn "Autostart $($c.Key): failed to register the task ($($_.Exception.Message)). Falling back to Startup."
            try { New-StartupShortcut -Component $c }
            catch { Step-Warn "Autostart $($c.Key): Startup fallback also failed: $($_.Exception.Message)" }
        } finally {
            Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
        }
    }
    Step-Ok "Autostart registered (Scheduled Tasks At-LogOn): $($components.Key -join ', ')"
}

function Unregister-Autostart {
    foreach ($c in Get-AutostartComponents) {
        $full = Get-TaskFullName -TaskName $c.TaskName
        & schtasks.exe /Delete /TN $full /F *> $null
    }
    Remove-StartupShortcuts
}

function Get-AutostartStatus {
    <# Key -> bool (task registered or fallback .lnk present), per component. #>
    $startup = [Environment]::GetFolderPath('Startup')
    $status = @{}
    foreach ($c in Get-AutostartComponents) {
        $hasTask = Test-Task -TaskName $c.TaskName
        $hasLnk = Test-Path (Join-Path $startup $c.LnkName)
        $status[$c.Key] = ($hasTask -or $hasLnk)
    }
    $status
}

# --- Lock-screen sync (on-demand elevated task) ---------------------------------------
function New-OnDemandElevatedTaskXml {
    <# On-demand-only (empty <Triggers /> -- no LogonTrigger) with RunLevel HighestAvailable,
       so the registered task carries its OWN elevation: once install.ps1 -Activate (itself
       run elevated) registers it, a later `schtasks /Run` -- even from an unelevated caller
       like apply-wallust-outputs.ps1 -- runs it elevated with no UAC prompt, because Task
       Scheduler grants the token the Principal asks for rather than the caller's own.
       Otherwise mirrors New-TaskXml's shape (IgnoreNew multiple-instances policy), except
       AllowHardTerminate=true and a 1-minute ExecutionTimeLimit rather than New-TaskXml's
       false/unlimited -- this runs a single quick registry write, not a long-lived daemon,
       so a runaway instance should be killable and shouldn't be able to block later runs
       (IgnoreNew) indefinitely. #>
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][string]$Command,
          [string]$Arguments = '', [Parameter(Mandatory)][string]$User)
    $u = [System.Security.SecurityElement]::Escape($User)
    $desc = [System.Security.SecurityElement]::Escape($Description)
    $cmd = [System.Security.SecurityElement]::Escape($Command)
    $arg = [System.Security.SecurityElement]::Escape($Arguments)
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$desc</Description>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>$u</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmd</Command>
      <Arguments>$arg</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-LockScreenSyncTask {
    <# Registers the on-demand elevated 'lock-screen-sync' task (see
       New-OnDemandElevatedTaskXml and scripts\Sync-LockScreen.ps1). No LogonTrigger -- it
       never fires on its own; tools\apply-wallust-outputs.ps1 fires it with `schtasks /Run`
       every time the wallpaper (and so the wallust palette) changes. Requires an elevated
       shell to REGISTER (same as Set-DefenderExclusions); once registered, later RUNS need
       no further elevation (see New-OnDemandElevatedTaskXml). Idempotent (/F overwrites).
       Warn-and-skip if not elevated or pwsh is missing -- never fails the install; the lock
       screen just won't sync until install.ps1 is re-run from an admin shell with PS7
       present. #>
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Step-Warn 'Lock-screen sync needs an elevated shell to register -- re-run install.ps1 from an admin PowerShell to enable it.'
        return
    }
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) {
        Step-Warn 'Lock-screen sync: pwsh.exe not found on PATH -- skipping (install PowerShell 7 first).'
        return
    }
    # One-time snapshot of PersonalizationCSP as it stood before this task can ever fire
    # and write to it -- registration (here) is the only point that's guaranteed to run
    # before the first sync, so it's the right place to capture "before", not
    # Sync-LockScreen.ps1 itself (which only ever SETS these values, never should be the
    # one deciding what "original" means). Almost always Existed=$false for all three on
    # a non-managed machine (PersonalizationCSP is an Enterprise/MDM-only key Home doesn't
    # ship with) -- see Restore-LockScreen below for what that means on revert.
    $cspPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    Save-OriginalState -Label 'lockscreen-personalizationcsp' -Data @{
        LockScreenImageStatus = Get-RegValueSnapshot -Path $cspPath -Name 'LockScreenImageStatus'
        LockScreenImagePath   = Get-RegValueSnapshot -Path $cspPath -Name 'LockScreenImagePath'
        LockScreenImageUrl    = Get-RegValueSnapshot -Path $cspPath -Name 'LockScreenImageUrl'
    }
    $script = Join-Path $Root 'scripts\Sync-LockScreen.ps1'
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) '710-task-lock-screen-sync.xml'
    try {
        $xml = New-OnDemandElevatedTaskXml -Description '710.DesktopRice: syncs the lock screen image to the current wallpaper (on-demand, fired by apply-wallust-outputs.ps1)' `
            -Command $pwsh -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`"" -User $user
        Set-Content -Path $xmlPath -Value $xml -Encoding Unicode
        $full = Get-TaskFullName -TaskName 'lock-screen-sync'
        & schtasks.exe /Create /TN $full /XML $xmlPath /F *> $null
        if ($LASTEXITCODE -ne 0) { throw "schtasks /Create exited with code $LASTEXITCODE" }
        Step-Ok 'Lock-screen sync task registered (fires on wallpaper change, via apply-wallust-outputs.ps1).'
    } catch {
        Step-Warn "Lock-screen sync: failed to register the task ($($_.Exception.Message))."
    } finally {
        Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
    }
}

function Unregister-LockScreenSyncTask {
    <# Reverts Register-LockScreenSyncTask -- called from uninstall.ps1. Only deletes the
       Scheduled Task itself; the actual PersonalizationCSP registry values are a separate
       concern, reverted by Restore-LockScreen below (uninstall.ps1 calls both). Mirrors
       Unregister-Autostart: no elevation check, best-effort, ignores the exit code. #>
    $full = Get-TaskFullName -TaskName 'lock-screen-sync'
    & schtasks.exe /Delete /TN $full /F *> $null
}

function Restore-LockScreen {
    <# Reverts whatever Sync-LockScreen.ps1 wrote to PersonalizationCSP, back to the
       Save-OriginalState 'lockscreen-personalizationcsp' snapshot Register-
       LockScreenSyncTask took at registration time. $null means that snapshot was never
       taken (lock-screen sync was never successfully registered on this machine) -- safe
       no-op. On the common case (the key didn't exist before -- see Register-
       LockScreenSyncTask's comment), this deletes the whole PersonalizationCSP key rather
       than three now-empty values, so the manual "choose a photo" Settings option comes
       back too, not just an empty-but-still-managed key. Requires elevation (HKLM) --
       warns and skips, same as every other elevation-gated revert in this file, rather
       than failing the uninstall. #>
    $snap = Get-OriginalState -Label 'lockscreen-personalizationcsp'
    if (-not $snap) { return $false }
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Step-Warn 'Lock-screen registry keys need an elevated shell to revert -- re-run uninstall.ps1 from an admin PowerShell to finish restoring the original lock screen.'
        return $false
    }
    $cspPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    $anyExistedBefore = $snap.LockScreenImageStatus.Existed -or $snap.LockScreenImagePath.Existed -or $snap.LockScreenImageUrl.Existed
    if (-not $anyExistedBefore) {
        Remove-Item -Path $cspPath -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Set-RegValueFromSnapshot -Path $cspPath -Name 'LockScreenImageStatus' -Snapshot $snap.LockScreenImageStatus
        Set-RegValueFromSnapshot -Path $cspPath -Name 'LockScreenImagePath' -Snapshot $snap.LockScreenImagePath
        Set-RegValueFromSnapshot -Path $cspPath -Name 'LockScreenImageUrl' -Snapshot $snap.LockScreenImageUrl
    }
    Remove-OriginalState -Label 'lockscreen-personalizationcsp'
    return $true
}

# --- Stopping running components (uninstall-only; not gated behind -Activate) --------
function Stop-RunningComponents {
    <# Stops every process 710.DesktopRice may have launched, whether or not -Activate/
       autostart was ever registered -- install.ps1's own "start now" step (-Activate) can
       leave these running even after autostart itself is torn down, and a machine that was
       only ever coexisting (no -Activate) may still have been started by hand. winarchy's
       own uninstall.ps1 never stops anything at all (a documented gap this repo closes --
       see plan doc); called unconditionally, first thing, from uninstall.ps1, independent
       of whatever -Activate state the install was left in. Each component is independent
       and best-effort (one failing to stop doesn't block the rest of the uninstall), and
       nothing here touches a process this repo didn't start -- see the AHK note below. #>

    # window-slots daemon first: it reacts to komorebi's socket/pipe going away, so
    # stopping it before komorebi avoids a burst of reconcile attempts against a dying
    # event stream. Dot-sourced lazily (only when actually stopping something) so
    # install.ps1's -Activate path, which never calls this function, doesn't pay for it.
    try {
        . (Join-Path $Root 'tools\lib\window-slots.ps1')
        if (Test-WindowSlotsRunning) { Stop-WindowSlotsDaemon }
    } catch { Step-Warn "window-slots daemon: $($_.Exception.Message)" }

    # komorebi: try its own graceful `stop` first (releases window-management hooks,
    # restores window styles/borders) before a hard kill, so a stray leftover style isn't
    # left on a window after uninstall.
    if (Get-Process komorebi -ErrorAction SilentlyContinue) {
        $komorebic = (Get-Command komorebic -ErrorAction SilentlyContinue)?.Source
        if ($komorebic) { try { & $komorebic stop 2>$null | Out-Null; Start-Sleep -Milliseconds 300 } catch { } }
        Stop-Process -Name komorebi -Force -ErrorAction SilentlyContinue
    }

    # YASB: same graceful-stop-then-kill pattern.
    if (Get-Process yasb -ErrorAction SilentlyContinue) {
        $yasbc = (Get-Command yasbc -ErrorAction SilentlyContinue)?.Source
        if ($yasbc) { try { & $yasbc stop 2>$null | Out-Null; Start-Sleep -Milliseconds 300 } catch { } }
        Stop-Process -Name yasb -Force -ErrorAction SilentlyContinue
    }

    # ShareX: no CLI stop -- the resident tray process is all there is to end.
    Stop-Process -Name ShareX -Force -ErrorAction SilentlyContinue

    # AHK: matched by command line (Win32_Process), not a blanket `Stop-Process -Name
    # AutoHotkey64` -- that would also kill any unrelated AHK v2 script the person happens
    # to have running, which isn't this repo's to touch. If Win32_Process can't be queried
    # for some reason, this is skipped and warned rather than falling back to the blanket
    # kill (see Stop-WindowSlotsDaemon for the same reasoning, applied to komorebi's
    # equivalent pwsh-daemon case).
    try {
        $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
        Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ahkScript) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {
        Step-Warn "Could not check for a running 710.ahk AutoHotkey process (Win32_Process unavailable): $($_.Exception.Message)"
    }
}

# --- Shell profile hook ($PROFILE -> config\pwsh\profile.ps1) ------------------------
# Ported from winarchy's ShellProfile.ps1 @ 4574fc7: a marker-delimited block inserted (or
# updated) in pwsh's CurrentUserAllHosts $PROFILE, idempotent, snapshotting the profile
# before any change (Copy-Item .bak, this repo's own established pattern -- see
# tools/setup-flow-launcher.ps1 -- rather than winarchy's own New-WinarchySnapshot module).
$script:ProfileMarkerStart = '# >>> managed by 710.DesktopRice >>>'
$script:ProfileMarkerEnd = '# <<< managed by 710.DesktopRice <<<'

function Get-ShellProfilePath {
    # Computed by hand (not $PROFILE) so this works even when the calling session isn't
    # pwsh with $PROFILE populated.
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\profile.ps1'
}

function Install-ShellProfile {
    $profilePath = Get-ShellProfilePath
    $managed = Join-Path $Root 'config\pwsh\profile.ps1'
    $block = @(
        $script:ProfileMarkerStart
        ". '$managed'"
        $script:ProfileMarkerEnd
    ) -join "`r`n"

    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
    $pattern = '(?s)' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd)

    if ($existing -match $pattern) {
        if (($Matches[0] -replace '\r?\n', "`r`n") -eq $block) {
            Step-Ok "Profile hook already installed: $profilePath"
            return
        }
        Copy-Item $profilePath "$profilePath.bak" -Force
        $updated = [regex]::Replace($existing, $pattern, $block.Replace('$', '$$'))
        Set-Content -Path $profilePath -Value $updated -Encoding utf8NoBOM
        Step-Ok "Profile hook updated: $profilePath (previous saved to $profilePath.bak)"
        return
    }

    if (Test-Path $profilePath) { Copy-Item $profilePath "$profilePath.bak" -Force }
    else { New-Item -ItemType Directory -Path (Split-Path $profilePath) -Force | Out-Null }
    $newContent = if ($existing.Trim()) { $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n" } else { $block + "`r`n" }
    Set-Content -Path $profilePath -Value $newContent -Encoding utf8NoBOM
    Step-Ok "Profile hook installed: $profilePath"
}

function Remove-ShellProfile {
    $profilePath = Get-ShellProfilePath
    if (-not (Test-Path $profilePath)) {
        Step-Info 'No pwsh $PROFILE found; nothing to remove.'
        return
    }
    $existing = Get-Content $profilePath -Raw
    $pattern = '(?s)\r?\n?' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd) + '\r?\n?'
    if ($existing -notmatch $pattern) {
        Step-Info 'Profile hook not present; nothing to remove.'
        return
    }
    Copy-Item $profilePath "$profilePath.bak" -Force
    $updated = [regex]::Replace($existing, $pattern, "`r`n").Trim()
    if ($updated) { Set-Content -Path $profilePath -Value ($updated + "`r`n") -Encoding utf8NoBOM }
    else { Remove-Item $profilePath }
    Step-Ok "Profile hook removed: $profilePath (previous saved to $profilePath.bak)"
}

# --- Restoring theming side effects (wallpaper/accent/Terminal/Flow) -- uninstall-only --
# The wallpaper/lock-screen restore functions live next to what they revert, above
# (Restore-OriginalWallpaper near Set-DesktopWallpaper, Restore-LockScreen near
# Register-LockScreenSyncTask). These three cover the rest of what install.ps1 Section 4
# and tools\apply-wallust-outputs.ps1 change on a real wallpaper/theme apply, plus Flow
# Launcher's settings -- all called from uninstall.ps1.
function Restore-WindowsAccent {
    <# Reverts the accent-color/dark-mode values tools\apply-wallust-outputs.ps1 sets,
       back to its own 'windows-accent' snapshot (taken there, via a small duplicated
       inline copy of Save-OriginalState/Get-RegValueSnapshot -- see that script and this
       file's header note on why it doesn't dot-source this one). $null means that script
       never actually ran on this machine -- safe no-op. #>
    $snap = Get-OriginalState -Label 'windows-accent'
    if (-not $snap) { return $false }
    $personalize = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $dwm = 'HKCU:\SOFTWARE\Microsoft\Windows\DWM'
    Set-RegValueFromSnapshot -Path $personalize -Name 'AppsUseLightTheme' -Snapshot $snap.Personalize_AppsUseLightTheme
    Set-RegValueFromSnapshot -Path $personalize -Name 'SystemUsesLightTheme' -Snapshot $snap.Personalize_SystemUsesLightTheme
    Set-RegValueFromSnapshot -Path $personalize -Name 'ColorPrevalence' -Snapshot $snap.Personalize_ColorPrevalence
    Set-RegValueFromSnapshot -Path $dwm -Name 'ColorPrevalence' -Snapshot $snap.Dwm_ColorPrevalence
    Set-RegValueFromSnapshot -Path $dwm -Name 'AccentColor' -Snapshot $snap.Dwm_AccentColor
    Set-RegValueFromSnapshot -Path $dwm -Name 'ColorizationColor' -Snapshot $snap.Dwm_ColorizationColor
    Send-SettingChangeBroadcast
    Remove-OriginalState -Label 'windows-accent'
    return $true
}

function Restore-WindowsTerminalSettings {
    <# Reverts both Terminal changes back to their own independent snapshots: 'terminal-
       colorscheme' (profiles.defaults.colorScheme/theme/the "wallust" themes[] entry --
       taken by tools\apply-wallust-outputs.ps1's own inline duplicate, same reasoning as
       Restore-WindowsAccent above) and 'terminal-defaultprofile' (taken by install.ps1
       Section 8). Two separate labels, not one, because they're written by two different
       scripts that don't run in a fixed relative order relative to each other over the
       life of an install (Section 4 calls apply-wallust-outputs.ps1 before Section 8 ever
       runs on a first install, but apply-wallust-outputs.ps1 also fires independently on
       every later real wallpaper change) -- combining them into one label would let
       whichever runs first "win" the snapshot and silently drop the other's fields.
       Applies whichever of the two snapshots exist (each is independently optional) to
       the CURRENT settings.json in a single read-modify-write, so anything else the person
       changed in Terminal in between (a new profile, a font tweak) survives. #>
    $colorSnap = Get-OriginalState -Label 'terminal-colorscheme'
    $profileSnap = Get-OriginalState -Label 'terminal-defaultprofile'
    if (-not $colorSnap -and -not $profileSnap) { return $false }

    $wtSettingsCandidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    $wtSettingsPath = $wtSettingsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $wtSettingsPath) {
        Step-Info 'Windows Terminal settings.json not found -- nothing to restore (already gone, or Terminal was never launched).'
        Remove-OriginalState -Label 'terminal-colorscheme'
        Remove-OriginalState -Label 'terminal-defaultprofile'
        return $true
    }
    $wt = Get-Content $wtSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

    if ($colorSnap) {
        if ($colorSnap.ColorSchemeExisted -and $wt['profiles'] -and $wt['profiles']['defaults'] -is [hashtable]) {
            $wt['profiles']['defaults']['colorScheme'] = $colorSnap.ColorScheme
        } elseif ($wt['profiles'] -and $wt['profiles']['defaults'] -is [hashtable]) {
            $wt['profiles']['defaults'].Remove('colorScheme')
        }
        if ($colorSnap.ThemeKeyExisted) { $wt['theme'] = $colorSnap.Theme }
        elseif ($wt.ContainsKey('theme')) { $wt.Remove('theme') }
        if (-not $colorSnap.WallustThemeEntryExisted -and $wt['themes'] -is [array]) {
            $wt['themes'] = @($wt['themes'] | Where-Object { $_['name'] -ne 'wallust' })
        }
        Remove-OriginalState -Label 'terminal-colorscheme'
    }
    if ($profileSnap) {
        if ($profileSnap.Existed) { $wt['defaultProfile'] = $profileSnap.Value }
        elseif ($wt.ContainsKey('defaultProfile')) { $wt.Remove('defaultProfile') }
        Remove-OriginalState -Label 'terminal-defaultprofile'
    }

    $wt | ConvertTo-Json -Depth 50 | Set-Content -Path $wtSettingsPath -Encoding UTF8
    return $true
}

function Restore-FlowLauncherSettings {
    <# Reverts setup-flow-launcher.ps1's ActionKeyword merge and identity toggles back to
       its 'flow-settings' snapshot (taken there, before either ever changes anything), and
       removes the Everything plugin folder this repo installed (matched by its fixed
       plugin ID, not by folder name, same as setup-flow-launcher.ps1's own idempotency
       check). $null means setup-flow-launcher.ps1 never actually changed anything on this
       machine (Flow's Settings.json didn't exist yet, or everything was already how this
       repo wants it on the very first run) -- safe no-op either way. Same read-modify-
       write-current-file approach as Restore-WindowsTerminalSettings, so anything else the
       person changed in Flow's settings in between survives. #>
    $snap = Get-OriginalState -Label 'flow-settings'
    $everythingPluginId = 'D2D2C23B084D411DB66FE0C79D6C2A6E'
    $pluginsDir = Join-Path "$env:APPDATA\FlowLauncher" 'Plugins'
    if (Test-Path $pluginsDir) {
        Get-ChildItem $pluginsDir -Directory -ErrorAction SilentlyContinue | Where-Object {
            $manifest = Join-Path $_.FullName 'plugin.json'
            (Test-Path $manifest) -and ((Get-Content $manifest -Raw | ConvertFrom-Json).ID -eq $everythingPluginId)
        } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $snap) { return $false }

    $settingsPath = Join-Path "$env:APPDATA\FlowLauncher" 'Settings\Settings.json'
    if (-not (Test-Path $settingsPath)) {
        Step-Info 'Flow Launcher Settings.json not found -- nothing to restore.'
        Remove-OriginalState -Label 'flow-settings'
        return $true
    }
    $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

    $plugins = $settings['PluginSettings']['Plugins']
    if ($plugins -and $plugins.ContainsKey($snap.ProgramPluginId)) {
        $program = $plugins[$snap.ProgramPluginId]
        if ($snap.ActionKeywordsExisted) { $program['ActionKeywords'] = @($snap.ActionKeywords) }
        elseif ($program.ContainsKey('ActionKeywords')) { $program.Remove('ActionKeywords') }
    }
    foreach ($k in $snap.Identity.Keys) {
        $field = $snap.Identity[$k]
        if ($field.Existed) { $settings[$k] = $field.Value }
        elseif ($settings.ContainsKey($k)) { $settings.Remove($k) }
    }

    $settings | ConvertTo-Json -Depth 50 | Set-Content -Path $settingsPath -Encoding UTF8
    Remove-OriginalState -Label 'flow-settings'
    return $true
}
