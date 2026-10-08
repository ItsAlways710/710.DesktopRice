; Part of 710.ahk: Palette -- PalOpen() and the themed popup every menu uses.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Palette -- the one themed, searchable popup behind every 710sRice menu
; ============================================================================
; SUPER+Alt+Space (main menu), SUPER+Esc (system), SUPER+K (keybindings) and
; Quick add rule's "Match on" step all open this one list. Ported from
; winarchy bb72240 (v1.5.0, "searchable palette for the Winarchy menus"),
; re-pointed at wallust's colors (RefreshMenuColors below) instead of his
; theme.ini. It replaced two engines of ours -- the ShowThemedGuiMenu() menu
; and the 4-column SUPER+K overlay -- agreed 2026-09-23 ("easier to maintain
; is better").
;
; How it works (same as winarchy's):
;  - A hand-built Gui (-Caption, DWM-rounded corners), NOT a native Menu():
;    the first native attempt here wore a white border DWM can't touch on the
;    #32768 popup class. (The tray icon's right-click is still native --
;    Windows draws that one; see BuildNativeMenu.)
;  - The search box has focus from the start. Words match in any order; in
;    the menus the search reaches into submenus and lists the leaves as
;    "Capture > Region".
;  - Items are {text, action} or {text, sub: [...]}, plus an optional
;    hint: 'SUPER+...' shown right-aligned (submenus show a chevron instead).
;  - Up/Down, Tab, PgUp/PgDn and the wheel move; hover highlights; click or
;    Enter picks. Esc clears the search, then backs out a level, then closes;
;    Backspace backs out a level only while the search box is empty.
;  - Hover and clicks arrive as WM_MOUSEMOVE / WM_LBUTTONUP on the Gui itself
;    (the row Text controls have no SS_NOTIFY, so the mouse goes straight
;    through them) -- this retired our old 50ms hover-polling timer.
;  - Closes itself when it loses focus; opens centred on the monitor under
;    the mouse (DPI-correct, which our old menus weren't quite).
; Ours on top: SUPER+K is sized to ~80% of that monitor's height (agreed
; 2026-09-23) instead of winarchy's fixed 18 rows, to soften losing the old
; everything-at-once column view.
;
; Colors: the palette profile's Menus colours (config\ahk\menu-colors.css, written by
; the wallpaper pipeline -- tools\palette\targets\menus.ps1); the bar's file stands in
; until that one exists (an install from before Palette Profiles, before its first
; theme run); sensible dark fallbacks before either does (fresh checkout).
; ============================================================================
MenuCss := RepoRoot "\config\ahk\menu-colors.css"
WallustCss := RepoRoot "\config\yasb\wallust_colors.css"
MenuBgHex := '2B2B2B', MenuFgHex := 'E0E0E0', MenuAccentHex := '5C41A5', MenuAccentTextHex := 'FAF1FD'
MenuMutedHex := '9A9A9A'   ; secondary/hint text -- used by the key overlay's description column
MenuSelTextHex := ''       ; the selected row's text; '' = the background colour, as it always was

RefreshMenuColors() {
    global MenuCss, WallustCss, MenuBgHex, MenuFgHex, MenuAccentHex, MenuAccentTextHex, MenuMutedHex, MenuSelTextHex
    css := FileExist(MenuCss) ? MenuCss : WallustCss
    if !FileExist(css)
        return   ; keep the fallback colors above
    css := FileRead(css)
    if RegExMatch(css, '--wallust-background:\s*#([0-9A-Fa-f]{6})', &m)
        MenuBgHex := m[1]
    if RegExMatch(css, '--wallust-text:\s*#([0-9A-Fa-f]{6})', &m)
        MenuFgHex := m[1]
    if RegExMatch(css, '--wallust-accent:\s*#([0-9A-Fa-f]{6})', &m)
        MenuAccentHex := m[1]
    if RegExMatch(css, '--wallust-accentText:\s*#([0-9A-Fa-f]{6})', &m)
        MenuAccentTextHex := m[1]
    if RegExMatch(css, '--wallust-subtext:\s*#([0-9A-Fa-f]{6})', &m)
        MenuMutedHex := m[1]
    MenuSelTextHex := RegExMatch(css, '--wallust-selectedText:\s*#([0-9A-Fa-f]{6})', &m) ? m[1] : ''
}

Pal := ''

PalColors() {
    global MenuBgHex, MenuFgHex, MenuAccentHex, MenuMutedHex, MenuSelTextHex
    RefreshMenuColors()       ; re-read on every open -- a wallpaper change recolors the next menu, no reload
    return {bg: MenuBgHex, fg: MenuFgHex, ac: MenuAccentHex, mut: MenuMutedHex,
        sel: (MenuSelTextHex != '' ? MenuSelTextHex : MenuBgHex)}
}

; Closes any open palette; true when it was showing `mode` -- so each hotkey
; toggles its own palette, and pressing a different one swaps.
PalClosed(mode) {
    global Pal
    if !IsObject(Pal)
        return false
    same := (Pal.mode = mode)
    PalClose()
    return same
}

; dropDown: open just under the bar with its left edge near the mouse, like a dropdown from the
; button that opened it (Screens, from the bar's monitor button), instead of centred like the rest.
PalOpen(mode, items, title, dropDown := false) {
    global Pal
    PalClose()
    c := PalColors()
    keys := (mode = 'keys')
    pad := 20, rowH := keys ? 24 : 32
    labelW := keys ? 250 : 330, hintW := keys ? 470 : 190
    w := pad * 2 + labelW + hintW
    y0 := pad + 80                         ; rows start under the crumb + search box
    WorkAreaUnderMouse(&wl, &wt, &wr, &wb)
    dpi := A_ScreenDPI / 96                ; Gui units are 96-dpi; the work area is real pixels
    if keys                                ; ~80% of the screen, minus the chrome around the rows
        n := Max(8, Floor(((wb - wt) / dpi * 0.8 - (y0 + 46)) / rowH))
    else
        n := Min(Max(items.Length, 8), 14)

    g := Gui('-Caption +AlwaysOnTop +ToolWindow', '710sRicePalette')
    g.BackColor := c.bg
    g.MarginX := 0, g.MarginY := 0

    PalSetFont(g, 's10 bold')
    crumb := g.Add('Text', Format('x{} y{} w{} h20 c{} 0x4200', pad, pad, w - pad * 2, c.ac), '')
    PalSetFont(g, 's12 norm')
    g.Add('Text', Format('x{} y{} w24 h30 c{} 0x200', pad, pad + 30, c.mut), Chr(0xF002))   ; Nerd Font search glyph
    ed := g.Add('Edit', Format('x{} y{} w{} h30 -E0x200 -Multi Background{} c{}', pad + 28, pad + 34, w - pad * 2 - 28, c.bg, c.fg))
    SendMessage(0x1501, 1, StrPtr(keys ? 'Filter by key or action' : 'Search'), ed)   ; EM_SETCUEBANNER
    g.Add('Text', Format('x{} y{} w{} h1 Background{}', pad, pad + 68, w - pad * 2, c.mut))

    PalSetFont(g, keys ? 's10 norm' : 's11 norm')
    rows := []
    loop n {
        y := y0 + (A_Index - 1) * rowH
        ; 0x4200 = SS_CENTERIMAGE | SS_ENDELLIPSIS: vertically centred, and anything too
        ; long for its column ends in "..." instead of wrapping into the next row.
        lbl := g.Add('Text', Format('x{} y{} w{} h{} c{} Background{} 0x4200', pad - 8, y, labelW + 8, rowH, c.fg, c.bg), '')
        hnt := g.Add('Text', Format('x{} y{} w{} h{} c{} Background{} 0x4200 {}', pad + labelW, y, hintW + 8, rowH, c.mut, c.bg, keys ? '' : 'Right'), '')
        rows.Push({label: lbl, hint: hnt, y: y, on: false})
    }
    fy := y0 + n * rowH + 10
    PalSetFont(g, 's9 norm')
    arrows := Chr(0x2191) Chr(0x2193)
    help := keys ? arrows ' scroll    esc close' : arrows ' move    ' Chr(0x21B5) ' select    esc back'
    g.Add('Text', Format('x{} y{} w{} h20 c{}', pad, fy, labelW, c.mut), help)
    count := g.Add('Text', Format('x{} y{} w{} h20 c{} Right', pad + labelW, fy, hintW, c.mut), '')
    h := fy + 20 + pad - 4

    Pal := {gui: g, mode: mode, colors: c, items: items, title: title, stack: [], list: [],
        sel: 0, top: 1, rows: rows, rowH: rowH, y0: y0, x0: pad - 8, x1: pad + labelW + hintW + 8,
        edit: ed, crumb: crumb, count: count, mouse: '', pressed: 0}
    ed.OnEvent('Change', PalSearchChanged)
    g.OnEvent('Close', (*) => PalClose())
    MouseGetPos(&ox, &oy)                   ; Screen coordinates (WorkAreaUnderMouse, above)
    Pal.openPos := ox ',' oy                ; see PalMouseMove
    PalRefresh()

    if dropDown {
        CoordMode('Mouse', 'Screen')
        MouseGetPos(&mx)
        x := Max(wl, Min(mx - 24, wr - Round(w * dpi)))
        y := wt + 4                        ; the work area starts under the bar (YASB reserves its strip)
    } else {
        x := wl + (wr - wl - Round(w * dpi)) // 2
        y := wt + (wb - wt - Round(h * dpi)) // 2
    }
    g.Show(Format('x{} y{} w{} h{}', x, y, w, h))
    DllCall('dwmapi\DwmSetWindowAttribute', 'ptr', g.Hwnd, 'int', 33, 'int*', 2, 'int', 4)  ; DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND
    ed.Focus()
    OnMessage(0x200, PalMouseMove)       ; WM_MOUSEMOVE
    OnMessage(0x201, PalPress)           ; WM_LBUTTONDOWN
    OnMessage(0x202, PalClick)           ; WM_LBUTTONUP
    OnMessage(0x20A, PalWheel)           ; WM_MOUSEWHEEL
    SetTimer(PalWatch, 250)              ; closes when it loses focus
}

; JetBrainsMono under its Nerd Fonts v3 or v2 family name (install.ps1 installs
; DEVCOM.JetBrainsMonoNerdFont; whichever name exists wins, the other is a no-op).
PalSetFont(g, opts) {
    g.SetFont(opts, 'JetBrainsMono Nerd Font')
    g.SetFont(opts, 'JetBrainsMono NF')
}

; Every way into an open palette -- its mouse messages, its keys, the search box --
; starts Critical, so nothing closes it halfway through: PalWatch (below) and Esc both
; end here, and AHK lets another thread cut in once one has run ~15 ms. Over an
; exclusive-fullscreen game that window always gets used: the palette taking focus
; drops the game out of exclusive mode, the screen switches modes, a hover redraw
; crawls, the palette gets closed mid-redraw and PalDraw writes into destroyed
; controls -- an AHK error every single time on Godzilla (2026-10-04; the stack trace
; fits exactly that). Critical makes the close wait its turn. PalEnter switches it
; back off before running the picked action, so actions run as they always did.
PalClose() {
    global Pal
    SetTimer(PalWatch, 0)
    OnMessage(0x200, PalMouseMove, 0)
    OnMessage(0x201, PalPress, 0)
    OnMessage(0x202, PalClick, 0)
    OnMessage(0x20A, PalWheel, 0)
    if IsObject(Pal)
        try Pal.gui.Destroy()
    Pal := ''
}

PalWatch() {
    try {
        if IsObject(Pal) && !WinActive('ahk_id ' Pal.gui.Hwnd)
            PalClose()
    } catch
        PalClose()
}

PalActive() => IsObject(Pal) && WinActive('ahk_id ' Pal.gui.Hwnd)

; Every typed word must appear somewhere (any order, case-insensitive).
PalMatch(q, hay) {
    for word in StrSplit(q, ' ')
        if (word != '' && !InStr(hay, word))
            return false
    return true
}

; A submenu row shows its hint before the chevron (a screen's "on · 150%", System's key).
PalHint(it) => it.HasOwnProp('sub') ? (it.HasOwnProp('hint') ? it.hint ' ' Chr(0x203A) : Chr(0x203A))
    : (it.HasOwnProp('hint') ? it.hint : '')

; Leaves of the tree whose path matches, e.g. "Capture > Region".
PalFlatten(items, path, q, list) {
    for it in items {
        name := (path = '') ? it.text : path ' ' Chr(0x203A) ' ' it.text
        if it.HasOwnProp('sub')
            PalFlatten(it.sub, name, q, list)
        else if PalMatch(q, name ' ' PalHint(it))
            list.Push({text: name, hint: PalHint(it), item: it})
    }
}

; The search box's Change event: a way in like the others (Critical -- see PalClose).
PalSearchChanged(*) {
    Critical('On')
    PalRefresh()
}

PalRefresh(sel := 0) {
    q := Trim(Pal.edit.Value)
    list := []
    if (Pal.mode = 'keys') {
        for s in Pal.items {
            hits := []
            for it in s.items
                if PalMatch(q, it.keys ' ' it.desc ' ' s.title)
                    hits.Push({text: it.keys, hint: it.desc})
            if hits.Length {
                list.Push({text: StrUpper(s.title), hint: '', header: true})
                for e in hits
                    list.Push(e)
            }
        }
    } else if (q = '') {
        for it in Pal.items
            list.Push({text: it.text, hint: PalHint(it), item: it})
    } else
        PalFlatten(Pal.items, '', q, list)
    Pal.list := list
    Pal.top := 1
    Pal.sel := 0
    for i, e in list
        if !e.HasOwnProp('header') && (!Pal.sel || i = sel) {
            Pal.sel := i
            if !sel
                break
        }
    crumb := StrUpper(Pal.title)
    for lvl in Pal.stack
        crumb := StrUpper(lvl.title) ' ' Chr(0x203A) ' ' crumb
    Pal.crumb.Text := crumb
    found := 0
    for e in list
        found += !e.HasOwnProp('header')
    Pal.count.Text := (Pal.mode = 'keys') ? found ' bindings' : (q = '' ? '' : found ' results')
    PalDraw()
}

PalDraw() {
    c := Pal.colors, n := Pal.rows.Length, len := Pal.list.Length
    if Pal.sel {
        if (Pal.sel < Pal.top)
            Pal.top := Pal.sel
        else if (Pal.sel > Pal.top + n - 1)
            Pal.top := Pal.sel - n + 1
        if (Pal.top = Pal.sel && Pal.sel > 1 && Pal.list[Pal.sel - 1].HasOwnProp('header'))
            Pal.top -= 1                 ; keep the section title above its first row
    }
    Pal.top := Max(1, Min(Pal.top, len - n + 1))
    for k, r in Pal.rows {
        i := Pal.top + k - 1
        e := (i <= len) ? Pal.list[i] : {text: (k = 1 && !len) ? 'No matches' : '', hint: '', empty: true}
        head := e.HasOwnProp('header'), on := (i = Pal.sel)
        if (on != r.on) {
            r.on := on
            r.label.Opt('Background' (on ? c.ac : c.bg))
            r.hint.Opt('Background' (on ? c.ac : c.bg))
        }
        ; selected row: the profile's "selected row text" on the accent bar (the background
        ; colour under Default -- same as our old menus)
        r.label.SetFont((head ? 'bold' : 'norm') ' c' (on ? c.sel : head ? c.ac : e.HasOwnProp('empty') ? c.mut : c.fg))
        r.hint.SetFont('c' (on ? c.sel : Pal.mode = 'keys' ? c.fg : c.mut))
        r.label.Text := ' ' e.text
        r.hint.Text := e.hint ' '
    }
}

PalMove(d) {
    Critical('On')                       ; a way in -- see PalClose
    if !Pal.sel
        return
    len := Pal.list.Length, i := Pal.sel, step := (d > 0) ? 1 : -1
    loop Abs(d) {
        j := i
        loop {
            j += step
            if (j < 1 || j > len) {
                if (Abs(d) > 1)          ; page / wheel: stop at the ends
                    break 2
                j := (j < 1) ? len : 1   ; single step: wrap around
            }
            if !Pal.list[j].HasOwnProp('header')
                break
        }
        i := j
    }
    Pal.sel := i
    PalDraw()
}

PalEnter() {
    Critical('On')                       ; a way in -- see PalClose
    if !Pal.sel || !Pal.list[Pal.sel].HasOwnProp('item')
        return                           ; SUPER+K rows are information, not actions
    it := Pal.list[Pal.sel].item
    if it.HasOwnProp('sub') {
        Pal.stack.Push({items: Pal.items, title: Pal.title, sel: Pal.sel})
        Pal.items := it.sub, Pal.title := it.text
        Pal.edit.Value := ''
        PalRefresh()
        return
    }
    PalClose()
    Critical('Off')                      ; the action runs like any other thread
    it.action.Call()
}

PalBack() {
    Critical('On')                       ; a way in -- see PalClose
    if !Pal.stack.Length
        return
    prev := Pal.stack.Pop()
    Pal.items := prev.items, Pal.title := prev.title
    PalRefresh(prev.sel)
}

PalEscape() {
    Critical('On')                       ; a way in -- see PalClose
    if (Pal.edit.Value != '') {
        Pal.edit.Value := ''
        PalRefresh()
    } else if Pal.stack.Length
        PalBack()
    else
        PalClose()
}

; List index under the cursor, or 0.
PalIndexAtCursor(hwnd) {
    if !IsObject(Pal) || DllCall('GetAncestor', 'ptr', hwnd, 'uint', 2, 'ptr') != Pal.gui.Hwnd
        return 0
    pt := Buffer(8)
    DllCall('GetCursorPos', 'ptr', pt)
    DllCall('ScreenToClient', 'ptr', Pal.gui.Hwnd, 'ptr', pt)
    x := NumGet(pt, 0, 'int') * 96 / A_ScreenDPI, y := NumGet(pt, 4, 'int') * 96 / A_ScreenDPI
    k := Floor((y - Pal.y0) / Pal.rowH) + 1
    if (x < Pal.x0 || x > Pal.x1 || k < 1 || k > Pal.rows.Length)
        return 0
    i := Pal.top + k - 1
    return (i <= Pal.list.Length && !Pal.list[i].HasOwnProp('header')) ? i : 0
}

PalMouseMove(wParam, lParam, msg, hwnd) {
    Critical('On')                       ; a way in -- see PalClose
    if !IsObject(Pal) || (lParam = Pal.mouse)    ; ignore synthetic moves after a redraw
        return
    ; Nor the move Windows sends when the menu appears under a mouse that hasn't moved: the row
    ; under it would take the selection from the first row, and Enter would pick it -- the
    ; Screens warning puts Cancel first so Enter backs out (2026-10-05).
    if (Pal.openPos != '') {
        CoordMode('Mouse', 'Screen')
        MouseGetPos(&mx, &my)
        if (mx ',' my = Pal.openPos)
            return
        Pal.openPos := ''
    }
    Pal.mouse := lParam
    if (i := PalIndexAtCursor(hwnd)) && (i != Pal.sel) {
        Pal.sel := i
        PalDraw()
    }
}

; A click only counts when the button went down AND up on the same row. Ours, not
; winarchy's: Quick add rule opens its palette straight from a mouse click, and
; that click's button-up could otherwise land on whatever row appeared under the
; cursor and pick it.
PalPress(wParam, lParam, msg, hwnd) {
    Critical('On')                       ; a way in -- see PalClose
    if IsObject(Pal)
        Pal.pressed := PalIndexAtCursor(hwnd)
}

PalClick(wParam, lParam, msg, hwnd) {
    Critical('On')                       ; a way in -- see PalClose
    if !IsObject(Pal)
        return
    pressed := Pal.pressed, Pal.pressed := 0
    if (i := PalIndexAtCursor(hwnd)) && (i = pressed) {
        Pal.sel := i
        PalDraw()
        PalEnter()
    }
}

PalWheel(wParam, lParam, msg, hwnd) {
    Critical('On')                       ; a way in -- see PalClose
    if !IsObject(Pal) || DllCall('GetAncestor', 'ptr', hwnd, 'uint', 2, 'ptr') != Pal.gui.Hwnd
        return
    delta := (wParam >> 16) & 0xFFFF
    PalMove(delta > 0x7FFF ? 3 : -3)
    return 0
}

; Keyboard, only while a palette is the active window.
#HotIf PalActive()
Up::PalMove(-1)
Down::PalMove(1)
Tab::PalMove(1)
+Tab::PalMove(-1)
PgUp::PalMove(-Pal.rows.Length)
PgDn::PalMove(Pal.rows.Length)
Enter::PalEnter()
NumpadEnter::PalEnter()
Esc::PalEscape()
#HotIf PalActive() && Pal.edit.Value = ''
Backspace::PalBack()
#HotIf

; Work area (minus taskbar) of the monitor under the mouse -- plain Win32, no
; komorebi dependency, so a palette lands where you're looking.
WorkAreaUnderMouse(&wl, &wt, &wr, &wb) {
    CoordMode('Mouse', 'Screen')
    MouseGetPos(&mx, &my)
    wl := 0, wt := 0, wr := A_ScreenWidth, wb := A_ScreenHeight
    loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (mx >= l && mx < r && my >= t && my < b) {
            MonitorGetWorkArea(A_Index, &wl, &wt, &wr, &wb)
            return
        }
    }
}

OpenSysMenu(*) {
    if !PalClosed('system')
        PalOpen('system', SysMenuItems, 'System')
}
