<#
.SYNOPSIS
  Explorer's restart: the one restart full time's Windows settings need (taskbar auto-hide and the
  hardening only take effect that way), waiting for the real shell to be back, and every app's
  tray-icon choice kept around it. Loaded by tools\lib\activation.ps1. Only functions.
#>

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
    <# The ONE Explorer restart for install -Activate / uninstall / `710sRice activate` /
       `deactivate` (taskbar auto-hide + hardening both need it; Set-FullTimeWindowsSettings
       and Restore-FullTimeWindowsSettings run this once if either changed something). Kills
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
