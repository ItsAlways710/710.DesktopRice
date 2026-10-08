; Part of 710.ahk: YASB watchdog -- the bar's.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; YASB watchdog
; ============================================================================
; Ported from winarchy bb72240 (v1.5.0), with three changes agreed 2026-09-23:
;  - The relaunch is StartBar() (above): Start-Yasb.ps1's wait-for-desktop + retry
;    loop, a hidden launch, and never as admin. Until 2026-10-06 it went through
;    YASB's own task (schtasks /Run), which put the bar in the task's job.
;  - Armed only once yasb.exe has actually been seen running. Getting YASB up at
;    boot is Start-Yasb.ps1's job (it retries for a full minute); this is the
;    crash net for afterwards.
;  - Gives up with a toast pointing at `710sRice doctor`, which reads the story
;    back out of yasb-autostart.log -- every relaunch and the give-up get their
;    own line there.
; A 5s check only counts as a miss when yasb.exe is gone AND nothing is already
; bringing it back: winget running (an install/upgrade), or a Start-Yasb.ps1
; launcher still alive (boot, SUPER+Shift+R, or our own previous relaunch still
; working). Two misses in a row (5-10s with no bar) = relaunch. Three relaunches
; inside 5 minutes = YASB is crash-looping; stop and say so instead of thrashing.
; The crash itself, if YASB caught it, is in config\yasb\yasb.log.
; ============================================================================
YasbSeen := false, YasbMisses := 0, YasbRelaunches := []
YasbAutostartLog := EnvGet('LOCALAPPDATA') '\710.DesktopRice\yasb-autostart.log'
; Not as admin: it couldn't relaunch the bar anyway (AppStartAllowed, above, has said so).
if !A_IsAdmin
    SetTimer(YasbWatch, 5000)

YasbWatch() {
    global YasbSeen, YasbMisses, YasbRelaunches
    if ProcessExist('yasb.exe') {
        YasbSeen := true, YasbMisses := 0
        return
    }
    if !YasbSeen || ProcessExist('winget.exe') || YasbLauncherRunning() {
        YasbMisses := 0
        return
    }
    if (++YasbMisses < 2)
        return
    YasbMisses := 0
    while YasbRelaunches.Length && A_TickCount - YasbRelaunches[1] > 300000
        YasbRelaunches.RemoveAt(1)
    if (YasbRelaunches.Length >= 3) {
        SetTimer(YasbWatch, 0)
        YasbLog('watchdog: YASB died again after 3 relaunches in 5 min -- stopped relaunching until AHK restarts.')
        TrayTip('The bar keeps crashing -- stopped relaunching it.`nRun 710sRice doctor for what happened.', '710sRice')
        return
    }
    YasbRelaunches.Push(A_TickCount)
    YasbLog('watchdog: yasb.exe gone for 2 checks -- relaunching it (' YasbRelaunches.Length ' of 3 in 5 min).')
    if !StartBar('watchdog') {
        ; Windows PowerShell wouldn't start (ahk-autostart.log has the error) -- nothing sane
        ; to relaunch with.
        SetTimer(YasbWatch, 0)
        YasbLog("watchdog: couldn't start Start-Yasb.ps1 (ahk-autostart.log says why) -- watchdog off.")
        TrayTip("Couldn't relaunch the bar -- watchdog off.`nRun 710sRice doctor.", '710sRice')
    }
}

; Is a Start-Yasb.ps1 launcher already on the job? Only asked when yasb.exe is
; missing, so the WMI query costs nothing in the normal case.
YasbLauncherRunning() {
    try {
        for p in ComObjGet('winmgmts:').ExecQuery("SELECT ProcessId FROM Win32_Process WHERE (Name = 'powershell.exe' OR Name = 'pwsh.exe') AND CommandLine LIKE '%Start-Yasb.ps1%'")
            return true
    }
    return false
}

; Same line format as Start-Yasb.ps1's own Write-Log. UTF-8-RAW: the file already
; exists with its BOM (PS 5.1 Out-File), so no BOM mid-file.
YasbLog(m) {
    global YasbAutostartLog
    try FileAppend(FormatTime(, 'yyyy-MM-dd HH:mm:ss') '  ' m '`n', YasbAutostartLog, 'UTF-8-RAW')
}
