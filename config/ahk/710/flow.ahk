; Part of 710.ahk: Flow Launcher -- SUPER+Space, SUPER+S.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Flow Launcher
; ============================================================================
; ToggleFlow()/ToggleFlowScoped() ported from winarchy's winarchy.ahk -- real toggle logic, not
; a naive relaunch. A Flow that's up and ready gets its own native Alt+Space (show / hide), as
; always. One that isn't -- not running (quit, crashed, an on-demand machine before `710sRice
; start`) or still starting -- is waited for, then shown through Flow's own second-instance
; signal. Normally Flow is already up and ready: this script starts it when it comes up (at
; sign-in, or `710sRice start`) -- see "The apps 710.ahk starts". The cold start below is
; StartFlow too, so it's never as admin either.
; Why the wait (Flow 2.1.3's source -- claude/group1-plan.md #4; the old "Flow's indexing delay"
; note here was wrong): Flow starts hidden (HideOnStartup) and registers Alt+Space only at the end
; of its startup (App.xaml.cs:237, after a plugin-manifest download at :221). A second start of
; Flow.Launcher.exe shows the running Flow (OnSecondAppStarted -> ShowMainWindow), but not before
; its main window exists, and a show before Flow's own startup hide has finished is hidden again
; by it (MainWindow OnLoaded -> MainViewModel.Hide: DWM cloak, then 50 ms later the window goes
; invisible). So "ready" = the main window exists, cloaked and invisible (or shown).
FlowWindow := 'Flow.Launcher ahk_exe Flow.Launcher.exe'

FlowState() {
    ; Flow's main window (hidden or not -- its title is exactly Flow.Launcher) and where it is:
    ; 'hidden' (cloaked + invisible: ready), 'shown', 'hiding' (cloaked, not yet invisible) or
    ; 'starting' (neither: just created). hwnd 0 = no main window yet. Where DWM gives no answer
    ; (not on Windows 11), an invisible window counts as hidden.
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    st := {hwnd: 0, state: ''}
    try {
        for hwnd in WinGetList('ahk_exe Flow.Launcher.exe') {
            if WinGetTitle('ahk_id ' hwnd) != 'Flow.Launcher'
                continue
            visible := (WinGetStyle('ahk_id ' hwnd) & 0x10000000) != 0     ; WS_VISIBLE
            cloaked := 0
            if DllCall('dwmapi\DwmGetWindowAttribute', 'ptr', hwnd, 'uint', 14, 'uint*', &cloaked, 'uint', 4, 'int') != 0
                cloaked := !visible                                        ; 14 = DWMWA_CLOAKED
            st.hwnd := hwnd
            st.state := cloaked ? (visible ? 'hiding' : 'hidden') : (visible ? 'shown' : 'starting')
            break
        }
    }
    DetectHiddenWindows(prev)
    return st
}

WaitFlowShown(flow, timeoutMs) {
    ; Waits for Flow to be ready (see above), then shows it with the second-instance signal --
    ; again after 2 s if it isn't on screen yet (the second instance can exit before its signal
    ; lands). A Flow that shows itself at start (HideOnStartup off) is taken as it is once it has
    ; stayed shown for half a second (so the flash before its own startup hide doesn't count).
    ; Returns the visible window, or 0.
    global FlowWindow
    deadline := A_TickCount + timeoutMs
    shownSince := 0
    while A_TickCount < deadline {
        st := FlowState()
        if st.state = 'hidden' {
            loop 3 {
                Run('"' flow '"')
                if hwnd := WinWait(FlowWindow, , 2)
                    return hwnd
            }
            return 0
        }
        if st.state = 'shown' {
            if !shownSince
                shownSince := A_TickCount
            else if A_TickCount - shownSince >= 500
                return st.hwnd
        } else
            shownSince := 0
        Sleep(50)
    }
    return 0
}

ToggleFlow() {
    global FlowWindow
    flow := EnvGet('LOCALAPPDATA') '\FlowLauncher\Flow.Launcher.exe'
    if !FileExist(flow)
        return 0
    if ProcessExist('Flow.Launcher.exe') {
        st := FlowState()
        if st.state = 'hidden' || st.state = 'shown' {
            ; Up and ready: Flow's own hotkey toggles it.
            wasVisible := WinExist(FlowWindow)
            Send('!{Space}')
            if wasVisible
                return 0
            hwnd := WinWait(FlowWindow, , 2)
            return hwnd ? hwnd : 0
        }
        ; Still starting (sign-in, or a start a moment ago): the wait below.
    } else if !StartFlow('a Flow key')   ; cold start: Flow starts hidden, so the wait below shows it
        return 0
    hwnd := WaitFlowShown(flow, 20000)
    if !hwnd
        return 0
    ; The background instance doesn't always get to take the foreground
    ; (Windows foreground lock) -- retry activation until focus genuinely
    ; lands in the query box.
    loop 10 {
        if !WinExist('ahk_id ' hwnd)
            return 0
        try WinActivate('ahk_id ' hwnd)
        if WinActive('ahk_id ' hwnd)
            return hwnd
        Sleep(30)
    }
    return 0
}

ToggleFlowScoped(prefix) {
    ; Same as ToggleFlow(), but preloads a plugin keyword in the query box so
    ; the search is scoped (winarchy a4dd1f7's ToggleFlowScoped). Both
    ; keywords are set up by install's flow step (tools/components/flow.ps1):
    ;   'app ' -> Flow's built-in Program plugin: installed programs only
    ;             (parity with Omarchy's Walker "Apps", no hand-curated list)
    ;   'f '   -> Flow's built-in Explorer plugin's FILE search, on the
    ;             voidtools Everything index
    if !ToggleFlow()
        return
    Sleep(50)
    Send('^a')
    SendText(prefix)
}

#Space::ToggleFlow()                  ; Flow Launcher (global search)
#s::ToggleFlowScoped('f ')            ; search files (Everything)
#^Space::ToggleFlowScoped('app ')     ; Flow Launcher, apps only
