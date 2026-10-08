; Part of 710.ahk: komorebi's monitor watcher -- a second look after every display change.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; komorebi's monitor watcher: a second look after every display change
; ============================================================================
; komorebi (0.1.41 -- and upstream's master is the same, read 2026-10-01) recounts the screens the
; moment Windows says "a device changed", which is often before Windows has finished rearranging the
; desktop: it sees the old count, decides the counts match, and does nothing. The "display changed"
; message that follows only makes it update sizes, never recount. So an unplugged monitor stays in
; komorebi's state (a pinned window opens on a screen that isn't there -- reachable only from the
; taskbar, not Alt+Tab) and one plugged back in never gets its workspaces and pins back. The Dell's
; pin re-test (2026-10-01): komorebi missed two unplugs out of two; one more WM_DEVICECHANGE /
; DBT_DEVNODES_CHANGED posted to its watcher window (class komorebi-hidden) and it had removed the
; screen 3 s later, then restored it from its cache on the plug-in.
; So: 3 s after the last display or device change -- each new one restarts the wait -- and once
; more 5 s after that, we post komorebi that same message. Counts unchanged: komorebi does nothing.
; komorebi runs elevated; posting to it works because 710.ahk runs with UI Access. One line per
; nudge in display-changes.log (710sRice logs), capped at 256 KB (then .old).
DisplayLog := EnvGet('LOCALAPPDATA') '\710.DesktopRice\display-changes.log', NudgeWhy := ''
OnMessage(AllowFromNormalProcesses(0x7E), (*) => ScheduleKomorebiNudge('display changed'))                           ; WM_DISPLAYCHANGE
OnMessage(AllowFromNormalProcesses(0x219), (wParam, *) => (wParam = 7 ? ScheduleKomorebiNudge('devices changed') : ''))  ; WM_DEVICECHANGE, DBT_DEVNODES_CHANGED

ScheduleKomorebiNudge(why) {
    global NudgeWhy := why
    SetTimer(KomorebiNudgeFirst, -3000)     ; a new change restarts the wait
    SetTimer(RefreshScreens, -3000)         ; the Screens menu's snapshot, the same wait (Screens, below)
}
KomorebiNudgeFirst() {
    NudgeKomorebi('3 s')
    SetTimer(KomorebiNudgeSecond, -5000)
}
KomorebiNudgeSecond() => NudgeKomorebi('8 s')

NudgeKomorebi(after) {
    global NudgeWhy
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)               ; its watcher window is never shown
    try {
        PostMessage(0x219, 7, 0, , 'ahk_class komorebi-hidden')
        result := 'komorebi asked to recount the screens'
    } catch TargetError {
        result := "komorebi isn't running -- nothing to ask"
    } catch as e {
        result := "couldn't reach komorebi's monitor watcher: " e.Message
    }
    DetectHiddenWindows(prev)
    DisplayLogLine(NudgeWhy ', ' after ' later: ' result)
}

DisplayLogLine(m) {
    global DisplayLog
    try {
        if FileExist(DisplayLog) && FileGetSize(DisplayLog) > 262144
            FileMove(DisplayLog, DisplayLog '.old', 1)
        FileAppend(FormatTime(, 'yyyy-MM-dd HH:mm:ss') '  ' m '`n', DisplayLog, 'UTF-8-RAW')
    }
}
