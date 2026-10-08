; Part of 710.ahk: Scrolling beside another screen -- SUPER+Alt+L's check, and the switch to Columns.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Scrolling beside another screen
; ============================================================================
; komorebi's Scrolling layout puts the columns that scroll off one side of a screen on the screen
; next to it there (Godzilla, 2026-10-04: the main TV's columns landed on the TV to its left;
; Monitor 3, with nothing beside it, was fine). komorebi (0.1.41; master the same, 2026-10-08)
; only checks when it loads its config and in its own change-layout command, and both just count
; screens; workspace-layout, what SUPER+Alt+L sends, doesn't check at all.
; His rule (2026-10-06, its shape 2026-10-08): Scrolling only on a screen with no other screen to
; its left or right -- their heights overlapping at all; one above or below doesn't count. Only
; SUPER+Alt+L checks before it switches; the bar's layout button and SUPER+Shift+L stay YASB's and
; komorebi's own, unchecked (his call). For a screen that gets a neighbour later,
; tools\scrolling-rule.ps1 switches its Scrolling workspaces to Columns: run from here once a
; display change has settled, and by scripts\Start-Komorebi.ps1 after every komorebi start.

; Flips the FOCUSED workspace between Scrolling (2 columns) and bsp -- asks
; komorebi what you're standing on and what it's currently running, so it
; works identically on workspace 3 or C, and doesn't touch anything you're
; not looking at. Promoted here from the user's personal user.ahk override --
; this is a real, daily-used feature, not a per-machine tweak, so it belongs
; in the tracked dispatcher rather than the gitignored override file.
; Leaving Scrolling always works; going to it, on a screen with another beside it, is a toast
; saying why, and the layout stays as it is.
ToggleScrolling() {
    global KomorebicExe
    mon := QueryKomorebic('query focused-monitor-index')
    ws := QueryKomorebic('query focused-workspace-index')
    layout := QueryKomorebic('query focused-workspace-layout')
    if (StrLower(layout) = 'scrolling') {
        Run('"' KomorebicExe '" workspace-layout ' mon ' ' ws ' bsp', , 'Hide')
    } else if ScreenHasSideNeighbour(mon) {
        TrayTip("No Scrolling on this screen: there's another screen beside it, and komorebi would put the windows that scroll off this one on it", '710sRice')
    } else {
        Run('"' KomorebicExe '" workspace-layout ' mon ' ' ws ' scrolling', , 'Hide')
        Run('"' KomorebicExe '" scrolling-layout-columns 2', , 'Hide')
    }
}

; Does komorebi's screen `mon` (its index, 0 first) have another screen to its left or right --
; their heights overlapping at all? One above or below doesn't count. tools\scrolling-rule.ps1
; has the same test (Test-SideNeighbour). komorebi's own rectangles for every screen, never mixed
; with AutoHotkey's MonitorGet numbers. A read that fails answers no, so the key keeps working,
; and says so in display-changes.log.
ScreenHasSideNeighbour(mon) {
    if !IsInteger(mon)
        return false
    rects := KomorebiScreenRects(QueryKomorebic('monitor-information'))
    if (mon + 1 > rects.Length) {
        DisplayLogLine("SUPER+Alt+L: couldn't read komorebi's screens -- Scrolling allowed")
        return false
    }
    me := rects[mon + 1]
    for i, r in rects
        if (i != mon + 1 && r.top < me.top + me.height && me.top < r.top + r.height)
            return true
    return false
}

; komorebic monitor-information's answer (a JSON list, in komorebi's screen order) as
; [{left, top, width, height}], one per screen, from its `size`: left and top, then right and
; bottom, which in komorebi's Rect are the WIDTH and the HEIGHT (komorebi-layouts rect.rs), not
; edges. [] when there's no screen in it, or one is missing a number.
KomorebiScreenRects(json) {
    rects := [], pos := 1
    while (pos := RegExMatch(json, 's)"size"\s*:\s*\{(.*?)\}', &m, pos)) {
        n := Map()
        for f in ['left', 'top', 'right', 'bottom'] {
            if !RegExMatch(m[1], '"' f '"\s*:\s*(-?\d+)', &v)
                return []
            n[f] := Integer(v[1])
        }
        rects.Push({left: n['left'], top: n['top'], width: n['right'], height: n['bottom']})
        pos += m.Len
    }
    return rects
}

; Once a display change has settled -- monitor-watcher.ahk calls this 2 s after its 8 s nudge, so
; komorebi has recounted -- tools\scrolling-rule.ps1 has its look: only when komorebi's screens
; differ from the ones it saw last time, every workspace in Scrolling on a screen that now has
; another beside it goes to Columns. Through RunThen (screens.ahk), so nothing waits for it; one
; at a time, and a change that lands meanwhile gets another look straight after.
ScrollingRuleRunning := false, ScrollingRuleAgain := false
ScrollingRuleAfterChange(*) {
    global RepoRoot, ScrollingRuleRunning, ScrollingRuleAgain
    if ScrollingRuleRunning {
        ScrollingRuleAgain := true
        return
    }
    ScrollingRuleRunning := true
    RunThen('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' RepoRoot '\tools\scrolling-rule.ps1"', ScrollingRuleDone, 60000)
}
ScrollingRuleDone(code) {
    global ScrollingRuleRunning, ScrollingRuleAgain
    ScrollingRuleRunning := false
    if (code = 10)                          ; it switched at least one: scrolling-rule.txt says which
        ScrollingSwitchedToast()
    if ScrollingRuleAgain {
        ScrollingRuleAgain := false
        ScrollingRuleAfterChange()
    }
}

; The toast, from what the helper wrote. After a komorebi start, Start-Komorebi.ps1's run of it asks
; for the toast with '710sRice.ScrollingSwitched' (a 710.ahk from before this part ignores that
; message; the switch is in display-changes.log either way).
ScrollingSwitchedToast(*) {
    try text := Trim(FileRead(EnvGet('LOCALAPPDATA') '\710.DesktopRice\scrolling-rule.txt', 'UTF-8'), " `t`r`n")
    catch
        return
    if (text != '')
        TrayTip(text, '710sRice')
}
OnMessage(AllowFromNormalProcesses(DllCall('RegisterWindowMessage', 'Str', '710sRice.ScrollingSwitched', 'UInt')), (*) => SetTimer(ScrollingSwitchedToast, -1))
