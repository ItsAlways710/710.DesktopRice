<#
.SYNOPSIS
  The library install.ps1, uninstall.ps1, the 710sRice command's install-side commands and
  Start-All / Stop-All load: it loads the shared helpers (one small library each, just below)
  and holds the pieces that haven't moved into modules of their own yet -- docs\map.md says
  which. Dot-sourced -- never run directly.

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

  display_index_preferences (which screen is screen 1-4): install's monitors step keeps the
  stable map in config\komorebi\display-index.local.json (tools\write-display-index.ps1,
  rules in tools\lib\monitors.ps1) -- keyed by serial_number_id, which komorebi's own docs
  (multi-monitor-setup.md) recommend for this key, or the device_id when a screen has no serial
  or shares it. winarchy writes a live, device_id-keyed copy from its window-slots daemon
  instead; that daemon's port was dropped from this repo (Group 1 #7).
#>

# Your lock-screen picture: Invoke-LockScreenSetter and its record (install's tasks step and
# uninstall use them below; the wallpaper pipeline dot-sources the same file).
. (Join-Path $PSScriptRoot 'lockscreen.ps1')

# The components (tools\components\<id>.ps1, Group 1 #12). Only functions -- nothing is read
# until something asks.
if (-not (Get-Command Get-RiceComponents -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'components.ps1') }

# The shared helpers, one small library each (docs\map.md says what's in each).
. (Join-Path $PSScriptRoot 'text.ps1')
. (Join-Path $PSScriptRoot 'snapshots.ps1')
. (Join-Path $PSScriptRoot 'userenv.ps1')
. (Join-Path $PSScriptRoot 'wallpaper.ps1')
. (Join-Path $PSScriptRoot 'apps.ps1')
. (Join-Path $PSScriptRoot 'tasks.ps1')
. (Join-Path $PSScriptRoot 'elevation.ps1')
. (Join-Path $PSScriptRoot 'ahk.ps1')
. (Join-Path $PSScriptRoot 'shortcuts.ps1')
. (Join-Path $PSScriptRoot 'explorer.ps1')
. (Join-Path $PSScriptRoot 'fonts.ps1')
. (Join-Path $PSScriptRoot 'terminal.ps1')

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

# --- Full time's Windows settings: saved, applied, put back ----------------------------
# What a full-time machine changes in Windows: taskbar auto-hide, the hardening values
# (Get-HardeningSettings) and the Startup delay. Since 2026-10-03 the switch to full time --
# `710sRice activate`, or install -Activate on a machine that wasn't full-time -- first saves
# how each one was, once, in original-state\full-time-settings.json, and the way back --
# `710sRice deactivate`, uninstall -- puts each one back from that copy, so a setting you had
# your own way (Task View hidden in Settings writes the very value the hardening does) stays
# yours. A machine made full-time before then has no copy: the way back deletes the values
# instead, which hands each setting to Windows' own default (what uninstall always did).
# Never saved on a machine that's already full-time: the "before" would be full time's own.

function Get-FullTimeSettingsPath {
    # Where the saved copy lives (Save-OriginalState's label 'full-time-settings'). Built here
    # rather than through Get-OriginalStateDir, which creates the folder: dry runs read this.
    Join-Path $env:LOCALAPPDATA '710.DesktopRice\original-state\full-time-settings.json'
}

function Get-TaskbarAutoHideSetting {
    <# "Automatically hide the taskbar" as stored: StuckRects3's byte 8, the bit
       Set-TaskbarAutoHide flips (not the shell's live answer, Test-TaskbarAutoHide -- the copy
       and the put-back compare against what Set-TaskbarAutoHide writes). $null when there's no
       StuckRects3 to read. #>
    $val = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' -Name Settings -ErrorAction SilentlyContinue).Settings
    if ($null -eq $val -or @($val).Count -lt 9) { return $null }
    [bool]($val[8] -band 0x01)
}

function Get-SavedFullTimeSettings {
    # The saved copy (Save-FullTimeSettings) as a hashtable, or $null when there's none. Never
    # writes anything.
    $file = Get-FullTimeSettingsPath
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
}

function Get-SavedFullTimeSettingsWhen {
    # When the copy was saved, as it gets printed ("2026-10-03 13:20").
    param($Saved)
    $s = if ($Saved) { $Saved['Saved'] }
    if ($s -is [datetime]) { return $s.ToString('yyyy-MM-dd HH:mm') }
    if ("$s" -match '^(\d{4}-\d\d-\d\d)T(\d\d:\d\d)') { return "$($Matches[1]) $($Matches[2])" }
    'by an earlier activate'
}

function Save-FullTimeSettings {
    <# Saves full time's Windows settings as they are right now -- each hardening value
       (Get-RegValueSnapshot: existed, value, type), auto-hide, the Startup delay -- for the way
       back to put back. Once: a copy that's already there is kept, since it's the real "before"
       (left by a switch that was cut off part-way). Callers save only when a machine is about to
       go from on demand to full time, before anything changes. $true when it saved now, $false
       when a copy was already there. Throws when the copy can't be written: the caller decides
       whether to go on without one. #>
    if (Test-Path -LiteralPath (Get-FullTimeSettingsPath)) { return $false }
    $hardening = @(foreach ($s in Get-HardeningSettings) {
        $path, $name, $null = $s
        $snap = Get-RegValueSnapshot -Path $path -Name $name
        [ordered]@{ Path = $path; Name = $name; Existed = $snap.Existed; Value = $snap.Value; Type = $snap.Type }
    })
    $delay = Get-RegValueSnapshot -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' -Name 'StartupDelayInMSec'
    Save-OriginalState -Label 'full-time-settings' -Data ([ordered]@{
        Saved           = (Get-Date -Format 's')
        TaskbarAutoHide = Get-TaskbarAutoHideSetting
        Hardening       = $hardening
        StartupDelay    = $delay
    })
    if (-not (Test-Path -LiteralPath (Get-FullTimeSettingsPath))) { throw "the copy wasn't written ($(ConvertTo-SafePath (Get-FullTimeSettingsPath)))" }
    $true
}

function Get-HardeningToChange {
    # The names of the hardening values Set-WindowsHardening would change right now. Read-only.
    foreach ($s in Get-HardeningSettings) {
        $path, $name, $value = $s
        $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Ignore
        $current = if ($item) { $item.$name }
        if ($current -ne $value) { $name }
    }
}

function Get-FullTimeSettingsRestorePlan {
    <# What the way back would do (Restore-FullTimeWindowsSettings), read-only:
         FromCopy / When     -- a saved copy, and when it was saved
         Values              -- each hardening value that would change: Path, Name, and the saved
                                Existed / Value / Type (Existed $false: remove it). Without a
                                copy, every hardening value that's there (all removed). A value
                                added to Get-HardeningSettings after the copy was saved is
                                removed too.
         AutoHideNow / AutoHideTo / AutoHideChange
         Delay / DelayChange -- the saved StartupDelayInMSec (Existed $false: remove it) #>
    param($Saved)
    $values = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Saved) {
        foreach ($h in @($Saved['Hardening'])) {
            if (-not $h -or -not $h['Path'] -or -not $h['Name']) { continue }
            [void]$seen.Add("$($h['Path'])|$($h['Name'])")
            $item = Get-ItemProperty -Path $h['Path'] -Name $h['Name'] -ErrorAction Ignore
            $current = if ($item) { $item.($h['Name']) }
            $change = if ($h['Existed']) { ($null -eq $current) -or ("$current" -ne "$($h['Value'])") } else { $null -ne $current }
            if ($change) {
                $values.Add([pscustomobject]@{ Path = $h['Path']; Name = $h['Name']; Existed = [bool]$h['Existed']; Value = $h['Value']; Type = $h['Type'] })
            }
        }
    }
    foreach ($s in Get-HardeningSettings) {
        $path, $name, $null = $s
        if ($seen.Contains("$path|$name")) { continue }
        $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Ignore
        if ($item -and $null -ne $item.$name) {
            $values.Add([pscustomobject]@{ Path = $path; Name = $name; Existed = $false; Value = $null; Type = $null })
        }
    }
    $autoNow = Get-TaskbarAutoHideSetting
    $autoTo = if ($Saved -and $null -ne $Saved['TaskbarAutoHide']) { [bool]$Saved['TaskbarAutoHide'] } else { $false }
    $delayNow = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' -Name 'StartupDelayInMSec' -ErrorAction Ignore
    $delay = if ($Saved -and $Saved['StartupDelay']) { $Saved['StartupDelay'] } else { @{ Existed = $false; Value = $null; Type = $null } }
    $delayChange = if ($delay['Existed']) { (-not $delayNow) -or ("$($delayNow.StartupDelayInMSec)" -ne "$($delay['Value'])") } else { [bool]$delayNow }
    [pscustomobject]@{
        FromCopy       = [bool]$Saved
        When           = if ($Saved) { Get-SavedFullTimeSettingsWhen $Saved } else { $null }
        Values         = @($values)
        AutoHideNow    = $autoNow
        AutoHideTo     = $autoTo
        AutoHideChange = ($null -ne $autoNow -and $autoNow -ne $autoTo)
        Delay          = $delay
        DelayChange    = [bool]$delayChange
    }
}

function Set-FullTimeWindowsSettings {
    <# Full time's Windows settings, applied: taskbar auto-hide on, the hardening, no Startup
       delay -- ONE Explorer restart if either of the first two changed something (see
       Restart-Explorer: two back-to-back restarts left the desktop blank, 2026-09-24), with the
       tray icons' "always show" choices put back around it (Backup-TrayIconPromotions). Moved
       here from install.ps1's windows step (2026-10-03) so `710sRice activate` applies exactly
       the same. Save-FullTimeSettings comes first, when the machine is going full-time.
       -DryRun: what it would change; nothing is changed. Prints its own lines. #>
    param([switch]$DryRun)
    if ($DryRun) {
        $auto  = Get-TaskbarAutoHideSetting
        $hard  = @(Get-HardeningToChange)
        $total = @(Get-HardeningSettings).Count
        $delay = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' -Name 'StartupDelayInMSec' -ErrorAction Ignore
        if ($auto -eq $true) { Step-Info 'Native taskbar: already set to auto-hide' }
        else { Write-Host '  [ ] Set the native taskbar to auto-hide' }
        # The Widgets button (TaskbarDa) counts, but Windows refuses scripts that write it on
        # current builds (see Set-WindowsHardening): the run's own count leaves it out.
        $widgets = if ($hard -contains 'TaskbarDa') { " -- one is the Widgets button, which Windows may refuse to let a script change" } else { '' }
        if ($hard.Count) { Write-Host "  [ ] Windows hardening: $($hard.Count) of $total value(s) to change (no Bing search, ad suggestions, Copilot/Widgets/Task View buttons, Start recommendations, tips and suggested content)$widgets" }
        else { Step-Info 'Windows hardening: already applied' }
        if ($auto -ne $true -or $hard.Count) { Write-Host '  [ ] Restart Explorer once (the taskbar and these settings only take effect that way)' }
        if (-not $delay -or $delay.StartupDelayInMSec -ne 0) { Write-Host '  [ ] Remove the Startup app-launch delay (StartupDelayInMSec=0)' }
        else { Step-Info 'Startup app-launch delay: already removed' }
        return
    }

    # Snapshot tray-icon promotions before the kill below -- Explorer's own forced restart can
    # reset every app's "always show this icon" preference, not just this repo's own (see
    # Backup-TrayIconPromotions). Restored once Explorer's confirmed back up.
    $trayIconBackup = Backup-TrayIconPromotions

    # Both only change settings; Explorer is restarted ONCE below if either did.
    $needExplorerRestart = $false
    try {
        if (Set-TaskbarAutoHide -Enabled $true) { Step-Ok 'Native taskbar set to auto-hide'; $needExplorerRestart = $true }
        else { Step-Ok 'Native taskbar already set to auto-hide' }
    } catch { Step-Warn "Could not set the taskbar to auto-hide: $($_.Exception.Message)" }

    try {
        $n = Set-WindowsHardening
        Step-Ok "Windows hardening applied ($n setting(s) changed: no Bing search, ad suggestions, Copilot/Widgets/Task View buttons, Start recommendations)"
        if ($n -gt 0) { $needExplorerRestart = $true }
    } catch { Step-Warn "Could not apply Windows hardening: $($_.Exception.Message)" }

    if ($needExplorerRestart) {
        if (Restart-Explorer) { Step-Ok 'Explorer restarted once to apply the taskbar/hardening changes' }
        else { Step-Warn "Explorer didn't come back after its restart -- sign out and back in (Ctrl+Alt+Del) to get the desktop back." }
    }
    Restore-TrayIconPromotions -BackupFile $trayIconBackup

    try {
        Set-StartupDelay
        Step-Ok 'Startup app-launch delay removed (StartupDelayInMSec=0)'
    } catch { Step-Warn "Could not remove the Startup app-launch delay: $($_.Exception.Message)" }
}

function Restore-FullTimeWindowsSettings {
    <# The way back from full time (`710sRice deactivate`, uninstall): taskbar auto-hide, the
       hardening values and the Startup delay as they were before the machine went full-time,
       from the saved copy (Save-FullTimeSettings). With no copy on a full-time machine (made
       full-time before 710sRice saved one) -- what uninstall always did: auto-hide off, every
       hardening value deleted (Set-WindowsHardening -Revert), the delay value deleted, which
       hands each setting to Windows' own default. With no copy on an on-demand machine
       (-FullTime:$false, the mode read before anything changed): nothing at all -- 710sRice
       never changed them there (they only change on the way to full time, after the copy is
       saved), so whatever is there is yours or Windows', and a delete would wipe it (your Task
       View hidden, an auto-hide you chose; the Dell, 2026-10-03). ONE Explorer restart if auto-hide or a
       hardening value changed, with the tray icons' choices put back around it. Leaves the
       saved copy where it is: the caller deletes it once the whole switch is done, so a switch
       cut off part-way puts back the same values when it's run again. Your lock-screen
       picture's own restore runs after this in uninstall: the hardening holds two lock-screen
       values. -DryRun: what it would do; nothing is changed. Prints its own lines. #>
    param([switch]$DryRun, [bool]$FullTime = $true)
    $saved = Get-SavedFullTimeSettings
    if (-not $saved -and -not $FullTime) {
        Step-Info "Taskbar, Windows hardening and Startup delay: nothing to put back -- 710sRice only changes them on a full-time machine, and this one is on demand"
        return
    }
    $plan  = Get-FullTimeSettingsRestorePlan -Saved $saved
    $total = @(Get-HardeningSettings).Count
    $onOff = { param($b) if ($b) { 'on' } else { 'off' } }

    if ($DryRun) {
        if ($plan.AutoHideChange) { Write-Host "  [ ] Native taskbar: auto-hide $(& $onOff $plan.AutoHideTo)$(if ($plan.FromCopy) { ', as it was before' })" }
        elseif ($null -ne $plan.AutoHideNow) { Step-Info "Native taskbar: auto-hide already $(& $onOff $plan.AutoHideNow)" }
        if (-not $plan.Values.Count) { Step-Info 'Windows hardening: nothing to put back' }
        elseif ($plan.FromCopy) { Write-Host "  [ ] Windows hardening: $($plan.Values.Count) of $total value(s) put back as they were before this machine went full-time (saved $($plan.When))" }
        else { Write-Host "  [ ] Windows hardening: $($plan.Values.Count) of $total value(s) deleted, handed back to Windows' own defaults (no saved copy of how they were before)" }
        if ($plan.AutoHideChange -or $plan.Values.Count) { Write-Host '  [ ] Restart Explorer once (the taskbar and these settings only take effect that way)' }
        if ($plan.DelayChange) { Write-Host "  [ ] Startup app-launch delay: $(if ($plan.Delay['Existed']) { "put back as it was ($($plan.Delay['Value']) ms)" } else { "removed (Explorer's own ~10 s)" })" }
        else { Step-Info 'Startup app-launch delay: nothing to put back' }
        return
    }

    # Snapshot tray-icon promotions before the kill below (see Backup-TrayIconPromotions).
    $trayIconBackup = Backup-TrayIconPromotions
    $needExplorerRestart = $false

    if ($plan.AutoHideChange) {
        try {
            if (Set-TaskbarAutoHide -Enabled $plan.AutoHideTo) {
                Step-Ok "Native taskbar auto-hide turned $(& $onOff $plan.AutoHideTo)$(if ($plan.FromCopy) { ', as it was before' })"
                $needExplorerRestart = $true
            }
        } catch { Step-Warn "Could not change the taskbar's auto-hide: $($_.Exception.Message)" }
    } elseif ($null -ne $plan.AutoHideNow) {
        Step-Ok "Native taskbar auto-hide already $(& $onOff $plan.AutoHideNow)"
    }

    try {
        if (-not $plan.FromCopy) {
            # No copy: exactly what uninstall always did.
            $n = Set-WindowsHardening -Revert
            Step-Ok "Windows hardening reverted ($n setting(s) removed, handed back to Windows' own defaults -- no saved copy of how they were before)"
            if ($n -gt 0) { $needExplorerRestart = $true }
        } elseif (-not $plan.Values.Count) {
            Step-Ok 'Windows hardening: nothing to put back -- already as it was before'
        } else {
            $put = 0
            foreach ($v in $plan.Values) {
                try {
                    if ($v.Existed) {
                        if (-not (Test-Path -Path $v.Path)) { $null = New-Item -Path $v.Path -Force }
                        $type = if ($v.Type) { "$($v.Type)" } else { 'DWord' }
                        $value = switch ($type) {
                            'DWord'       { [int]$v.Value }
                            'QWord'       { [long]$v.Value }
                            'Binary'      { [byte[]]@($v.Value) }
                            'MultiString' { [string[]]@($v.Value) }
                            default       { "$($v.Value)" }
                        }
                        Set-ItemProperty -Path $v.Path -Name $v.Name -Value $value -Type $type -ErrorAction Stop
                    } else {
                        Remove-ItemProperty -Path $v.Path -Name $v.Name -ErrorAction Stop
                    }
                    $put++
                } catch {
                    # The Widgets button: Windows refuses script writes to TaskbarDa on current
                    # builds (see Set-WindowsHardening), so say where to set it instead.
                    if ($v.Name -eq 'TaskbarDa' -and ($_.Exception -is [System.UnauthorizedAccessException] -or $_.Exception.Message -match 'unauthorized operation')) {
                        Step-Info "Windows won't let a script change the Widgets button -- set it in Settings > Personalization > Taskbar."
                    } else {
                        Step-Warn "$($v.Name): $($_.Exception.Message)"
                    }
                }
            }
            Step-Ok "Windows hardening: $put setting(s) put back as they were before this machine went full-time (saved $($plan.When))"
            if ($put -gt 0) { $needExplorerRestart = $true }
        }
    } catch { Step-Warn "Could not put back the Windows hardening: $($_.Exception.Message)" }

    if ($needExplorerRestart) {
        if (Restart-Explorer) { Step-Ok 'Explorer restarted once to apply the taskbar/hardening changes' }
        else { Step-Warn "Explorer didn't come back after its restart -- sign out and back in (Ctrl+Alt+Del) to get the desktop back." }
    }
    Restore-TrayIconPromotions -BackupFile $trayIconBackup

    try {
        if (-not $plan.DelayChange) {
            Step-Ok 'Startup app-launch delay: nothing to put back'
        } elseif ($plan.Delay['Existed']) {
            Set-RegValueFromSnapshot -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' -Name 'StartupDelayInMSec' -Snapshot $plan.Delay
            Step-Ok "Startup app-launch delay put back as it was ($($plan.Delay['Value']) ms)"
        } else {
            Remove-StartupDelay
            Step-Ok 'Startup app-launch delay setting removed (Explorer falls back to its own ~10s default)'
        }
    } catch { Step-Warn "Could not put back the Startup app-launch delay: $($_.Exception.Message)" }
}

# --- Autostart: Scheduled Tasks At-LogOn (-Activate-gated) ---------------------------

function Get-AutostartComponents {
    <# The parts of the stack that start through a Scheduled Task of their own: komorebi and
       710.ahk (AHK). net-icon is deliberately not ported -- see this file's header comment.
       Returns only the components whose executable is actually present.
       Each item: Key, TaskName, LnkName, Exe, Arguments, Delay (ISO-8601 duration, for the
       LogonTrigger's Delay), Spec (the launch-<key>.txt path) and SpecLines (what goes in it):
       both are powershell-hosted, so both go through ConvertTo-HiddenLaunch -- see that function
       for why. Process is always $null (their launchers check for themselves; kept for callers
       that ask).
       -NoWrite: the same answer without writing any launch-<key>.txt -- for `710sRice doctor`
       (read-only) and Get-AutostartStatus, which only need the names.
       The bar, Flow Launcher and ShareX had tasks of their own until 2026-10-06; 710.ahk starts
       them now (Get-AhkStartedApps below says why), and their old tasks are retired
       (Remove-RetiredStartTasks). No other app gets one: a task's job is what broke them. #>
    param([switch]$NoWrite)
    $items = [System.Collections.Generic.List[object]]::new()
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # komorebi.exe direct (not `komorebic start`, which is flaky on some machines --
    # os error 1920, retries in a loop and can hang on launch). Start-Komorebi.ps1 waits
    # for a real foreground window and retries with a time budget; see that script.
    $komorebiExe = Get-KomorebiExe
    if ($komorebiExe) {
        $launcher = Join-Path $Root 'scripts\Start-Komorebi.ps1'
        $hidden = ConvertTo-HiddenLaunch -NoWrite:$NoWrite -Key 'komorebi' -Exe $ps -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
        $items.Add([pscustomobject]@{
            Key = 'komorebi'; TaskName = 'komorebi'; LnkName = '710.DesktopRice komorebi.lnk'
            Exe = $hidden.Exe
            Arguments = $hidden.Arguments
            Delay = 'PT0S'
            Spec = $hidden.Spec; SpecLines = $hidden.SpecLines; Process = $null
        })
    }

    # AHK dispatcher via its own resilient launcher. 710.ahk starts the bar, Flow and ShareX as
    # it loads (config\ahk\710.ahk, "The apps 710.ahk starts").
    $ahkExe = Get-AhkExe
    if ($ahkExe) {
        $launcher = Join-Path $Root 'scripts\Start-Ahk.ps1'
        $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
        $hidden = ConvertTo-HiddenLaunch -NoWrite:$NoWrite -Key 'ahk' -Exe $ps -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" -AhkExe `"$ahkExe`" -ScriptPath `"$ahkScript`""
        $items.Add([pscustomobject]@{
            Key = 'ahk'; TaskName = 'ahk'; LnkName = '710.DesktopRice hotkeys.lnk'
            Exe = $hidden.Exe
            Arguments = $hidden.Arguments
            Delay = 'PT0S'
            Spec = $hidden.Spec; SpecLines = $hidden.SpecLines; Process = $null
        })
    }

    $items
}

function Get-AhkStartedApps {
    <# The apps only 710.ahk starts (config\ahk\710.ahk, "The apps 710.ahk starts"): the bar, Flow
       Launcher and ShareX -- at its own start, and whenever one has to come back. Never a Scheduled
       Task (2026-10-06): whatever a task starts runs inside a job that refuses a child's request to
       start apart from it, and everything it starts inherits that job -- Mod Organizer 2 opened
       from the bar's taskbar drawer, from Flow or by a ShareX action couldn't start LOOT, xEdit or
       the game (Error 5). Proven on both machines; what 710.ahk starts is clean. Each: Key, Name,
       Process (the process name that means "running"), Bit (its share of the '710sRice.StartApps'
       message's wParam), Installed. #>
    $flowExe = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'FlowLauncher\Flow.Launcher.exe' }
    @(
        [pscustomobject]@{ Key = 'yasb';   Name = 'YASB';          Process = 'yasb';          Bit = 1; Installed = [bool](Get-YasbcExe) }
        [pscustomobject]@{ Key = 'flow';   Name = 'Flow Launcher'; Process = 'Flow.Launcher'; Bit = 2; Installed = [bool]($flowExe -and (Test-Path -LiteralPath $flowExe)) }
        [pscustomobject]@{ Key = 'sharex'; Name = 'ShareX';        Process = 'ShareX';        Bit = 4; Installed = [bool](Get-ShareXExe) }
    )
}

function Start-AhkFromTask {
    <# Starts 710.ahk through its own task (schtasks /Run: at the task's level, whatever shell
       this is) unless it's running, then waits up to -WaitSeconds for its window -- Start-Ahk.ps1
       waits for the desktop first, so it can take a while at sign-in. 'running' (it already
       was), 'started', 'late' (the task ran, no window yet when the wait ended) or 'none' (no
       task, or it wouldn't run). As it loads, 710.ahk starts the bar, Flow and ShareX. #>
    param([int]$WaitSeconds = 30)
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    $find = { try { Find-AhkWindow -ScriptPath $ahkScript } catch { [IntPtr]::Zero } }
    if ((& $find) -ne [IntPtr]::Zero) { return 'running' }
    if (-not (Test-Task -TaskName 'ahk')) { return 'none' }
    $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName 'ahk') 2>&1
    if ($LASTEXITCODE -ne 0) { return 'none' }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((& $find) -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if ((& $find) -ne [IntPtr]::Zero) { 'started' } else { 'late' }
}

function Restart-AhkFromTask {
    <# Restarts a running 710.ahk through its own task: what `710sRice restart` does to 710.ahk,
       for 710.ahk alone. Asked to quit ('710sRice.Quit', which every 710.ahk since 2026-09-25
       knows), then ended if its window is still there after 2 s -- an older one, or one that's
       stuck; only from an admin window, and only a process whose command line names this
       710.ahk (Stop-RunningComponents' rule: never another AutoHotkey script) -- and waited for
       until its process is gone. Then Start-AhkFromTask: Start-Ahk.ps1, as at sign-in. Used by
       Request-RetiredAppsRestart, for a 710.ahk too old to hear its ask (it reads that file as it
       starts). Does nothing without the ahk task (it could be stopped but not started again) or
       when 710.ahk isn't running. Returns 'started' / 'late' (Start-AhkFromTask's), 'none' (it was
       stopped and its task didn't start it again: 710.ahk is down), 'stuck' (it wouldn't stop),
       'notask' or 'notrunning'. #>
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    $find = { try { Find-AhkWindow -ScriptPath $ahkScript } catch { [IntPtr]::Zero } }
    if ((& $find) -eq [IntPtr]::Zero) { return 'notrunning' }
    if (-not (Test-Task -TaskName 'ahk')) { return 'notask' }
    $ahkPid = try { Get-AhkWindowProcessId -ScriptPath $ahkScript } catch { $null }
    try { [void](Send-AhkQuit -ScriptPath $ahkScript) } catch { }
    $deadline = (Get-Date).AddSeconds(2)
    while ((& $find) -ne [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ((& $find) -ne [IntPtr]::Zero) {
        try {
            Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe' OR Name = 'AutoHotkey64_UIA.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ahkScript) } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch { }
        $deadline = (Get-Date).AddSeconds(2)
        while ((& $find) -ne [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    }
    if ((& $find) -ne [IntPtr]::Zero) { return 'stuck' }
    if ($ahkPid) {
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Process -Id $ahkPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    }
    Start-AhkFromTask
}

function Start-AhkStartedApps {
    <# Has 710.ahk start the ones of -Keys (Get-AhkStartedApps: yasb, flow, sharex) that are
       installed and not running -- the '710sRice.StartApps' message -- then waits up to
       -WaitSeconds for them. 710.ahk not running: it's started first, through its own task
       (Start-AhkFromTask) -- it starts all three as it loads -- unless -NoAhkStart, or it has no
       task (then nothing starts: NoAhk). Used wherever one of them must come (back) up: Start-All
       and `activate` (with -NoAhkStart: they start 710.ahk themselves), `reload bar`, repair,
       update, install's Flow and ShareX steps, a theme change. Returns {Up; Missing; AhkStarted;
       NoAhk} -- Up and Missing are Get-AhkStartedApps items (Missing: not running when the wait
       ended). Never throws for a start that didn't happen. #>
    param([string[]]$Keys = @('yasb', 'flow', 'sharex'), [int]$WaitSeconds = 30, [switch]$NoAhkStart)
    $apps = @(Get-AhkStartedApps | Where-Object { $Keys -contains $_.Key -and $_.Installed })
    $todo = @($apps | Where-Object { -not (Get-Process -Name $_.Process -ErrorAction SilentlyContinue) })
    $result = [pscustomobject]@{ Up = @($apps | Where-Object { $todo -notcontains $_ }); Missing = @(); AhkStarted = $false; NoAhk = $false }
    if (-not $todo.Count) { return $result }
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    $find = { try { Find-AhkWindow -ScriptPath $ahkScript } catch { [IntPtr]::Zero } }
    $hwnd = & $find
    if ($hwnd -eq [IntPtr]::Zero) {
        if ($NoAhkStart -or (Start-AhkFromTask) -eq 'none') { $result.NoAhk = $true; $result.Missing = $todo; return $result }
        $result.AhkStarted = $true
        # It starts all three as it loads; the message below covers one it found running then
        # that has gone since. 'late': no window to post to -- it starts them when it's up.
        $hwnd = & $find
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        $bits = 0
        foreach ($a in $todo) { $bits = $bits -bor $a.Bit }
        [void](Send-AhkMessage -ScriptPath $ahkScript -Name '710sRice.StartApps' -WParam $bits)
    }
    $missing = $todo
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ($missing.Count -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $missing = @($missing | Where-Object { -not (Get-Process -Name $_.Process -ErrorAction SilentlyContinue) })
    }
    $result.Up = @($result.Up) + @($todo | Where-Object { $missing -notcontains $_ })
    $result.Missing = @($missing)
    $result
}

function Get-RetiredStartTasks {
    <# The tasks that started the bar, Flow and ShareX until 2026-10-06 (710.ahk starts them now),
       with the Startup-folder shortcut each one fell back to when its task couldn't be made. #>
    @(
        [pscustomobject]@{ TaskName = 'yasb';   Name = 'the bar';       LnkName = '710.DesktopRice YASB.lnk' }
        [pscustomobject]@{ TaskName = 'flow';   Name = 'Flow Launcher'; LnkName = '710.DesktopRice Flow Launcher.lnk' }
        [pscustomobject]@{ TaskName = 'sharex'; Name = 'ShareX';        LnkName = '710.DesktopRice ShareX.lnk' }
    )
}

function Remove-RetiredStartTasks {
    <# Retires the bar's, Flow's and ShareX's old tasks (Get-RetiredStartTasks), their Startup
       shortcuts and the bar's launch-yasb.txt, wherever they're still here. Called by install's
       tasks step (Register-Autostart / Register-OnDemandTasks: -Activate, a plain re-run,
       `710sRice install -Only tasks` -- repair's fix, and so update's -- activate and deactivate)
       and by uninstall (Unregister-Autostart). A no-op on a machine without them; says what it
       removed, then has 710.ahk restart what those tasks may have started
       (Request-RetiredAppsRestart). -Uninstall: no lines (uninstall prints its own) and nothing
       restarted (it has stopped everything). Returns what it removed. #>
    param([switch]$Uninstall)
    $removed = [System.Collections.Generic.List[string]]::new()
    $tasksGone = [System.Collections.Generic.List[string]]::new()
    $startup = [Environment]::GetFolderPath('Startup')
    foreach ($r in Get-RetiredStartTasks) {
        if (Test-Task -TaskName $r.TaskName) {
            $null = & schtasks.exe /Delete /TN (Get-TaskFullName -TaskName $r.TaskName) /F 2>&1
            if (Test-Task -TaskName $r.TaskName) {
                if (-not $Uninstall) { Step-Warn "Couldn't remove the old task that started $($r.Name) ($(Get-TaskFullName -TaskName $r.TaskName)) -- run 710sRice install -Only tasks from an admin window." }
            } else {
                $tasksGone.Add($r.TaskName)
                if ($removed -notcontains $r.Name) { $removed.Add($r.Name) }
            }
        }
        if ($startup) {
            $lnk = Join-Path $startup $r.LnkName
            if (Test-Path -LiteralPath $lnk) {
                Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $lnk) -and $removed -notcontains $r.Name) { $removed.Add($r.Name) }
            }
        }
    }
    if ($env:LOCALAPPDATA) { Remove-Item (Join-Path $env:LOCALAPPDATA '710.DesktopRice\launch-yasb.txt') -Force -ErrorAction SilentlyContinue }
    if ($Uninstall) {
        if ($env:LOCALAPPDATA) { Remove-Item -LiteralPath (Get-RetiredRestartPath) -Force -ErrorAction SilentlyContinue }
        return $removed
    }
    if ($removed.Count) {
        Step-Info "Removed the old start-up task$(if ($removed.Count -gt 1) { 's' }) of $(Join-RiceNameList $removed) -- 710.ahk starts $(if ($removed.Count -gt 1) { 'them' } else { 'it' }) now."
    }
    # (A Startup shortcut's start came from Explorer, not a task: nothing to restart for those.)
    if ($tasksGone.Count) { Request-RetiredAppsRestart -Keys $tasksGone }
    $removed
}

function Get-RetiredRestartPath { Join-Path $env:LOCALAPPDATA '710.DesktopRice\restart-after-retire.txt' }

function Request-RetiredAppsRestart {
    <# The apps whose old task Remove-RetiredStartTasks just removed (-Keys: Get-AhkStartedApps
       keys), when they're running: each may be the copy its task started -- still inside the
       task's job, so what you open from it still can't start programs of its own -- and it stays
       that way until it restarts. They're added to restart-after-retire.txt (the StartApps bits,
       with any already there), which 710.ahk reads once -- stopping each one still running and
       starting it again itself (its RestartRetired) -- as it loads, and when asked
       ('710sRice.RestartRetired', posted here). Waits 5 s for the ask to be taken (the file gone).
       Still there with 710.ahk running: it's one from before this version (every existing
       install's first update to it -- it has no ear for the ask), so it's restarted through its
       task (Restart-AhkFromTask) and the new one takes the file as it starts; up to 30 s more.
       Then up to 30 s for each one to run again as a new process, and says how it went. No
       710.ahk running: nothing is started here, and the file waits for its next start
       (`710sRice restart`). #>
    param([string[]]$Keys)
    # Named as the retired tasks name them ('the bar', not 'YASB').
    $label = @{}
    foreach ($r in Get-RetiredStartTasks) { $label[$r.TaskName] = $r.Name }
    $apps = @(Get-AhkStartedApps | Where-Object { $Keys -contains $_.Key } |
              ForEach-Object { $_ | Select-Object *, @{ n = 'Label'; e = { $label[$_.Key] } } })
    $running = @($apps | Where-Object { Get-Process -Name $_.Process -ErrorAction SilentlyContinue })
    if (-not $running.Count) { return }
    $oldIds = @{}
    foreach ($a in $running) { $oldIds[$a.Key] = @(Get-Process -Name $a.Process -ErrorAction SilentlyContinue | ForEach-Object Id) }
    $bits = 0
    foreach ($a in $running) { $bits = $bits -bor $a.Bit }
    $file = Get-RetiredRestartPath
    try { $bits = $bits -bor ([int]"$(Get-Content -LiteralPath $file -Raw -ErrorAction Stop)".Trim()) } catch { }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        Set-Content -LiteralPath $file -Value $bits -Encoding ascii -ErrorAction Stop
    } catch {
        Step-Warn "Couldn't ask 710.ahk to restart $(Join-RiceNameList @($running | ForEach-Object Label)) ($($_.Exception.Message)) -- sign out and back in before opening Mod Organizer 2 from $(if ($running.Count -gt 1) { 'them' } else { 'it' })."
        return
    }
    $names = Join-RiceNameList @($running | ForEach-Object Label)
    $first = $names.Substring(0, 1).ToUpper() + $names.Substring(1)   # the same, starting a sentence
    $many = $running.Count -gt 1
    $them = if ($many) { 'them' } else { 'it' }
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    try { [void](Send-AhkMessage -ScriptPath $ahkScript -Name '710sRice.RestartRetired') } catch { }
    $deadline = (Get-Date).AddSeconds(5)
    while ((Test-Path -LiteralPath $file) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    $running710 = { try { (Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero } catch { $false } }
    if ((Test-Path -LiteralPath $file) -and (& $running710) -and (Test-Task -TaskName 'ahk')) {
        # Not taken, with 710.ahk running: one from before this version can't hear the ask -- every
        # existing install's first update to it. It reads the file as it starts, so it's restarted
        # through its task (Restart-AhkFromTask). (One running as admin, or stuck, comes back as a
        # normal one that takes it.) A 710.ahk that isn't running is left so -- an on-demand machine
        # with its stack stopped -- and the file waits for its next start.
        Step-Info "710.ahk didn't answer (a copy from before this version can't hear it) -- restarting it through its task; the new one restarts $them as it starts..."
        $how = "$(Restart-AhkFromTask)"
        if ($how -eq 'stuck') { Step-Warn "710.ahk wouldn't stop (only an admin window can end it) -- left running as it was." }
        elseif ($how -in 'started', 'late') {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Test-Path -LiteralPath $file) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
        }
        if ((Test-Path -LiteralPath $file) -and $how -ne 'stuck' -and -not (& $running710)) {
            Step-Warn "710.ahk was stopped for this, but it isn't back -- 710sRice start brings it back, and it restarts $them as it starts (ahk-autostart.log says what happened)."
            return
        }
    }
    if (Test-Path -LiteralPath $file) {
        Step-Info "$first may still be the cop$(if ($many) { 'ies their old tasks' } else { 'y its old task' }) started -- 710.ahk restarts $them the next time it starts (710sRice restart does that now). Until then, what you open from $them can't start programs of its own."
        return
    }
    $isBack = { param($a) [bool]@(Get-Process -Name $a.Process -ErrorAction SilentlyContinue | Where-Object { $oldIds[$a.Key] -notcontains $_.Id }).Count }
    $deadline = (Get-Date).AddSeconds(30)
    while (@($running | Where-Object { -not (& $isBack $_) }).Count -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    $back    = @($running | Where-Object { & $isBack $_ })
    $notBack = @($running | Where-Object { $back -notcontains $_ })
    if ($back.Count) {
        Step-Ok "Restarted $(Join-RiceNameList @($back | ForEach-Object Label)) through 710.ahk, in case $(if ($back.Count -gt 1) { 'their old tasks had started them' } else { 'its old task had started it' })"
        if ($back.Key -contains 'yasb') { Step-Info 'Chrome, the Claude app and other Chromium apps can pick up an extra title bar when the bar restarts -- focus the app and press SUPER+Ctrl+C to redraw it.' }
    }
    if ($notBack.Count) {
        $nb = Join-RiceNameList @($notBack | ForEach-Object Label)
        Step-Warn "$($nb.Substring(0, 1).ToUpper() + $nb.Substring(1)) didn't come back as a new copy within 30 s -- ahk-autostart.log says why; 710sRice restart (or sign out and in) finishes it."
    }
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

function Register-Autostart {
    <# Registers every present component as an At-LogOn Scheduled Task, delay 0 (or per-
       component), unelevated, interactive-session-only. Deletes legacy .lnk files first
       (migration), and the bar's, Flow's and ShareX's old tasks (Remove-RetiredStartTasks).
       Idempotent. Falls back to a Startup .lnk for any component whose task registration fails.
       -Key: just that one component, and no whole-install cleanup (Startup shortcuts, old
       tasks) -- `710sRice tiling` re-registers komorebi alone. #>
    param([string]$Key)
    if (-not $Key) { Remove-StartupShortcuts; [void](Remove-RetiredStartTasks) }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $components = @(Get-AutostartComponents | Where-Object { -not $Key -or $_.Key -eq $Key })
    if ($components.Count -eq 0) {
        Step-Warn "Autostart: $(if ($Key) { "$Key isn't installed" } else { 'no components installed' })."
        return
    }
    $admin = Test-IsAdmin
    # Only what actually got its task goes in the closing [OK] line (Group 1 #23): a task that
    # couldn't be updated, or a component that fell back to a Startup shortcut, keeps its own
    # warning and isn't listed -- the same pattern as Register-OnDemandTasks.
    $registered = [System.Collections.Generic.List[string]]::new()
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
            $registered.Add($c.Key + $(if ($c.Key -eq 'komorebi') { " ($(if ($runLevel -eq 'HighestAvailable') { 'elevated' } else { 'non-elevated' }))" }))
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
    if ($registered.Count -gt 0) {
        Step-Ok "Autostart registered (Scheduled Tasks At-LogOn): $($registered -join ', ')"
    }
}

function Unregister-Autostart {
    foreach ($c in Get-AutostartComponents) {
        $full = Get-TaskFullName -TaskName $c.TaskName
        & schtasks.exe /Delete /TN $full /F *> $null
    }
    # The bar's, Flow's and ShareX's tasks from before 2026-10-06, wherever they're still here
    # -- even when the app itself is already gone.
    [void](Remove-RetiredStartTasks -Uninstall)
    Remove-StartupShortcuts
}

function Get-AutostartStatus {
    <# Key -> bool (task registered or fallback .lnk present), per component. Reads only:
       the names are all it needs, so no launch-<key>.txt is rewritten on the way. #>
    $startup = [Environment]::GetFolderPath('Startup')
    $status = @{}
    foreach ($c in Get-AutostartComponents -NoWrite) {
        $hasTask = Test-Task -TaskName $c.TaskName -AtLogOn
        $hasLnk = Test-Path (Join-Path $startup $c.LnkName)
        $status[$c.Key] = ($hasTask -or $hasLnk)
    }
    $status
}

function Test-FullTimeMachine {
    # install's long-standing rule for "this machine was -Activate'd": any component with a
    # sign-in task (or its Startup-shortcut fallback). install's tasks step keeps such a machine
    # full-time and -Only windows only acts on one; `710sRice doctor` reads its mode line from
    # the same rule. Moved here from install.ps1 (2026-09-27) so the two can't drift. Read-only.
    # (Until 2026-09-28 the lock-screen sync task counted too; it's retired -- every install sets
    # the lock screen now -- so a leftover one says nothing about the mode.)
    $autostart = Get-AutostartStatus
    @($autostart.Values | Where-Object { $_ }).Count -gt 0
}

function Write-RiceModeLines {
    <# The machine's mode and the command that switches it: the end of a full install run and of
       `710sRice activate` / `deactivate`, one wording for all three. Test-FullTimeMachine is the
       rule, as for doctor's mode line. #>
    $fullTime = try { [bool](Test-FullTimeMachine) } catch { $false }
    Write-Host ''
    if ($fullTime) {
        Write-Host 'Mode: full-time -- it starts at every sign-in.'
        Write-Host 'To switch to on demand: 710sRice deactivate'
    } else {
        Write-Host 'Mode: on demand -- 710sRice start starts it.'
        Write-Host 'To switch to full-time: 710sRice activate'
    }
}

function Register-OnDemandTasks {
    <# For an install WITHOUT -Activate: every component's task, with no trigger at all.
       Nothing starts at sign-in; Start-All.ps1 (`710sRice start`) and reload-stack.ps1
       (SUPER+Shift+R) fire them, so an on-demand stack starts and restarts exactly like an
       -Activate'd one -- each at its task's own run level, whatever shell fires it: komorebi
       at the tiling mode's (elevated by default, and no UAC prompt), 710.ahk LeastPrivilege
       (and it starts the bar, Flow and ShareX). That's also why `710sRice start` works from an
       admin window here: nothing has to be launched directly from it.
       Until 2026-09-26 only komorebi got one (plan doc Open item 37), so on these installs
       every YASB restart through its task -- SUPER+Shift+R's, the watchdog's -- killed the
       bar and left it down (cli-plan, commit 3a). Test-Task -AtLogOn ignores these tasks,
       so they never make the machine look -Activate'd, and uninstall's Unregister-Autostart
       deletes them like any other component task. The bar's, Flow's and ShareX's old tasks go
       (Remove-RetiredStartTasks): 710.ahk starts those three now. -Key: just that one component
       (the `tiling` command re-registers komorebi alone), no cleanup. Idempotent (/F). #>
    param([string]$Key)
    if (-not $Key) { [void](Remove-RetiredStartTasks) }
    $components = @(Get-AutostartComponents | Where-Object { -not $Key -or $_.Key -eq $Key })
    if ($components.Count -eq 0) {
        Step-Warn "On-demand tasks: $(if ($Key) { "$Key isn't installed" } else { 'no components installed' }) -- nothing registered."
        return
    }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $admin = Test-IsAdmin
    $registered = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $components) {
        $runLevel = if ($c.Key -eq 'komorebi') { Get-KomorebiRunLevel } else { 'LeastPrivilege' }
        if ($runLevel -eq 'HighestAvailable' -and -not $admin) {
            # Same rule as Register-Autostart: only an admin can register a task that runs
            # elevated. Only reachable by running install.ps1 directly from a normal window --
            # `710sRice install` always elevates first.
            if (Test-Task -TaskName $c.TaskName) {
                Step-Warn "On-demand task komorebi: elevated tiling needs an admin PowerShell to register -- its existing task was left as it is. Re-run .\install.ps1 from an admin shell."
                continue
            }
            Step-Warn "On-demand task komorebi: elevated tiling needs an admin PowerShell to register -- registering it non-elevated for now (admin windows won't tile). Re-run .\install.ps1 from an admin shell."
            $runLevel = 'LeastPrivilege'
        }
        $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) "710-task-$($c.TaskName)-ondemand.xml"
        try {
            Set-Content -Path $xmlPath -Value (New-TaskXml -Component $c -User $user -RunLevel $runLevel -NoTrigger) -Encoding Unicode
            $null = & schtasks.exe /Create /TN (Get-TaskFullName -TaskName $c.TaskName) /XML $xmlPath /F 2>&1
            if ($LASTEXITCODE -ne 0) { throw "schtasks /Create exited with code $LASTEXITCODE" }
            $registered.Add($c.Key + $(if ($c.Key -eq 'komorebi') { " ($(if ($runLevel -eq 'HighestAvailable') { 'elevated' } else { 'non-elevated' }))" }))
        } catch {
            # Same split as Register-Autostart: a task that exists but couldn't be UPDATED
            # (typically created from an elevated shell, this run isn't) still works as it is.
            if (Test-Task -TaskName $c.TaskName) {
                Step-Warn "On-demand task $($c.Key): couldn't update the existing task ($($_.Exception.Message)) -- keeping the old one."
            } else {
                Step-Warn "On-demand task $($c.Key): couldn't register it ($($_.Exception.Message)) -- ``710sRice start`` will launch it directly instead (from a normal window only)."
            }
        } finally {
            Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($registered.Count -gt 0) {
        Step-Ok "On-demand tasks registered (no sign-in trigger -- ``710sRice start`` fires them): $($registered -join ', ')"
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

# --- Lock screen: your own lock-screen picture -----------------------------------------
# Since 2026-09-28 the lock screen follows the wallpaper as YOUR lock-screen picture (Windows'
# per-user one), set on every wallpaper change by the pipeline -- scripts\Set-LockScreen.ps1
# through tools\lib\lockscreen.ps1, on every install, with no task and no admin. Before that
# (2026-09-22 .. 09-28) -Activate registered an elevated on-demand task that wrote a machine
# policy (HKLM PersonalizationCSP) pointing at the wallpaper file, and the screen before sign-in
# stayed black after a wallpaper change until the next Win+L (plan doc items 46 and 48). What's
# left of that here: retiring it on a machine that still has it.

function Restore-LockScreenPolicy {
    <# Puts the machine policy the old sync wrote (HKLM PersonalizationCSP) back the way it was,
       from the 'lockscreen-personalizationcsp' snapshot install took when it registered the old
       task. On the usual machine nothing was there before, so the whole key goes (and Settings'
       own lock-screen picker works again); otherwise its three values are restored. A key with
       no snapshot of ours is never touched (a company's policy, say), and a key that's already
       gone is fine. Needs admin (HKLM): warns and skips without it. $true when the snapshot was
       used. #>
    $snap = Get-OriginalState -Label 'lockscreen-personalizationcsp'
    if (-not $snap) { return $false }
    if (-not (Test-IsAdmin)) {
        Step-Warn "The old lock-screen policy key needs an admin window to remove -- run this again from one."
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
    $true
}

function Remove-RetiredLockScreenSync {
    <# Retires the old lock-screen sync on a machine that still has it: the elevated
       'lock-screen-sync' task, its launch file (launch-lock-screen-sync.txt), and the policy it
       wrote (Restore-LockScreenPolicy). Called by install's tasks step (so -Activate, a plain
       re-run and `710sRice install -Only tasks` -- repair's fix, and so update's) and by
       uninstall. A no-op on a machine that never had it. $true when it removed something:
       install then sets your picture once, since nothing else would before the next wallpaper
       change. #>
    $removed = $false
    if (Test-Task -TaskName 'lock-screen-sync') {
        $null = & schtasks.exe /Delete /TN (Get-TaskFullName -TaskName 'lock-screen-sync') /F 2>&1
        if (Test-Task -TaskName 'lock-screen-sync') {
            Step-Warn "Couldn't remove the retired lock-screen sync task -- run this again from an admin window."
        } else {
            Step-Info 'Removed the retired lock-screen sync task (the lock screen is your own picture now, set on every wallpaper change).'
            $removed = $true
        }
    }
    Remove-Item (Join-Path $env:LOCALAPPDATA '710.DesktopRice\launch-lock-screen-sync.txt') -Force -ErrorAction SilentlyContinue
    if (Restore-LockScreenPolicy) {
        Step-Info "Removed the old lock-screen policy key (put back the way it was before 710sRice) -- it hid your own picture."
        $removed = $true
    }
    $removed
}

function Set-LockScreenToWallpaper {
    <# Your lock-screen picture = the wallpaper that's up now, once, outside a wallpaper change:
       install's tasks step, right after retiring the old sync, or when nothing has set it yet.
       One line either way. #>
    $r = Invoke-LockScreenSetter -Root $Root -Image (Get-CurrentWallpaper)
    $text = ConvertTo-SafeText $r.Message
    switch ($r.ExitCode) {
        0       { Step-Ok "Lock screen $text" }
        2       { Step-Warn "Lock screen $text" }
        default { Step-Warn "Lock screen: $text -- it follows the next wallpaper change (SUPER+W)." }
    }
}

function Get-WindowsLockScreenDefault {
    # Windows' own default lock-screen picture, for when your original is gone: img100.jpg in
    # %WINDIR%\Web\Screen, or the first picture there. $null when there's none.
    $dir = Join-Path $env:WINDIR 'Web\Screen'
    $first = Join-Path $dir 'img100.jpg'
    if (Test-Path -LiteralPath $first -PathType Leaf) { return $first }
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.jpg', '.jpeg', '.png' } | Sort-Object Name |
        Select-Object -First 1 -ExpandProperty FullName
}

function Restore-LockScreenPicture {
    <# Uninstall: your lock screen as it was before 710sRice first set it, from the
       'lockscreen-picture' snapshot scripts\Set-LockScreen.ps1 takes before its first set. The
       picture first -- the original file (Windows reports the original, not a copy), or Windows'
       own default picture when that file is gone -- THEN the Spotlight / Slideshow settings, so it
       doesn't matter whether setting a picture switched them off. If -Activate had already
       switched Spotlight off when the snapshot was taken (Hardened), those two values were its,
       not the original: full time's own way back (Restore-FullTimeWindowsSettings) puts them
       back, so they're left alone here. Run after that. Last, Windows' own copy of the choice
       for the screens before sign-in, from the 'lockscreen-signin' snapshot the setter takes
       before it first changes that copy (no snapshot = it never did: left alone). -> 'restored',
       'default' (the original was gone), 'failed', or $null (nothing ever set here -- nothing to
       do). #>
    $snap = Get-OriginalState -Label 'lockscreen-picture'
    if (-not $snap) { return $null }
    $img = "$($snap.Image)"
    $result = 'restored'
    if (-not $img -or -not (Test-Path -LiteralPath $img -PathType Leaf)) { $img = Get-WindowsLockScreenDefault; $result = 'default' }
    if ($img) {
        # -KeepMode: Windows' Picture / Spotlight / Slideshow choice comes back from the snapshot
        # just below, not from the setter (which otherwise chooses Picture).
        $r = Invoke-LockScreenSetter -Root $Root -Image $img -KeepMode
        if ($r.ExitCode -notin 0, 2) { Step-Warn "Lock-screen picture not put back: $(ConvertTo-SafeText $r.Message)"; $result = 'failed' }
    } else { $result = 'failed' }
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    if (-not $snap.Hardened) {
        foreach ($name in 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled') {
            if ($snap[$name]) { Set-RegValueFromSnapshot -Path $cdm -Name $name -Snapshot $snap[$name] }
        }
    }
    if ($snap.SlideshowEnabled) {
        Set-RegValueFromSnapshot -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen' -Name 'SlideshowEnabled' -Snapshot $snap.SlideshowEnabled
    }
    $signIn = Get-OriginalState -Label 'lockscreen-signin'
    if ($signIn) {
        $signInKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Creative\' +
            [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($name in 'RotatingLockScreenEnabled', 'LockImageFlags') {
            if ($signIn[$name]) { Set-RegValueFromSnapshot -Path $signInKey -Name $name -Snapshot $signIn[$name] }
        }
        Remove-OriginalState -Label 'lockscreen-signin'
    }
    Remove-OriginalState -Label 'lockscreen-picture'
    Remove-Item -LiteralPath (Get-LockScreenRecordPath) -Force -ErrorAction SilentlyContinue
    $result
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

    # komorebi: try its own graceful `stop` first (releases window-management hooks,
    # restores window styles/borders) before a hard kill, so a stray leftover style isn't
    # left on a window after uninstall.
    # komorebic next to komorebi.exe first (Get-KomorebicExe): from a window whose PATH predates
    # the install, a PATH lookup found nothing, the graceful stop never ran, and windows komorebi
    # had cloaked on other workspaces stayed invisible after the kill (Group 1 W6).
    if (Get-Process komorebi -ErrorAction SilentlyContinue) {
        $komorebic = Get-KomorebicExe
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
        $yasbc = Get-YasbcExe
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

function Get-RunningStackNames {
    # The stack components running right now, named as Stop-RunningComponents stops them:
    # komorebi, YASB, 710.ahk (by its window, so another AHK script doesn't count), ShareX. Flow
    # Launcher and Everything aren't the stack's to stop. Read-only.
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    @(
        if (Get-Process komorebi -ErrorAction SilentlyContinue) { 'komorebi' }
        if (Get-Process yasb -ErrorAction SilentlyContinue) { 'YASB' }
        if ((Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero) { '710.ahk' }
        if (Get-Process ShareX -ErrorAction SilentlyContinue) { 'ShareX' }
    )
}

function Start-StackFromTasks {
    <# Starts every component now, through its own autostart task (schtasks /Run), never
       launched directly from this shell: install -Activate's "start now" and `710sRice activate`
       (moved here from install.ps1, 2026-10-03). Both need an elevated shell, and anything
       started from one runs elevated: an elevated AHK makes every Terminal it opens elevated,
       and non-elevated komorebi can't tile elevated windows (the 2026-09-23 admin-AHK incident).
       The tasks run at their own registered level whatever shell fires them -- LeastPrivilege,
       except komorebi's in elevated tiling mode -- the same path logon and SUPER+Shift+R use, so
       "start now" and "start at next sign-in" stay one code path. A component whose task couldn't
       be registered (Register-Autostart fell back to a Startup shortcut) is started from that
       shortcut only when this shell is NOT elevated; elevated, it says so and waits for the next
       sign-in. The bar, Flow and ShareX: 710.ahk starts them as it loads -- and when it was
       already running, it's asked to (Start-AhkStartedApps), so one of them that's down comes up
       too. #>
    Step-Info 'Starting services...'
    $elevated = Test-IsAdmin
    $startupDir = [Environment]::GetFolderPath('Startup')
    $ahkWasUp = try { (Find-AhkWindow -ScriptPath (Join-Path $Root 'config\ahk\710.ahk')) -ne [IntPtr]::Zero } catch { $false }
    foreach ($c in @(Get-AutostartComponents)) {
        if (Test-Task -TaskName $c.TaskName) {
            $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName $c.TaskName) 2>&1
            if ($LASTEXITCODE -eq 0) { Step-Ok "$($c.Key): started via its autostart task" }
            else { Step-Warn "$($c.Key): schtasks /Run failed (exit $LASTEXITCODE) -- it will start at the next sign-in." }
            continue
        }
        $lnk = Join-Path $startupDir $c.LnkName
        if ((Test-Path $lnk) -and -not $elevated) {
            Start-Process $lnk
            Step-Ok "$($c.Key): started via its Startup shortcut (no task)"
        } elseif (Test-Path $lnk) {
            Step-Warn "$($c.Key): only a Startup shortcut, no task -- not starting it from this elevated shell (it would run elevated); it starts at the next sign-in."
        } else {
            Step-Warn "$($c.Key): no autostart task or Startup shortcut -- not started."
        }
    }
    if ($ahkWasUp) {
        $apps = Start-AhkStartedApps -NoAhkStart -WaitSeconds 0
        $down = @($apps.Missing | ForEach-Object Name)
        if ($down.Count -and $apps.NoAhk) { Step-Warn "710.ahk stopped just now -- $($down -join ', ') not started; run 710sRice start." }
        elseif ($down.Count) { Step-Ok "Asked 710.ahk to start $($down -join ', ')" }
    }
    Step-Ok 'Services starting in the background (see %LOCALAPPDATA%\710.DesktopRice\*-autostart.log if one seems to not have come up).'
}

# --- Shell profile hook ($PROFILE -> config\pwsh\profile.ps1) ------------------------
# Ported from winarchy's ShellProfile.ps1 @ 4574fc7: a marker-delimited block inserted (or
# updated) in pwsh's CurrentUserAllHosts $PROFILE, idempotent, snapshotting the profile
# before any change (Copy-Item .bak, this repo's own established pattern -- see
# tools/components/flow.ps1 -- rather than winarchy's own New-WinarchySnapshot module).
$script:ProfileMarkerStart = '# >>> managed by 710.DesktopRice >>>'
$script:ProfileMarkerEnd = '# <<< managed by 710.DesktopRice <<<'

function Get-ShellProfilePath {
    # Computed by hand (not $PROFILE) so this works even when the calling session isn't
    # pwsh with $PROFILE populated.
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\profile.ps1'
}

function Get-ShellProfileBlock {
    # The exact block install writes into $PROFILE for this clone -- one definition, read by
    # Install-ShellProfile and by `710sRice doctor` (Get-ShellProfileHookState). The path goes
    # in single quotes, so a ' in it is doubled: a clone under a folder with an apostrophe broke
    # every new PS7 window (winarchy 731a0a1, Group 1 W5). Every other path's block is
    # byte-identical to before; an old unescaped one reads as "points somewhere else" to doctor,
    # whose fix (-Only profile) rewrites it.
    $managed = Join-Path $Root 'config\pwsh\profile.ps1'
    @(
        $script:ProfileMarkerStart
        ". '$($managed.Replace("'", "''"))'"
        $script:ProfileMarkerEnd
    ) -join "`r`n"
}

function Get-ShellProfileHookState {
    <# Read-only, for doctor: 'installed' ($PROFILE holds this clone's block exactly as
       Install-ShellProfile writes it), 'other' (a 710.DesktopRice block pointing somewhere
       else -- a moved clone, say), or 'missing' (no block, or no profile file at all). #>
    $profilePath = Get-ShellProfilePath
    if (-not (Test-Path -LiteralPath $profilePath)) { return 'missing' }
    $existing = Get-Content -LiteralPath $profilePath -Raw
    $pattern = '(?s)' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd)
    if ("$existing" -notmatch $pattern) { return 'missing' }
    if (($Matches[0] -replace '\r?\n', "`r`n") -eq (Get-ShellProfileBlock)) { 'installed' } else { 'other' }
}

function Install-ShellProfile {
    $profilePath = Get-ShellProfilePath
    $block = Get-ShellProfileBlock

    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
    $pattern = '(?s)' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd)

    if ($existing -match $pattern) {
        if (($Matches[0] -replace '\r?\n', "`r`n") -eq $block) {
            Step-Ok "Profile hook already installed: $(ConvertTo-SafePath $profilePath)"
            return
        }
        Copy-Item $profilePath "$profilePath.bak" -Force
        $updated = [regex]::Replace($existing, $pattern, $block.Replace('$', '$$'))
        Set-Content -Path $profilePath -Value $updated -Encoding utf8NoBOM
        Step-Ok "Profile hook updated: $(ConvertTo-SafePath $profilePath) (previous saved to $(ConvertTo-SafePath "$profilePath.bak"))"
        return
    }

    if (Test-Path $profilePath) { Copy-Item $profilePath "$profilePath.bak" -Force }
    else { New-Item -ItemType Directory -Path (Split-Path $profilePath) -Force | Out-Null }
    $newContent = if ($existing.Trim()) { $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n" } else { $block + "`r`n" }
    Set-Content -Path $profilePath -Value $newContent -Encoding utf8NoBOM
    Step-Ok "Profile hook installed: $(ConvertTo-SafePath $profilePath)"
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
    Step-Ok "Profile hook removed: $(ConvertTo-SafePath $profilePath) (previous saved to $(ConvertTo-SafePath "$profilePath.bak"))"
}

# --- Restoring theming side effects (wallpaper/accent/Flow) -- uninstall-only ------------
# The wallpaper/lock-screen restore functions live next to what they revert
# (Restore-OriginalWallpaper in tools\lib\wallpaper.ps1, Restore-LockScreenPicture in the lock
# screen's own section above). These two cover the rest of what install.ps1 Section 4
# and tools\apply-wallust-outputs.ps1 change on a real wallpaper/theme apply, plus Flow
# Launcher's theme -- both called from uninstall.ps1. (Windows Terminal's and Flow's own settings
# are their components': tools\components\terminal.ps1, flow.ps1.)
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

function Restore-FlowTheme {
    <# Undoes the palette pipeline's Flow target (tools\palette\targets\flow.ps1): Flow's selected
       theme goes back to what it was before (the 'flow-theme' snapshot) and our 710sRice.xaml is
       deleted. Only while Flow is still on ours -- a theme you picked yourself since stays. The
       old theme comes back only if its file still exists (Flow shows an error box at start for a
       theme it can't find -- winarchy's Winarchy.xaml, say, once that's gone); otherwise the key
       goes and Flow uses its own default. Flow is stopped first and NOT relaunched, as in
       the flow component's uninstall (tools\components\flow.ps1). $false when there was nothing
       to undo. #>
    $snap = Get-OriginalState -Label 'flow-theme'
    $flowRoot = Join-Path $env:APPDATA 'FlowLauncher'
    $xaml = Join-Path $flowRoot 'Themes\710sRice.xaml'
    if (-not $snap -and -not (Test-Path -LiteralPath $xaml)) { return $false }
    $flow = @(Get-Process -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)
    if ($flow.Count) {
        $flow | Stop-Process -Force
        $flow | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
    }
    $settingsPath = Join-Path $flowRoot 'Settings\Settings.json'
    if ($snap -and (Test-Path -LiteralPath $settingsPath)) {
        $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ("$($settings['Theme'])" -eq '710sRice') {
            $old = "$($snap.Theme)"
            $oldThere = $old -and (@(Join-Path $flowRoot "Themes\$old.xaml") + @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'FlowLauncher\app-*\Themes') -Filter "$old.xaml" -File -ErrorAction SilentlyContinue | ForEach-Object FullName) |
                        Where-Object { Test-Path -LiteralPath $_ }).Count
            if ($snap.ThemeExisted -and $oldThere) { $settings['Theme'] = $old } else { $settings.Remove('Theme') }
            $settings | ConvertTo-Json -Depth 50 | Set-Content -Path $settingsPath -Encoding UTF8
        }
    }
    Remove-Item -LiteralPath $xaml -Force -ErrorAction SilentlyContinue
    Remove-OriginalState -Label 'flow-theme'
    $true
}
