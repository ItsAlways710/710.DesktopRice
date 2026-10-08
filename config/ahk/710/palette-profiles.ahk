; Part of 710.ahk: Palette profiles -- choosing, creating and editing them from the menu.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Palette profiles -- SUPER+Alt+Space > Palette profiles > Choose / Create / Edit
; ============================================================================
; The profiles are config\palettes\default.json (Default, ships with the repo)
; and profile0-9.json (yours, gitignored); the one in use is named in
; %LOCALAPPDATA%\710.DesktopRice\palette-profile.txt. Read fresh on every open,
; like Game mode's state, so a profile the editor just saved is already listed.
;  - Choose runs the wallpaper pipeline with -ProfileId (tools\apply-wallust-
;    outputs.ps1, hidden): everything is re-themed from the wallpaper that's up,
;    and the choice only sticks when that worked. A toast says how it went.
;  - Create / Edit open the editor (tools\palette-editor.ps1, a WPF window of
;    its own -- kept out of this file so 710.ahk stays small and fast).
; Menu actions capture their profile with .Bind(), not a closure: a fat arrow
; in a for-loop would see the loop's LAST profile in every item.
PaletteDir := RepoRoot "\config\palettes"
PaletteStateDir := EnvGet('LOCALAPPDATA') "\710.DesktopRice"
PaletteSwitching := false   ; a Choose is running: it reports its own outcome

PaletteMenuItems() {
    profiles := PaletteProfiles()
    chosen := PaletteChosen()
    choose := [], edit := []
    for p in profiles {
        choose.Push({text: p.label, hint: (p.id = chosen ? 'in use' : p.summary), action: PaletteUse.Bind(p.id, p.label)})
        edit.Push({text: p.label, hint: p.summary, action: PaletteEditor.Bind('-ProfileId ' p.id)})
    }
    free := 11 - profiles.Length
    return [
        {text: 'Choose profile', sub: choose},
        {text: 'Create profile', hint: (free ? free ' of 10 free' : 'all 10 in use'), action: PaletteEditor.Bind('-New')},
        {text: 'Edit profile',   sub: edit} ]
}

; Default plus every profileN.json there is, in slot order: {id, label, summary}.
; Labels match the editor's and 710sRice palette's ("Profile 3 . Night").
PaletteProfiles() {
    global PaletteDir
    list := [{id: 'default', label: 'Default', summary: 'kmeans'}]
    loop 10 {
        n := A_Index - 1
        f := PaletteDir '\profile' n '.json'
        if !FileExist(f)
            continue
        try
            txt := FileRead(f, 'UTF-8')
        catch
            continue
        ; The source object can hold a "name" of its own (a built-in theme's) -- the
        ; profile's name is the one outside it.
        src := RegExMatch(txt, 's)"source"\s*:\s*(\{[^{}]*\})', &m) ? m[1] : ''
        name := PaletteJsonString(StrReplace(txt, src, ''), 'name')
        list.Push({id: 'profile' n, label: 'Profile ' n (name != '' ? ' ' Chr(0xB7) ' ' name : ''), summary: PaletteSourceHint(src)})
    }
    return list
}

; The source in a few words for the hint column: kmeans / salience, light /
; closest theme / Nord / random theme / mocha.json.
PaletteSourceHint(src) {
    switch PaletteJsonString(src, 'kind') {
        case 'wallpaper':
            method := PaletteJsonString(src, 'method')
            method := (method != '' ? method : 'kmeans')
            return method (method != 'kmeans' && PaletteJsonString(src, 'style') = 'light' ? ', light' : '')
        case 'match':  return 'closest theme'
        case 'theme':  return PaletteJsonString(src, 'name')
        case 'random': return 'random theme'
        case 'scheme': return PaletteJsonString(src, 'file')
    }
    return ''
}

; A string field's value out of JSON text ('' when it isn't there) -- enough JSON
; for our own files: \" \\ \/ \n \t and \uXXXX undone.
PaletteJsonString(txt, key) {
    if !RegExMatch(txt, '"' key '"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
        return ''
    out := '', v := m[1], i := 1
    while (i <= StrLen(v)) {
        ch := SubStr(v, i, 1)
        if (ch != '\') {
            out .= ch, i += 1
            continue
        }
        nx := SubStr(v, i + 1, 1)
        if (nx = 'u') {
            out .= Chr(Integer('0x' SubStr(v, i + 2, 4))), i += 6
            continue
        }
        out .= (nx = 'n') ? '`n' : (nx = 't') ? '`t' : nx
        i += 2
    }
    return out
}

; The profile in use: the choice file's id when that profile is there, else
; Default (what the pipeline falls back to).
PaletteChosen() {
    global PaletteDir, PaletteStateDir
    try
        id := StrLower(Trim(FileRead(PaletteStateDir '\palette-profile.txt'), " `t`r`n"))
    catch
        return 'default'
    return (RegExMatch(id, '^profile[0-9]$') && FileExist(PaletteDir '\' id '.json')) ? id : 'default'
}

; Choose: the pipeline with -ProfileId, its output caught in a temp file so the
; toast can say what went wrong in its own words. RunWait only parks this
; menu's thread; every hotkey stays live meanwhile.
PaletteUse(id, label, *) {
    global RepoRoot, PaletteSwitching
    if PaletteSwitching
        return                      ; one switch at a time
    PaletteSwitching := true
    TrayTip('Switching to ' label '...', '710sRice')
    out := A_Temp '\710sRice-palette-use.txt'
    try FileDelete(out)
    q(p) => "'" StrReplace(p, "'", "''") "'"
    cmd := 'pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command "& ' q(RepoRoot '\tools\apply-wallust-outputs.ps1')
        . ' -ProfileId ' id ' *> ' q(out) '; exit $LASTEXITCODE"'
    try {
        code := RunWait(cmd, , 'Hide')
    } catch as e {
        PaletteSwitching := false
        TrayTip("Couldn't start the switch: " e.Message, '710sRice')
        return
    }
    PaletteSwitching := false
    ; The first [XX] line. Redirected, Write-Host -NoNewline pieces come out as lines
    ; of their own: "  [XX] ", then the message on the next line.
    why := ''
    try {
        lines := StrSplit(FileRead(out, 'UTF-8'), '`n', '`r')
        for i, line in lines
            if RegExMatch(line, '^\s*\[XX\]\s*(.*)$', &m) {
                why := Trim(m[1])
                if (why = '' && i < lines.Length)
                    why := Trim(lines[i + 1])
                break
            }
    }
    if (StrLen(why) > 180)
        why := SubStr(why, 1, 177) '...'
    switch code {
        case 0: TrayTip(label ' is in use -- every wallpaper change uses it too', '710sRice')
        case 2: TrayTip(label ' is in use, but ' (why != '' ? why : "an app couldn't be themed") ' (710sRice doctor)', '710sRice')
        default: TrayTip('Still on the old profile -- ' (why != '' ? why : 'the switch failed (710sRice doctor)'), '710sRice')
    }
}

; Create / Edit: the editor, hidden pwsh (only its window shows). -STA: WPF needs it.
PaletteEditor(args, *) {
    global RepoRoot
    try
        Run('pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File "' RepoRoot '\tools\palette-editor.ps1" ' args, , 'Hide')
    catch as e
        TrayTip("Couldn't open the palette editor: " e.Message, '710sRice')
}

; A wallpaper change whose palette wallust couldn't make: the pipeline kept the
; last good theme and knocks here (Send-PaletteAhkMessage), so it doesn't go
; unnoticed. The reason is in palette-status.json (doctor shows it too).
PaletteFailedToast() {
    global PaletteStateDir, PaletteSwitching
    if PaletteSwitching
        return                      ; Choose reports its own outcome
    why := ''
    try why := PaletteJsonString(FileRead(PaletteStateDir '\palette-status.json', 'UTF-8'), 'reason')
    if (StrLen(why) > 150)
        why := SubStr(why, 1, 147) '...'
    TrayTip("The wallpaper changed, but its palette couldn't be made -- the last theme stays." (why != '' ? '`n' why : ''), '710sRice')
}
