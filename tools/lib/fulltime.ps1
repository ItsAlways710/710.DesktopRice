<#
.SYNOPSIS
  Full time's Windows settings -- taskbar auto-hide, the hardening values (no Bing search, ad
  suggestions, Copilot / Widgets / Task View buttons, Start recommendations, tips and suggested
  content), no Startup delay: saved when a machine goes full-time, applied (install -Activate's
  windows step, `710sRice activate`), put back on the way back (`710sRice deactivate`, uninstall),
  and doctor's "Windows settings" line. Loaded by tools\lib\activation.ps1. Only functions.
#>

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
    # like Get-OriginalStateDir's (which created the folder until 2026-10-07): dry runs read this.
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

# --- install's parts: -Activate's save (before any step), the windows step ----------------------

function Save-FullTimeSettingsOnActivate {
    <# install -Activate, before any step, on a machine going full-time now (install asks only
       then: never on a machine that's already full-time -- the "before" would be full time's own
       values): your Windows settings as they are, saved before anything changes them --
       `710sRice deactivate` and uninstall put them back. $true: saved, or a copy already there
       (it's the real "before"), and the switch goes ahead. $false: no copy, so no switch -- the
       same rule as `710sRice activate` -- and install runs as a plain install, on demand, and
       fails at its end (Write-FullTimeNotSwitched). Until 2026-10-07 install warned and switched
       anyway, changing settings it had no copy of (review item 6). #>
    Write-Host "`n-- Save your Windows settings --" -ForegroundColor Cyan
    try {
        if (Save-FullTimeSettings) { Step-Ok 'Saved your Windows settings as they are now (taskbar auto-hide, the hardening values, the Startup delay) -- 710sRice deactivate and uninstall put them back' }
        else { Step-Info "Kept the copy of your Windows settings saved $(Get-SavedFullTimeSettingsWhen (Get-SavedFullTimeSettings)) -- it's how they were before" }
        $true
    } catch {
        Write-Host "  [XX] Couldn't save your Windows settings ($($_.Exception.Message)) -- so this run doesn't switch to full-time: it installs on demand, and nothing of full time's is changed" -ForegroundColor Red
        $false
    }
}

function Write-FullTimeNotSwitched {
    # The closing line of an install -Activate whose save failed (Save-FullTimeSettingsOnActivate).
    Write-Host ''
    Write-Host "  [XX] Not switched to full-time: your Windows settings couldn't be saved (see the top) -- 710sRice activate tries again" -ForegroundColor Red
}

function Install-FullTimeWindowsSettings {
    <# install's windows step: a plain run only gets here with -Activate. -Only windows gets here
       on any machine, and these settings only belong to a full-time one. -Activate switching
       this machine to full-time: the stack goes down before its Windows settings change -- the
       switch never changes them under a running stack -- and install's start-now block starts
       it again (the same rule as `710sRice activate`). $true when it stopped the stack. What the
       two calls print goes to the screen (Out-Host), never into that answer. #>
    param([bool]$OnlyRun, [bool]$Activate, [bool]$WasFullTime)
    $stopped = $false
    Write-Host "`n-- Windows settings --" -ForegroundColor Cyan
    if ($OnlyRun -and -not (Test-FullTimeMachine)) {
        Step-Info 'Nothing to do (on-demand machine) -- these settings are only for a full-time install (710sRice activate).'
    } else {
        # -Activate switching this machine to full-time: the stack goes down before its Windows
        # settings change -- the switch never changes them under a running stack -- and install's
        # start-now block starts it again (the same rule as `710sRice activate`).
        if ($Activate -and -not $WasFullTime) {
            $running = @(Get-RunningStackNames)
            if ($running.Count) {
                Step-Info "Stopping the stack first ($($running -join ', ')) -- it starts again at the end of this run."
                Stop-RunningComponents | Out-Host
                $stopped = $true
            }
        }
        # Auto-hide, the hardening, the Startup delay: one Explorer restart, the tray icons kept
        # (Set-FullTimeWindowsSettings, above).
        Set-FullTimeWindowsSettings | Out-Host
    }
    $stopped
}

# --- Doctor's check: the Windows settings line in Integrations -------------------------------
function Test-DoctorWindowsSettings {
    # What -Activate applies on a full-time machine: taskbar auto-hide, the hardening values
    # (Get-HardeningSettings), no Startup delay. Worth knowing when it drifts, but the fix
    # restarts Explorer and a change may be deliberate -- so [!!]. TaskbarDa (the Widgets
    # button) is left out: Windows refuses a script's write to it, so no fix could clear it
    # (install already points at Settings for that one).
    if (-not (Test-FullTimeMachine)) { return }
    $drift = @()
    try { if (-not (Test-TaskbarAutoHide)) { $drift += "taskbar doesn't auto-hide" } } catch { }
    $hard = @(foreach ($s in Get-HardeningSettings) {
        $path, $name, $value = $s
        if ($name -eq 'TaskbarDa') { continue }
        $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Ignore
        if ($null -eq $item -or $item.$name -ne $value) { $name }
    })
    if ($hard.Count) {
        $shown = @($hard | Select-Object -First 4) -join ', '
        $drift += "hardening: $shown$(if ($hard.Count -gt 4) { " and $($hard.Count - 4) more" })"
    }
    $delay = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' -Name StartupDelayInMSec -ErrorAction Ignore
    if ($null -eq $delay -or $delay.StartupDelayInMSec -ne 0) { $drift += 'the Startup delay is back' }
    if ($drift.Count) {
        return New-DoctorResult -Id 'windows' -Status 'XX' -Text "Windows settings drifted: $($drift -join '; ')" -Fix '710sRice install -Only windows' -Step 'windows'
    }
    New-DoctorResult -Id 'windows' -Status 'OK' -Text 'Windows settings (-Activate): taskbar auto-hides, hardening applied, no Startup delay'
}
