; Part of 710.ahk: Window drag -- SUPER+left-drag moves a window and swaps it with the tile it's dropped on; SUPER+right-drag resizes it.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Window drag
; ============================================================================
; Ported from winarchy 6418583 (its drag half; the Layout submenu stays parked) and the three
; fixes after it, two of them reshaped:
;  - 97a2004 as it is: the move uses SetWindowPos with no delay and a 1 ms timer, so the window
;    keeps up with the cursor (WinMove waits 100 ms after every call: ~10 updates a second).
;  - 9d315d7's fix: the drop goes to the window really under the cursor, looking through
;    komorebi's borders, and a drop inside the window's own tile changes nothing. Its code put
;    the drop-and-swap half in DragResize, where `t` is never set, so on winarchy's main a
;    SUPER+left-drag never swaps and a SUPER+right-drag dies with an UnsetError (AutoHotkey
;    2.0.28, 2026-10-16). Here it's in DragMove, where its message says it goes.
;  - Not ddd0c4e's pass-through `*~LButton Up` / `*~RButton Up` hotkeys. They let injected test
;    clicks end a drag, but they hand the app the button-up whose down AHK swallowed: after a
;    SUPER+right-drag the window under the cursor got WM_RBUTTONUP, then WM_CONTEXTMENU (its
;    right-click menu), and a stray WM_LBUTTONUP after a left one (AutoHotkey 2.0.28, real X
;    input under wine, 2026-10-16). Without them AHK swallows that orphan itself. The release
;    comes from the button's physical state (6418583's own way), with ddd0c4e's 30-second cap
;    kept in case a release is ever missed.
; Everything goes through komorebic: AHK swallows the click, so neither Windows' own move/size
; loop nor komorebi's drag handling ever sees the button held. On its own screen a drop swaps
; with the neighbour in the direction of the tile it landed on (komorebic's `move`); dropped on
; another screen, the window moves there (`move-to-monitor`, ours: see DragMove).
#LButton::WindowDrag(true)                       ; move the window: swap with a tile, or move to another screen
#RButton::WindowDrag(false)                      ; resize the window from the nearest edge or corner

WindowDrag(move, held := 0) {
    CoordMode('Mouse', 'Screen')
    MouseGetPos(&x, &y, &under)
    hwnd := DllCall('user32\GetAncestor', 'ptr', under, 'uint', 2, 'ptr')   ; GA_ROOT: its top-level window
    btn := move ? 'LButton' : 'RButton'
    t0 := A_TickCount
    held := held || (() => GetKeyState(btn, 'P') && A_TickCount - t0 < 30000)
    if !hwnd || !DragTarget(hwnd) || WinGetMinMax(hwnd) = 1 {   ; nothing to drag, or maximized: just wait out the press
        while held()
            Sleep(10)
        return
    }
    try WinActivate(hwnd), WinWaitActive(hwnd, , 0.5)            ; komorebic acts on the focused window
    move ? DragMove(hwnd, x, y, held) : DragResize(hwnd, x, y, held)
}

; A real, visible app window: not the desktop, the taskbar, the bar or a tool window (the palette is one).
; A window that's gone, or one this script can't read, isn't one.
DragTarget(hwnd) {
    try return (WinGetStyle(hwnd) & 0x10000000) && !(WinGetExStyle(hwnd) & 0x80)   ; WS_VISIBLE, not WS_EX_TOOLWINDOW
        && WinGetMinMax(hwnd) != -1
        && !(WinGetClass(hwnd) ~= '^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd)$')
        && WinGetProcessName(hwnd) != 'yasb.exe'
    return false
}

DragMove(hwnd, x0, y0, held) {
    WinGetPos(&wx, &wy, &ww, &wh, hwnd)
    SetWinDelay(-1)
    DllCall('winmm\timeBeginPeriod', 'uint', 1)    ; Sleep(1) otherwise rounds up to ~15 ms
    try {
        px := x0, py := y0
        while held() {
            MouseGetPos(&x, &y)
            if (x != px || y != py) {
                px := x, py := y
                DllCall('user32\SetWindowPos', 'ptr', hwnd, 'ptr', 0, 'int', wx + x - x0, 'int', wy + y - y0, 'int', 0, 'int', 0, 'uint', 0x15)   ; NOSIZE | NOZORDER | NOACTIVATE
            }
            Sleep(1)
        }
    } finally
        DllCall('winmm\timeEndPeriod', 'uint', 1)
    DllCall('user32\SetWindowPos', 'ptr', hwnd, 'ptr', 0, 'int', wx, 'int', wy, 'int', 0, 'int', 0, 'uint', 0x15)   ; back home; komorebi does the moving
    MouseGetPos(&x, &y, &under)                    ; what's under the cursor once the window is back
    ; Dropped on another screen: the window goes to that screen, wherever on it, a window under
    ; the cursor or not -- komorebi slots it in there (move-to-monitor; base.json's
    ; cross_monitor_move_behaviour: Insert). One move toward the tile only crosses from the column
    ; next to that screen; from further in it swapped with a neighbour (his call, 10-16).
    if (DllCall('user32\MonitorFromPoint', 'int64', (y << 32) | (x & 0xFFFFFFFF), 'uint', 2, 'ptr')
        != DllCall('user32\MonitorFromWindow', 'ptr', hwnd, 'uint', 2, 'ptr')) {   ; 2: MONITOR_DEFAULTTONEAREST
        mon := DragKomorebiScreenAt(x, y)
        if (mon >= 0)
            Komorebic('move-to-monitor ' mon)
        return
    }
    t := DllCall('user32\GetAncestor', 'ptr', under, 'uint', 2, 'ptr')
    while t && DragIsKomorebi(t) {                 ; its borders overhang the tile: look through them
        loop {
            t := DllCall('user32\GetWindow', 'ptr', t, 'uint', 2, 'ptr')   ; GW_HWNDNEXT
            if !t
                break
            try {
                WinGetPos(&tx, &ty, &tw, &th, t)
                if (WinGetStyle(t) & 0x10000000) && x >= tx && x < tx + tw && y >= ty && y < ty + th
                    break
            }
        }
    }
    if !t || t = hwnd || !DragTarget(t)
        return                                     ; dropped on itself, or on nothing: stay put
    try WinGetPos(&tx, &ty, &tw, &th, t)
    catch
        return                                     ; it closed under the cursor
    dx := tx + tw // 2 - (wx + ww // 2), dy := ty + th // 2 - (wy + wh // 2)
    Komorebic('move ' (Abs(dx) >= Abs(dy) ? (dx < 0 ? 'left' : 'right') : (dy < 0 ? 'up' : 'down')))
}

DragIsKomorebi(hwnd) {
    try return WinGetProcessName(hwnd) = 'komorebi.exe'
    return false
}

; komorebi's number for the screen holding a point (0 first), from komorebi's own screen
; rectangles (KomorebiScreenRects, scrolling.ahk) -- never AutoHotkey's MonitorGet numbering,
; which needn't match. -1 when komorebi doesn't answer.
DragKomorebiScreenAt(x, y) {
    for i, r in KomorebiScreenRects(QueryKomorebic('monitor-information'))
        if (x >= r.left && x < r.left + r.width && y >= r.top && y < r.top + r.height)
            return i - 1
    return -1
}

; Grab a third of the window: a corner moves both of its edges, the middle of a side moves that
; side, the very middle moves the right and bottom edges. komorebi moves the shared edge by half
; the delta, hence the * 2; the delta goes back to komorebi's default (50, base.json sets none),
; which SUPER+= / SUPER+- use, even if a step fails.
DragResize(hwnd, x0, y0, held) {
    WinGetPos(&wx, &wy, &ww, &wh, hwnd)
    col := Min(Max((x0 - wx) * 3 // ww, 0), 2), row := Min(Max((y0 - wy) * 3 // wh, 0), 2)
    while held()
        Sleep(10)
    MouseGetPos(&x, &y)
    dx := x - x0, dy := y - y0
    K := (cmd) => RunWait('"' KomorebicExe '" ' cmd, , 'Hide')
    try {
        for axis in [[dx, col = 0 ? 'left' : 'right', col = 1 && row != 1], [dy, row = 0 ? 'up' : 'down', row = 1 && col != 1]] {
            d := axis[1], edge := axis[2]
            if axis[3] || Abs(d) < 20
                continue
            grows := (edge = 'left' || edge = 'up') ? d < 0 : d > 0
            K('resize-delta ' Abs(d) * 2)
            K('resize-edge ' edge (grows ? ' increase' : ' decrease'))
        }
    } finally
        K('resize-delta 50')
}
