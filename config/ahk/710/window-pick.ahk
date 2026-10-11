; Part of 710.ahk: Picking a window with a click -- the first step of Quick add rule and of Turn
; off a shipped rule. config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Picking a window (Quick add rule, Turn off a shipped rule)
; ============================================================================
; PickWindow(name, tip, picked): "Click the window <tip>   (Esc cancels)" follows the mouse until
; a click, then picked({hwnd, exe, cls, title}) gets the top-level window clicked. Esc, 15 s
; without a click, a window it can't read and one that isn't an app window end it instead, each
; with a toast naming the feature (name). Quick add rule's own pick until Turn off a shipped rule
; (rule-off.ahk) needed it too; moved here whole from quick-rule.ahk.
;
; Picking is a tooltip + a temporary blocking *LButton hotkey, NOT a swapped
; system crosshair cursor: if anything died mid-pick, a changed system cursor
; would stay changed; a tooltip and a hook hotkey just go away with it.
PickWindowActive := false, PickWindowFor := ''

PickWindow(name, tip, picked) {
    global PickWindowActive, PickWindowFor
    if PickWindowActive
        return
    PickWindowActive := true, PickWindowFor := {name: name, tip: tip, picked: picked}
    HotIf()                                       ; the two temp hotkeys live in the plain global context
    Hotkey('*LButton', PickWindowClick, 'On')     ; blocking: the pick-click never reaches the window
    Hotkey('*Esc', PickWindowCancel, 'On')
    SetTimer(PickWindowTip, 50)
    SetTimer(PickWindowTimeout, -15000)           ; walked away mid-pick? give the mouse back
}

PickWindowTip() {
    global PickWindowFor
    ToolTip('Click the window ' PickWindowFor.tip '   (Esc cancels)')
}

PickWindowEnd() {
    global PickWindowActive
    PickWindowActive := false
    SetTimer(PickWindowTip, 0)
    SetTimer(PickWindowTimeout, 0)
    ToolTip()
    try Hotkey('*LButton', 'Off')
    try Hotkey('*Esc', 'Off')
}

PickWindowCancel(*) {
    global PickWindowFor
    PickWindowEnd()
    TrayTip(PickWindowFor.name ' cancelled', '710sRice')
}

PickWindowTimeout() {
    global PickWindowActive
    if PickWindowActive
        PickWindowCancel()
}

PickWindowClick(*) {
    global PickWindowFor
    PickWindowEnd()
    CoordMode('Mouse', 'Screen')
    MouseGetPos(, , &hwnd)
    root := DllCall('GetAncestor', 'Ptr', hwnd, 'UInt', 2, 'Ptr')   ; GA_ROOT: the top-level window, never a child control
    try {
        exe   := WinGetProcessName('ahk_id ' root)
        cls   := WinGetClass('ahk_id ' root)
        title := WinGetTitle('ahk_id ' root)
        pid   := WinGetPID('ahk_id ' root)
    } catch {
        ; typically an elevated window -- which non-elevated komorebi can't manage anyway
        TrayTip("Couldn't read that window (an admin window?) -- " StrLower(PickWindowFor.name) ' cancelled', '710sRice')
        return
    }
    ; Not app windows: the desktop, the taskbars, the YASB bar, and this script's own GUIs.
    if (cls ~= '^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd)$')
        || (StrLower(exe) = 'yasb.exe') || (pid = DllCall('GetCurrentProcessId')) {
        TrayTip("That's not an app window -- " StrLower(PickWindowFor.name) ' cancelled', '710sRice')
        return
    }
    PickWindowFor.picked.Call({hwnd: root, exe: exe, cls: cls, title: title})
}
