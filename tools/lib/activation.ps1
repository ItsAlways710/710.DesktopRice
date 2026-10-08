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

# The lock screen, all of it but its setter script: the setter's runner and record (the wallpaper
# pipeline dot-sources the same file), install's and uninstall's parts, doctor's check.
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
. (Join-Path $PSScriptRoot 'fulltime.ps1')
. (Join-Path $PSScriptRoot 'stack.ps1')

# install's fixed steps, one module each (tools\steps\<step>.ps1): the step itself, what uninstall
# puts back, doctor's checks (docs\map.md, Install steps).
. (Join-Path $PSScriptRoot '..\steps\envvars.ps1')
. (Join-Path $PSScriptRoot '..\steps\path.ps1')
. (Join-Path $PSScriptRoot '..\steps\wallust.ps1')
. (Join-Path $PSScriptRoot '..\steps\theme.ps1')
. (Join-Path $PSScriptRoot '..\steps\profile.ps1')

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
