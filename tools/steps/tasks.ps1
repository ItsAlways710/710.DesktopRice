<#
.SYNOPSIS
  install's tasks step: komorebi's and 710.ahk's scheduled tasks -- with a sign-in trigger on a
  full-time machine (-Activate, `710sRice activate`), without one on an on-demand machine (`710sRice
  start` fires them) -- and the machine's mode, read from them (Test-FullTimeMachine: the one rule
  install, uninstall, the switch, the components and doctor all go by); the step itself (the tiling
  mode first -- tools\lib\tiling.ps1 -- then the tasks, then the lock screen's part,
  tools\lib\lockscreen.ps1); uninstall's removal of them (section 2, Unregister-Autostart);
  doctor's mode and task lines. The Task Scheduler plumbing is tools\lib\tasks.ps1. Loaded by
  tools\lib\activation.ps1. Only functions.

  net-icon is deliberately NOT ported from winarchy (see Get-AutostartComponents and the plan doc):
  it's a different mechanism than our YASB systray's show_network, and with the taskbar hidden
  there's currently no network status shown either way regardless of which we'd pick.
#>

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
       them now (Get-AhkStartedApps, tools\lib\stack.ps1, says why), and their old tasks are retired
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

# --- install's step -------------------------------------------------------------------------------
function Install-TasksStep {
    # install's tasks step, with install's own switches: -Activate (registers the sign-in tasks),
    # -Only (no on-demand note), -ElevatedTiling / -NoElevatedTiling (the tiling mode).
    param([bool]$Activate, [bool]$OnlyRun, [bool]$ElevatedTiling, [bool]$NoElevatedTiling)
    # --- 10b. Tiling mode (elevated komorebi or not) -------------------------------------------
    # Resolved (switch -> remembered -> default 'elevated') and remembered here; the task
    # registration just below reads it back through Get-KomorebiRunLevel.
    Write-Host "`n-- Tiling mode --" -ForegroundColor Cyan
    $tiling = Resolve-TilingMode -Elevated:$ElevatedTiling -Normal:$NoElevatedTiling
    $tilingWhy = switch ($tiling.Source) { 'switch' { 'set by this run' } 'remembered' { 'remembered from a previous install' } default { 'the default' } }
    if ($tiling.Mode -eq 'elevated') {
        Step-Ok "Elevated tiling ($tilingWhy): komorebi runs elevated, so admin windows tile too. Opt out with -NoElevatedTiling."
    } else {
        Step-Ok "Non-elevated tiling ($tilingWhy): admin windows float. Opt back in with -ElevatedTiling."
    }
    if ($tiling.Changed -and (Get-Process komorebi -ErrorAction SilentlyContinue)) {
        Step-Info 'komorebi is already running in the old mode -- the new one takes effect when it next starts: sign out and back in, or run `710sRice restart`.'
    }

    # --- 11a. Tasks: komorebi's and 710.ahk's, in the machine's mode -------------------------
    # (The bar's, Flow's and ShareX's old tasks go here too, whichever branch runs:
    # Register-Autostart / Register-OnDemandTasks call Remove-RetiredStartTasks. 710.ahk starts
    # those three now -- see config\ahk\710.ahk, "The apps 710.ahk starts".)
    if ($Activate) {
        Write-Host "`n-- Activate --" -ForegroundColor Cyan
        Register-Autostart
    } elseif (Test-FullTimeMachine) {
        # Already full-time from an earlier -Activate: re-register so the tasks pick up any
        # change to how components are launched (a newer launcher script, a moved clone),
        # without switching modes.
        Write-Host "`n-- Activate --" -ForegroundColor Cyan
        Step-Info 'Autostart is active: re-registering to pick up any startup changes...'
        Register-Autostart
    } else {
        # On-demand: komorebi and 710.ahk still get their tasks (no trigger), so Start-All.ps1
        # and SUPER+Shift+R start each one at its task's own level -- the same as -Activate,
        # from any window (Register-OnDemandTasks).
        # The closing lines say how to switch to full-time (`710sRice activate`).
        if (-not $OnlyRun) {
            Step-Info 'On demand: packages, config, theming, Defender, the profile hook and Flow are applied; nothing starts at sign-in, and the taskbar, hardening and Startup delay are left as they are.'
        }
        Register-OnDemandTasks
    }

    # --- 11c. The lock screen: the old sync retired, your picture set once when needed --------
    # (tools\lib\lockscreen.ps1; doctor's fix for the old sync is `-Only tasks`).
    Install-LockScreen
}

# --- Doctor's checks: the mode and task lines in Tasks and tiling mode -----------------------------
# komorebi and 710.ahk start through their scheduled tasks -- with a sign-in trigger on a
# full-time (-Activate'd) machine, without one on an on-demand machine; 710.ahk starts the bar,
# Flow and ShareX, whose own tasks are retired -- and install's tasks step (`710sRice install
# -Only tasks`) re-registers them all in the machine's mode, which fixes nearly everything here.
# The mode itself is install's own rule (Test-FullTimeMachine). The
# task's command is compared with what install would register now (Get-AutostartComponents
# -NoWrite: the same answer, nothing written); a difference is reported by part, never with
# the paths -- the launch files live under %LOCALAPPDATA%, whose path carries the user name.

function Test-DoctorSameText { param([string]$A, [string]$B) [string]::Equals("$A".Trim(), "$B".Trim(), [StringComparison]::OrdinalIgnoreCase) }

function Get-DoctorTaskDrift {
    # What differs between a component's task as registered and what install would register
    # now: the task's command, and (for the three launched through run-hidden.vbs) its
    # launch-<key>.txt. Nothing = they match.
    param($Component, $Task)
    if (-not (Test-DoctorSameText $Task.Command $Component.Exe) -or -not (Test-DoctorSameText $Task.Arguments $Component.Arguments)) {
        "its task's command differs"
    }
    if ($Component.Spec) {
        $leaf = Split-Path -Leaf $Component.Spec
        if (-not (Test-Path -LiteralPath $Component.Spec)) { "$leaf is missing" }
        else {
            $lines = @(Get-Content -LiteralPath $Component.Spec -ErrorAction Stop)
            if ($lines.Count -ne 2 -or -not (Test-DoctorSameText $lines[0] $Component.SpecLines[0]) -or -not (Test-DoctorSameText $lines[1] $Component.SpecLines[1])) {
                "$leaf differs"
            }
        }
    }
}

function Test-DoctorTasks {
    # The mode line and one line per component's task (the worst thing found), then the bar's,
    # Flow's and ShareX's old tasks if they're still here. (The lock-screen sync task was checked
    # here until it was retired, 2026-09-28: plan doc item 48.)
    $tasksFix = @{ Fix = '710sRice install -Only tasks'; Step = 'tasks' }
    $startup = [Environment]::GetFolderPath('Startup')
    # Their tasks (2026-10-06): what a task starts runs in its job, and so does everything opened
    # from it -- Mod Organizer 2 opened from the bar, Flow or a ShareX action couldn't start its
    # tools (Error 5). 710.ahk starts all three now; the tasks step removes the old tasks and their
    # Startup-folder fallbacks (Remove-RetiredStartTasks). A machine still has them until then.
    $old = @(Get-RetiredStartTasks | Where-Object {
        (Test-Task -TaskName $_.TaskName) -or ($startup -and (Test-Path -LiteralPath ([IO.Path]::Combine($startup, $_.LnkName))))
    })
    $oldResult = if ($old.Count) {
        New-DoctorResult -Id 'task:retired' -Status 'XX' -Text "Old start-up tasks still here: $(($old | ForEach-Object Name) -join ', ')" `
            -Detail "710.ahk starts $(if ($old.Count -eq 1) { 'it' } else { 'them' }) now -- what you open from an app a task started can't start programs of its own (Mod Organizer 2's tools: Error 5); the fix restarts the ones running" @tasksFix
    }
    $components = @(Get-AutostartComponents -NoWrite)
    if (-not $components.Count) { return $oldResult }   # nothing installed: group b says so
    $fullTime = Test-FullTimeMachine
    $infos = @{}
    foreach ($c in $components) { $infos[$c.Key] = Get-ComponentTaskInfo -TaskName $c.TaskName }
    $names = { param($list) ($list | ForEach-Object { Get-DoctorComponentName $_.Key }) -join ', ' }

    # Mode. Full-time with a task that has no sign-in trigger = mixed (install's rule makes the
    # whole machine full-time, so the tasks step gives every task its trigger back).
    $signIn   = @($components | Where-Object { $infos[$_.Key] -and $infos[$_.Key].AtLogOn })
    $noSignIn = @($components | Where-Object { $infos[$_.Key] -and -not $infos[$_.Key].AtLogOn })
    if ($fullTime -and $noSignIn.Count) {
        $text = if ($signIn.Count) { "Mode: mixed -- $(& $names $signIn) start at sign-in; $(& $names $noSignIn) $(if ($noSignIn.Count -eq 1) { "doesn't" } else { "don't" })" }
                else { "Mode: mixed -- a Startup shortcut says full-time, but no task starts at sign-in" }
        New-DoctorResult -Id 'mode' -Status 'XX' -Text $text @tasksFix
    } elseif ($fullTime) {
        # The switch named on the line itself: an [OK] line prints no fix.
        New-DoctorResult -Id 'mode' -Status 'OK' -Text 'Mode: full-time (starts at sign-in) -- 710sRice deactivate switches to on demand'
    } else {
        New-DoctorResult -Id 'mode' -Status 'OK' -Text 'Mode: on demand (710sRice start) -- 710sRice activate switches to full-time'
    }

    foreach ($c in $components) {
        $name = Get-DoctorComponentName $c.Key
        $id   = "task:$($c.Key)"
        $t    = $infos[$c.Key]
        if (-not $t) { New-DoctorResult -Id $id -Status 'XX' -Text "$name has no task" @tasksFix; continue }
        if ($c.Key -ne 'komorebi' -and $t.RunLevel -eq 'HighestAvailable') {
            New-DoctorResult -Id $id -Status 'XX' -Text "$name's task runs elevated -- only komorebi's may" @tasksFix; continue
        }
        $drift = @(Get-DoctorTaskDrift $c $t)
        if ($drift.Count) {
            New-DoctorResult -Id $id -Status 'XX' -Text "$name's task doesn't match what install would register now (a moved clone or a moved exe?)" -Detail $drift @tasksFix
            continue
        }
        # A Startup shortcut from before the tasks (or Register-Autostart's fallback) next to a
        # working task. The tasks step removes them (Register-Autostart; a shortcut makes the
        # machine full-time by install's rule, so that's the path it takes).
        if (Test-Path -LiteralPath ([IO.Path]::Combine($startup, $c.LnkName))) {
            $why = if ($t.AtLogOn) { "$name starts twice at sign-in" } else { "it starts $name at sign-in on its own" }
            New-DoctorResult -Id $id -Status 'XX' -Text "Startup folder still has `"$($c.LnkName)`" next to $name's task -- $why" @tasksFix
            continue
        }
        if (-not $t.Enabled) {
            New-DoctorResult -Id $id -Status 'XX' -Text "$name's task is disabled in Task Scheduler" `
                -Detail 'the tasks step registers it again, enabled' @tasksFix
            continue
        }
        $kind = @(if ($t.AtLogOn) { 'sign-in' } else { 'on demand' }; if ($t.RunLevel -eq 'HighestAvailable') { 'elevated' }) -join ', '
        New-DoctorResult -Id $id -Status 'OK' -Text "$name's task ($kind)"
    }
    $oldResult
}
