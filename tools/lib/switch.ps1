<#
.SYNOPSIS
  `710sRice activate` / `deactivate`: the switch between full time and on demand, both ways, on an
  installed machine -- the tasks, full time's Windows settings (tools\lib\fulltime.ps1) and the
  stack, nothing else. Dot-sourced by 710sRice.ps1's activate and deactivate rows, and only there:
  it uses the dispatcher's own Write-RiceError, Show-RiceCommandHelp and $script:RiceExit.
  Invoke-RiceSwitch loads tools\lib\activation.ps1 itself. Only functions.
#>

# --- activate / deactivate: full time and on demand ---------------------------------------------
# The switch, both ways, on an installed machine (the user's decisions, 2026-10-03). The mode is
# never stored: Test-FullTimeMachine reads it from the tasks (any sign-in task, or a Startup-
# shortcut fallback). Rules:
#   - The tasks change LAST either way, so a switch cut off part-way still reads as the old mode,
#     and running it again finishes it -- from the same saved copy of your Windows settings, which
#     goes only once the way back is done.
#   - No Windows setting changes under a running stack: deactivate stops it first and leaves it
#     stopped; activate stops it, switches, and starts everything through the tasks (komorebi's
#     and 710.ahk's -- 710.ahk starts the bar, Flow and ShareX).
#   - Either way the tasks step also retires the bar's, Flow's and ShareX's old tasks
#     (Remove-RetiredStartTasks), and the dry run says so when there are any.
#   - activate saves your Windows settings before changing them (Save-FullTimeSettings), only
#     when the machine isn't full-time yet; deactivate puts them back
#     (Restore-FullTimeWindowsSettings: the saved copy, else Windows' defaults -- uninstall's
#     own way back).
#   - Run in the mode it's already in, each says so and re-registers that mode's tasks (which
#     mends a mixed set) and changes nothing else -- except that deactivate still puts back a
#     copy left by an activate that didn't finish.
# install -Activate on a machine that isn't full-time yet makes the same switch (its tasks and
# windows steps), with its whole install run around it.

function Invoke-RiceSwitch {
    # `activate` / `deactivate` (admin by now): -DryRun, or nothing at all.
    $name = "$($args[0])"
    $dry = $false
    foreach ($a in @($args | Select-Object -Skip 1)) {
        if ("$a" -ieq '-DryRun') { $dry = $true; continue }
        Write-RiceError "Unknown option '$a' for $name"
        Show-RiceCommandHelp $name
        $script:RiceExit = 1
        return
    }
    . (Join-Path $Root 'tools\lib\activation.ps1')
    if ($name -eq 'activate') { Invoke-RiceActivate -DryRun:$dry } else { Invoke-RiceDeactivate -DryRun:$dry }
}

function Get-RiceSwitchTaskNames {
    # The components whose tasks the switch re-registers, as the dry run lists them.
    param([object[]]$Components)
    @($Components | ForEach-Object {
        if ($_.Key -eq 'komorebi') { "komorebi ($(if ((Get-KomorebiRunLevel) -eq 'HighestAvailable') { 'elevated' } else { 'non-elevated' }))" } else { $_.Key }
    }) -join ', '
}

function Write-RiceRetiredTasksDryRun {
    # The dry run's line for the old tasks the switch's tasks step removes (Remove-RetiredStartTasks),
    # when any are still here.
    $old = @(Get-RetiredStartTasks | Where-Object { Test-Task -TaskName $_.TaskName } | ForEach-Object Name)
    if ($old.Count) { Write-Host "  [ ] Remove the old start-up tasks of $($old -join ', ') -- 710.ahk starts them now" }
}

function Stop-RiceStackForSwitch {
    # The stack goes down before any Windows setting changes (Stop-RunningComponents, uninstall's
    # and `710sRice stop`'s own). -Then finishes the line. $true when something was running.
    param([switch]$DryRun, [string]$Then = '')
    $running = @(Get-RunningStackNames)
    if (-not $running.Count) { Step-Info "The stack isn't running -- nothing to stop"; return $false }
    if ($DryRun) {
        Write-Host "  [ ] Stop the stack: $($running -join ', ') (Flow Launcher and Everything keep running)$Then"
        return $true
    }
    Stop-RunningComponents
    $left = @(Get-RunningStackNames)
    $stopped = @($running | Where-Object { $left -notcontains $_ })
    if ($stopped.Count) { Step-Ok "Stopped: $($stopped -join ', ') (Flow Launcher and Everything keep running)$Then" }
    $true
}

function Test-RiceSwitchInstalled {
    # Something of the stack's is installed: the switch has tasks to change. $false (and the run's
    # error line, exit 1) when nothing is.
    param([object[]]$Components)
    if ($Components.Count) { return $true }
    Write-RiceError "Nothing of 710sRice's that starts through a task is installed here (no komorebi, no AutoHotkey) -- run 710sRice install first. Nothing was changed."
    $script:RiceExit = 1
    $false
}

function Set-RiceSwitchLockScreen {
    # deactivate's last Windows setting: your lock-screen picture (the wallpaper) set again. The
    # put-back can hand Windows' lock screen back to Spotlight -- the hardening held its Picture
    # choice -- and Spotlight hides the picture (Win+L and the boot screen showed Windows' default
    # image on the Dell, 2026-10-03). The setter chooses Picture again (scripts\Set-LockScreen.ps1).
    param([switch]$DryRun)
    if ($DryRun) { Write-Host "  [ ] Set your lock-screen picture again (the wallpaper, with Windows' lock screen on Picture)"; return }
    Set-LockScreenToWallpaper
}

function Invoke-RiceActivate {
    # `activate`: on demand -> full-time. Save your Windows settings (once), stop the stack, apply
    # full time's settings, every task with its sign-in trigger, then start everything.
    param([switch]$DryRun)
    Write-Host "`n== 710sRice activate ==" -ForegroundColor Cyan
    if ($DryRun) { Step-Info 'DRY RUN: nothing will be changed.' }
    $components = @(Get-AutostartComponents -NoWrite)
    if (-not (Test-RiceSwitchInstalled $components)) { return }

    if (Test-FullTimeMachine) {
        Step-Info 'Already full-time: it starts at every sign-in.'
        Write-Host "`n-- Tasks --" -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "  [ ] Re-register the sign-in tasks as they are (puts back a trigger one has lost): $(Get-RiceSwitchTaskNames $components)"
            Write-RiceRetiredTasksDryRun
            Write-Host ''
            Step-Info 'DRY RUN complete: nothing was changed.'
            return
        }
        Register-Autostart
        Write-RiceModeLines
        return
    }

    # 1. Your Windows settings as they are, saved before anything changes -- or a copy that's
    #    already here kept: an activate that didn't finish left it, and it's the real "before".
    Write-Host "`n-- Save your Windows settings --" -ForegroundColor Cyan
    $saved = Get-SavedFullTimeSettings
    if ($saved) {
        Step-Info "Keeping the copy saved $(Get-SavedFullTimeSettingsWhen $saved) -- it's how they were before (by a 710sRice activate that didn't finish)"
    } elseif ($DryRun) {
        Write-Host '  [ ] Save them as they are now (taskbar auto-hide, the hardening values, the Startup delay) -- 710sRice deactivate and uninstall put them back'
    } else {
        try {
            $null = Save-FullTimeSettings
            Step-Ok 'Saved as they are now (taskbar auto-hide, the hardening values, the Startup delay) -- 710sRice deactivate and uninstall put them back'
        } catch {
            Write-RiceError "Couldn't save your Windows settings ($($_.Exception.Message)) -- nothing was changed."
            $script:RiceExit = 1
            return
        }
    }

    # 2. The stack down. 3. Full time's Windows settings.
    Write-Host "`n-- Stack --" -ForegroundColor Cyan
    $null = Stop-RiceStackForSwitch -DryRun:$DryRun -Then ' -- it starts again at the end'
    Write-Host "`n-- Windows settings --" -ForegroundColor Cyan
    Set-FullTimeWindowsSettings -DryRun:$DryRun

    # 4. The tasks, last: they make it full-time.
    Write-Host "`n-- Tasks --" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "  [ ] Every task gets its sign-in trigger: $(Get-RiceSwitchTaskNames $components)"
        Write-RiceRetiredTasksDryRun
        Write-Host '  [ ] Start the stack through its tasks (710.ahk starts the bar, Flow and ShareX)'
        Write-Host ''
        Step-Info 'DRY RUN complete: nothing was changed. 710sRice activate does it.'
        return
    }
    Register-Autostart
    if (-not (Test-FullTimeMachine)) {
        Write-RiceError "Not full-time: no task starts at sign-in (see above). Full time's Windows settings are on and your own are saved; 710sRice activate again retries the tasks, and 710sRice start starts the stack meanwhile."
        $script:RiceExit = 1
        return
    }

    # 5. Everything started, through the tasks.
    Write-Host "`n-- Start --" -ForegroundColor Cyan
    Start-StackFromTasks
    Step-Info 'Chrome, the Claude app and other Chromium apps can pick up an extra title bar when the bar restarts -- focus the app and press SUPER+Ctrl+C to redraw it.'
    Write-RiceModeLines
}

function Invoke-RiceDeactivate {
    # `deactivate`: full-time -> on demand. Stop the stack, put your Windows settings back (the
    # saved copy, else Windows' defaults), every task without its sign-in trigger and the Startup
    # fallbacks gone -- then, once the machine reads on demand, the saved copy goes.
    param([switch]$DryRun)
    Write-Host "`n== 710sRice deactivate ==" -ForegroundColor Cyan
    if ($DryRun) { Step-Info 'DRY RUN: nothing will be changed.' }
    $components = @(Get-AutostartComponents -NoWrite)
    if (-not (Test-RiceSwitchInstalled $components)) { return }

    if (-not (Test-FullTimeMachine)) {
        Step-Info 'Already on demand: nothing starts at sign-in.'
        # A copy on an on-demand machine: an activate that didn't finish saved it (and may have
        # changed your settings). Finish the way back.
        $saved = Get-SavedFullTimeSettings
        if ($saved) {
            Write-Host "`n-- Windows settings --" -ForegroundColor Cyan
            Step-Info "A copy of your Windows settings saved $(Get-SavedFullTimeSettingsWhen $saved) is still here (by a 710sRice activate that didn't finish) -- putting them back."
            Restore-FullTimeWindowsSettings -DryRun:$DryRun
            Set-RiceSwitchLockScreen -DryRun:$DryRun
            if (-not $DryRun) { Remove-OriginalState -Label 'full-time-settings' }
        }
        Write-Host "`n-- Tasks --" -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "  [ ] Re-register the tasks with no sign-in trigger, as they are: $(Get-RiceSwitchTaskNames $components)"
            Write-RiceRetiredTasksDryRun
            Write-Host ''
            Step-Info 'DRY RUN complete: nothing was changed.'
            return
        }
        Register-OnDemandTasks
        Write-RiceModeLines
        return
    }

    # 1. The stack down, and it stays down: on demand starts when you say.
    Write-Host "`n-- Stack --" -ForegroundColor Cyan
    $null = Stop-RiceStackForSwitch -DryRun:$DryRun -Then ' -- 710sRice start brings it back'

    # 2. Your Windows settings back, and your lock-screen picture with them.
    Write-Host "`n-- Windows settings --" -ForegroundColor Cyan
    Restore-FullTimeWindowsSettings -DryRun:$DryRun
    Set-RiceSwitchLockScreen -DryRun:$DryRun

    # 3. The tasks, last: without their sign-in trigger the machine is on demand.
    Write-Host "`n-- Tasks --" -ForegroundColor Cyan
    $startup = [Environment]::GetFolderPath('Startup')
    $lnks = @(if ($startup) { Get-ChildItem -LiteralPath $startup -Filter '710.DesktopRice *.lnk' -File -ErrorAction SilentlyContinue })
    if ($DryRun) {
        Write-Host "  [ ] Every task loses its sign-in trigger (710sRice start still starts them all): $(Get-RiceSwitchTaskNames $components)"
        Write-RiceRetiredTasksDryRun
        if ($lnks.Count) { Write-Host "  [ ] Remove 710.DesktopRice's Startup-folder shortcut$(if ($lnks.Count -gt 1) { 's' }) ($($lnks.Count))" }
        Write-Host ''
        Step-Info 'DRY RUN complete: nothing was changed. 710sRice deactivate does it.'
        return
    }
    Register-OnDemandTasks
    if ($lnks.Count) {
        Remove-StartupShortcuts
        Step-Ok "Startup-folder shortcut$(if ($lnks.Count -gt 1) { 's' }) removed ($($lnks.Count))"
    }
    $still = @((Get-AutostartStatus).GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })
    if ($still.Count) {
        Write-RiceError "Still full-time: $($still -join ', ') still start$(if ($still.Count -eq 1) { 's' }) at sign-in (see above). Your Windows settings are back; 710sRice deactivate again retries the rest."
        $script:RiceExit = 1
        return
    }
    Remove-OriginalState -Label 'full-time-settings'
    Write-RiceModeLines
}
