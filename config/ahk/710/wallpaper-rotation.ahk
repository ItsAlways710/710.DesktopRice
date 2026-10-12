; Part of 710.ahk: Wallpaper rotation -- a random wallpaper on a clock you set.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Wallpaper rotation
; ============================================================================
; (2026-10-12; the plan: claude\wallpaper-rotation-plan.md in the project notes) A new random
; wallpaper every 15 or 30 minutes, every hour, 4 hours, 24 hours or week -- or never, the
; default -- from the gallery's own folders, each change a full re-theme like a gallery pick:
; tools\rotate-wallpaper.ps1 picks one, sets it and runs the pipeline. The menu: middle-click on
; the bar's wallpaper button (config\yasb\config.yaml's on_middle runs send-command.ahk
; wallpaper-rotation: RiceCommands, main-menu.ahk), or SUPER+Ctrl+Alt+W below.
;
; Ours, not YASB's own change_automatically / update_interval: YASB reads those once, as the bar
; starts, so changing them would mean a bar restart; its countdown starts over at every bar
; restart (a scale change, `reload bar`, a sign-in); and it can't wait out a game. config.yaml is
; tracked, too: a per-machine value could only ride in an $env: string, and an unset one reaches
; YASB's check as "" -- the bar won't load.
;
; A fixed clock (his call): only turning it on, or picking an interval -- the one in use too --
; starts it over. A wallpaper picked by hand (the gallery, right-click, Windows Settings) or a
; palette-profile switch never moves the next change. The next change's time is saved
; (wallpaper-rotation.ini in the logs folder), so reloads, bar restarts and reboots keep the
; schedule. One that comes due while the PC is off or asleep, 710sRice isn't running, or it's
; held (below) happens once it can, and the clock carries on from where it was: never a burst of
; catch-ups. Local time, so a daily or weekly change keeps its time of day across a DST change
; (DateAdd is plain calendar arithmetic).
;
; Held -- tried again each minute -- while game mode is on (GameWatch: the switch, a games.toml /
; [[game]] exe, or the focused window fullscreen on a screen, a video or a slideshow included),
; Flow is open (every theme run restarts Flow: it would vanish mid-search), a palette-profile
; switch is running, or this script runs as admin (the pipeline's Flow restart asks here, and an
; admin 710.ahk starts nothing). Only the focused window counts: a fullscreen video on another
; screen doesn't hold it -- the change lands behind the video (his OK, 2026-10-12).
WallpaperRotationIni := EnvGet('LOCALAPPDATA') '\710.DesktopRice\wallpaper-rotation.ini'
WallpaperRotationLogFile := EnvGet('LOCALAPPDATA') '\710.DesktopRice\wallpaper-rotation.log'
WallpaperRotationSteps := [15, 30, 60, 240, 1440, 10080]   ; the menu's intervals, in minutes
WallpaperRotationBusy := false        ; a change is running
WallpaperRotationHeldFor := ''        ; why the change that's due is waiting (logged once)
WallpaperRotationWarned := false      ; a failed change has said so (once, until one works)
WallpaperRotationDrop := false        ; the menu came from the bar: it drops down under it

; The first look waits 3 minutes -- at sign-in the bar, Flow and ShareX are still coming up, and a
; change's theme run restarts Flow -- then it's once a minute.
SetTimer(WallpaperRotationStart, -180000)
WallpaperRotationStart() {
    WallpaperRotationTick()
    SetTimer(WallpaperRotationTick, 60000)
}

#^!w::OpenWallpaperRotation()         ; wallpaper rotation: on or off, and how often

; The menu. Opened again while it's showing, it closes, like the other menus.
OpenWallpaperRotation(dropDown := false, *) {
    global WallpaperRotationDrop
    if PalClosed('wallpaper-rotation')
        return
    WallpaperRotationDrop := dropDown
    WallpaperRotationMenu()
}

; Row 1 turns it on or off, with the time to the next change beside it while it's on; then,
; while it's on, the intervals, the one in use marked. sel: the row to start on.
WallpaperRotationMenu(sel := 0) {
    global WallpaperRotationSteps, WallpaperRotationDrop
    s := WallpaperRotationRead()
    items := [{text: 'Auto-apply random wallpaper ' Chr(0xB7) ' ' (s.on ? 'on' : 'off'),
        hint: (s.on ? WallpaperRotationNextText(s.next) : ''), action: WallpaperRotationToggle}]
    if s.on
        for m in WallpaperRotationSteps
            items.Push({text: WallpaperRotationStepText(m), hint: (m = s.minutes ? 'current' : ''),
                action: WallpaperRotationPick.Bind(m)})
    PalOpen('wallpaper-rotation', items, 'Wallpaper rotation', WallpaperRotationDrop, sel)
}

; Off: off, and a toast says so. On: the interval last used (an hour the first time), the clock
; started now, and the menu again, on that interval -- Enter or a click keeps it (and starts the
; clock again), another row picks that one, Esc leaves it as it is.
WallpaperRotationToggle(*) {
    global WallpaperRotationSteps
    s := WallpaperRotationRead()
    if s.on {
        WallpaperRotationSave(false, s.minutes, '')
        WallpaperRotationLog('turned off')
        TrayTip('Wallpaper rotation: off', '710sRice')
        return
    }
    next := DateAdd(A_Now, s.minutes, 'Minutes')
    WallpaperRotationSave(true, s.minutes, next)
    WallpaperRotationLog('turned on: ' StrLower(WallpaperRotationStepText(s.minutes)) ', next ' FormatTime(next, 'yyyy-MM-dd HH:mm'))
    for i, m in WallpaperRotationSteps
        if (m = s.minutes)
            return WallpaperRotationMenu(i + 1)       ; row 1 is the on / off row
    WallpaperRotationMenu()
}

; An interval: set, and the clock starts again from now -- the one in use too.
WallpaperRotationPick(minutes, *) {
    next := DateAdd(A_Now, minutes, 'Minutes')
    WallpaperRotationSave(true, minutes, next)
    text := StrLower(WallpaperRotationStepText(minutes))
    WallpaperRotationLog('set to ' text ', next ' FormatTime(next, 'yyyy-MM-dd HH:mm'))
    TrayTip('Wallpaper rotation: ' text, '710sRice')
}

; Once a minute: a change when one is due and nothing holds it. The clock moves on before the
; change starts, so one that fails isn't tried again every minute -- the next comes at the next
; time on the clock.
WallpaperRotationTick() {
    global RepoRoot, WallpaperRotationBusy, WallpaperRotationHeldFor
    s := WallpaperRotationRead()
    if !s.on || WallpaperRotationBusy || DateDiff(A_Now, s.next, 'Seconds') < 0
        return
    if (why := WallpaperRotationHeld()) {
        if (why != WallpaperRotationHeldFor)
            WallpaperRotationLog('due, waiting: ' why)
        WallpaperRotationHeldFor := why
        return
    }
    WallpaperRotationHeldFor := ''
    next := WallpaperRotationAfter(s.next, s.minutes, A_Now)
    WallpaperRotationSave(true, s.minutes, next)
    WallpaperRotationBusy := true
    WallpaperRotationLog('changing (then next ' FormatTime(next, 'yyyy-MM-dd HH:mm') ')')
    RunThen('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' RepoRoot '\tools\rotate-wallpaper.ps1"', WallpaperRotationDone, 180000)
}

; Why a change that's due has to wait, or '' when it doesn't.
WallpaperRotationHeld() {
    global GameModeActive, GameFlag, PaletteSwitching
    if A_IsAdmin
        return '710.ahk is running as admin'
    if GameModeActive || FileExist(GameFlag)
        return 'game mode'
    if (FlowState().state = 'shown')
        return 'Flow is open'
    if PaletteSwitching
        return 'a palette profile switch'
    return ''
}

; The first time on the clock after now: the saved one, a whole number of intervals on -- one
; change for however many were missed.
WallpaperRotationAfter(next, minutes, now) {
    late := DateDiff(now, next, 'Seconds')
    return (late < 0) ? next : DateAdd(next, (late // (minutes * 60) + 1) * minutes, 'Minutes')
}

; What the change script said (its exit codes: tools\rotate-wallpaper.ps1). 0-2: the wallpaper
; changed (1: it wasn't themed -- wallust's own failure gets its toast from the pipeline; 2: an
; app couldn't be themed, which doctor names, same as after a gallery pick). Anything else says
; so once, until a change works again.
WallpaperRotationDone(code) {
    global WallpaperRotationBusy, WallpaperRotationWarned
    WallpaperRotationBusy := false
    WallpaperRotationLog('change done: exit ' code)
    if (code >= 0 && code <= 2) {
        WallpaperRotationWarned := false
        return
    }
    if WallpaperRotationWarned
        return
    WallpaperRotationWarned := true
    switch code {
        case 3: msg := "no other wallpaper to change to -- the gallery's folders have only the one that's up"
        case 4: msg := "Windows didn't take the new wallpaper"
        case -1: msg := "PowerShell 7 couldn't be started"
        case -2: msg := 'a change ran over 3 minutes and was stopped'
        default: msg := 'a change failed (exit ' code ')'
    }
    TrayTip('Wallpaper rotation: ' msg '. It tries again at the next change; wallpaper-rotation.log (710sRice logs) has more.', '710sRice')
}

; The saved choice: on or off, the interval in minutes (the last one used; an hour until one's
; picked), and while it's on, the next change's time (YYYYMMDDHH24MISS, local). Anything that
; won't read falls back: off, an hour -- and on with no time, a clock started now.
WallpaperRotationRead() {
    global WallpaperRotationIni, WallpaperRotationSteps
    on := false, minutes := 60, next := ''
    try {
        on := (IniRead(WallpaperRotationIni, 'rotation', 'on', '0') = '1')
        m := IniRead(WallpaperRotationIni, 'rotation', 'minutes', '60')
        for step in WallpaperRotationSteps
            if (m = step)
                minutes := step
        next := IniRead(WallpaperRotationIni, 'rotation', 'next', '')
    } catch as e
        WallpaperRotationLog("couldn't read the choice: " e.Message)
    if on && !(StrLen(next) = 14 && IsTime(next)) {
        next := DateAdd(A_Now, minutes, 'Minutes')
        WallpaperRotationSave(true, minutes, next)
    }
    return {on: on, minutes: minutes, next: next}
}

WallpaperRotationSave(on, minutes, next) {
    global WallpaperRotationIni
    try {
        DirCreate(EnvGet('LOCALAPPDATA') '\710.DesktopRice')
        IniWrite(on ? 1 : 0, WallpaperRotationIni, 'rotation', 'on')
        IniWrite(minutes, WallpaperRotationIni, 'rotation', 'minutes')
        IniWrite(next, WallpaperRotationIni, 'rotation', 'next')
    } catch as e
        WallpaperRotationLog("couldn't save the choice: " e.Message)
}

WallpaperRotationStepText(m) {
    if (m = 60)
        return 'Every hour'
    if (m = 10080)
        return 'Every week'
    return (m > 60) ? 'Every ' (m // 60) ' hours' : 'Every ' m ' minutes'
}

; "next in 42 min" / "next in 3 h 10 min" / "next in 2 days 4 h"; "due now" while a change that's
; due waits (held, or the first look after a start hasn't come yet).
WallpaperRotationNextText(next) {
    s := DateDiff(next, A_Now, 'Seconds')
    if (s <= 0)
        return 'due now'
    m := (s + 59) // 60                   ; whole minutes, rounded up: never "next in 0 min"
    if (m < 60)
        return 'next in ' m ' min'
    if (m < 1440)
        return 'next in ' (m // 60) ' h' (Mod(m, 60) ? ' ' Mod(m, 60) ' min' : '')
    d := m // 1440, h := Mod(m, 1440) // 60
    return 'next in ' d (d = 1 ? ' day' : ' days') (h ? ' ' h ' h' : '')
}

; The change script's own line format (it keeps the file under 1 MB, every log's rule); this side
; adds a line now and then.
WallpaperRotationLog(m) {
    global WallpaperRotationLogFile
    try FileAppend(FormatTime(, 'yyyy-MM-dd HH:mm:ss') '  710.ahk: ' m '`n', WallpaperRotationLogFile, 'UTF-8-RAW')
}
