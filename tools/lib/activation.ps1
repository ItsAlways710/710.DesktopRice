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

function Set-WindowsHardening {
    <# Applies (or, with -Revert, undoes) every setting from Get-HardeningSettings.
       Backs up each touched registry key first (Backup-RegistryKey, label 'hardening').
       Restarts explorer.exe once at the end if anything actually changed -- most of these
       values are only read at Explorer startup. Returns the number of settings changed. #>
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
    if ($changed -gt 0) { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue }
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

function Get-AutostartComponents {
    <# Definition of the 5 autostart components this repo actually uses (komorebi, YASB,
       window-slots, ShareX, AHK). net-icon is deliberately not ported -- see this file's
       header comment. Returns only the components whose executable is actually present.
       Each item: Key, TaskName, LnkName, Exe, Arguments, Delay (ISO-8601 duration, for the
       LogonTrigger's Delay). #>
    $items = [System.Collections.Generic.List[object]]::new()
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # komorebi.exe direct (not `komorebic start`, which is flaky on some machines --
    # os error 1920, retries in a loop and can hang on launch). Start-Komorebi.ps1 waits
    # for a real foreground window and retries with a time budget; see that script.
    $komorebiExe = Get-KomorebiExe
    if ($komorebiExe) {
        $launcher = Join-Path $Root 'scripts\Start-Komorebi.ps1'
        $items.Add([pscustomobject]@{
            Key = 'komorebi'; TaskName = 'komorebi'; LnkName = '710.DesktopRice komorebi.lnk'
            Exe = $ps
            Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
            Delay = 'PT0S'
        })
    }

    # YASB via its own resilient launcher (waits for shell ready, retries).
    $yasbc = (Get-Command yasbc -ErrorAction SilentlyContinue)?.Source
    if ($yasbc) {
        $launcher = Join-Path $Root 'scripts\Start-Yasb.ps1'
        $yasbHome = Join-Path $Root 'config\yasb'
        $items.Add([pscustomobject]@{
            Key = 'yasb'; TaskName = 'yasb'; LnkName = '710.DesktopRice YASB.lnk'
            Exe = $ps
            Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" -YasbExe `"$yasbc`" -YasbConfigHome `"$yasbHome`""
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
        $items.Add([pscustomobject]@{
            Key = 'window-slots'; TaskName = 'window-slots'; LnkName = '710.DesktopRice window slots.lnk'
            Exe = $ps
            Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$inner`""
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
        $items.Add([pscustomobject]@{
            Key = 'ahk'; TaskName = 'ahk'; LnkName = '710.DesktopRice hotkeys.lnk'
            Exe = $ps
            Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" -AhkExe `"$ahkExe`" -ScriptPath `"$ahkScript`""
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
    $full = Get-TaskFullName -TaskName $TaskName
    & schtasks.exe /Query /TN $full *> $null
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
       execution time limit. Ported from New-WinarchyTaskXml. #>
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
