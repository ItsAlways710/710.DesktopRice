; Part of 710.ahk: Screens -- the Screens menu.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Screens (2026-10-05; the plan: claude\screens-plan.md in the project notes) -- every
; connected screen, from the bar's monitor button (a dropdown under the mouse) and
; SUPER+Alt+Space > Screens
; ============================================================================
; Each screen by its Windows name, the main one marked, whether it's on and at what scale; its
; submenu turns it off or back on and sets its scale (ScreenOff / ScreenOn / ScreenScale, below),
; and any scale change restarts the bar (CheckScreenScales). The menu reads a snapshot,
; %LOCALAPPDATA%\710.DesktopRice\screens.tsv, written by tools\screens.ps1 -Snapshot (the
; DisplayConfig module), instead of asking PowerShell on every open: a cold pwsh plus the module
; costs about a second. It's taken when this script starts and again 3 s after the last display
; or device change (ScheduleKomorebiNudge, above) -- a scale change arrives as a WM_DISPLAYCHANGE
; too (display-changes.log, Godzilla, 2026-10-04) -- so it's current by the time a menu opens.
ScreensFile := EnvGet('LOCALAPPDATA') '\710.DesktopRice\screens.tsv'
ScreensScales := Map()                       ; screen -> {scale, res} in the last snapshot (screens that are on)
ScreensRefreshing := false, ScreensRefreshAgain := false

; A new snapshot, then the scale check -- through RunThen (below), so nothing waits for it,
; startup included. One at a time: a change that lands meanwhile takes another one straight after.
RefreshScreens(*) {
    global RepoRoot, ScreensRefreshing, ScreensRefreshAgain
    if ScreensRefreshing {
        ScreensRefreshAgain := true
        return
    }
    ScreensRefreshing := true
    RunThen('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' RepoRoot '\tools\screens.ps1" -Snapshot', ScreensRefreshed, 30000)
}
ScreensRefreshed(code) {
    global ScreensRefreshing, ScreensRefreshAgain
    ScreensRefreshing := false
    if (code >= 0)                          ; it ran (1: written with an error line, which the check skips)
        CheckScreenScales()
    if ScreensRefreshAgain {
        ScreensRefreshAgain := false
        RefreshScreens()
    }
}
RefreshScreens()

; The bar restart on every display-scale change (decided with him 2026-10-04, after the scaling
; test: YASB redraws at the new scale, but the strip it reserves at the top keeps its old height,
; so windows ran under a bigger bar or stopped short of a smaller one; `710sRice reload bar` fixed
; it, SUPER+Shift+R didn't). Whether the change came from this menu or from Settings > Display, it
; arrives as a display change, so it's caught here: a screen that's on in this snapshot and the
; last one with a different scale -> tools\reload-stack.ps1 -BarOnly stops the bar (what `reload
; bar` runs too: it leaves the bar alone while komorebi is paused), then BarRestarted starts it
; again (StartBar: only this script starts the bar). YASB 2.0.7 does re-register its strip when a
; screen's geometry changes (bar.py, on_geometry_changed), but evidently before the new scale has
; reached it, and nothing outside YASB can ask it to do that again -- so, the restart. The first
; snapshot after this script starts has nothing to compare with. Only a change at the same
; resolution counts: Windows keeps a screen's scale relative to what it recommends for the
; resolution, so a game taking a screen to another resolution (exclusive fullscreen) moves the
; reading on its own -- and a bar restart mid-game is the last thing wanted.
CheckScreenScales() {
    global ScreensScales, RepoRoot
    r := ReadScreens()
    if (r.error != '' || r.waiting)
        return
    now := Map(), changed := ''
    for s in r.screens {
        if !s.on || s.scale = ''
            continue
        key := (s.path != '') ? s.path : s.name
        now[key] := {scale: s.scale, res: s.res}
        if !ScreensScales.Has(key)
            continue
        was := ScreensScales[key]
        if (was.scale != s.scale && was.res = s.res)
            changed .= (changed = '' ? '' : ', ') s.name ' ' was.scale '% -> ' s.scale '%'
    }
    ScreensScales := now
    if (changed = '')
        return
    DisplayLogLine('scale changed (' changed '): restarting the bar')
    TrayTip('Display scale changed -- restarting the bar', '710sRice')
    RunThen('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' RepoRoot '\tools\reload-stack.ps1" -BarOnly', BarRestarted, 120000)
}

; reload-stack.ps1 -BarOnly's answer: 3 = komorebi is paused, so it left the bar alone (a bar
; started then never connects to komorebi). Otherwise the bar is started again here, whatever
; the stop said: StartBar does nothing when one is still up.
BarRestarted(code) {
    if (code = 3) {
        DisplayLogLine('bar left alone: komorebi is paused')
        TrayTip('komorebi is paused, so the bar was left alone -- unpause (SUPER+P), then: 710sRice reload bar', '710sRice')
        return
    }
    if (code != 0)
        TrayTip("The bar didn't restart cleanly -- reload-stack.log says why; 710sRice reload bar tries again", '710sRice')
    StartBar('scale change')
}

; The snapshot as {screens: [{id, name, path, res, on, main, scale, steps}], error, waiting}; the file's
; format is in tools\screens.ps1's header. waiting: there's no snapshot yet (this script started
; a moment ago and the first one is still being taken).
ReadScreens() {
    global ScreensFile
    r := {screens: [], error: '', waiting: false}
    if !FileExist(ScreensFile) {
        r.waiting := true
        return r
    }
    try text := FileRead(ScreensFile, 'UTF-8')
    catch {
        r.error := "Couldn't read the screens snapshot (screens.tsv)"
        return r
    }
    for line in StrSplit(text, '`n', '`r') {
        if (line = '')
            continue
        if (SubStr(line, 1, 1) = '#') {
            if RegExMatch(line, ' error: (.*)$', &m)
                r.error := m[1]
            continue
        }
        f := StrSplit(line, '`t')
        if (f.Length < 6)
            continue
        ; v2 adds the screen's device path after its name; a v1 file (until the first snapshot
        ; after an update) has none, and its screens can't be switched yet.
        path := (f.Length >= 7) ? f[7] : ''
        res := (f.Length >= 8) ? f[8] : ''
        name := f[6]
        steps := []
        for s in StrSplit(f[5], ',')
            if IsInteger(s)
                steps.Push(Integer(s))
        r.screens.Push({id: f[1], on: (f[2] = '1'), main: (f[3] = '1'), scale: f[4], steps: steps, path: path, res: res, name: name})
    }
    return r
}

; One row per screen, its state on the right ("on · 150%" / "off"). Its submenu: Turn off and
; the scales Windows allows it, the current one marked; for a screen that's off, Turn on (Windows
; only scales a screen that's on). The main display has no Turn off: it always stays on (his
; rule, 2026-10-05; Settings > Display chooses which screen is main). A name two screens share
; gets the screen's number after it, so both menus can tell them apart (the tray's native menu
; would merge two items with the same name). Something wrong (DisplayConfig missing, or it
; threw) is one short row -- the whole message wouldn't fit -- and choosing it shows the message.
ScreensMenuItems() {
    r := ReadScreens()
    items := []
    if r.waiting
        items.Push({text: 'Still reading your screens', hint: 'in a moment', action: (*) => 0})
    if (r.error != '') {
        err := r.error
        items.Push({text: "Couldn't read your screens", hint: 'details', action: (*) => TrayTip(err, '710sRice')})
    }
    seen := Map()
    for s in r.screens
        seen[s.name] := seen.Has(s.name) ? seen[s.name] + 1 : 1
    for s in r.screens {
        name := s.name (seen[s.name] > 1 ? ' #' s.id : '') (s.main ? ' (main)' : '')
        state := s.on ? 'on' (s.scale != '' ? ' ' Chr(0xB7) ' ' s.scale '%' : '') : 'off'
        sub := []
        if (s.path != '') {
            if !s.on
                sub.Push({text: 'Turn on', action: ScreenOn.Bind(s, name)})
            else {
                if !s.main
                    sub.Push({text: 'Turn off', action: ScreenOff.Bind(s, name, false)})
                for pct in s.steps
                    sub.Push({text: 'Scale ' pct '%', hint: (pct = s.scale ? 'current' : ''), action: ScreenScale.Bind(s, name, pct)})
            }
        }
        if sub.Length
            items.Push({text: name, hint: state, sub: sub})
        else
            items.Push({text: name, hint: state, action: (*) => 0})
    }
    if !items.Length
        items.Push({text: 'No screens found', action: (*) => 0})
    return items
}

; The bar's monitor button runs config\ahk\send-command.ahk screens (RiceCommands, below). Opened
; again while it's showing, it closes, like the other menus.
OpenScreensMenu(*) {
    if !PalClosed('screens')
        PalOpen('screens', ScreensMenuItems(), 'Screens', true)
}

; Turning a screen off or on runs tools\screens.ps1 -Off / -On (DisplayConfig: Windows' own
; "Disconnect this display" / "Extend desktop to this display"). The screen goes by its device
; path, in the environment -- never on a command line, like Quick add's values -- since
; DisplayConfig's numbers can change as screens come and go. Each action costs a cold pwsh (a
; second or two), so a tooltip says what's happening meanwhile; one at a time. The display-change
; hook (above) takes a new snapshot once Windows has settled, so the next menu shows the change.
ScreensBusy := false

; Runs cmd hidden and calls done(its exit code) once it has finished, without waiting for it: a
; RunWait holds up its own thread and, on a timer's thread, whichever thread the timer
; interrupted too -- startup included. done gets -1 when cmd couldn't start, and -2 when it was
; still running after timeoutMs (it's stopped then).
RunThen(cmd, done, timeoutMs := 60000) {
    try Run(cmd, , 'Hide', &pid)
    catch {
        done(-1)
        return
    }
    ; A handle keeps its exit code, and keeps the process id from going to another process.
    h := DllCall('OpenProcess', 'UInt', 0x1000, 'Int', false, 'UInt', pid, 'Ptr')   ; PROCESS_QUERY_LIMITED_INFORMATION
    started := A_TickCount
    Check() {
        code := 259                         ; STILL_ACTIVE
        if h
            DllCall('GetExitCodeProcess', 'Ptr', h, 'UInt*', &code)
        else if !ProcessExist(pid)
            code := 0                       ; gone before it could be opened: no code to read
        if (code = 259) {
            if (A_TickCount - started < timeoutMs)
                return
            try ProcessClose(pid)
            code := -2
        }
        SetTimer(Check, 0)
        if h
            DllCall('CloseHandle', 'Ptr', h)
        done(code)
    }
    SetTimer(Check, 250)
}

; Runs the helper for screen s (args: -Off, -Off -Anyway, -On, -Scale <pct>), then done(its exit
; code).
ScreensRun(s, args, done) {
    global RepoRoot
    EnvSet('SCREENS_PATH', s.path)          ; the helper takes it as it starts
    RunThen('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' RepoRoot '\tools\screens.ps1" ' args, done)
    EnvSet('SCREENS_PATH')
}

; What the helper said (screens-result.txt), as lines -- the first one says what happened.
ScreensResult() {
    try return StrSplit(RTrim(FileRead(EnvGet('LOCALAPPDATA') '\710.DesktopRice\screens-result.txt', 'UTF-8'), '`r`n'), '`n', '`r')
    return ["The screens helper didn't say what happened"]
}

; How a helper run ended, when that needs saying: what it reported, or why it didn't.
ScreensToast(code) {
    if (code = -1)
        TrayTip("Couldn't start the screens helper (pwsh)", '710sRice')
    else if (code = -2)
        TrayTip("The screens helper didn't finish within a minute, so it was stopped", '710sRice')
    else if (code > 0)                      ; 1 failed, 4 refused (main / the only one on), 5 gone, 6 placed by Windows
        TrayTip(ScreensResult()[1], '710sRice')
}

; Turn off: at once when komorebi has no windows on that screen; otherwise ScreenOffWarn lists
; them first. anyway (its "Turn it off anyway") skips that check.
ScreenOff(s, name, anyway, *) {
    global ScreensBusy
    if ScreensBusy
        return
    ScreensBusy := true
    ToolTip('Turning off ' name '...')
    ScreensRun(s, '-Off' (anyway ? ' -Anyway' : ''), ScreenOffDone.Bind(s, name))
}
ScreenOffDone(s, name, code) {
    global ScreensBusy
    ToolTip()
    ScreensBusy := false
    if (code = 3)
        ScreenOffWarn(s, name)
    else
        ScreensToast(code)
}

ScreenOn(s, name, *) {
    global ScreensBusy
    if ScreensBusy
        return
    ScreensBusy := true
    ToolTip('Turning on ' name '...')
    ScreensRun(s, '-On', ScreensActionDone)
}
; How Turn on and a new scale end.
ScreensActionDone(code) {
    global ScreensBusy
    ToolTip()
    ScreensBusy := false
    ScreensToast(code)
}

; A new scale; CheckScreenScales restarts the bar once Windows reports the change.
ScreenScale(s, name, pct, *) {
    global ScreensBusy
    if ScreensBusy || (pct = s.scale)
        return
    ScreensBusy := true
    ToolTip('Scaling ' name ' to ' pct '%...')
    ScreensRun(s, '-Scale ' pct, ScreensActionDone)
}

; komorebi still has windows on the screen being turned off, on some workspace of it: off, they'd
; be left on a screen that's gone -- reachable only from the taskbar or Alt+Tab. So it asks (his
; design, 2026-10-05): Cancel first, so Enter and Esc both back out to move them; "Turn it off
; anyway" second; then the windows, each with its workspace (choosing one is Cancel too).
ScreenOffWarn(s, name) {
    lines := ScreensResult()
    wins := []
    loop lines.Length - 1 {
        f := StrSplit(lines[A_Index + 1], '`t')
        if (f.Length < 3)
            continue
        app := RegExReplace(f[2], 'i)\.exe$')
        wins.Push({text: app (f[3] != '' ? ' ' Chr(0xB7) ' ' f[3] : ''), hint: 'workspace ' f[1], action: (*) => 0})
    }
    n := wins.Length
    items := [{text: 'Cancel', hint: (n ? 'move them first' : ''), action: (*) => 0},
        {text: 'Turn it off anyway', action: ScreenOff.Bind(s, name, true)}]
    if n
        items.Push(wins*)
    else                                    ; komorebi didn't answer: say so instead of a list
        items.Push({text: lines[1], action: (*) => 0})
    PalOpen('screens', items, 'Turn off ' name '?' (n ? ' ' n (n = 1 ? ' window is' : ' windows are') ' still on it' : ''))
}
