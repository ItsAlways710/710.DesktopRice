; ============================================================================
; 710.ahk — global hotkey dispatcher for 710.DesktopRice (AHK v2)
; Ported deliberately from winarchy's winarchy.ahk, piece by piece, keeping
; only what's actually used — see claude/winarchy-decoupling-plan.md.
; ============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
ProcessSetPriority "High"   ; the dispatcher must always respond, ~0 cost

; Clears inherited Claude Code sub-session flags / a stray empty NO_COLOR, so any child
; process this dispatcher spawns (pwsh, komorebic) doesn't inherit dev-session state from
; wherever AHK itself got launched. Ported from winarchy's winarchy.ahk @ 4574fc7 (tag
; v1.4.0) -- our own 710.ahk was missing all three despite an earlier pass here believing
; they were already ported; verified against the live file before adding these, not
; assumed. EnvSet(name) with no second arg deletes the var from THIS process's environment.
EnvSet('CLAUDE_CODE_CHILD_SESSION')
EnvSet('CLAUDECODE')
EnvSet('NO_COLOR')

; --- Paths (this script lives at <repo>\config\ahk) ------------------------
RepoRoot := RegExReplace(A_ScriptDir, "\\config\\ahk$")
StateDir := RepoRoot "\state"
DirCreate(StateDir)
GameFlag := StateDir "\game-mode.flag"
GamesToml := RepoRoot "\games.toml"

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

; Flips the FOCUSED workspace between Scrolling (2 columns) and bsp -- asks
; komorebi what you're standing on and what it's currently running, so it
; works identically on workspace 3 or C, and doesn't touch anything you're
; not looking at. Promoted here from the user's personal user.ahk override --
; this is a real, daily-used feature, not a per-machine tweak, so it belongs
; in the tracked dispatcher rather than the gitignored override file.
ToggleScrolling() {
    global KomorebicExe
    mon := QueryKomorebic('query focused-monitor-index')
    ws := QueryKomorebic('query focused-workspace-index')
    layout := QueryKomorebic('query focused-workspace-layout')
    if (StrLower(layout) = 'scrolling') {
        Run('"' KomorebicExe '" workspace-layout ' mon ' ' ws ' bsp', , 'Hide')
    } else {
        Run('"' KomorebicExe '" workspace-layout ' mon ' ' ws ' scrolling', , 'Hide')
        Run('"' KomorebicExe '" scrolling-layout-columns 2', , 'Hide')
    }
}

Komorebic(cmd) {
    global KomorebicExe
    Run('"' KomorebicExe '" ' cmd, , 'Hide')
}

; Launches a program and then forces its new top-level window onto whichever
; monitor the mouse cursor is actually on. Windows' own default placement for
; an unpositioned window ignores komorebi's focus state entirely (confirmed
; by reading this file's old bare #Enter binding plus Windows Terminal's own
; settings.json/state.json -- neither targets a monitor; see
; claude/winarchy-decoupling-plan.md, New-window placement section), so this
; corrects it explicitly after the fact instead of trusting Windows to guess
; right. The 3s WinWait is a ceiling, not a fixed delay -- it returns the
; moment winCriteria matches, so a normal-speed launch adds no felt delay; it
; only matters if the window is unusually slow to appear (or never does), in
; which case this silently skips the move (today's behaviour, not worse).
LaunchOnCursorMonitor(target, winCriteria) {
    global KomorebicExe
    Komorebic('focus-monitor-at-cursor')
    mon := QueryKomorebic('query focused-monitor-index')
    Run(target)
    if WinWait(winCriteria, , 3)
        Run('"' KomorebicExe '" move-to-monitor ' mon, , 'Hide')
}

; Close the window that's actually in front of you: WM_CLOSE straight to the
; active window -- the same message clicking its X sends, so "save changes?"
; prompts still happen. Ported from winarchy bb72240 (v1.5.0), which dropped
; `komorebic close` for this: no komorebic.exe spawn per press, and it doesn't
; depend on komorebi's idea of focus, which can lag behind for windows it
; ignores or floats (games, Flow, anything in the ignore rules). Refuses the
; desktop, both taskbars and the YASB bar, so a stray SUPER+X there is a no-op.
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

; --- Windows -----------------------------------------------------------
#x::CloseWindow()                                ; close window
                                                  ; (moved off #w -- X reads better for close, frees W below)
#w::Send('^!w')                                  ; open wallpaper gallery
                                                  ; (re-sends YASB's own native ctrl+alt+w hotkey,
                                                  ; toggle_gallery, rather than duplicating it; needs
                                                  ; a live check that it fires regardless of focus)
#f::Komorebic('toggle-monocle')                  ; monocle (logical fullscreen)
#+f::Komorebic('toggle-maximize')                ; real maximize
#t::Komorebic('toggle-float')                    ; float/tile
#p::Komorebic('toggle-pause')                    ; pause tiling
#r::Komorebic('retile')                          ; force retile
#+r::ReloadStack()                               ; reload whole stack
#+Enter::Komorebic('promote')                    ; promote to largest tile
#+l::Komorebic('cycle-layout next')              ; cycle to next layout
#!l::ToggleScrolling()                           ; toggle scrolling layout - 2 cols
#Tab::Komorebic('focus-last-workspace')          ; back to the previous workspace
#+Tab::Komorebic('move-to-last-workspace')       ; send window to previous workspace
#^Enter::Komorebic('promote-focus')              ; focus top of the tree
#+h::Komorebic('flip-layout horizontal')         ; mirror the layout left/right
#+j::Komorebic('flip-layout vertical')           ; mirror the layout up/down
#+z::Komorebic('toggle-tiling')                  ; stop tiling this workspace
#!Home::Komorebic('quick-save-resize')           ; save current tile sizes
#Home::Komorebic('quick-load-resize')            ; restore them
#+d::Komorebic('toggle-transparency')            ; dim unfocused windows
#^m::Komorebic('minimize')                       ; minimize the focused window
#^f::Komorebic('toggle-workspace-layer')         ; toggle tiling/floating layer
#^l::Komorebic('toggle-lock')                    ; lock container (pin it)

; --- Focus ---------------------------------------------------------------
#Left::Komorebic('focus left')                   ; move focus
#Right::Komorebic('focus right')
#Up::Komorebic('focus up')
#Down::Komorebic('focus down')

; --- Move window -----------------------------------------------------------
#+Left::Komorebic('move left')                   ; move window
#+Right::Komorebic('move right')
#+Up::Komorebic('move up')
#+Down::Komorebic('move down')

; --- Stacks ---
; komorebi draws these as tabs in the stackbar
#!Left::Komorebic('stack left')                  ; stack with neighbor
#!Right::Komorebic('stack right')
#!Up::Komorebic('stack up')
#!Down::Komorebic('stack down')
#!u::Komorebic('unstack')                        ; unstack this window
#^s::Komorebic('stack-all')                      ; stack the whole workspace
#^u::Komorebic('unstack-all')                    ; unstack the whole container
#!,::Komorebic('cycle-stack previous')           ; previous tab in the stack
#!.::Komorebic('cycle-stack next')               ; next tab in the stack

; --- Resize ------------------------------------------------------------------
#=::Komorebic('resize-axis horizontal increase') ; width +
#-::Komorebic('resize-axis horizontal decrease') ; width -
#+=::Komorebic('resize-axis vertical increase')  ; height +
#+-::Komorebic('resize-axis vertical decrease')  ; height -

; --- Workspaces --------------------------------------------------------------
; 1-9 (komorebi, no native virtual desktops)
#1::Komorebic('focus-workspace 0')               ; go to workspace N
#2::Komorebic('focus-workspace 1')
#3::Komorebic('focus-workspace 2')
#4::Komorebic('focus-workspace 3')
#5::Komorebic('focus-workspace 4')
#6::Komorebic('focus-workspace 5')
#7::Komorebic('focus-workspace 6')
#8::Komorebic('focus-workspace 7')
#9::Komorebic('focus-workspace 8')

#+1::Komorebic('move-to-workspace 0')            ; move window to workspace N
#+2::Komorebic('move-to-workspace 1')
#+3::Komorebic('move-to-workspace 2')
#+4::Komorebic('move-to-workspace 3')
#+5::Komorebic('move-to-workspace 4')
#+6::Komorebic('move-to-workspace 5')
#+7::Komorebic('move-to-workspace 6')
#+8::Komorebic('move-to-workspace 7')
#+9::Komorebic('move-to-workspace 8')

#^1::Komorebic('send-to-workspace 0')            ; send window, focus stays
#^2::Komorebic('send-to-workspace 1')
#^3::Komorebic('send-to-workspace 2')
#^4::Komorebic('send-to-workspace 3')
#^5::Komorebic('send-to-workspace 4')
#^6::Komorebic('send-to-workspace 5')
#^7::Komorebic('send-to-workspace 6')
#^8::Komorebic('send-to-workspace 7')
#^9::Komorebic('send-to-workspace 8')

; --- Monitors ------------------------------------------------------------------
#,::Komorebic('cycle-monitor previous')          ; focus previous monitor
#.::Komorebic('cycle-monitor next')              ; focus next monitor
#+,::Komorebic('cycle-move-to-monitor previous') ; move to previous monitor
#+.::Komorebic('cycle-move-to-monitor next')     ; move to next monitor
#^,::Komorebic('cycle-send-to-monitor previous') ; send to previous monitor
#^.::Komorebic('cycle-send-to-monitor next')     ; send to next monitor
#!+,::Komorebic('cycle-move-workspace-to-monitor previous')  ; move workspace to prev monitor
#!+.::Komorebic('cycle-move-workspace-to-monitor next')      ; move workspace to next monitor

; ============================================================================
; ShareX
; ============================================================================
; Direct, bypasses winarchy's CLI/module entirely.
ShareXExe := FileExist(A_ProgramFiles "\ShareX\ShareX.exe")
    ? A_ProgramFiles "\ShareX\ShareX.exe"
    : (FileExist(EnvGet('ProgramFiles(x86)') "\ShareX\ShareX.exe") ? EnvGet('ProgramFiles(x86)') "\ShareX\ShareX.exe" : "")

Sharex(action) {
    global ShareXExe
    if !ShareXExe {
        TrayTip('ShareX is not installed (winget install ShareX.ShareX)', '710sRice')
        return
    }
    Run('"' ShareXExe '" -' action, , 'Hide')
}

#+s::Sharex('RectangleRegion')                    ; region capture
#+w::Sharex('ActiveWindow')                        ; active window capture
#+p::Sharex('PrintScreen')                         ; fullscreen capture
#+v::Sharex('ScreenRecorder')                      ; screen recording
#^v::Sharex('StopScreenRecording')                 ; stop recording
#^q::Sharex('QRCodeScanRegion')                     ; decode a QR on screen
#^o::Sharex('OCR')                                  ; text from screen
#+g::Sharex('ScreenRecorderGIF')                    ; GIF recording

; ============================================================================
; App launchers
; ============================================================================
; Reads the real default-browser registry association rather than assuming
; one -- ported from winarchy's DefaultBrowser(). Falls back to Edge (always
; present on Windows 11) if the registry read fails for any reason.
DefaultBrowser() {
    try {
        progId := RegRead('HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice', 'ProgId')
        cmd := RegRead('HKCR\' progId '\shell\open\command')
        exe := RegExReplace(cmd, '^"([^"]+)".*$', '$1')
        if FileExist(exe)
            return exe
    }
    return 'msedge.exe'
}

; Chromeless app-mode window (--app=, Chromium-based browsers only -- Firefox
; would just open a normal tab instead). Ported from winarchy's WebApp().
WebApp(url) {
    Run('"' DefaultBrowser() '" --app=' url)
}

#b::Run(DefaultBrowser())                         ; default browser
#e::Run('explorer.exe')                           ; file explorer
#y::WebApp('https://youtube.com')                 ; YouTube

; Best-effort path -- %LOCALAPPDATA%\Claude is walled off from the device
; bridge that built this (Claude's own app-data folders are protected), so
; this couldn't be directly verified the way everything else in this file
; is. Standard install location for this kind of app on Windows; if it's
; wrong the TrayTip below will say so rather than silently doing nothing.
LaunchClaudeDesktop() {
    ; The Claude desktop app is a packaged (MSIX) app: its exe sits in a
    ; versioned folder under Program Files\WindowsApps that changes with every
    ; update, so it's launched by its app ID, the way the Start menu does it.
    ; (The old guess, %LOCALAPPDATA%\Claude\Claude.exe, is only the app's data
    ; folder -- plan item 26.) App ID from
    ; `Get-StartApps | Where-Object Name -like '*Claude*'` (2026-09-24). The
    ; package's own folder under %LOCALAPPDATA%\Packages exists once it's
    ; installed, so that's the "is it installed" check.
    if !DirExist(EnvGet('LOCALAPPDATA') '\Packages\Claude_pzs8sxrjxfjjc') {
        TrayTip('The Claude desktop app is not installed', '710sRice')
        return
    }
    try Run('shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude')
    catch as e
        TrayTip("Couldn't start the Claude desktop app: " e.Message, '710sRice')
}

#+a::LaunchClaudeDesktop()                        ; Claude Desktop (SUPER+Shift+A)

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
; Colors: sensible dark fallbacks are used until wallust has written its CSS
; (fresh checkout, before the first wallpaper switch).
; ============================================================================
WallustCss := RepoRoot "\config\yasb\wallust_colors.css"
MenuBgHex := '2B2B2B', MenuFgHex := 'E0E0E0', MenuAccentHex := '5C41A5', MenuAccentTextHex := 'FAF1FD'
MenuMutedHex := '9A9A9A'   ; secondary/hint text -- used by the key overlay's description column

RefreshMenuColors() {
    global WallustCss, MenuBgHex, MenuFgHex, MenuAccentHex, MenuAccentTextHex, MenuMutedHex
    if !FileExist(WallustCss)
        return   ; keep the fallback colors above
    css := FileRead(WallustCss)
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
}

Pal := ''

PalColors() {
    global MenuBgHex, MenuFgHex, MenuAccentHex, MenuMutedHex
    RefreshMenuColors()       ; re-read on every open -- a wallpaper change recolors the next menu, no reload
    return {bg: MenuBgHex, fg: MenuFgHex, ac: MenuAccentHex, mut: MenuMutedHex}
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

PalOpen(mode, items, title) {
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
    ed.OnEvent('Change', (*) => PalRefresh())
    g.OnEvent('Close', (*) => PalClose())
    PalRefresh()

    g.Show(Format('x{} y{} w{} h{}', wl + (wr - wl - Round(w * dpi)) // 2, wt + (wb - wt - Round(h * dpi)) // 2, w, h))
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

PalHint(it) => it.HasOwnProp('sub') ? Chr(0x203A) : (it.HasOwnProp('hint') ? it.hint : '')

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
        ; selected row: background color as text on the accent bar -- same as our old menus
        r.label.SetFont((head ? 'bold' : 'norm') ' c' (on ? c.bg : head ? c.ac : e.HasOwnProp('empty') ? c.mut : c.fg))
        r.hint.SetFont('c' (on ? c.bg : Pal.mode = 'keys' ? c.fg : c.mut))
        r.label.Text := ' ' e.text
        r.hint.Text := e.hint ' '
    }
}

PalMove(d) {
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
    it.action.Call()
}

PalBack() {
    if !Pal.stack.Length
        return
    prev := Pal.stack.Pop()
    Pal.items := prev.items, Pal.title := prev.title
    PalRefresh(prev.sel)
}

PalEscape() {
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
    if !IsObject(Pal) || (lParam = Pal.mouse)    ; ignore synthetic moves after a redraw
        return
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
    if IsObject(Pal)
        Pal.pressed := PalIndexAtCursor(hwnd)
}

PalClick(wParam, lParam, msg, hwnd) {
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

; ============================================================================
; Key overlay
; ============================================================================
; SUPER+K, ported from winarchy's ToggleKeyOverlay()/ParseKeymap(). Parses
; this very script's own source (+ user.ahk) for hotkey lines and their
; trailing "; comment" description, grouped under whichever section header
; precedes them -- so the list can never drift out of sync with the actual
; bindings. Shown in the palette above (searchable, one scrolling list with
; section headers) since 2026-09-23; before that it was our own 4-column
; overlay.
;
; ParseKeymap recognizes both of this file's section-header styles: the
; three-line "; ====.../ ; Title / ; ====..." banner used for the big
; top-level sections, AND winarchy's own original single-line
; "; --- Title ---" divider, which this file already uses as sub-dividers
; INSIDE some of those bigger sections (e.g. "komorebi" contains its own
; Windows/Focus/Move window/Stacks/Resize/Workspaces/Monitors dividers) --
; without both, the "komorebi" section alone would dump 78 hotkeys under one
; heading. Sections with no hotkeys (like the Palette one) just don't show.
ParseKeymap(path, defaultTitle := '') {
    sections := []
    cur := ''
    if (defaultTitle != '') {
        cur := {title: defaultTitle, items: []}
        sections.Push(cur)
    }
    state := 0, pendingTitle := ''   ; 0=idle, 1=saw an opening "; ====" line, 2=saw the title line after it
    for line in StrSplit(FileRead(path, 'UTF-8'), '`n') {
        line := RTrim(line, '`r')
        if RegExMatch(line, '^; --- (.+?) -{2,}', &m) {
            cur := {title: Trim(m[1]), items: []}
            sections.Push(cur)
            state := 0
            continue
        }
        if RegExMatch(line, '^; =+$') {
            if (state = 2) {
                cur := {title: pendingTitle, items: []}
                sections.Push(cur)
            }
            state := (state = 2) ? 0 : 1
            continue
        }
        if (state = 1) && RegExMatch(line, '^; (.+)$', &m) {
            pendingTitle := Trim(m[1])
            state := 2
            continue
        }
        state := 0
        if !IsObject(cur) || !RegExMatch(line, '^#([+^!]*)(.+?)::(.*)$', &m)
            continue
        mods := m[1], key := m[2], rest := m[3]
        ; repetitive ranges collapsed to one entry (workspaces 1..9, arrow cluster)
        if RegExMatch(key, '^[2-9]$') || key = 'Right' || key = 'Up' || key = 'Down'
            continue
        if (key = '1')
            key := '1..9'
        else if (key = 'Left')
            key := Chr(0x2190) '/' Chr(0x2192) '/' Chr(0x2191) '/' Chr(0x2193)
        desc := RegExMatch(rest, ';\s*(.+)$', &md) ? Trim(md[1]) : Trim(rest)
        disp := 'SUPER+' (InStr(mods, '+') ? 'Shift+' : '') (InStr(mods, '^') ? 'Ctrl+' : '') (InStr(mods, '!') ? 'Alt+' : '') key
        cur.items.Push({keys: disp, desc: StrUpper(SubStr(desc, 1, 1)) SubStr(desc, 2)})
    }
    return sections
}

ToggleKeyOverlay(*) {
    if PalClosed('keys')
        return
    sections := ParseKeymap(A_ScriptFullPath)
    if FileExist(A_ScriptDir '\user.ahk')
        for s in ParseKeymap(A_ScriptDir '\user.ahk', 'User')
            sections.Push(s)
    PalOpen('keys', sections, 'Keybindings')
}

#k::ToggleKeyOverlay()                             ; this keybindings list

; ============================================================================
; Power / system menu
; ============================================================================
; Real reboot/shutdown/sleep/lock actions, ported from winarchy's
; WinarchySysItems()/action functions -- rendered through the wallust-themed
; Gui menu above instead of a plain Settings-page link.
LaunchScreensaver() {
    try {
        scr := RegRead('HKCU\Control Panel\Desktop', 'SCRNSAVE.EXE')
        if FileExist(scr)
            Run('"' scr '" /s')
    }
}
LockWorkstation() {
    Run('rundll32.exe user32.dll,LockWorkStation', , 'Hide')
}
SleepSystem() {
    Run('rundll32.exe powrprof.dll,SetSuspendState 0,1,0', , 'Hide')
}
HibernateSystem() {
    Run('shutdown.exe /h', , 'Hide')
}
SignOutSystem() {
    Run('shutdown.exe /l', , 'Hide')
}
RestartSystem() {
    Run('shutdown.exe /r /t 0', , 'Hide')
}
ShutdownSystem() {
    Run('shutdown.exe /s /t 0', , 'Hide')
}

SysMenuItems := [
    {text: 'Settings...', action: (*) => Run('explorer.exe ms-settings:')},
    {text: 'Screensaver', action: (*) => LaunchScreensaver()},
    {text: 'Lock',        action: (*) => LockWorkstation()},
    {text: 'Sleep',       action: (*) => SleepSystem()},
    {text: 'Hibernate',   action: (*) => HibernateSystem()},
    {text: 'Sign out',    action: (*) => SignOutSystem()},
    {text: 'Restart',     action: (*) => RestartSystem()},
    {text: 'Shut down',   action: (*) => ShutdownSystem()} ]

#Esc::OpenSysMenu()

; ============================================================================
; Terminal
; ============================================================================
#Enter::LaunchOnCursorMonitor('wt.exe', 'ahk_class CASCADIA_HOSTING_WINDOW_CLASS')  ; Windows Terminal
                                    ; Windows Terminal (SUPER+Enter) -- WezTerm dropped, matches the
                                    ; user's own user.ahk override on winarchy. Forces the new window
                                    ; onto the cursor's monitor -- see LaunchOnCursorMonitor() above.

; ============================================================================
; Flow Launcher
; ============================================================================
; ToggleFlow()/ToggleFlowScoped() ported from winarchy's winarchy.ahk — real
; toggle logic, not a naive relaunch. Reuses Flow's own native Alt+Space
; show/hide for an already-running instance; only cold-launches the exe the
; very first time (post-logon), with a retry/focus loop for Flow's indexing
; delay. See claude/winarchy-decoupling-plan.md, Flow Launcher section.
FlowWindow := 'Flow.Launcher ahk_exe Flow.Launcher.exe'

ToggleFlow() {
    global FlowWindow
    flow := EnvGet('LOCALAPPDATA') '\FlowLauncher\Flow.Launcher.exe'
    if !FileExist(flow)
        return 0
    if ProcessExist('Flow.Launcher.exe') {
        wasVisible := WinExist(FlowWindow)
        Send('!{Space}')
        if wasVisible
            return 0
        hwnd := WinWait(FlowWindow, , 2)
        return hwnd ? hwnd : 0
    }
    ; Cold start: no process running yet (fresh logon), so Flow's own hotkey
    ; isn't registered either -- this is the one case a real launch is needed.
    Run('"' flow '"')
    ; Flow keeps indexing programs after logon and can take longer than a
    ; couple seconds -- wait longer here so the first press of the day isn't
    ; silently dropped.
    hwnd := WinWait(FlowWindow, , 5)
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
    ; keywords are set up by tools/setup-flow-launcher.ps1:
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

; ============================================================================
; Stay awake
; ============================================================================
AwakeFlag := StateDir "\stay-awake.flag"

ToggleStayAwake() {
    global AwakeFlag
    if FileExist(AwakeFlag) {
        DllCall('SetThreadExecutionState', 'UInt', 0x80000000)   ; ES_CONTINUOUS
        FileDelete(AwakeFlag)
        TrayTip('Stay awake: off', '710sRice')
    } else {
        ; ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
        DllCall('SetThreadExecutionState', 'UInt', 0x80000003)
        FileAppend('', AwakeFlag)
        TrayTip('Stay awake: on', '710sRice')
    }
}

#^w::ToggleStayAwake()             ; keep the machine awake

; ============================================================================
; Game mode -- state tracking only, NOT floating. games.toml-listed exes are
; already floated unconditionally by komorebi's own compiled rules (see
; tools/compile-komorebi-rules.ps1 / the App rules section of the plan doc),
; regardless of whether this flag is set. This watcher exists to (a) give the
; tray/main menu a live ON/OFF indicator and (b) hot-reload games.toml when a
; game is first detected. Ported from winarchy's winarchy.ahk @ 4574fc7 --
; ToggleGameMode() drops the Winarchy('game-mode on/off') CLI call per the
; plan doc's "gets a small rewrite" note and just flips the flag file
; directly, matching ToggleStayAwake()'s existing pattern in this file. The
; unused MonitorGetPrimary() probe in winarchy's original fullscreen-check
; (never read again once the per-monitor loop below it starts) is dropped
; here as dead code, not a behavior change.
; ============================================================================
GameExes := Map()
LoadGames() {
    global GameExes, GamesToml
    GameExes := Map()
    if !FileExist(GamesToml)
        return
    for line in StrSplit(FileRead(GamesToml, 'UTF-8'), '`n') {
        if RegExMatch(line, 'i)^\s*exe\s*=\s*"([^"]+)"', &m) {
            exe := StrLower(m[1])
            if !InStr(exe, '*')
                GameExes[exe] := true
        }
    }
}
LoadGames()

GameModeActive := false
SetTimer(GameWatch, 1000)

GameWatch() {
    global GameModeActive, GameFlag, GameExes
    active := false

    ; 1) Manual/tray flag
    if FileExist(GameFlag)
        active := true

    ; 2) Foreground process listed in games.toml
    if !active {
        try {
            exe := StrLower(WinGetProcessName('A'))
            if GameExes.Has(exe) || GameExes.Has(RegExReplace(exe, '\.exe$'))
                active := true
        }
    }

    ; 3) Safety net: fullscreen-exclusive (no caption, covers a whole monitor)
    if !active {
        try {
            hwnd := WinGetID('A')
            style := WinGetStyle(hwnd)
            if !(style & 0xC00000) {            ; no WS_CAPTION
                WinGetPos(&x, &y, &w, &h, hwnd)
                loop MonitorGetCount() {
                    MonitorGet(A_Index, &l, &t, &r, &b)
                    if (x <= l && y <= t && x + w >= r && y + h >= b) {
                        exe := StrLower(WinGetProcessName(hwnd))
                        ; never treat shell/desktop/the bar itself as a game
                        if exe != 'explorer.exe' && exe != 'searchhost.exe' && exe != 'yasb.exe'
                            active := true
                        break
                    }
                }
            }
        }
    }

    if (active && !GameModeActive) {
        GameModeActive := true
        LoadGames()                              ; pick up any hot-added game
    } else if (!active && GameModeActive) {
        GameModeActive := false
    }
}

ToggleGameMode() {
    global GameFlag
    if FileExist(GameFlag) {
        FileDelete(GameFlag)
        TrayTip('Game mode: off', '710sRice')
    } else {
        FileAppend('', GameFlag)
        TrayTip('Game mode: on', '710sRice')
    }
}

; ============================================================================
; YASB watchdog
; ============================================================================
; Ported from winarchy bb72240 (v1.5.0), with three changes agreed 2026-09-23:
;  - The relaunch goes through YASB's own autostart task (schtasks /Run) -- the
;    same door boot and SUPER+Shift+R use. That buys Start-Yasb.ps1's
;    wait-for-desktop + retry loop, a hidden launch, and LeastPrivilege every
;    time: the bar never comes back elevated even if AHK somehow is (the
;    elevated-Terminal trap from the SUPER+Shift+R testing).
;  - Armed only once yasb.exe has actually been seen running. Getting YASB up at
;    boot is Start-Yasb.ps1's job (it retries for a full minute); this is the
;    crash net for afterwards.
;  - Gives up pointing at yasb-autostart.log (no doctor yet). Every relaunch and
;    the give-up get their own line in that log, so it tells the story.
; A 5s check only counts as a miss when yasb.exe is gone AND nothing is already
; bringing it back: winget running (an install/upgrade), or a Start-Yasb.ps1
; launcher still alive (boot, SUPER+Shift+R, or our own previous relaunch still
; working). Two misses in a row (5-10s with no bar) = relaunch. Three relaunches
; inside 5 minutes = YASB is crash-looping; stop and say so instead of thrashing.
; The crash itself, if YASB caught it, is in config\yasb\yasb.log.
; ============================================================================
YasbSeen := false, YasbMisses := 0, YasbRelaunches := []
YasbAutostartLog := EnvGet('LOCALAPPDATA') '\710.DesktopRice\yasb-autostart.log'
SetTimer(YasbWatch, 5000)

YasbWatch() {
    global YasbSeen, YasbMisses, YasbRelaunches
    if ProcessExist('yasb.exe') {
        YasbSeen := true, YasbMisses := 0
        return
    }
    if !YasbSeen || ProcessExist('winget.exe') || YasbLauncherRunning() {
        YasbMisses := 0
        return
    }
    if (++YasbMisses < 2)
        return
    YasbMisses := 0
    while YasbRelaunches.Length && A_TickCount - YasbRelaunches[1] > 300000
        YasbRelaunches.RemoveAt(1)
    if (YasbRelaunches.Length >= 3) {
        SetTimer(YasbWatch, 0)
        YasbLog('watchdog: YASB died again after 3 relaunches in 5 min -- stopped relaunching until AHK restarts.')
        TrayTip('The bar keeps crashing -- stopped relaunching it.`nSee %LOCALAPPDATA%\710.DesktopRice\yasb-autostart.log', '710sRice')
        return
    }
    YasbRelaunches.Push(A_TickCount)
    YasbLog('watchdog: yasb.exe gone for 2 checks -- relaunching via the autostart task (' YasbRelaunches.Length ' of 3 in 5 min).')
    try code := RunWait('schtasks.exe /Run /TN "\710.DesktopRice\yasb"', , 'Hide')
    catch
        code := -1
    if (code != 0) {
        ; No task = autostart was never activated (or got removed) -- nothing sane to relaunch with.
        SetTimer(YasbWatch, 0)
        YasbLog('watchdog: schtasks /Run failed (' code ') -- is the \710.DesktopRice\yasb task registered? Watchdog off.')
        TrayTip("Couldn't relaunch the bar (no autostart task?) -- watchdog off.`nSee %LOCALAPPDATA%\710.DesktopRice\yasb-autostart.log", '710sRice')
    }
}

; Is a Start-Yasb.ps1 launcher already on the job? Only asked when yasb.exe is
; missing, so the WMI query costs nothing in the normal case.
YasbLauncherRunning() {
    try {
        for p in ComObjGet('winmgmts:').ExecQuery("SELECT ProcessId FROM Win32_Process WHERE (Name = 'powershell.exe' OR Name = 'pwsh.exe') AND CommandLine LIKE '%Start-Yasb.ps1%'")
            return true
    }
    return false
}

; Same line format as Start-Yasb.ps1's own Write-Log. UTF-8-RAW: the file already
; exists with its BOM (PS 5.1 Out-File), so no BOM mid-file.
YasbLog(m) {
    global YasbAutostartLog
    try FileAppend(FormatTime(, 'yyyy-MM-dd HH:mm:ss') '  ' m '`n', YasbAutostartLog, 'UTF-8-RAW')
}

; ============================================================================
; Quick add rule (Tiling menu)
; ============================================================================
; Click-to-pick a window, choose what to match it on (exe / class / title,
; showing that window's real values) and which rule (Float / Ignore / Manage),
; and it lands in config\komorebi\rules.toml via tools\add-rule.ps1 (ported
; from winarchy's Add-WinarchyUserRule -- winarchy only ever had a CLI for
; this, no UI). add-rule.ps1 also applies the rule to the picked window right
; away, because komorebi only applies rules to windows opened AFTER them (the
; 2026-09-23 Notepad test); then SUPER+Shift+R's reload makes it stick for
; every future window. A rule addition always rides komorebi's fast hot-reload
; path, so layouts survive. Every menu here is the palette -- same look,
; search and back-nav as SUPER+Esc / SUPER+Alt+Space.
;
; Picking is a tooltip + a temporary blocking *LButton hotkey, NOT a swapped
; system crosshair cursor: if anything died mid-pick, a changed system cursor
; would stay changed; a tooltip and a hook hotkey just go away with it.
QuickPickActive := false, QuickTarget := ''

QuickAddRule(*) {
    global QuickPickActive
    if QuickPickActive
        return
    QuickPickActive := true
    HotIf()                                   ; the two temp hotkeys live in the plain global context
    Hotkey('*LButton', QuickPickClick, 'On')  ; blocking: the pick-click never reaches the window
    Hotkey('*Esc', QuickPickCancel, 'On')
    SetTimer(QuickPickTip, 50)
    SetTimer(QuickPickTimeout, -15000)        ; walked away mid-pick? give the mouse back
}

QuickPickTip() {
    ToolTip('Click the window to add a rule for   (Esc cancels)')
}

QuickPickEnd() {
    global QuickPickActive
    QuickPickActive := false
    SetTimer(QuickPickTip, 0)
    SetTimer(QuickPickTimeout, 0)
    ToolTip()
    try Hotkey('*LButton', 'Off')
    try Hotkey('*Esc', 'Off')
}

QuickPickCancel(*) {
    QuickPickEnd()
    TrayTip('Quick add rule cancelled', '710sRice')
}

QuickPickTimeout() {
    global QuickPickActive
    if QuickPickActive
        QuickPickCancel()
}

QuickPickClick(*) {
    global QuickTarget
    QuickPickEnd()
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
        TrayTip("Couldn't read that window (an admin window?) -- quick add cancelled", '710sRice')
        return
    }
    ; Not app windows: the desktop, the taskbars, the YASB bar, and this script's own GUIs.
    if (cls ~= '^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd)$')
        || (StrLower(exe) = 'yasb.exe') || (pid = DllCall('GetCurrentProcessId')) {
        TrayTip("That's not an app window -- quick add cancelled", '710sRice')
        return
    }
    QuickTarget := {hwnd: root}
    ; exe first so Enter takes the common case. Full values: the palette's label
    ; column ends anything too long in "..." on its own (and search still sees
    ; the whole value).
    items := [
        {text: 'exe: '   exe, sub: QuickRuleItems('exe', exe)},
        {text: 'class: ' cls, sub: QuickRuleItems('class', cls)} ]
    if (title != '')
        items.Push({text: 'title: ' title, sub: QuickRuleItems('title', title)})
    PalOpen('quick', items, 'Match on')
}

QuickRuleItems(field, value) {
    return [
        {text: 'Float (never tile)',  action: (*) => QuickApplyRule('floating', field, value)},
        {text: 'Ignore (hands off)',  action: (*) => QuickApplyRule('ignore', field, value)},
        {text: 'Manage (force tile)', action: (*) => QuickApplyRule('manage', field, value)} ]
}

QuickApplyRule(cat, field, value) {
    global QuickTarget, RepoRoot
    hwnd := QuickTarget.hwnd
    if !WinExist('ahk_id ' hwnd) {
        TrayTip('That window closed -- quick add cancelled', '710sRice')
        return
    }
    ; add-rule.ps1's apply-now komorebic calls act on the FOCUSED window
    try WinActivate('ahk_id ' hwnd)
    WinWaitActive('ahk_id ' hwnd, , 1)
    ; The value rides in the environment, never quoted onto a command line --
    ; window titles can hold anything. Cleared again straight after.
    EnvSet('QUICKADD_VALUE', value)
    try {
        code := RunWait('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' RepoRoot '\tools\add-rule.ps1" -Category ' cat ' -Field ' field ' -Hwnd ' hwnd, , 'Hide')
    } catch as e {
        EnvSet('QUICKADD_VALUE')
        TrayTip('Quick add could not start: ' e.Message, '710sRice')
        return
    }
    EnvSet('QUICKADD_VALUE')
    label := Map('floating', 'Float', 'ignore', 'Ignore', 'manage', 'Manage')[cat]
    switch code {
        case 0: ReloadStack(label ' rule added (' field ' ' value ')')
        case 2: ReloadStack(label ' rule added, not applied to that window (see add-rule.log)')
        case 3: TrayTip('Already in rules.toml (' label ' ' field ' ' value ') -- applied to that window', '710sRice')
        default: TrayTip('Rule not added (see add-rule.log)', '710sRice')
    }
}

; ============================================================================
; Tray + main menu (Apps / Capture / Tiling / Game mode)
; ============================================================================
; Shared {text, action} / {text, sub:[...]} item structure (same shape
; SysMenuItems above already uses, plus an optional hint -- the palette drills
; into a `sub` array and Esc/Backspace come back, arbitrarily deep). Fed to
; TWO different renderers:
;   - the real tray icon's right-click, via native A_TrayMenu -- Windows
;     draws that menu itself and it can't be themed; winarchy's own comment
;     on this exact point: "the tray's right-click still uses native
;     A_TrayMenu... equally functional fallback." Unavoidable, not a gap.
;   - SUPER+Alt+Space, via the palette -- the wallust-themed, searchable
;     popup shared with SUPER+Esc and SUPER+K. Key hints show right-aligned
;     in both (the tray through NativeMenuName's tab).
; Ported from winarchy's SetupTray()/WinarchyCaptureItems()/
; WinarchyTilingItems(). Themes and Bar submenus are dropped (both
; eliminated entirely elsewhere in this repo -- see the plan doc's Palette
; and YASB sections); Doctor is left out rather than wired to nothing,
; since it isn't built yet in this repo. Capture's action strings are Sharex()'s real ShareX CLI switches,
; matching this file's own 8 already-wired capture hotkeys exactly (not
; winarchy's old Winarchy('screenshot ...') CLI pass-through, and not the 5
; extra ShareX actions winarchy exposes that this repo never wired a hotkey
; for) -- the exact fix the plan doc's App rules/AHK section already flagged
; as still owed ("Capture menu items -- small consistency fix while
; rewriting").
CaptureItems := [
    {text: 'Region',                 hint: 'SUPER+Shift+S', action: (*) => Sharex('RectangleRegion')},
    {text: 'Active window',          hint: 'SUPER+Shift+W', action: (*) => Sharex('ActiveWindow')},
    {text: 'Full screen',            hint: 'SUPER+Shift+P', action: (*) => Sharex('PrintScreen')},
    {text: 'Record',                 hint: 'SUPER+Shift+V', action: (*) => Sharex('ScreenRecorder')},
    {text: 'Stop recording',         hint: 'SUPER+Ctrl+V',  action: (*) => Sharex('StopScreenRecording')},
    {text: 'Record as GIF',          hint: 'SUPER+Shift+G', action: (*) => Sharex('ScreenRecorderGIF')},
    {text: 'Text from screen (OCR)', hint: 'SUPER+Ctrl+O',  action: (*) => Sharex('OCR')},
    {text: 'Scan QR code',           hint: 'SUPER+Ctrl+Q',  action: (*) => Sharex('QRCodeScanRegion')} ]

TilingItems := [
    {text: 'Quick add rule...',                          action: (*) => QuickAddRule()},
    {text: 'Manage this window',                         action: (*) => Komorebic('manage')},
    {text: 'Unmanage this window',                        action: (*) => Komorebic('unmanage')},
    {text: 'Stop tiling this workspace', hint: 'SUPER+Shift+Z', action: (*) => Komorebic('toggle-tiling')},
    {text: 'New windows: stack / tile',                   action: (*) => Komorebic('toggle-window-container-behaviour')},
    {text: 'Title bars',                                  action: (*) => Komorebic('toggle-title-bars')},
    {text: 'Mouse follows focus',                         action: (*) => Komorebic('toggle-mouse-follows-focus')},
    {text: 'Restore hidden windows',                      action: (*) => Komorebic('restore-windows')} ]

; Built fresh each open (not a static array) so Game mode / Stay awake show
; their CURRENT state ("Game mode . on") -- winarchy's OnOff() wording, short
; enough to leave room for the key hint column.
OnOff(flag) => Chr(0xB7) ' ' (FileExist(flag) ? 'on' : 'off')

MainMenuItems() {
    global GameFlag, AwakeFlag
    return [
        {text: 'Apps',                     hint: 'SUPER+Ctrl+Space', action: (*) => ToggleFlowScoped('app ')},
        {text: 'Files',                    hint: 'SUPER+S',          action: (*) => ToggleFlowScoped('f ')},
        {text: 'Capture',                                            sub: CaptureItems},
        {text: 'Tiling',                                             sub: TilingItems},
        {text: 'Keybindings',              hint: 'SUPER+K',          action: (*) => ToggleKeyOverlay()},
        {text: 'Game mode ' OnOff(GameFlag),                         action: (*) => ToggleGameMode()},
        {text: 'Stay awake ' OnOff(AwakeFlag), hint: 'SUPER+Ctrl+W', action: (*) => ToggleStayAwake()},
        {text: 'Reload stack',             hint: 'SUPER+Shift+R',    action: (*) => ReloadStack()},
        {text: 'System',                   hint: 'SUPER+Esc',        sub: SysMenuItems},
        {text: 'Quit 710sRice',                                      action: (*) => QuitStack()} ]
}

OpenMainMenu(*) {
    if !PalClosed('menu')
        PalOpen('menu', MainMenuItems(), '710sRice')
}

; YASB's home widget "Main Menu" entry runs config\ahk\open-main-menu.ahk, which
; posts this registered message to our hidden window (YASB can only launch
; programs). Opened on a new thread so the message handler returns at once.
OnMessage(DllCall('RegisterWindowMessage', 'Str', '710sRice.OpenMainMenu', 'UInt'), (*) => SetTimer(OpenMainMenu, -1))

; Builds a native Menu() tree from the shared {text, action}/{text, sub}
; structure -- recursive so Capture/Tiling/System (all one level deep today)
; and any deeper nesting later both just work.
BuildNativeMenu(menuObj, items) {
    for item in items {
        if item.HasOwnProp('sub') {
            childMenu := Menu()
            BuildNativeMenu(childMenu, item.sub)
            menuObj.Add(NativeMenuName(item), childMenu)
        } else {
            menuObj.Add(NativeMenuName(item), item.action)
        }
    }
}

; A tab in a native menu item's name puts what follows in Windows' own
; right-aligned accelerator column -- so the tray shows the same key hints as
; the palette.
NativeMenuName(item) => item.text (item.HasOwnProp('hint') ? '`t' item.hint : '')

SetupTray() {
    ico := RepoRoot "\assets\logo\710rice.ico"
    if FileExist(ico)
        try TraySetIcon(ico)   ; no logo asset exists yet -- keeps AHK's default until one does
    A_IconTip := '710sRice'

    tray := A_TrayMenu
    tray.Delete()               ; drop AHK's default Pause/Suspend/Reload/Edit menu
    BuildNativeMenu(tray, MainMenuItems())
    try tray.Default := NativeMenuName(MainMenuItems()[1])   ; Apps -- try: a name mismatch must never stop AHK loading
    tray.ClickCount := 1        ; single left-click runs Default, matching winarchy
}
SetupTray()

#!Space::OpenMainMenu()             ; main menu (Apps/Capture/Tiling/Game mode/...)

; SUPER+Shift+R. tools\reload-stack.ps1 does the actual stack work (compile
; rules, keep live layouts across komorebi's reload, wallust borders -> YASB kill and
; restart); this just runs it, says how it went,
; and then restarts THIS script -- the one step the PS script can't do itself
; without killing its own caller, and the reason AHK goes last. RunWait only
; parks this hotkey's thread, so every other hotkey stays live meanwhile.
; Exit codes are reload-stack.ps1's: 0 ok, 1 rules didn't compile (nothing
; was touched, so AHK isn't restarted either), 2 partial (see the log).
ReloadStack(note := '', *) {
    static running := false
    if running                  ; double-tap while the first one's mid-flight
        return
    running := true
    TrayTip('Reloading stack...', '710sRice')
    script := RepoRoot '\tools\reload-stack.ps1'
    try {
        code := RunWait('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' script '"', , 'Hide')
    } catch as e {
        running := false
        TrayTip('Reload could not start: ' e.Message, '710sRice')
        return
    }
    if (code = 1) {
        running := false
        TrayTip((note != '' ? note ', but ' : '') 'rules failed to compile -- nothing reloaded (see reload-stack.log)', '710sRice')
        return
    }
    ; `note` lets a caller (Quick add rule) say what just changed; empty for a plain SUPER+Shift+R
    TrayTip((note != '' ? note '. ' : '') (code = 0 ? 'Stack reloaded' : 'Reloaded, with errors (see reload-stack.log)'), '710sRice')
    Sleep(1500)                 ; let the toast land before this process swaps itself out
    Reload()
}

QuitStack() {
    ; Ordered, non-elevated stop -- the same set as scripts\Stop-All.ps1
    ; (Stop-RunningComponents in tools\lib\activation.ps1): komorebi, the
    ; bar/capture tools, AHK last. Flow Launcher isn't touched -- it's not one of
    ; this repo's autostart components and manages its own lifecycle.
    try Komorebic('stop')
    try RunWait('taskkill /IM yasb.exe /F', , 'Hide')
    try RunWait('taskkill /IM ShareX.exe /F', , 'Hide')
    ExitApp()
}

; ============================================================================
; User overrides (config\ahk\user.ahk, gitignored -- per-machine only, same
; pattern as winarchy's own user.ahk: survives a `git pull` updating this
; file, the same way winarchy's version survives `winarchy update`)
; ============================================================================
#Include *i %A_ScriptDir%\user.ahk
