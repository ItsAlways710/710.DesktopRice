; Part of 710.ahk: Quick add rule -- and Remove a rule, Edit my rules.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Quick add rule (Tiling menu)
; ============================================================================
; Click-to-pick a window, choose what to match it on (exe / class / title,
; showing that window's real values) and which rule (Float / Ignore / Manage /
; Layered / Opaque), and it lands in YOUR rules file, the gitignored
; config\komorebi\rules.local.toml, via tools\add-rule.ps1 (ported from
; winarchy's Add-WinarchyUserRule -- winarchy only ever had a CLI for this, no
; UI). add-rule.ps1 also applies Float / Ignore / Manage to the picked window
; right away, because komorebi only applies rules to windows opened AFTER them
; (the 2026-09-23 Notepad test); then SUPER+Shift+R's reload makes it stick for
; every future window. Opaque needs no apply-now (it takes the next time the
; window is focused); Layered can't have one (komorebi still turns the window
; away until the reload lands), so its toast says to relaunch the app -- what
; fixed Claude Desktop on 2026-09-25. Matching on exe also offers Game (never
; tiled + game mode, applied now like Ignore; Group 1 #5) and Pin to this
; workspace (the app's windows open on the screen + workspace the picked one
; is on now; Group 1 #7) -- add-rule.ps1 finds where that is and refuses the
; windows a pin can't work for, each with its own exit code (below).
; "Remove a rule..." and "Edit my rules..." below manage the same file (plan
; doc Open item 38). A rule addition always rides komorebi's fast hot-reload
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
    ; Suggest Layered for a window that has WS_EX_LAYERED AND isn't managed by
    ; komorebi -- exactly how Claude Desktop looked before its rule: turned away
    ; by komorebi's eligibility check. Both halves matter: komorebi's own
    ; transparency puts that same style on every unfocused TILED window, and the
    ; pick click is blocked, so the picked window usually isn't focused. "Not
    ; managed" = its handle appears nowhere in `komorebic state`.
    suggest := false
    try suggest := (WinGetExStyle('ahk_id ' root) & 0x80000)
        && !RegExMatch(QueryKomorebic('state'), '"hwnd":\s*' root '\b')
    ; exe first so Enter takes the common case. Full values: the palette's label
    ; column ends anything too long in "..." on its own (and search still sees
    ; the whole value).
    items := [
        {text: 'exe: '   exe, sub: QuickRuleItems('exe', exe, suggest)},
        {text: 'class: ' cls, sub: QuickRuleItems('class', cls, suggest)} ]
    if (title != '')
        items.Push({text: 'title: ' title, sub: QuickRuleItems('title', title, suggest)})
    PalOpen('quick', items, 'Match on')
}

QuickRuleItems(field, value, suggestLayered := false) {
    layered := {text: 'Layered (tile an app komorebi skips)', action: (*) => QuickApplyRule('layered', field, value)}
    items := [
        {text: 'Float (never tile)',  action: (*) => QuickApplyRule('floating', field, value)},
        {text: 'Ignore (hands off)',  action: (*) => QuickApplyRule('ignore', field, value)},
        {text: 'Manage (force tile)', action: (*) => QuickApplyRule('manage', field, value)},
        layered,
        {text: 'Opaque (never translucent)', action: (*) => QuickApplyRule('transparency_ignore', field, value)} ]
    ; Games and pins are by exe only -- every reader of them matches the exe.
    if (field = 'exe') {
        items.Push({text: 'Game (never tile ' Chr(0xB7) ' game mode)', action: (*) => QuickApplyRule('game', field, value)})
        items.Push({text: 'Pin to this workspace',              action: (*) => QuickApplyRule('pin', field, value)})
    }
    if suggestLayered {
        layered.hint := 'suggested'
        items.InsertAt(1, items.RemoveAt(4))    ; to the top, so Enter takes it
    }
    return items
}

; Menu name for a rules-file section ([[transparency_ignore]] reads as "Opaque").
QuickRuleLabel(cat) => Map('floating', 'Float', 'ignore', 'Ignore', 'manage', 'Manage',
    'layered', 'Layered', 'transparency_ignore', 'Opaque', 'game', 'Game', 'pin', 'Pin').Get(cat, cat)

; A pin as menus show it: "chrome.exe -> screen 2, workspace 3".
PinText(exe, screen, workspace) => exe ' ' Chr(0x2192) ' screen ' screen ', workspace ' workspace

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
    if (cat = 'pin') {
        QuickPinResult(code, value)
        return
    }
    label := QuickRuleLabel(cat)
    if (cat = 'game') {
        if (code = 0 || code = 2)
            LoadGames()                           ; game mode knows it straight away
        switch code {
            case 0: ReloadStack('Game added (' value ") -- never tiled, game mode while it's focused")
            case 2: ReloadStack('Game added (' value '), not applied to that window (see add-rule.log)')
            case 3: TrayTip('Already a game (' value ')', '710sRice')
            default: TrayTip('Game not added (see add-rule.log)', '710sRice')
        }
        return
    }
    applied := (cat = 'floating' || cat = 'ignore' || cat = 'manage')
    switch code {
        case 0: ReloadStack(label ' rule added (' field ' ' value ')' (cat = 'layered' ? ' -- relaunch the app to tile it' : ''))
        case 2: ReloadStack(label ' rule added, not applied to that window (see add-rule.log)')
        case 3: TrayTip('Already there (' label ' ' field ' ' value ')' (applied ? ' -- applied to that window' : ''), '710sRice')
        default: TrayTip('Rule not added (see add-rule.log)', '710sRice')
    }
}

; add-rule.ps1 -Category pin's exit codes -> what happened. The pin's screen
; and workspace come back out of rules.local.toml (add-rule.ps1 worked them out).
QuickPinResult(code, exe) {
    pinned := ''
    for r in ReadLocalRules()
        if (r.section = 'pin' && r.field = 'exe' && StrLower(r.value) = StrLower(exe))
            pinned := PinText(r.value, r.screen, r.workspace)
    switch code {
        case 0: ReloadStack('Pinned ' (pinned != '' ? pinned : exe) ' -- its windows open there')
        case 3: TrayTip('Already pinned there (' (pinned != '' ? pinned : exe) ')', '710sRice')
        case 6: TrayTip("komorebi doesn't manage that window -- nothing pinned", '710sRice')
        case 7: TrayTip("Terminal and Explorer can't be pinned (every window of theirs would follow) -- nothing pinned", '710sRice')
        case 8: TrayTip("That's a game (never tiled) -- nothing pinned", '710sRice')
        case 9: TrayTip("That screen has no number in the screen map -- run 710sRice doctor", '710sRice')
        default: TrayTip('Not pinned (see add-rule.log)', '710sRice')
    }
}

; --- Remove a rule... / Edit my rules... (Tiling menu) -----------------------
; Both work on YOUR rules only (rules.local.toml). The rules this repo ships
; (rules.toml) aren't removable here -- edit and commit those like any config.
LocalRulesPath() => RepoRoot '\config\komorebi\rules.local.toml'

; Your rules as {section, field, value, screen, workspace}, in file order. Same
; grammar as compile-komorebi-rules.ps1 and tools\remove-rule.ps1: a block is
; a [[section]] line plus the lines after it up to a blank line; its first
; exe / class / title line names the rule. A pin's screen = N / workspace = N
; (bare numbers) ride along; '' for every other rule.
ReadLocalRules() {
    rules := []
    if !FileExist(LocalRulesPath())
        return rules
    cur := ''
    loop parse FileRead(LocalRulesPath(), 'UTF-8') '`n', '`n', '`r' {
        line := Trim(A_LoopField)
        if (line = '' || RegExMatch(line, '^\[\[(\w+)\]\]$', &m)) {
            if (IsObject(cur) && cur.field != '')
                rules.Push(cur)
            cur := (line = '') ? '' : {section: m[1], field: '', value: '', screen: '', workspace: ''}
        } else if IsObject(cur) {
            if (cur.field = '' && RegExMatch(line, '^(exe|class|title)\s*=\s*"([^"]*)"$', &m))
                cur.field := m[1], cur.value := m[2]
            else if (cur.screen = '' && RegExMatch(line, '^screen\s*=\s*(\d+)$', &m))
                cur.screen := m[1]
            else if (cur.workspace = '' && RegExMatch(line, '^workspace\s*=\s*(\d+)$', &m))
                cur.workspace := m[1]
        }
    }
    return rules
}

RuleText(r) {
    if (r.section = 'pin')
        return 'Pin ' Chr(0xB7) ' ' PinText(r.value, r.screen, r.workspace)
    return QuickRuleLabel(r.section) ' ' Chr(0xB7) ' ' r.field ' = ' r.value
}

RemoveRuleMenu(*) {
    rules := ReadLocalRules()
    if !rules.Length {
        TrayTip('No rules of your own yet -- nothing to remove', '710sRice')
        return
    }
    items := []
    for r in rules
        items.Push({text: RuleText(r), action: RemoveRuleConfirm.Bind(r)})
    PalOpen('rules', items, 'Remove a rule')
}

RemoveRuleConfirm(r, *) {
    PalOpen('rules', [
        {text: 'Remove', action: (*) => RemoveRuleNow(r)},
        {text: 'Cancel', action: (*) => 0} ], 'Remove ' RuleText(r) '?')
}

RemoveRuleNow(r) {
    global RepoRoot
    EnvSet('REMOVERULE_VALUE', r.value)       ; same no-command-line rule as Quick add
    try {
        code := RunWait('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' RepoRoot '\tools\remove-rule.ps1" -Category ' r.section ' -Field ' r.field, , 'Hide')
    } catch as e {
        EnvSet('REMOVERULE_VALUE')
        TrayTip('Remove rule could not start: ' e.Message, '710sRice')
        return
    }
    EnvSet('REMOVERULE_VALUE')
    ; A removal takes reload-stack's komorebi-restart path -- the only way to drop
    ; a live rule -- so every open window is checked again straight away. A pin
    ; is the exception: komorebi rebuilds workspace rules on every hot reload, so
    ; unpinning rides the fast one (see tools\remove-rule.ps1).
    if (code = 0) {
        if (r.section = 'game')
            LoadGames()                           ; no longer a game for game mode either
        ReloadStack('Removed ' RuleText(r))
    } else
        TrayTip('Rule not removed (see remove-rule.log)', '710sRice')
}

; Opens your rules file, creating it first with the same header add-rule.ps1
; writes (keep the two in step) so you never land in an empty mystery file.
; Default app for .toml if Windows has one, else Notepad. Applying stays
; manual: save, then SUPER+Shift+R.
EditMyRules(*) {
    path := LocalRulesPath()
    if !FileExist(path) {
        header := "# Your own komorebi rules -- this machine only (gitignored), the highest-priority`n"
            . "# layer: above rules.toml (the rules this repo ships), games.toml and the vendored`n"
            . "# community ASC rules. Quick add rule writes here; compiled into komorebi.json by`n"
            . "# tools\compile-komorebi-rules.ps1 (SUPER+Shift+R). Sections: [[floating]], [[ignore]],`n"
            . "# [[manage]], [[layered]], [[transparency_ignore]], ... with one of exe / class /`n"
            . "# title per entry; [[game]] with an exe; [[pin]] with an exe, screen = N, workspace = N.`n"
            . "# Want a rule on every machine? Move it into rules.toml (a game: games.toml) and commit.`n`n"
        try FileAppend(header, path, 'UTF-8-RAW')
        catch as e {
            TrayTip("Couldn't create rules.local.toml: " e.Message, '710sRice')
            return
        }
    }
    ; Ask Windows what opens .toml rather than just Run()ning the file: with no
    ; app registered, Run() wouldn't fail, it would pop the "How do you want to
    ; open this?" picker. AssocQueryString (ASSOCSTR_EXECUTABLE = 2) comes back
    ; empty, or as OpenWith.exe, when nothing is registered -- that's the Notepad case.
    size := 520
    buf := Buffer(size * 2, 0)
    handler := DllCall('shlwapi\AssocQueryStringW', 'UInt', 0, 'UInt', 2, 'Str', '.toml', 'Ptr', 0, 'Ptr', buf, 'UInt*', &size, 'UInt') = 0 ? StrGet(buf) : ''
    useDefault := (handler != '' && !InStr(handler, 'OpenWith.exe'))
    try {
        if useDefault
            Run('"' path '"')
        else
            Run('notepad.exe "' path '"')
    } catch
        Run('notepad.exe "' path '"')
    TrayTip('Save, then SUPER+Shift+R to apply', '710sRice')
}
