; Part of 710.ahk: Focus back after a recolor restarts Flow Launcher.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Focus back after a recolor restarts Flow
; ============================================================================
; A recolor (a wallpaper, a palette profile) stops Flow so it reads its new theme, and asks here to
; start it again (tools\palette\targets\flow.ps1): the '710sRice.StartApps' message, Flow's bit 2
; plus 8, "a recolor's restart". A starting Flow grabs the foreground without showing anything:
; first its invisible "Hotkey sink" window, then its main window, which hides itself again
; (flow.ahk's notes on Flow's startup) -- and the foreground stays on the invisible sink. Your keys
; went nowhere until you clicked a window (his report, 2026-10-10). The focus logger on the Dell
; (2026-10-11): the sink took it 4 s after the ask, the main window 1.9 s later, hidden again
; 0.1 s after that, then the sink for good.
; So the window that had focus when the ask came is remembered, and gets focus back once Flow is up
; and hidden -- hidden for a quarter second, so Flow finishes its own hide first -- and again any
; time a hidden Flow takes it, for a minute (Flow's start took 6 s on the Dell). Only while your
; window still exists and nothing but Flow took focus in between: a window you clicked (or
; komorebi focused), or Flow on screen (you opened it), ends the watch -- focus is never taken
; back from anything but Flow. Bit 8 is new: an older 710.ahk (an update's repair runs before its
; reload) masks it off (& 7) and just starts Flow, as before.
FlowFocus := ''

; The '710sRice.StartApps' message (main-menu.ahk): its bits, 1 the bar, 2 Flow, 4 ShareX, and 8.
StartAppsAsked(wParam) {
    if (wParam & 10) = 10
        FlowFocusArm()
    StartApps(wParam & 7, 'asked by 710sRice')
}

FlowFocusArm() {
    global FlowFocus
    hwnd := DllCall('GetForegroundWindow', 'ptr')
    ; Nothing to give back: no window has focus, or Flow has it already (a second recolor while
    ; the first one's watch waits -- that watch carries on), or an invisible one does.
    if !hwnd || IsFlowWindow(hwnd) || !DllCall('IsWindowVisible', 'ptr', hwnd)
        return
    FlowFocus := {hwnd: hwnd, exe: WindowExe(hwnd), until: A_TickCount + 60000, hiddenSince: 0, gaveBack: 0}
    SetTimer(FlowFocusWatch, 50)
}

FlowFocusWatch() {
    global FlowFocus
    w := FlowFocus
    if !IsObject(w) || A_TickCount > w.until || !WinExist('ahk_id ' w.hwnd)
        return FlowFocusEnd()
    fg := DllCall('GetForegroundWindow', 'ptr')
    if fg && fg != w.hwnd && !IsFlowWindow(fg)
        return FlowFocusEnd()            ; another window has it: yours to keep, never taken back
    st := FlowState()
    if st.state = 'shown'
        return FlowFocusEnd()            ; Flow on screen: you opened it
    if st.state != 'hidden' {            ; still starting, or mid-way through its own hide
        w.hiddenSince := 0
        return
    }
    if !w.hiddenSince
        w.hiddenSince := A_TickCount
    if fg = w.hwnd || A_TickCount - w.hiddenSince < 250
        return                           ; yours has it, or Flow's own hide may not be over
    try WinActivate('ahk_id ' w.hwnd)
    if !w.gaveBack++
        AppsLog('focus back to ' w.exe ' -- Flow took it as it started again for a recolor')
}

FlowFocusEnd() {
    global FlowFocus
    SetTimer(FlowFocusWatch, 0)
    FlowFocus := ''
}

IsFlowWindow(hwnd) => WindowExe(hwnd) = 'Flow.Launcher.exe'

; The exe a window belongs to, hidden windows included (Flow's are); '' when it's gone.
WindowExe(hwnd) {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    exe := ''
    try exe := WinGetProcessName('ahk_id ' hwnd)
    DetectHiddenWindows(prev)
    return exe
}
