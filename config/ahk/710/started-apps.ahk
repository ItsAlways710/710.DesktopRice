; Part of 710.ahk: The apps 710.ahk starts -- the bar, Flow Launcher, ShareX.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; The apps 710.ahk starts: the bar (YASB), Flow Launcher, ShareX
; ============================================================================
; Only this script starts these three: when it comes up, and every time one has to come back
; -- the bar's watchdog (below), a display-scale change, SUPER+Shift+R (whose Reload() is how
; a bar the reload stopped comes back), and the scripts: `710sRice start`, `reload bar`,
; repair, update, install's Flow and ShareX steps and a theme change all ask here, through the
; '710sRice.StartApps' message (further down).
; Why (2026-10-06): until then each had its own Scheduled Task, and whatever a task starts runs
; inside a job that refuses a child's request to start apart from it (CREATE_BREAKAWAY_FROM_JOB)
; -- and everything those apps start inherits the job. Mod Organizer 2 starts every tool that
; way, with no fallback, so an MO2 opened from the bar's taskbar drawer, from Flow or by a ShareX
; action couldn't start LOOT, xEdit or the game: "Error 5 ERROR_ACCESS_DENIED". Proven both ways
; on both machines: the bar and Flow on Godzilla (10-05), Flow and ShareX on the Dell (10-06 --
; ShareX started by its task: Error 5; the same action from a ShareX this script started: the
; file's own error 193, so Windows got as far as the file). What this script starts is clean --
; proven, not explained: it runs as AutoHotkey's UI Access build, which Start-Ahk.ps1 has to
; start through ShellExecute (the likely reason: Windows' AppInfo service creates a UI Access
; process on the caller's behalf). komorebi keeps its task: it has to run elevated, and it
; starts nothing for you.
; Running as admin (A_IsAdmin: someone started this script from an admin window) it starts none
; of them -- they'd run as admin, and so would everything opened from them. One toast says so;
; doctor flags an admin 710.ahk too, and `710sRice restart` from a normal window fixes it.
; Each one starts only if it isn't running. The bar: Start-Yasb.ps1 through Windows PowerShell
; (System32's, never the Store's pwsh, which runs inside a job of its own) -- it waits for the
; desktop, retries, logs to yasb-autostart.log and reads the environment fresh from the
; registry, so a restarted bar sees a changed YASB_WALLPAPER_PATH as the task's start did.
; Flow: its root Flow.Launcher.exe (it starts hidden). ShareX: -silent, into the tray, as at
; sign-in. Each start (or refusal) gets a line in ahk-autostart.log.
; ============================================================================
AhkAutostartLog := EnvGet('LOCALAPPDATA') '\710.DesktopRice\ahk-autostart.log'
FlowExe := EnvGet('LOCALAPPDATA') '\FlowLauncher\Flow.Launcher.exe'

; which: 1 the bar, 2 Flow, 4 ShareX (added up) -- the '710sRice.StartApps' message's wParam too.
StartApps(which, why) {
    if (which & 1)
        StartBar(why)
    if (which & 2)
        StartFlow(why)
    if (which & 4)
        StartShareX(why)
}

; True when the bar is up or on its way (a Start-Yasb.ps1 still at work), or this just started
; it; false when it couldn't (or wouldn't: admin).
StartBar(why) {
    global RepoRoot
    if ProcessExist('yasb.exe') || YasbLauncherRunning()
        return true
    if !AppStartAllowed('the bar')
        return false
    ps := A_WinDir '\System32\WindowsPowerShell\v1.0\powershell.exe'
    try Run('"' ps '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' RepoRoot '\scripts\Start-Yasb.ps1" -Reason "' why '"', , 'Hide')
    catch as e {
        AppsLog("couldn't start the bar (" why "): " e.Message)
        return false
    }
    AppsLog('started the bar (' why ')')
    return true
}

StartFlow(why) {
    global FlowExe
    if !FileExist(FlowExe) || ProcessExist('Flow.Launcher.exe')
        return true
    if !AppStartAllowed('Flow Launcher')
        return false
    try Run('"' FlowExe '"')
    catch as e {
        AppsLog("couldn't start Flow Launcher (" why "): " e.Message)
        return false
    }
    AppsLog('started Flow Launcher (' why ')')
    return true
}

StartShareX(why) {
    global ShareXExe
    if !ShareXExe || ProcessExist('ShareX.exe')
        return true
    if !AppStartAllowed('ShareX')
        return false
    try Run('"' ShareXExe '" -silent')
    catch as e {
        AppsLog("couldn't start ShareX (" why "): " e.Message)
        return false
    }
    AppsLog('started ShareX (' why ')')
    return true
}

; False -- with one toast, the first time -- while this script runs as admin.
AppStartAllowed(what) {
    static told := false
    if !A_IsAdmin
        return true
    AppsLog('not starting ' what ': 710.ahk is running as admin')
    if !told {
        told := true
        TrayTip("710.ahk is running as admin, so it won't start the bar, Flow or ShareX -- they'd run as admin too.`nRun 710sRice restart from a normal window.", '710sRice')
    }
    return false
}

; Same line format as Start-Ahk.ps1's own Write-Log -- it's that file. UTF-8-RAW: it already
; has its BOM (PS 5.1 Out-File), so no BOM mid-file.
AppsLog(m) {
    global AhkAutostartLog
    try FileAppend(FormatTime(, 'yyyy-MM-dd HH:mm:ss') '  710.ahk: ' m '`n', AhkAutostartLog, 'UTF-8-RAW')
}

; Once, after install's tasks step removed the old start-up tasks (Remove-RetiredStartTasks,
; tools\lib\stack.ps1): a bar, Flow or ShareX still running may be the copy its task started,
; still inside the task's job -- MO2 opened from it would keep failing until it restarts. The step
; writes which ones were running (the StartApps bits) to restart-after-retire.txt and asks here
; ('710sRice.RestartRetired', further down). The file is read as this script starts too: a 710.ahk
; from before this has no ear for the ask, so the step restarts it through its task, and the new
; one does it as it starts. Each one still running is closed and started again from here. The file
; goes first, so this happens once whatever happens next. Not as admin: nothing could start again,
; so the file waits for a normal 710.ahk.
RetiredRestartFile := EnvGet('LOCALAPPDATA') '\710.DesktopRice\restart-after-retire.txt'

RestartRetired(*) {
    global RetiredRestartFile
    if A_IsAdmin || !FileExist(RetiredRestartFile)
        return
    ; " `t`r`n": PowerShell's Set-Content ends the file with a line break, and Trim's default
    ; (spaces and tabs) leaves it on -- "7`r`n" isn't a number (the Dell, 2026-10-06).
    which := 0
    try which := Integer(Trim(FileRead(RetiredRestartFile), " `t`r`n"))
    catch as e
        AppsLog("couldn't read restart-after-retire.txt (" e.Message ") -- nothing restarted")
    try FileDelete(RetiredRestartFile)
    restarted := [], stuck := []
    for bit, app in Map(1, ['yasb.exe', 'the bar'], 2, ['Flow.Launcher.exe', 'Flow Launcher'], 4, ['ShareX.exe', 'ShareX']) {
        if !(which & bit)
            continue
        if !ProcessExist(app[1]) {
            which &= ~bit           ; not running: StartApps at load starts it anyway
            continue
        }
        if CloseAllNamed(app[1])
            restarted.Push(app[2])
        else
            stuck.Push(app[2]), which &= ~bit
    }
    many := restarted.Length > 1
    if restarted.Length {
        AppsLog('restarting ' JoinNames(restarted) ': the old start-up task' (many ? 's that may have started them are' : ' that may have started it is') ' gone')
        StartApps(which, 'restarted: its old task is gone')
    }
    if stuck.Length
        AppsLog("couldn't close " JoinNames(stuck) ' to restart it (running as admin?)')
    if !(restarted.Length || stuck.Length)
        return
    msg := ''
    if restarted.Length
        msg := 'Restarted ' JoinNames(restarted) ' -- ' (many ? 'their old start-up tasks may have started them.' : 'its old start-up task may have started it.')
    if stuck.Length
        msg .= (msg != '' ? '`n' : '') "Couldn't restart " JoinNames(stuck) ' -- 710sRice restart, or sign out and in.'
    if (which & 1)
        msg .= '`nAn app with an extra title bar: SUPER+Ctrl+C.'
    TrayTip(msg, '710sRice')
}

; Every process called exe closed (TerminateProcess -- the way Stop-All ends the bar and ShareX,
; and install's Flow step ends Flow), each one waited for; false when one is still there after
; 5 s (one running as admin: this script can't end it).
CloseAllNamed(exe) {
    deadline := A_TickCount + 5000
    while (pid := ProcessExist(exe)) {
        if (A_TickCount > deadline)
            return false
        try ProcessClose(pid)
        ProcessWaitClose(pid, 1)
    }
    return true
}

; 'a', 'a and b', 'a, b and c'.
JoinNames(names) {
    out := ''
    for i, n in names
        out .= (i = 1 ? '' : i = names.Length ? ' and ' : ', ') n
    return out
}

; At start: a restart left for us (above), then whichever of the three isn't running -- at sign-in,
; after `710sRice start` and `restart`, and after SUPER+Shift+R's Reload(). On a timer, so it runs
; once this script has finished loading.
StartAppsAtLoad() {
    RestartRetired()
    StartApps(7, 'at start')
}
SetTimer(StartAppsAtLoad, -1)
