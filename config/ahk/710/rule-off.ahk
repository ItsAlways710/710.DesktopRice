; Part of 710.ahk: Turn off a shipped rule (Tiling menu), and how a turned-off rule reads.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Turn off a shipped rule (Tiling menu)
; ============================================================================
; GitHub's first issue: a rule this repo ships -- the community ASC rules, games.toml,
; rules.toml -- turned off on this machine only, kept in YOUR rules.local.toml as an [[off]]
; block (tools\lib\rules-off.ps1 has the format), so `710sRice update` never touches it. Your own
; rules could already outvote a shipped float / ignore / manage; this turns off the rest too: an
; extra-behavior rule (Layered, Opaque, ...: every layer's are added together) or a game.
; It starts like Quick add rule -- click the window (the same pick: PickWindow,
; window-pick.ahk) -- then tools\rule-off.ps1 -List names the shipped rules komorebi matches to
; that window, each with what it does and where it comes from. Pick one, confirm, and
; rule-off.ps1 -Add writes the [[off]]; SUPER+Shift+R's reload then restarts komorebi to drop
; the rule, as Remove a rule's does. A turned-off game stops counting for game mode too
; (LoadGames, game-mode.ahk; Start-Komorebi.ps1's check through tools\lib\games.ps1).
; Back on: Remove a rule... lists your [[off]]s beside your rules, games and pins.
TurnOffRuleMenu(*) => PickWindow('Turn off a shipped rule', 'whose shipped rule to turn off', RuleOffPicked)

; The pick's window ({hwnd, exe, cls, title}) -> the shipped rules that match it.
RuleOffPicked(win) {
    global RepoRoot
    list := EnvGet('LOCALAPPDATA') '\710.DesktopRice\rule-off.tsv'
    path := ''
    try path := WinGetProcessPath('ahk_id ' win.hwnd)
    ; The window's values ride in the environment, never quoted onto a command line --
    ; titles can hold anything (Quick add's rule). Cleared again straight after.
    for name, value in Map('EXE', win.exe, 'CLASS', win.cls, 'TITLE', win.title, 'PATH', path)
        EnvSet('RULEOFF_' name, value)
    try code := RunWait('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' RepoRoot '\tools\rule-off.ps1" -List', , 'Hide')
    catch as e
        code := -1, err := e.Message
    for name in ['EXE', 'CLASS', 'TITLE', 'PATH']
        EnvSet('RULEOFF_' name)
    if (code = 4)
        return TrayTip('No shipped rule matches that window (' win.exe ')', '710sRice')
    if (code != 0)
        return TrayTip((code = -1 ? 'Turn off a shipped rule could not start: ' err : "Couldn't list the shipped rules (see rule-off.log)"), '710sRice')
    items := []
    try {
        loop parse FileRead(list, 'UTF-8'), '`n', '`r' {
            f := StrSplit(A_LoopField, '`t')
            if (f.Length < 5)
                continue
            rule := {section: f[1], key: f[2], name: f[3], conditions: f[4], from: f[5]}
            items.Push({text: rule.name ' ' Chr(0xB7) ' ' rule.conditions, hint: rule.from, action: RuleOffConfirm.Bind(rule)})
        }
    }
    if !items.Length
        return TrayTip("Couldn't read the shipped rules (see rule-off.log)", '710sRice')
    PalOpen('ruleoff', items, 'Turn off a shipped rule')
}

RuleOffConfirm(rule, *) {
    PalOpen('ruleoff', [
        {text: 'Turn off', hint: 'this machine only', action: (*) => RuleOffNow(rule)},
        {text: 'Cancel', action: (*) => 0} ], 'Turn off ' rule.name ' ' Chr(0xB7) ' ' rule.conditions ' (' rule.from ')?')
}

RuleOffNow(rule) {
    global RepoRoot
    EnvSet('RULEOFF_SECTION', rule.section), EnvSet('RULEOFF_KEY', rule.key)
    EnvSet('RULEOFF_NOTE', rule.name ' ' Chr(0xB7) ' ' rule.conditions ' (from ' rule.from ')')
    try code := RunWait('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' RepoRoot '\tools\rule-off.ps1" -Add', , 'Hide')
    catch as e
        code := -1, err := e.Message
    for name in ['SECTION', 'KEY', 'NOTE']
        EnvSet('RULEOFF_' name)
    text := rule.name ' ' Chr(0xB7) ' ' rule.conditions
    switch code {
        case 0:
            if (rule.name = 'Game')
                LoadGames()                       ; no longer a game for game mode
            ReloadStack('Turned off ' text ' -- on this machine; komorebi restarts to drop it')
        case 3: TrayTip('Already turned off (' text ')', '710sRice')
        case -1: TrayTip('Turn off a shipped rule could not start: ' err, '710sRice')
        default: TrayTip('Not turned off (see rule-off.log)', '710sRice')
    }
}

; An [[off]] as menus show it (Remove a rule...): its list's name and the rule's conditions, out
; of the compiler's key -- "Layered · exe = steam.exe", "Ignore · exe = steamwebhelper.exe &
; title ≠ steam" -- lower case, as the key keeps them. A games.toml game's reads "Game", as the
; Turn off list showed it.
OffRuleText(section, key) {
    if (section = 'ignore' && RegExMatch(key, '^exe=(.+)/equals$', &g) && ShippedGame(g[1]))
        return 'Game ' Chr(0xB7) ' exe = ' g[1]
    names := Map('ignore', 'Ignore', 'manage', 'Manage', 'floating', 'Float', 'layered', 'Layered',
        'transparency_ignore', 'Opaque', 'tray_and_multi_window', 'Tray app',
        'object_name_change', 'Name change', 'slow_application', 'Slow app')
    ops := Map('equals', '=', 'doesnotequal', Chr(0x2260), 'startswith', 'starts with',
        'doesnotstartwith', "doesn't start with", 'endswith', 'ends with', 'doesnotendwith', "doesn't end with",
        'contains', 'contains', 'doesnotcontain', "doesn't contain", 'regex', 'matches')
    parts := []
    for cond in StrSplit(key, '&') {
        if !RegExMatch(cond, '^(\w+)=(.*)/(\w+)$', &m) {
            parts.Push(cond)
            continue
        }
        op := ops.Has(m[3]) ? ops[m[3]] : (m[1] = 'title' || m[1] = 'class') ? 'starts or ends with' : '='
        parts.Push(m[1] ' ' op ' ' m[2])
    }
    text := ''
    for p in parts
        text .= (A_Index = 1 ? '' : ' & ') p
    return (names.Has(section) ? names[section] : section) ' ' Chr(0xB7) ' ' text
}

; games.toml has an exe = "<exe>" line (any case) -- the shipped games, as LoadGames reads them.
ShippedGame(exe) {
    global GamesToml
    try return RegExMatch(FileRead(GamesToml, 'UTF-8'), 'im)^\s*exe\s*=\s*"\Q' exe '\E"') > 0
    return false
}
