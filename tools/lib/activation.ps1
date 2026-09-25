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
  extras/window-slots/window-slots.ps1) writes a LIVE, device_id-keyed copy of this key into
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

# --- Windows Defender exclusions (unconditional -- not gated behind -Activate) ------
function Get-PwshPath {
    <# pwsh.exe path for anything that gets PERSISTED -- a Scheduled Task action or a
       run-hidden launch spec -- and must keep working after PowerShell updates itself.
       For the Store/MSIX build (Dell's), `Get-Command pwsh` in an elevated shell resolves
       to the versioned package folder (...\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__
       8wekyb3d8bbwe\pwsh.exe, seen live 2026-09-23 after re-registering autostart from an
       admin shell), which disappears on the next Store update and would silently stop
       lock-screen sync from launching. The per-user App Execution Alias
       under %LOCALAPPDATA%\Microsoft\WindowsApps is what the Store keeps pointed at the
       current version, whatever shell registered the task -- prefer it. MSI installs
       (Program Files\PowerShell\7\pwsh.exe, not versioned) have no alias there and fall
       through to Get-Command. NOT for Get-DefenderExclusionPaths: Defender matches the
       real image path, which IS the versioned folder. #>
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if (Test-Path $alias) { return $alias }
    (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
}

function Get-DefenderExclusionPaths {
    <# Ported from winarchy's Get-WinarchyDefenderExclusionPaths. Covers the same two lag
       sources: frequent I/O from ShareX/Everything, and Defender scanning komorebic.exe /
       pwsh.exe / this repo's own .ps1 files the first time they're touched per session
       (the "only the first time" lag seen on capture/window-close). Only returns paths
       that actually exist on this machine, plus pwsh.exe (see Get-PwshImagePath). #>
    $komorebic = Get-KomorebiExe
    @(
        (Get-ShareXExe),
        "$env:USERPROFILE\Documents\ShareX",
        "$env:ProgramFiles\Everything\Everything.exe",
        "${env:ProgramFiles(x86)}\Everything\Everything.exe",
        $komorebic,
        $Root
    ) | Where-Object { $_ -and (Test-Path $_) }
    Get-PwshImagePath
}

function Get-PwshImagePath {
    <# The pwsh.exe Defender should exclude: the real image this very process runs from
       ($PSHOME) -- install/uninstall always run under PowerShell 7. Defender matches the
       real image path, which for the Store build is the versioned package folder
       (...\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe\pwsh.exe).
       winarchy (and our port) used `Get-Command pwsh.exe`, which depends on PATH order:
       after install.ps1 re-reads PATH from the registry it finds the per-user App
       Execution Alias instead (%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe) -- seen
       on the 2026-09-24 third install, where that alias is what got excluded, which
       doesn't cover the real binary. No Test-Path: it's the running process's own
       binary, and Test-Path inside Program Files\WindowsApps isn't reliable. #>
    Join-Path $PSHOME 'pwsh.exe'
}

function Get-StalePwshExclusions {
    <# Existing Defender exclusions that are an earlier pwsh.exe of ours, not the current
       one: the per-user alias (what the old Get-Command lookup could add) and any other
       Store-build version folder (left behind when PowerShell updates itself -- its
       folder name carries the version). Only exact pwsh.exe paths in those two places,
       so nothing the person excluded themselves is touched. #>
    param([string[]]$Current)
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    $real  = Get-PwshImagePath
    @($Current | Where-Object {
        $_ -and $_ -ne $real -and (
            $_ -eq $alias -or
            $_ -like "$env:ProgramFiles\WindowsApps\Microsoft.PowerShell_*\pwsh.exe")
    })
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
    # An earlier pwsh.exe exclusion (the alias, or a PowerShell version since updated
    # away) is swapped for the current one rather than left to pile up.
    $stale = @(Get-StalePwshExclusions -Current $current)
    if ($stale.Count -gt 0) {
        try {
            Remove-MpPreference -ExclusionPath $stale
            Step-Ok "Old pwsh.exe Defender exclusion(s) removed: $($stale -join ', ')"
        } catch {
            Step-Warn "Could not remove old pwsh.exe Defender exclusion(s): $($_.Exception.Message)"
        }
    }
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
    # Plus any earlier pwsh.exe exclusion of ours (see Get-StalePwshExclusions).
    $toRemove = @(@($paths | Where-Object { $current -contains $_ }) + @(Get-StalePwshExclusions -Current $current))
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

function Test-ExplorerShell {
    # True once Explorer's real shell (the taskbar window) exists -- see Wait-ExplorerRunning.
    if (-not ('Win32Shell.NativeMethods' -as [type])) {
        Add-Type -Namespace Win32Shell -Name NativeMethods -MemberDefinition @'
            [DllImport("user32.dll", CharSet = CharSet.Auto)]
            public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
'@
    }
    [Win32Shell.NativeMethods]::FindWindow('Shell_TrayWnd', $null) -ne [IntPtr]::Zero
}

function Restart-Explorer {
    <# The ONE Explorer restart for install -Activate / uninstall (taskbar auto-hide +
       hardening both need it; callers run this once if either changed something). Kills
       Explorer, then waits for Windows (Winlogon's AutoRestartShell) to bring the shell
       back. If it hasn't within the wait, starts it -- through a one-shot LeastPrivilege
       scheduled task, never straight from this shell: install/uninstall run elevated, and
       an Explorer started from an elevated process can come up elevated, which would make
       everything launched from Start/the taskbar elevated (same trap as the admin-AHK
       incident). Returns $true if the shell is back. Added 2026-09-24 after the full
       reinstall test left the desktop blank: Winlogon had restarted the shell after the
       first of two back-to-back kills and didn't after the second. #>
    param([int]$WaitSeconds = 15)
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Wait-ExplorerRunning -TimeoutSeconds $WaitSeconds
    if (Test-ExplorerShell) { return $true }

    $task = Get-TaskFullName -TaskName 'restart-explorer'
    $null = & schtasks.exe /Create /TN $task /TR "$env:WINDIR\explorer.exe" /SC ONCE /ST 23:59 /RL LIMITED /F 2>&1
    $null = & schtasks.exe /Run /TN $task 2>&1
    Wait-ExplorerRunning -TimeoutSeconds $WaitSeconds
    $null = & schtasks.exe /Delete /TN $task /F 2>&1
    Test-ExplorerShell
}

function Set-WindowsHardening {
    <# Applies (or, with -Revert, undoes) every setting from Get-HardeningSettings.
       Backs up each touched registry key first (Backup-RegistryKey, label 'hardening').
       Returns the number of settings changed. Does NOT restart Explorer itself (most of
       these values are only read at Explorer startup): the caller runs Restart-Explorer
       once, after this AND Set-TaskbarAutoHide, if either changed anything. Two separate
       restarts back to back left the desktop blank -- three times live on Dell, the last
       on 2026-09-24 even with a wait in between (Winlogon restarted the shell once after
       the first kill, and doesn't retry after a second). #>
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
        } catch {
            # Widgets button: Windows refuses script writes to TaskbarDa on current builds
            # ("Attempted to perform an unauthorized operation", even elevated), while its
            # own Settings toggle still works. Still tried every run in case a build allows
            # it; when it's refused, say what to do instead of printing the raw error
            # (plan doc item 31, user's pick).
            if ($name -eq 'TaskbarDa' -and ($_.Exception -is [System.UnauthorizedAccessException] -or $_.Exception.Message -match 'unauthorized operation')) {
                $onOff = if ($Revert) { 'back on' } else { 'off' }
                Step-Info "Windows won't let a script change the Widgets button -- turn it $onOff in Settings > Personalization > Taskbar."
            } else {
                Step-Warn "${name}: $($_.Exception.Message)"
            }
        }
    }
    $changed
}

# --- Taskbar auto-hide (-Activate-gated) ----------------------------------------------
function Set-TaskbarAutoHide {
    <# Ported from winarchy's Set-WinarchyTaskbarAutoHide (Taskbar.ps1 @ 4574fc7):
       flips bit 0x01 of StuckRects3's Settings byte array (byte 8), the same bit Windows'
       own "Automatically hide the taskbar" checkbox flips. Idempotent -- returns $false
       and does nothing if the flag already matches $Enabled, so a re-run of install.ps1
       doesn't restart explorer.exe for no reason. Backs up StuckRects3 before changing it.
       Returns $true when it changed something -- the caller then runs Restart-Explorer
       (required for the change to take effect), once, together with any hardening
       change; see Set-WindowsHardening for why it's never two restarts. #>
    param([Parameter(Mandatory)][bool]$Enabled)
    $stuck = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
    $val = (Get-ItemProperty -Path $stuck -Name Settings).Settings
    $flags = if ($Enabled) { $val[8] -bor 0x01 } else { $val[8] -band (-bnot 0x01) }
    if ($flags -eq $val[8]) { return $false }
    $null = Backup-RegistryKey -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' -Label 'taskbar'
    $val[8] = $flags
    Set-ItemProperty -Path $stuck -Name Settings -Value $val
    $true
}

function Test-TaskbarAutoHide {
    <# Read-only: is "Automatically hide the taskbar" on right now? Asks the shell itself
       (SHAppBarMessage ABM_GETSTATE, bit ABS_AUTOHIDE) for the live state; falls back to
       StuckRects3's byte 8 (what Set-TaskbarAutoHide flips) if that call isn't available.
       Used by scripts\Start-All.ps1 / Stop-All.ps1, which only ADVISE on auto-hide for an
       on-demand (no -Activate) setup -- they never change it (user's call, 2026-09-24). #>
    try {
        if (-not ('Win32Shell.AppBar' -as [type])) {
            Add-Type -Namespace Win32Shell -Name AppBar -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct APPBARDATA { public uint cbSize; public System.IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public System.IntPtr lParam; }
[DllImport("shell32.dll")] public static extern System.UIntPtr SHAppBarMessage(uint dwMessage, ref APPBARDATA pData);
"@
        }
        $abd = New-Object 'Win32Shell.AppBar+APPBARDATA'
        $abd.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($abd)
        $state = [Win32Shell.AppBar]::SHAppBarMessage(4, [ref]$abd)   # 4 = ABM_GETSTATE
        return (($state.ToUInt64() -band 1) -ne 0)                     # 1 = ABS_AUTOHIDE
    } catch {
        $val = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' -Name Settings -ErrorAction Stop).Settings
        return (($val[8] -band 0x01) -ne 0)
    }
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
    <# Definition of the 4 autostart components this repo actually uses (komorebi, YASB,
       ShareX, AHK). net-icon is deliberately not ported -- see this file's header comment;
       window-slots was unwired 2026-09-24 (see Remove-RetiredAutostart). Returns only the
       components whose executable is actually present.
       Each item: Key, TaskName, LnkName, Exe, Arguments, Delay (ISO-8601 duration, for the
       LogonTrigger's Delay). The 3 powershell-hosted components (all but ShareX, which
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
    <# -AtLogOn: only a task that actually starts at sign-in counts. That's what "this
       machine is -Activate'd" means -- an on-demand install also has a komorebi task now
       (Register-KomorebiOnDemandTask, no trigger), and without this check a later plain
       install.ps1 would read it as "autostart is active" and quietly register everything
       to start at sign-in (plan doc Open item 37). #>
    param([Parameter(Mandatory)][string]$TaskName, [switch]$AtLogOn)
    # $null = ... 2>&1 (capture-and-discard), not *> $null (redirect-and-discard): the
    # latter doesn't fully suppress schtasks.exe's own "ERROR: ..." text for a genuinely
    # missing task -- found live tonight when toolspply-wallust-outputs.ps1's own copy
    # of this exact check (same *> $null) leaked that text to the console the first time
    # all night it ever queried a task that truly didn't exist yet. Every earlier call to
    # this function happened to query a task that already existed, so the leak was never
    # actually exercised here until now.
    $full = Get-TaskFullName -TaskName $TaskName
    if ($AtLogOn) {
        $xml = & schtasks.exe /Query /TN $full /XML 2>&1
        return ($LASTEXITCODE -eq 0) -and (($xml -join "`n") -match '<LogonTrigger>')
    }
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
    # -RunLevel HighestAvailable: komorebi in elevated tiling mode (Get-KomorebiRunLevel).
    # -NoTrigger: an on-demand task that never fires on its own -- Start-All.ps1 and
    # reload-stack.ps1 fire it (Register-KomorebiOnDemandTask).
    param([Parameter(Mandatory)][object]$Component, [Parameter(Mandatory)][string]$User,
          [ValidateSet('LeastPrivilege', 'HighestAvailable')][string]$RunLevel = 'LeastPrivilege',
          [switch]$NoTrigger)
    $u = [System.Security.SecurityElement]::Escape($User)
    $cmd = [System.Security.SecurityElement]::Escape($Component.Exe)
    $arg = [System.Security.SecurityElement]::Escape($Component.Arguments)
    $delay = if ($Component.Delay) { $Component.Delay } else { 'PT0S' }
    $triggers = if ($NoTrigger) { '  <Triggers />' } else { @"
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$u</UserId>
      <Delay>$delay</Delay>
    </LogonTrigger>
  </Triggers>
"@ }
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>710.DesktopRice autostart: $($Component.Key)</Description>
  </RegistrationInfo>
$triggers
  <Principals>
    <Principal id="Author">
      <UserId>$u</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>$RunLevel</RunLevel>
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
       registration fails. Also removes retired components (Remove-RetiredAutostart). #>
    Remove-StartupShortcuts
    Remove-RetiredAutostart
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $components = Get-AutostartComponents
    if ($components.Count -eq 0) {
        Step-Warn 'Autostart: no components installed.'
        return
    }
    $admin = Test-IsAdmin
    foreach ($c in $components) {
        $runLevel = if ($c.Key -eq 'komorebi') { Get-KomorebiRunLevel } else { 'LeastPrivilege' }
        if ($runLevel -eq 'HighestAvailable' -and -not $admin) {
            # Only an admin can register a task that runs elevated.
            if (Test-Task -TaskName $c.TaskName) {
                Step-Warn "Autostart komorebi: elevated tiling needs an admin PowerShell to register -- its existing task was left as it is. Re-run .\install.ps1 from an admin shell."
                continue
            }
            Step-Warn "Autostart komorebi: elevated tiling needs an admin PowerShell to register -- registering it non-elevated for now (admin windows won't tile). Re-run .\install.ps1 from an admin shell."
            $runLevel = 'LeastPrivilege'
        }
        $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) "710-task-$($c.TaskName).xml"
        try {
            Set-Content -Path $xmlPath -Value (New-TaskXml -Component $c -User $user -RunLevel $runLevel) -Encoding Unicode
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
    Remove-RetiredAutostart
}

function Remove-RetiredAutostart {
    <# Cleans autostart components this repo no longer runs off a machine that still has
       them: the sign-in task, its launch spec file, and a copy still running. Called by
       Register-Autostart (install -Activate) and Unregister-Autostart (uninstall). A
       leftover Startup .lnk is already covered by Remove-StartupShortcuts' wildcard.
         window-slots -- unwired 2026-09-24 (the user never pinned an app, so the daemon
                         sat idle); the code is kept under extras\window-slots\ as a
                         possible future feature (plan doc item 2). #>
    foreach ($name in @('window-slots')) {
        if (Test-Task -TaskName $name) {
            $null = & schtasks.exe /Delete /TN (Get-TaskFullName -TaskName $name) /F 2>&1
            Step-Info "Removed the retired '$name' sign-in task."
        }
        Remove-Item (Join-Path $env:LOCALAPPDATA "710.DesktopRice\launch-$name.txt") -Force -ErrorAction SilentlyContinue
    }
    Stop-RetiredWindowSlots
}

function Stop-RetiredWindowSlots {
    <# Stops a still-running window-slots daemon (retired 2026-09-24): the pwsh running
       Start-WindowSlots.ps1, and the powershell.exe that launched it, matched by command
       line so no other PowerShell is touched -- the same match its own
       Stop-WindowSlotsDaemon used. A no-op on a machine that never ran it. #>
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains('Start-WindowSlots.ps1') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Get-AutostartStatus {
    <# Key -> bool (task registered or fallback .lnk present), per component. #>
    $startup = [Environment]::GetFolderPath('Startup')
    $status = @{}
    foreach ($c in Get-AutostartComponents) {
        $hasTask = Test-Task -TaskName $c.TaskName -AtLogOn
        $hasLnk = Test-Path (Join-Path $startup $c.LnkName)
        $status[$c.Key] = ($hasTask -or $hasLnk)
    }
    $status
}

function Register-KomorebiOnDemandTask {
    <# For an install WITHOUT -Activate: komorebi's task with no trigger at all, at the
       tiling mode's run level. Nothing starts at sign-in; Start-All.ps1 and reload-stack.ps1
       (SUPER+Shift+R's komorebi restart) fire it, so on-demand komorebi comes up exactly
       like an -Activate'd one -- elevated in elevated tiling mode, with no UAC prompt,
       whatever shell fires it (plan doc Open item 37). Test-Task -AtLogOn ignores this
       task, so it never makes the machine look -Activate'd. Idempotent (/F). #>
    $c = @(Get-AutostartComponents) | Where-Object { $_.Key -eq 'komorebi' } | Select-Object -First 1
    if (-not $c) { Step-Warn 'komorebi on-demand task: komorebi.exe not found -- skipped.'; return }
    $runLevel = Get-KomorebiRunLevel
    if ($runLevel -eq 'HighestAvailable' -and -not (Test-IsAdmin)) {
        Step-Warn 'komorebi on-demand task: elevated tiling needs an admin PowerShell to register -- skipped (Start-All will start komorebi non-elevated). Re-run .\install.ps1 from an admin shell.'
        return
    }
    $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) '710-task-komorebi-ondemand.xml'
    try {
        Set-Content -Path $xmlPath -Value (New-TaskXml -Component $c -User "$env:USERDOMAIN\$env:USERNAME" -RunLevel $runLevel -NoTrigger) -Encoding Unicode
        $null = & schtasks.exe /Create /TN (Get-TaskFullName -TaskName $c.TaskName) /XML $xmlPath /F 2>&1
        if ($LASTEXITCODE -ne 0) { throw "schtasks /Create exited with code $LASTEXITCODE" }
        Step-Ok "komorebi on-demand task registered ($(if ($runLevel -eq 'HighestAvailable') { 'elevated' } else { 'non-elevated' }); no sign-in trigger -- Start-All.ps1 fires it)"
    } catch {
        Step-Warn "komorebi on-demand task: couldn't register it ($($_.Exception.Message)) -- Start-All will start komorebi directly (non-elevated)."
    } finally {
        Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
    }
}

# --- Tiling mode: elevated komorebi or not (plan doc Open item 37) ------------------------
# "elevated" (the default): komorebi's task runs HighestAvailable, so komorebi can see and
# tile admin windows -- a non-elevated komorebi can't even read their process, let alone
# move them. "normal": LeastPrivilege like everything else; admin windows float. Only
# komorebi ever runs elevated -- AHK runs with UI Access instead, so what it launches stays
# normal. The choice is remembered per machine and only changes when install.ps1 gets
# -ElevatedTiling or -NoElevatedTiling; uninstall forgets it.
# Security, accepted and documented (README): an elevated task whose launch chain reads
# user-writable files -- including komorebi's own komorebi.ps1/.ahk loading from its config
# folder -- is a silent route to admin for anything already running as you.
function Get-TilingModePath { Join-Path $env:LOCALAPPDATA '710.DesktopRice\tiling-mode.txt' }

function Get-TilingMode {
    <# 'elevated' or 'normal'; the remembered value, else the default ('elevated'). #>
    $path = Get-TilingModePath
    if (Test-Path $path) {
        $v = (Get-Content $path -Raw -ErrorAction SilentlyContinue)
        if ($v) { $v = $v.Trim() }
        if ($v -in 'elevated', 'normal') { return $v }
    }
    'elevated'
}

function Get-KomorebiRunLevel {
    if ((Get-TilingMode) -eq 'elevated') { 'HighestAvailable' } else { 'LeastPrivilege' }
}

function Resolve-TilingMode {
    <# install.ps1's switch -> remembered -> default, in that order. Writes the result back
       (so a first install remembers the default too) and returns Mode, Source
       ('switch' / 'remembered' / 'default') and Changed (vs. what was remembered before). #>
    param([switch]$Elevated, [switch]$Normal)
    $path = Get-TilingModePath
    $before = $null
    if (Test-Path $path) {
        $b = (Get-Content $path -Raw -ErrorAction SilentlyContinue)
        if ($b) { $b = $b.Trim() }
        if ($b -in 'elevated', 'normal') { $before = $b }
    }
    if ($Elevated) { $mode = 'elevated'; $source = 'switch' }
    elseif ($Normal) { $mode = 'normal'; $source = 'switch' }
    elseif ($before) { $mode = $before; $source = 'remembered' }
    else { $mode = 'elevated'; $source = 'default' }
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    Set-Content -Path $path -Value $mode -Encoding ascii
    [pscustomobject]@{ Mode = $mode; Source = $source; Changed = ($null -ne $before -and $before -ne $mode) }
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
    $pwsh = Get-PwshPath
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

    # A window-slots daemon still running from before it was unwired (2026-09-24).
    Stop-RetiredWindowSlots

    # komorebi: try its own graceful `stop` first (releases window-management hooks,
    # restores window styles/borders) before a hard kill, so a stray leftover style isn't
    # left on a window after uninstall.
    if (Get-Process komorebi -ErrorAction SilentlyContinue) {
        $komorebic = (Get-Command komorebic -ErrorAction SilentlyContinue)?.Source
        if ($komorebic) { try { & $komorebic stop 2>$null | Out-Null; Start-Sleep -Milliseconds 300 } catch { } }
        Stop-Process -Name komorebi -Force -ErrorAction SilentlyContinue
        # In elevated tiling mode komorebi runs as admin: `komorebic stop` still reaches it
        # from a normal shell, but the force-kill fallback can't -- so say so if it's still up.
        Start-Sleep -Milliseconds 300
        if (Get-Process komorebi -ErrorAction SilentlyContinue) {
            Step-Warn 'komorebi is still running (in elevated tiling mode it runs as admin, which a normal shell cannot force-stop). Run this from an admin PowerShell.'
        }
    }

    # YASB: same graceful-stop-then-kill pattern.
    if (Get-Process yasb -ErrorAction SilentlyContinue) {
        $yasbc = (Get-Command yasbc -ErrorAction SilentlyContinue)?.Source
        if ($yasbc) { try { & $yasbc stop 2>$null | Out-Null; Start-Sleep -Milliseconds 300 } catch { } }
        Stop-Process -Name yasb -Force -ErrorAction SilentlyContinue
    }

    # ShareX: no CLI stop -- the resident tray process is all there is to end.
    Stop-Process -Name ShareX -Force -ErrorAction SilentlyContinue

    # AHK, last. 710.ahk runs with UI Access (AutoHotkey64_UIA.exe), and a normal shell
    # (Stop-All.ps1) can't Stop-Process a UIA process -- 'Access is denied', found live
    # 2026-09-25. So: ask it to quit first (710.ahk lets exactly this one message through
    # its UIPI filter), give it a couple of seconds, then fall back to the old kill for
    # anything still standing -- which works from uninstall's admin shell, and for a
    # plain-AutoHotkey64 710.ahk from anywhere. Both steps only ever touch THIS repo's
    # 710.ahk (window title / command line), never a blanket Stop-Process: another AHK v2
    # script the person runs isn't ours to touch.
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    if (Send-AhkQuit -ScriptPath $ahkScript) {
        $deadline = (Get-Date).AddSeconds(2)
        while ((Get-Date) -lt $deadline -and (Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 100
        }
    }
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe' OR Name = 'AutoHotkey64_UIA.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ahkScript) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {
        Step-Warn "Could not check for a running 710.ahk AutoHotkey process (Win32_Process unavailable): $($_.Exception.Message)"
    }
    if ((Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero) {
        Step-Warn '710.ahk is still running (it runs with UI Access, which a normal shell cannot force-stop). Quit it from its tray icon, or run this from an admin PowerShell.'
    }
}

function Find-AhkWindow {
    <# The hidden main window of the AHK process running -ScriptPath, or [IntPtr]::Zero.
       AHK titles that window "<full script path> - AutoHotkey v2.x", so the title is how we
       tell 710.ahk apart from any other AHK script. Found by window rather than by
       Win32_Process because a normal shell can't read a UI Access process's command line;
       window titles, on the other hand, are readable across that boundary (open-main-menu.ahk
       finds 710.ahk the same way). #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    Initialize-AhkWindowNative
    $hwnd = [IntPtr]::Zero
    while ($true) {
        # [NullString]::Value, NOT $null: PowerShell hands $null to a .NET string parameter
        # as "" -- and FindWindowEx(..., "") only matches windows with an EMPTY title, so
        # the first build of this never found 710.ahk (Stop-All left it running, 2026-09-25).
        $hwnd = [Win710.AhkWindow]::FindWindowEx([IntPtr]::Zero, $hwnd, 'AutoHotkey', [NullString]::Value)
        if ($hwnd -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        $sb = [System.Text.StringBuilder]::new(1024)
        [void][Win710.AhkWindow]::GetWindowText($hwnd, $sb, $sb.Capacity)
        if ($sb.ToString().IndexOf($ScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $hwnd }
    }
}

function Send-AhkQuit {
    <# Posts the registered '710sRice.Quit' message to 710.ahk (see the OnMessage next to
       OpenMainMenu in config\ahk\710.ahk). $true if a 710.ahk window was found and the post
       went through, $false otherwise -- the caller's kill fallback covers the rest. #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    $hwnd = Find-AhkWindow -ScriptPath $ScriptPath
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    $msg = [Win710.AhkWindow]::RegisterWindowMessage('710sRice.Quit')
    return [Win710.AhkWindow]::PostMessage($hwnd, $msg, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Initialize-AhkWindowNative {
    if (-not ('Win710.AhkWindow' -as [type])) {
        Add-Type -Namespace Win710 -Name AhkWindow -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern uint RegisterWindowMessage(string lpString);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
'@
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
    <# Reverts setup-flow-launcher.ps1 from its two once-only snapshots:
         'flow-settings'          Program plugin ActionKeywords + identity toggles
         'flow-explorer-settings' Explorer plugin ActionKeywords + its FileSearchActionKeyword /
                                  FileSearchKeywordEnabled / IndexSearchEngine fields
         'flow-querymode'         LastQueryMode (Flow's "open with the last query" setting)
       and removes the legacy standalone Everything plugin folder if one is still there
       (matched by its fixed plugin ID, not folder name -- this repo used to install it).
       Flow is force-stopped first and NOT relaunched, same reasons as in
       setup-flow-launcher.ps1: a running Flow saves its in-memory settings back over the
       files on exit and holds its plugin DLLs locked; and uninstall.ps1 runs elevated, so
       a Flow started from here would run as admin. A missing snapshot means that part was
       never changed on this machine -- safe no-op. Same read-modify-write-current-file
       approach as Restore-WindowsTerminalSettings, so anything else the person changed in
       Flow's settings in between survives. #>
    $snap  = Get-OriginalState -Label 'flow-settings'
    $snapE = Get-OriginalState -Label 'flow-explorer-settings'
    $snapQ = Get-OriginalState -Label 'flow-querymode'
    $flowRoot   = Join-Path $env:APPDATA 'FlowLauncher'
    $pluginsDir = Join-Path $flowRoot 'Plugins'
    $legacyEverythingPluginId = 'D2D2C23B084D411DB66FE0C79D6C2A6E'

    $flow = @(Get-Process -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)
    if ($flow.Count) {
        $flow | Stop-Process -Force
        $flow | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
    }

    if (Test-Path $pluginsDir) {
        Get-ChildItem $pluginsDir -Directory -ErrorAction SilentlyContinue | Where-Object {
            $manifest = Join-Path $_.FullName 'plugin.json'
            (Test-Path $manifest) -and ((Get-Content $manifest -Raw | ConvertFrom-Json).ID -eq $legacyEverythingPluginId)
        } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $snap -and -not $snapE -and -not $snapQ) { return $false }

    $settingsPath = Join-Path $flowRoot 'Settings\Settings.json'
    if (-not (Test-Path $settingsPath)) {
        Step-Info 'Flow Launcher Settings.json not found -- nothing to restore.'
        Remove-OriginalState -Label 'flow-settings'
        Remove-OriginalState -Label 'flow-explorer-settings'
        Remove-OriginalState -Label 'flow-querymode'
        return $true
    }
    $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    $plugins = $settings['PluginSettings']['Plugins']

    if ($snap) {
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
    }

    if ($snapE) {
        if ($plugins -and $plugins.ContainsKey($snapE.ExplorerPluginId)) {
            $explorerEntry = $plugins[$snapE.ExplorerPluginId]
            if ($snapE.ActionKeywordsExisted) { $explorerEntry['ActionKeywords'] = @($snapE.ActionKeywords) }
            elseif ($explorerEntry.ContainsKey('ActionKeywords')) { $explorerEntry.Remove('ActionKeywords') }
        }
        $explorerPath = Join-Path $flowRoot 'Settings\Plugins\Flow.Launcher.Plugin.Explorer\Settings.json'
        if ($snapE.ExplorerFileExisted -and (Test-Path $explorerPath)) {
            $explorer = Get-Content $explorerPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            foreach ($k in $snapE.Fields.Keys) {
                $field = $snapE.Fields[$k]
                if ($field.Existed) { $explorer[$k] = $field.Value }
                elseif ($explorer.ContainsKey($k)) { $explorer.Remove($k) }
            }
            $explorer | ConvertTo-Json -Depth 50 | Set-Content -Path $explorerPath -Encoding UTF8
        }
    }

    if ($snapQ) {
        $field = $snapQ.LastQueryMode
        if ($field.Existed) { $settings['LastQueryMode'] = $field.Value }
        elseif ($settings.ContainsKey('LastQueryMode')) { $settings.Remove('LastQueryMode') }
    }

    $settings | ConvertTo-Json -Depth 50 | Set-Content -Path $settingsPath -Encoding UTF8
    Remove-OriginalState -Label 'flow-settings'
    Remove-OriginalState -Label 'flow-explorer-settings'
    Remove-OriginalState -Label 'flow-querymode'
    return $true
}
