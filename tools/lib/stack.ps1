<#
.SYNOPSIS
  The stack's starts and stops: komorebi and 710.ahk through their own tasks (never launched from
  an admin window), the bar, Flow Launcher and ShareX through 710.ahk (never a task of their own --
  Get-AhkStartedApps says why), the stop everything runs (Stop-RunningComponents), the bar's,
  Flow's and ShareX's old start-up tasks retired, and doctor's Stack lines. Used by install,
  uninstall, `710sRice start` / `stop` / `restart` / `reload` / `activate` / `deactivate`, repair
  and update. Loaded by tools\lib\activation.ps1. Only functions.
#>

# --- The apps 710.ahk starts, 710.ahk's own start, the old start-up tasks -----------------------

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

# --- The stop everything runs, what's running, the start through the tasks -------------------
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

# --- Doctor's check: the Stack group ------------------------------------------------------------
# The four components the stack starts, then each component with its own task (Flow Launcher,
# Group 1 #4). One line each, carrying the worst thing found. Nothing running at all is a plain
# fact -- an on-demand machine between sessions, or a full-time one after `710sRice stop` -- but
# some running and some not means something died. "Nothing running" is the four only: stop and
# Quit leave Flow running on purpose. Only komorebi may run as admin (the tiling mode's choice);
# anything else elevated makes everything it launches elevated too. Log paths are given by
# name only: the full path carries the Windows user name, and a report may get pasted into an
# issue.

function Get-DoctorYasbWatchdogNote {
    # Why YASB is down, when 710.ahk's watchdog says so and nothing has happened since: its
    # give-up line (or its "watchdog off" line), with no relaunch -- a '--- startup' line from
    # Start-Yasb.ps1 -- after it. The watchdog writes into yasb-autostart.log; the tail is plenty.
    $log = Join-Path (Get-DoctorLogDir) 'yasb-autostart.log'
    if (-not (Test-Path -LiteralPath $log)) { return $null }
    $note = $null
    foreach ($line in @(Get-Content -LiteralPath $log -Tail 300 -ErrorAction SilentlyContinue)) {
        if ($line -match '  --- startup') { $note = $null; continue }
        if ($line -notmatch '^(\d{4}-\d\d-\d\d) (\d\d:\d\d):\d\d  watchdog: (.*)$') { continue }
        $when = if ($Matches[1] -eq (Get-Date -Format 'yyyy-MM-dd')) { $Matches[2] } else { "$($Matches[1]) $($Matches[2])" }
        $what = $Matches[3]
        if ($what -match 'stopped relaunching') {
            $note = "the watchdog gave up at $when after 3 relaunches -- the crash is in config\yasb\yasb.log"
        } elseif ($what -match 'Watchdog off') {
            $note = "the watchdog couldn't relaunch it at $when (Windows PowerShell wouldn't start -- ahk-autostart.log says why) -- watchdog off"
        }
    }
    $note
}

function Get-DoctorStaleText {
    # A running YASB / 710.ahk that loaded older files than the repo has now: Text (+ Detail), or
    # $null. YASB: config.yaml against the fingerprint Start-Yasb.ps1 recorded when the bar started
    # -- reload-stack.ps1's own test for "restart the bar", byte for byte, so the two can't
    # disagree (no fingerprint = the same answer). 710.ahk: 710.ahk or user.ahk written after its
    # process started (AHK's Reload() starts a new process); a start time Windows won't hand
    # over = not checked, never guessed.
    param([string]$Key, $Process)
    if ($Key -eq 'yasb') {
        $fp  = Join-Path (Get-DoctorLogDir) 'yasb-config.sha256'
        $cfg = Join-Path $Root 'config\yasb\config.yaml'
        if (-not (Test-Path -LiteralPath $cfg)) { return $null }   # group e / the bar itself say so
        if (-not (Test-Path -LiteralPath $fp)) {
            return [pscustomobject]@{ Text = 'YASB is running an older config.yaml'; Detail = 'no record of the config.yaml it started with (yasb-config.sha256)' }
        }
        if ((Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash -ne (Get-Content -LiteralPath $fp -Raw).Trim()) {
            return [pscustomobject]@{ Text = 'YASB is running an older config.yaml'; Detail = $null }
        }
        return $null
    }
    if ($Key -eq 'ahk') {
        $started = try { $Process.StartTime } catch { $null }
        if (-not $started) { return $null }
        foreach ($f in 'config\ahk\710.ahk', 'config\ahk\user.ahk') {
            $item = Get-Item -LiteralPath (Join-Path $Root $f) -ErrorAction SilentlyContinue
            if ($item -and $item.LastWriteTime -gt $started) {
                $leaf = Split-Path -Leaf $f
                $text = if ($leaf -eq '710.ahk') { '710.ahk changed since it started' } else { 'user.ahk changed since 710.ahk started' }
                return [pscustomobject]@{ Text = $text; Detail = $null }
            }
        }
    }
    $null
}

function Test-DoctorStack {
    # One line per component (or one line for "nothing running").
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    $ahkExe    = Get-AhkExe
    $parts = @(
        [pscustomobject]@{ Key = 'komorebi'; Name = 'komorebi'; Log = 'komorebi-autostart.log'; Installed = [bool](Get-KomorebiExe) }
        [pscustomobject]@{ Key = 'yasb';     Name = 'YASB';     Log = 'yasb-autostart.log';     Installed = [bool](Get-YasbcExe) }
        [pscustomobject]@{ Key = 'ahk';      Name = '710.ahk';  Log = 'ahk-autostart.log';      Installed = [bool]$ahkExe }
        # 710.ahk starts ShareX (and the bar, and Flow), and logs each start -- or why not -- there.
        [pscustomobject]@{ Key = 'sharex';   Name = 'ShareX';   Log = 'ahk-autostart.log';      Installed = [bool](Get-ShareXExe) }
    )
    # What's running. 710.ahk by its window (Get-AhkWindowProcessId), the rest by name.
    $ahkPid = Get-AhkWindowProcessId -ScriptPath $ahkScript
    $procs = @{
        komorebi = @(Get-Process komorebi -ErrorAction SilentlyContinue)
        yasb     = @(Get-Process yasb -ErrorAction SilentlyContinue)
        ahk      = @(if ($ahkPid) { Get-Process -Id $ahkPid -ErrorAction SilentlyContinue })
        sharex   = @(Get-Process ShareX -ErrorAction SilentlyContinue)
    }
    # Not installed: group b already says so, and nothing here could start it.
    $parts = @($parts | Where-Object Installed)
    # Flow Launcher, which 710.ahk starts like the bar and ShareX (Get-AhkStartedApps): running =
    # its process. Up but running as admin: its own install step (it stops Flow and has 710.ahk
    # start it again) -- `710sRice restart` leaves Flow running.
    $own = @(foreach ($app in @(Get-AhkStartedApps | Where-Object { $_.Key -eq 'flow' -and $_.Installed })) {
        $procs[$app.Key] = @(Get-Process -Name $app.Process -ErrorAction SilentlyContinue)
        [pscustomobject]@{ Key = $app.Key; Name = $app.Name; Log = 'ahk-autostart.log'; Installed = $true; Own = $true }
    })
    # (None of the four installed but Flow: just Flow's line below.)
    # "Running" means komorebi, YASB or 710.ahk. ShareX on its own isn't the stack, the way Flow on
    # its own never was: you can open it yourself, and an on-demand machine's sign-in once started
    # it alone (its own startup shortcut, sharex.ps1) -- read as a half-started stack, that made
    # repair, and so update, start everything around it (the Dell, 2026-10-03).
    $core = @($parts | Where-Object { $_.Key -ne 'sharex' })
    if (-not @($core | Where-Object { $procs[$_.Key].Count }).Count -and ($parts.Count -or -not $own.Count)) {
        # Nothing running: normal on an on-demand machine between sessions. A full-time
        # (-Activate'd) machine is meant to run from sign-in, so there it's a problem, and
        # repair starts the lot (user, 2026-09-27: "repair just make it all on if possible") --
        # with Flow and ShareX, unless they're still up.
        if (Test-FullTimeMachine) {
            $keys = @($parts | Where-Object { -not $procs[$_.Key].Count } | ForEach-Object Key) + @($own | Where-Object { -not $procs[$_.Key].Count } | ForEach-Object Key)
            return New-DoctorResult -Id 'stack' -Status 'XX' -Text "Stack not running -- this is a full-time machine (it starts at sign-in)" `
                -Fix '710sRice start' -Repair "start:$($keys -join ',')"
        }
        return New-DoctorResult -Id 'stack' -Status '..' -Text 'Stack not running -- 710sRice start starts it'
    }
    foreach ($c in @($parts) + @($own)) {
        $id = "stack:$($c.Key)"
        $running = $procs[$c.Key]
        if (-not $running.Count) {
            $text   = "$($c.Name) isn't running$(if ($c.Key -eq 'sharex') { ' -- capture hotkeys do nothing without it' })"
            $detail = if ($c.Key -eq 'yasb') { Get-DoctorYasbWatchdogNote } else { $null }
            if (-not $detail -and $c.Log) { $detail = "its log: $($c.Log) (710sRice logs opens the folder)" }
            New-DoctorResult -Id $id -Status 'XX' -Text $text -Detail $detail -Fix '710sRice start' -Repair "start:$($c.Key)"
            continue
        }
        if ($c.Key -eq 'yasb' -and $running.Count -gt 1) {
            New-DoctorResult -Id $id -Status 'XX' -Text "$($running.Count) YASB processes -- two bars fight over komorebi's events" -Fix '710sRice reload bar' -Repair 'reload-bar'
            continue
        }
        if ($c.Key -ne 'komorebi' -and @($running | Where-Object { (Get-ProcessElevation -Id $_.Id) -eq 'elevated' }).Count) {
            $how = if ($c.Own) { @{ Fix = "710sRice install -Only $($c.Key)"; Step = $c.Key } } else { @{ Fix = '710sRice restart'; Repair = 'restart' } }
            New-DoctorResult -Id $id -Status 'XX' -Text "$($c.Name) is running as admin -- nothing but komorebi should" @how
            continue
        }
        # Running files older than the ones on disk (a pull or an edit since they started):
        # `710sRice reload` restarts the bar for a changed config.yaml and reloads 710.ahk at its
        # end. The last finding each line can have -- the ones above cover these anyway.
        $stale = Get-DoctorStaleText $c.Key $running[0]
        if ($stale) {
            New-DoctorResult -Id $id -Status 'XX' -Text $stale.Text -Detail $stale.Detail -Fix '710sRice reload' -Repair 'reload'
            continue
        }
        if ($c.Key -eq 'ahk') {
            # The UI Access build is what lets 710.ahk's hotkeys reach admin windows; the
            # installer only makes it in a Program Files install (Get-AhkExe prefers it).
            if ($running[0].ProcessName -eq 'AutoHotkey64_UIA') {
                New-DoctorResult -Id $id -Status 'OK' -Text '710.ahk running (UI Access)'
            } elseif ("$ahkExe" -like '*AutoHotkey64_UIA.exe') {
                New-DoctorResult -Id $id -Status '!!' -Text "710.ahk is running without UI Access -- its hotkeys don't reach admin windows" -Fix '710sRice restart'
            } else {
                New-DoctorResult -Id $id -Status 'OK' -Text '710.ahk running'
            }
            continue
        }
        New-DoctorResult -Id $id -Status 'OK' -Text "$($c.Name) running"
    }
}

function Test-DoctorPaused {
    # komorebi paused (SUPER+P) -- a plain fact, but it explains a lot: nothing tiles, and a bar
    # (re)started now never connects. Its own check, so a komorebic hiccup can't hide the lines above.
    if (-not (Get-Process komorebi -ErrorAction SilentlyContinue)) { return }
    $kc = Get-DoctorKomorebic
    if (-not $kc) { return }
    $text = @(& $kc state 2>$null) -join "`n"
    if (-not $text.Trim()) { return }   # no answer: nothing to say about a pause
    $state = $text | ConvertFrom-Json
    if ($state.is_paused) { New-DoctorResult -Id 'paused' -Status '..' -Text 'komorebi is paused -- SUPER+P resumes' }
}
