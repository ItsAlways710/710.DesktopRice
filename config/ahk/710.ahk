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

; --- Windows -----------------------------------------------------------
#x::Komorebic('close')                           ; close window
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
    exe := EnvGet('LOCALAPPDATA') '\Claude\Claude.exe'
    if FileExist(exe)
        Run('"' exe '"')
    else
        TrayTip('Claude Desktop not found at ' exe, '710sRice')
}

#+a::LaunchClaudeDesktop()                        ; Claude Desktop (SUPER+Shift+A)

; ============================================================================
; Menu theming (wallust-driven, ported from winarchy's own GUI menu system)
; ============================================================================
; The owner-drawn native Menu() approach tried first left an unfixable plain
; white 1px border around the popup (two different fixes -- DWM border-color
; and stripping WS_BORDER/WS_DLGFRAME -- both had zero effect). Turns out
; winarchy's own themed menus were never native Menu() objects at all --
; ShowSystemMenu()/RenderMenu() in winarchy.ahk build a plain AHK Gui() with
; -Caption (no title bar or system border to fight), draw the rows and
; selection bar by hand, and round the corners via DWM -- which DOES work,
; because DWM's frame attributes apply to real top-level windows like a Gui,
; just not to the internal #32768 popup-menu class the first attempt used.
; This is that same mechanism, ported and re-pointed at wallust's colors
; instead of winarchy's theme.ini.
;
; To theme a future menu (the tray Apps/Capture/Tiling/Game Mode menu): build
; its items as an array of {text, action} (or {text, sub: [...]} for a
; submenu -- same shape SysMenuItems below uses, back-nav via Backspace comes
; free) and call ShowThemedGuiMenu(items, 'Title').
;
; Sensible dark-theme fallbacks are used if the CSS doesn't exist yet (fresh
; checkout, before the first wallpaper switch has ever run wallust).
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

ThemedMenuGui := '', ThemedMenuStack := [], ThemedMenuItems := [], ThemedMenuSel := 1
ThemedMenuRows := [], ThemedMenuTitle := '', ThemedMenuSelBar := ''

ShowThemedGuiMenu(items, title) {
    global ThemedMenuGui, ThemedMenuItems, ThemedMenuSel, ThemedMenuRows, ThemedMenuTitle, ThemedMenuSelBar
    global MenuBgHex, MenuFgHex, MenuAccentHex, MenuAccentTextHex
    SetTimer(ThemedMenuWatch, 0)
    SetTimer(ThemedMenuHoverWatch, 0)
    if (ThemedMenuGui != '') {
        try ThemedMenuGui.Destroy()
        ThemedMenuGui := ''
    }
    ThemedMenuItems := items, ThemedMenuSel := 1, ThemedMenuRows := [], ThemedMenuTitle := title
    bg := MenuBgHex, fg := MenuFgHex, ac := MenuAccentHex

    g := Gui('-Caption +AlwaysOnTop +ToolWindow', '710sRiceMenu')
    g.BackColor := bg
    g.MarginX := 0, g.MarginY := 0

    pad := 16, rowH := 30, titleH := 32, labelW := 220
    w := pad * 2 + labelW

    ; JetBrainsMono Nerd Font, not Segoe UI: install.ps1 installs it unconditionally
    ; (DEVCOM.JetBrainsMonoNerdFont), so there's no silent-fallback risk to hedge against
    ; here -- matches winarchy's own themed system menu, which relies on the same font.
    g.SetFont('s12 bold', 'JetBrainsMono Nerd Font')
    g.Add('Text', Format('x{} y{} w{} c{}', pad, pad, labelW, ac), title)

    g.SetFont('s11 norm', 'JetBrainsMono Nerd Font')
    y0 := pad + titleH
    ; selection bar added first so it sits behind the (BackgroundTrans) row
    ; text, then gets moved onto the active row by SetThemedMenuSel().
    ThemedMenuSelBar := g.Add('Text', Format('x{} y{} w{} h{} Background{}', pad - 6, y0, labelW + 12, rowH, ac), '')
    for i, it in items {
        y := y0 + (i - 1) * rowH
        lbl := g.Add('Text', Format('x{} y{} w{} h{} c{} BackgroundTrans', pad, y + 4, labelW, rowH, (i = 1) ? bg : fg), it.text)
        lbl.OnEvent('Click', ThemedMenuClick.Bind(i))
        ThemedMenuRows.Push({label: lbl, y: y})
    }
    h := y0 + items.Length * rowH + pad

    ; centered on whichever monitor the mouse is on -- plain Win32, no
    ; komorebi dependency, so the menu always lands where you're looking
    ; regardless of komorebi's own focus state.
    CoordMode('Mouse', 'Screen')
    MouseGetPos(&mx, &my)
    wl := 0, wt := 0, wr := A_ScreenWidth, wb := A_ScreenHeight
    loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (mx >= l && mx < r && my >= t && my < b) {
            MonitorGetWorkArea(A_Index, &wl, &wt, &wr, &wb)
            break
        }
    }
    g.OnEvent('Escape', (*) => ThemedMenuBack())
    g.OnEvent('Close', (*) => CloseThemedMenu())
    ThemedMenuGui := g
    g.Show(Format('x{} y{} w{} h{}', wl + (wr - wl - w) // 2, wt + (wb - wt - h) // 2, w, h))
    DllCall('dwmapi\DwmSetWindowAttribute', 'Ptr', g.Hwnd, 'Int', 33, 'Int*', 2, 'Int', 4)   ; DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND
    SetTimer(ThemedMenuWatch, 250)   ; auto-close on focus loss
    SetTimer(ThemedMenuHoverWatch, 50)   ; move the selection bar to whatever row the mouse is over
}

SetThemedMenuSel(n) {
    global ThemedMenuRows, ThemedMenuItems, ThemedMenuSel, ThemedMenuSelBar
    global MenuBgHex, MenuFgHex
    n := Mod(n - 1 + ThemedMenuItems.Length, ThemedMenuItems.Length) + 1   ; wrap circular, 1-based
    old := ThemedMenuRows[ThemedMenuSel]
    old.label.SetFont('c' MenuFgHex)
    cur := ThemedMenuRows[n]
    cur.label.SetFont('c' MenuBgHex)   ; sits on the accent bar -- background color reads as text there
    try ThemedMenuSelBar.Move(, cur.y)
    ThemedMenuSel := n
}

ThemedMenuNav(dir) {
    global ThemedMenuSel
    SetThemedMenuSel(ThemedMenuSel + dir)
}

ThemedMenuActivate() {
    global ThemedMenuItems, ThemedMenuSel
    ThemedMenuInvoke(ThemedMenuItems[ThemedMenuSel])
}

ThemedMenuClick(i, *) {
    global ThemedMenuItems
    SetThemedMenuSel(i)
    ThemedMenuInvoke(ThemedMenuItems[i])
}

ThemedMenuInvoke(it) {
    global ThemedMenuStack, ThemedMenuItems, ThemedMenuTitle, ThemedMenuSel
    if it.HasOwnProp('sub') {
        ThemedMenuStack.Push({items: ThemedMenuItems, title: ThemedMenuTitle, sel: ThemedMenuSel})
        ShowThemedGuiMenu(it.sub, it.text)
        return
    }
    CloseThemedMenu()
    it.action.Call()
}

ThemedMenuBack() {
    global ThemedMenuStack
    if ThemedMenuStack.Length {
        prev := ThemedMenuStack.Pop()
        ShowThemedGuiMenu(prev.items, prev.title)
        SetThemedMenuSel(prev.sel)
        return
    }
    CloseThemedMenu()
}

CloseThemedMenu() {
    global ThemedMenuGui, ThemedMenuStack
    SetTimer(ThemedMenuWatch, 0)
    SetTimer(ThemedMenuHoverWatch, 0)
    if (ThemedMenuGui != '') {
        try ThemedMenuGui.Destroy()
        ThemedMenuGui := ''
    }
    ThemedMenuStack := []
}

ThemedMenuWatch() {
    global ThemedMenuGui
    try {
        if (ThemedMenuGui != '') && !WinActive('ahk_id ' ThemedMenuGui.Hwnd)
            CloseThemedMenu()
    } catch {
        CloseThemedMenu()
    }
}

; Mouse-follows-selection -- polled rather than hooked off WM_MOUSEMOVE
; (Text controls don't reliably forward that to a single handler the way a
; Gui's own client area does), matched by comparing the hovered control's
; hwnd against each row's own -- AHK Gui controls expose .Hwnd natively, no
; extra bookkeeping needed at row-creation time.
ThemedMenuHoverWatch() {
    global ThemedMenuGui, ThemedMenuRows, ThemedMenuSel
    if (ThemedMenuGui = '')
        return
    MouseGetPos(, , , &ctrlHwnd, 2)   ; flag 2 -> ctrlHwnd is an HWND, not a ClassNN string
    for i, row in ThemedMenuRows {
        if (row.label.Hwnd = ctrlHwnd) && (i != ThemedMenuSel) {
            SetThemedMenuSel(i)
            break
        }
    }
}

; Keyboard nav, only while a themed menu is actually open.
#HotIf WinActive('710sRiceMenu ahk_class AutoHotkeyGUI')
Up::ThemedMenuNav(-1)
Down::ThemedMenuNav(1)
Enter::ThemedMenuActivate()
Backspace::ThemedMenuBack()
#HotIf

OpenSysMenu(*) {
    global ThemedMenuGui, ThemedMenuStack
    if (ThemedMenuGui != '') {          ; already open -- toggle closes
        CloseThemedMenu()
        return
    }
    RefreshMenuColors()
    ThemedMenuStack := []
    ShowThemedGuiMenu(SysMenuItems, 'System')
}

; ============================================================================
; Key overlay
; ============================================================================
; SUPER+K, ported from winarchy's ToggleKeyOverlay()/ParseKeymap(). Parses
; this very script's own source (+ user.ahk) for hotkey lines and their
; trailing "; comment" description, groups them under whichever section header
; precedes them, and lays the result out in balanced columns -- so the overlay
; can never drift out of sync with the actual bindings, because it reads them
; straight from the file instead of being a separately hand-maintained list.
;
; ParseKeymap recognizes both of this file's section-header styles: the
; three-line "; ====.../ ; Title / ; ====..." banner used for the big
; top-level sections, AND winarchy's own original single-line
; "; --- Title ---" divider, which this file already uses as sub-dividers
; INSIDE some of those bigger sections (e.g. "komorebi" contains its own
; Windows/Focus/Move window/Stacks/Resize/Workspaces/Monitors dividers) --
; without both, the "komorebi" section alone would dump 78 hotkeys under one
; heading, wildly outweighing every other column and running off-screen.
KeyOverlayGui := ''

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
        cur.items.Push({keys: disp, desc: desc})
    }
    return sections
}

ToggleKeyOverlay() {
    global KeyOverlayGui, MenuBgHex, MenuFgHex, MenuAccentHex, MenuMutedHex
    if (KeyOverlayGui != '') {
        CloseKeyOverlay()
        return
    }
    RefreshMenuColors()
    bg := MenuBgHex, fg := MenuFgHex, ac := MenuAccentHex, mut := MenuMutedHex

    sections := ParseKeymap(A_ScriptFullPath)
    if FileExist(A_ScriptDir '\user.ahk')
        for s in ParseKeymap(A_ScriptDir '\user.ahk', 'User')
            sections.Push(s)
    visible := []
    total := 0
    for s in sections {
        if !s.items.Length
            continue
        visible.Push(s)
        total += s.items.Length + 2          ; header + one blank row
    }
    if !visible.Length
        return

    g := Gui('-Caption +AlwaysOnTop +ToolWindow', '710sRice Keybindings')
    g.BackColor := bg
    g.MarginX := 0, g.MarginY := 0

    rowH := 24, keyW := 150, descW := 250, gap := 12, pad := 30
    colW := keyW + gap + descW + 28
    cols := total > 70 ? 4 : total > 34 ? 3 : 2

    ; Balanced column split -- recalculated only when actually moving to a new
    ; column (not per item, which would shrink the target as each column
    ; fills and hand off too early), so one long section doesn't dump
    ; everything after it into the last column unbounded.
    colOf := Map(), colRows := []
    loop cols
        colRows.Push(0)
    remaining := total, remainingCols := cols, c := 0, i := 0
    target := Ceil(remaining / remainingCols)
    for s in visible {
        i += 1
        blk := s.items.Length + 2
        if (c < cols - 1 && colRows[c + 1] > 0 && colRows[c + 1] + blk > target) {
            c += 1
            remainingCols -= 1
            target := Ceil(remaining / remainingCols)
        }
        colOf[i] := c
        colRows[c + 1] += blk
        remaining -= blk
    }
    usedRows := 0
    for r in colRows
        if (r > usedRows)
            usedRows := r
    col := 0, row := 0, i := 0
    for s in visible {
        i += 1
        blk := s.items.Length + 2
        if (colOf[i] != col)
            col := colOf[i], row := 0
        x := pad + col * colW
        ; JetBrainsMono Nerd Font here too, matching winarchy's key overlay -- see the
        ; themed-system-menu comment above for why this isn't a silent-fallback risk.
        g.SetFont('s10 bold', 'JetBrainsMono Nerd Font')
        g.Add('Text', Format('x{} y{} w{} c{} +0x0C', x, pad + row * rowH, keyW + gap + descW, ac), StrUpper(s.title))
        row += 1
        g.SetFont('s10 norm', 'JetBrainsMono Nerd Font')
        for it in s.items {
            y := pad + row * rowH
            g.Add('Text', Format('x{} y{} w{} c{} +0x0C', x, y, keyW, fg), it.keys)
            g.Add('Text', Format('x{} y{} w{} c{} +0x0C', x + keyW + gap, y, descW, mut), it.desc)
            row += 1
        }
        row += 1
        if (row > usedRows)
            usedRows := row
    }
    w := pad * 2 + cols * colW - 28
    h := pad * 2 + (usedRows - 1) * rowH

    ; centered on whichever monitor the mouse is on, same as the themed menu
    CoordMode('Mouse', 'Screen')
    MouseGetPos(&mx, &my)
    wl := 0, wt := 0, wr := A_ScreenWidth, wb := A_ScreenHeight
    loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (mx >= l && mx < r && my >= t && my < b) {
            MonitorGetWorkArea(A_Index, &wl, &wt, &wr, &wb)
            break
        }
    }
    g.OnEvent('Escape', (*) => CloseKeyOverlay())
    g.OnEvent('Close', (*) => CloseKeyOverlay())
    KeyOverlayGui := g
    g.Show(Format('x{} y{} w{} h{}', wl + (wr - wl - w) // 2, wt + (wb - wt - h) // 2, w, h))
    DllCall('dwmapi\DwmSetWindowAttribute', 'Ptr', g.Hwnd, 'Int', 33, 'Int*', 2, 'Int', 4)   ; DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND
    SetTimer(KeyOverlayWatch, 300)   ; auto-close on focus loss
}

CloseKeyOverlay() {
    global KeyOverlayGui
    SetTimer(KeyOverlayWatch, 0)
    if (KeyOverlayGui != '') {
        try KeyOverlayGui.Destroy()
        KeyOverlayGui := ''
    }
}

KeyOverlayWatch() {
    global KeyOverlayGui
    try {
        if (KeyOverlayGui != '') && !WinActive('ahk_id ' KeyOverlayGui.Hwnd)
            CloseKeyOverlay()
    } catch {
        CloseKeyOverlay()
    }
}

#k::ToggleKeyOverlay()                             ; this keybindings overlay

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
; ToggleFlow()/ToggleFlowApps() ported from winarchy's winarchy.ahk — real
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

ToggleFlowApps() {
    ; Same as ToggleFlow(), but preloads "app " in the query box. The "app"
    ; ActionKeyword is merged into Flow's own Settings.json by
    ; tools/setup-flow-launcher.ps1 (scoped to Flow's built-in Program
    ; plugin) -- real parity with Omarchy's Walker "Apps" launcher, no
    ; hand-curated list.
    if !ToggleFlow()
        return
    Sleep(50)
    Send('^a')
    SendText('app ')
}

#Space::ToggleFlow()              ; Flow Launcher
#s::ToggleFlow()                  ; Win+S (search) -- winarchy @ 4574fc7, ported as-is
#^Space::ToggleFlowApps()         ; Flow Launcher, apps only

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
; path, so layouts survive. Every menu here is ShowThemedGuiMenu -- same look
; and Backspace back-nav as SUPER+Esc / SUPER+Alt+Space.
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
    global QuickTarget, ThemedMenuStack
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
    ; exe first so Enter takes the common case. Values trimmed to fit the menu's
    ; fixed 220px rows (the real, untrimmed value is what gets written).
    items := [
        {text: 'exe: '   QuickTrunc(exe, 19), sub: QuickRuleItems('exe', exe)},
        {text: 'class: ' QuickTrunc(cls, 17), sub: QuickRuleItems('class', cls)} ]
    if (title != '')
        items.Push({text: 'title: ' QuickTrunc(title, 17), sub: QuickRuleItems('title', title)})
    RefreshMenuColors()
    ThemedMenuStack := []
    ShowThemedGuiMenu(items, 'Match on')
}

QuickTrunc(s, n) {
    return (StrLen(s) > n) ? SubStr(s, 1, n - 1) '…' : s
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
; SysMenuItems above already uses -- ShowThemedGuiMenu()'s back-stack drills
; into a `sub` array and Backspace returns, arbitrarily deep, for free; see
; ThemedMenuInvoke()/ThemedMenuBack()). Fed to TWO different renderers:
;   - the real tray icon's right-click, via native A_TrayMenu -- Windows
;     draws that menu itself and it can't be themed; winarchy's own comment
;     on this exact point: "the tray's right-click still uses native
;     A_TrayMenu... equally functional fallback." Unavoidable, not a gap.
;   - SUPER+Alt+Space, via ShowThemedGuiMenu() -- the wallust-themed popup,
;     consistent with the System menu (SUPER+Esc) and Key overlay (SUPER+K).
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
    {text: 'Region (SUPER+Shift+S)',                action: (*) => Sharex('RectangleRegion')},
    {text: 'Active window (SUPER+Shift+W)',         action: (*) => Sharex('ActiveWindow')},
    {text: 'Full screen (SUPER+Shift+P)',           action: (*) => Sharex('PrintScreen')},
    {text: 'Record (SUPER+Shift+V)',                action: (*) => Sharex('ScreenRecorder')},
    {text: 'Stop recording (SUPER+Ctrl+V)',         action: (*) => Sharex('StopScreenRecording')},
    {text: 'Record as GIF (SUPER+Shift+G)',         action: (*) => Sharex('ScreenRecorderGIF')},
    {text: 'Text from screen -- OCR (SUPER+Ctrl+O)', action: (*) => Sharex('OCR')},
    {text: 'Scan QR (SUPER+Ctrl+Q)',                action: (*) => Sharex('QRCodeScanRegion')} ]

TilingItems := [
    {text: 'Quick add rule...',                          action: (*) => QuickAddRule()},
    {text: 'Manage this window',                         action: (*) => Komorebic('manage')},
    {text: 'Unmanage this window',                        action: (*) => Komorebic('unmanage')},
    {text: 'Stop tiling this workspace (SUPER+Shift+Z)',  action: (*) => Komorebic('toggle-tiling')},
    {text: 'New windows: stack / tile',                   action: (*) => Komorebic('toggle-window-container-behaviour')},
    {text: 'Title bars',                                  action: (*) => Komorebic('toggle-title-bars')},
    {text: 'Mouse follows focus',                         action: (*) => Komorebic('toggle-mouse-follows-focus')},
    {text: 'Restore hidden windows',                      action: (*) => Komorebic('restore-windows')} ]

; Built fresh each open (not a static array) so Game mode / Stay awake show
; their CURRENT state -- matches winarchy's own dynamic hint text for these.
MainMenuItems() {
    global GameFlag, AwakeFlag
    return [
        {text: 'Apps (SUPER+Ctrl+Space)', action: (*) => ToggleFlowApps()},
        {text: 'Capture', sub: CaptureItems},
        {text: 'Tiling',  sub: TilingItems},
        {text: 'Game mode: ' (FileExist(GameFlag) ? 'ON (click to turn off)' : 'OFF (click to turn on)'),
            action: (*) => ToggleGameMode()},
        {text: 'Stay awake: ' (FileExist(AwakeFlag) ? 'ON (click to turn off)' : 'OFF (click to turn on)'),
            action: (*) => ToggleStayAwake()},
        {text: 'Reload stack (SUPER+Shift+R)', action: (*) => ReloadStack()},
        {text: 'System (SUPER+Esc)', sub: SysMenuItems},
        {text: 'Quit 710sRice', action: (*) => QuitStack()} ]
}

OpenMainMenu(*) {
    global ThemedMenuGui, ThemedMenuStack
    if (ThemedMenuGui != '') {          ; already open -- toggle closes
        CloseThemedMenu()
        return
    }
    RefreshMenuColors()
    ThemedMenuStack := []
    ShowThemedGuiMenu(MainMenuItems(), '710sRice')
}

; Builds a native Menu() tree from the shared {text, action}/{text, sub}
; structure -- recursive so Capture/Tiling/System (all one level deep today)
; and any deeper nesting later both just work.
BuildNativeMenu(menuObj, items) {
    for item in items {
        if item.HasOwnProp('sub') {
            childMenu := Menu()
            BuildNativeMenu(childMenu, item.sub)
            menuObj.Add(item.text, childMenu)
        } else {
            menuObj.Add(item.text, item.action)
        }
    }
}

SetupTray() {
    ico := RepoRoot "\assets\logo\710rice.ico"
    if FileExist(ico)
        try TraySetIcon(ico)   ; no logo asset exists yet -- keeps AHK's default until one does
    A_IconTip := '710sRice'

    tray := A_TrayMenu
    tray.Delete()               ; drop AHK's default Pause/Suspend/Reload/Edit menu
    BuildNativeMenu(tray, MainMenuItems())
    tray.Default := 'Apps (SUPER+Ctrl+Space)'
    tray.ClickCount := 1        ; single left-click runs Default, matching winarchy
}
SetupTray()

#!Space::OpenMainMenu()             ; main menu (Apps/Capture/Tiling/Game mode/...)

; SUPER+Shift+R. tools\reload-stack.ps1 does the actual stack work (compile
; rules, keep live layouts across komorebi's reload, wallust borders -> YASB kill and
; restart -> window-slots if it's down); this just runs it, says how it went,
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
    ; Ordered, non-elevated stop: komorebi, then the bar/capture tools, AHK last.
    ; window-slots is deliberately left running -- it idles harmlessly once
    ; komorebi is gone (its own loop just waits and retries; see
    ; tools/lib/window-slots.ps1), and a clean stop needs pwsh + its own
    ; Stop-WindowSlotsDaemon, not worth wiring a second copy of that here.
    ; Flow Launcher isn't touched either -- unlike komorebi/YASB/ShareX/AHK,
    ; it's not one of this repo's own autostart components (see install.ps1's
    ; -Activate docstring), it manages its own lifecycle independently.
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
