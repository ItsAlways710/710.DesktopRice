; Part of 710.ahk: Game mode -- games.toml, GameWatch.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Game mode -- state tracking only, NOT floating. Games -- games.toml's exes
; and your [[game]] blocks in rules.local.toml (Quick add's Game, Group 1 #5)
; -- are already never tiled by komorebi's own compiled rules (an ignore rule
; each; see tools/compile-komorebi-rules.ps1), regardless of whether this flag
; is set. This watcher exists to (a) give the tray/main menu a live ON/OFF
; indicator (GameModeText(): on while a game is focused, or the switch is on)
; and (b) re-read the games when one is first detected (Quick add /
; Remove a rule re-read them straight away too). It doesn't suspend SUPER
; hotkeys, on purpose: winarchy did at first and pulled it five days later
; (its f6e96a6) -- the menu, launcher and screenshot keys went dark mid-game.
; Ported from winarchy's winarchy.ahk @ 4574fc7 --
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
    if FileExist(GamesToml) {
        for line in StrSplit(FileRead(GamesToml, 'UTF-8'), '`n') {
            if RegExMatch(line, 'i)^\s*exe\s*=\s*"([^"]+)"', &m) {
                exe := StrLower(m[1])
                if !InStr(exe, '*')
                    GameExes[exe] := true
            }
        }
    }
    ; Yours: the [[game]] blocks of rules.local.toml (ReadLocalRules, below).
    for r in ReadLocalRules()
        if (r.section = 'game' && r.field = 'exe')
            GameExes[StrLower(r.value)] := true
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

; "710sRice Game mode on" / "... off" (the Start-menu commands): the switch set, not flipped.
SetGameMode(on) {
    global GameFlag
    if (on = !!FileExist(GameFlag))
        TrayTip('Game mode: already ' (on ? 'on' : 'off'), '710sRice')
    else
        ToggleGameMode()
}
