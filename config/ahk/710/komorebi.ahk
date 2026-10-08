; Part of 710.ahk: komorebi -- Komorebic() and the helpers the keys and menus use (SUPER+Alt+L's in scrolling.ahk).
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; komorebi
; ============================================================================
; Full path, not relying on inherited PATH (AHK can start before komorebi's
; installed) -- same pattern winarchy itself uses for KomorebicExe.
KomorebicExe := FileExist(A_ProgramFiles "\komorebi\bin\komorebic.exe")
    ? A_ProgramFiles "\komorebi\bin\komorebic.exe"
    : "komorebic.exe"

; Synchronous query helper -- Run(...,'Hide') is fire-and-forget, this reads
; komorebic's actual stdout back via a tempfile. Promoted from the user's own
; config\ahk\user.ahk override on winarchy (not from winarchy.ahk itself --
; this was the user's personal addition on top of winarchy's defaults).
QueryKomorebic(args) {
    global KomorebicExe
    tempFile := A_Temp '\komorebic_' A_TickCount '.txt'
    inner := '"' KomorebicExe '" ' args ' > "' tempFile '"'
    RunWait(A_ComSpec ' /c "' inner '"', , 'Hide')
    result := FileExist(tempFile) ? Trim(FileRead(tempFile), " `t`r`n") : ''
    try FileDelete(tempFile)
    return result
}

Komorebic(cmd) {
    global KomorebicExe
    Run('"' KomorebicExe '" ' cmd, , 'Hide')
}

; Launches a program and then forces its NEW top-level window onto whichever
; monitor the mouse cursor is actually on. Windows' own default placement for
; an unpositioned window ignores komorebi's focus state entirely (confirmed
; by reading this file's old bare #Enter binding plus Windows Terminal's own
; settings.json/state.json -- neither targets a monitor; see
; claude/winarchy-decoupling-plan.md, New-window placement section), so this
; corrects it explicitly after the fact instead of trusting Windows to guess
; right.
; "New" is the point: it snapshots the windows matching winCriteria before the
; launch and only acts on one that wasn't there. A plain WinWait takes ANY
; match, so with a Terminal already open it returned at once and sent whatever
; komorebi had focused to the monitor (Open item 42). The short settle lets
; komorebi pick the new window up first -- move-to-monitor acts on komorebi's
; focused window, not on an hwnd. timeoutMs is a ceiling, not a delay: the poll
; stops the moment the window shows up. Nothing new in time (slow start, or
; Terminal set to open tabs in an existing window) = no move, nothing disturbed.
; A launch that throws (a cancelled UAC prompt, for one) = nothing to place.
LaunchOnCursorMonitor(target, winCriteria, timeoutMs := 3000) {
    global KomorebicExe
    Komorebic('focus-monitor-at-cursor')
    mon := QueryKomorebic('query focused-monitor-index')
    before := Map()
    for hwnd in WinGetList(winCriteria)
        before[hwnd] := true
    try Run(target)
    catch
        return
    deadline := A_TickCount + timeoutMs
    while (A_TickCount < deadline) {
        for hwnd in WinGetList(winCriteria) {
            if !before.Has(hwnd) {
                try WinActivate(hwnd)
                Sleep(200)
                Run('"' KomorebicExe '" move-to-monitor ' mon, , 'Hide')
                return
            }
        }
        Sleep(100)
    }
}

; SUPER+Alt+Enter: an ADMIN Windows Terminal, on purpose. `*RunAs` means a UAC
; prompt every time -- by design, elevation stays a choice you make per launch --
; and AHK itself stays non-elevated (UI Access), so nothing else it starts is admin.
; Placement is LaunchOnCursorMonitor() with 30s instead of 3s, to give you time
; to answer the prompt. Elevated tiling (install.ps1's default): komorebi tiles
; it and moves it to the cursor's monitor. -NoElevatedTiling: komorebi can't
; touch an admin window, so it floats wherever Windows put it and the move is a
; harmless no-op. Cancelling UAC makes Run throw -- nothing opened, nothing to place.
LaunchAdminTerminal() {
    LaunchOnCursorMonitor('*RunAs wt.exe', 'ahk_class CASCADIA_HOSTING_WINDOW_CLASS', 30000)
}

; Close the window that's actually in front of you: WM_CLOSE straight to the
; active window -- the same message clicking its X sends, so "save changes?"
; prompts still happen. Ported from winarchy bb72240 (v1.5.0), which dropped
; `komorebic close` for this: no komorebic.exe spawn per press, and it doesn't
; depend on komorebi's idea of focus, which can lag behind for windows it
; ignores or floats (games, Flow, anything in the ignore rules). Refuses the
; desktop, both taskbars and the YASB bar, so a stray SUPER+Q there is a no-op.
CloseWindow() {
    if !(hwnd := WinExist('A'))
        return
    try {
        if WinGetClass(hwnd) ~= '^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd)$'
            || WinGetProcessName(hwnd) = 'yasb.exe'
            return
        PostMessage(0x0010, 0, 0, , hwnd)   ; WM_CLOSE
    }
}

; SUPER+Ctrl+C: redraw the focused app (plan doc Open item 40). A bar restart moves the bar's screen strip, and a
; Chromium / Electron app (Chrome, the Claude desktop app, Discord...) can come back drawing a row low -- an extra
; title bar on top, every click a row off -- until it's relaunched. What's stuck is the app's drawing helper, its
; --type=gpu-process child: end just that one and Chromium starts a fresh helper and redraws in place; the app itself
; never closes (proven on the Dell 2026-10-02 with Stop-Process; this ends it the same way, TerminateProcess with
; exit code -1). The focused app only, on purpose. Chromium puts an app on slow software drawing after three helper
; losses close together (it forgives one every 5 minutes): a now-and-then key, not a reflex.
RedrawApp() {
    try exe := WinGetProcessName('A')
    catch {
        TrayTip("Couldn't tell which app is focused", '710sRice')
        return
    }
    r := EndGpuHelpers(exe)
    if r.ended
        TrayTip('Redrawing ' exe, '710sRice')
    else if r.failed
        TrayTip("Couldn't restart " exe "'s drawing helper (is it running as admin?)", '710sRice')
    else
        TrayTip(exe ' has no drawing helper to restart -- not a Chromium app', '710sRice')
}

; Ends every --type=gpu-process process named `exe`; returns {ended, failed}. Kept apart from RedrawApp so it can be
; tested without a focused window.
EndGpuHelpers(exe) {
    ended := 0, failed := 0
    if (exe = '' || InStr(exe, "'"))            ; the name goes into a WQL string
        return {ended: 0, failed: 0}
    for p in ComObjGet('winmgmts:').ExecQuery("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = '" exe "'") {
        cmd := ''
        try cmd := p.CommandLine                ; empty / null for a process we can't read (an admin one)
        if !(cmd is String) || !InStr(cmd, '--type=gpu-process')
            continue
        if (h := DllCall('OpenProcess', 'UInt', 0x0001, 'Int', false, 'UInt', p.ProcessId, 'Ptr')) {   ; PROCESS_TERMINATE
            if DllCall('TerminateProcess', 'Ptr', h, 'UInt', 0xFFFFFFFF)
                ended++
            else
                failed++
            DllCall('CloseHandle', 'Ptr', h)
        } else
            failed++
    }
    return {ended: ended, failed: failed}
}
