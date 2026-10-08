; Part of 710.ahk: Key overlay -- SUPER+K's keybindings list.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

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
;
; Since 710.ahk's sections became files of their own (config\ahk\710\), the source it parses
; is ReadScriptText's: each `#Include 710\<part>.ahk` line replaced by that part, so the list
; keeps the order and the section titles it had as one file. user.ahk has no parts.
ReadScriptText(path) {
    SplitPath(path, , &dir)
    text := ''
    for line in StrSplit(FileRead(path, 'UTF-8'), '`n') {
        if RegExMatch(RTrim(line, '`r'), '^#Include (710\\[\w-]+\.ahk)$', &m)
            text .= FileRead(dir '\' m[1], 'UTF-8') '`n'
        else
            text .= line '`n'
    }
    return text
}

ParseKeymap(path, defaultTitle := '') {
    sections := []
    cur := ''
    if (defaultTitle != '') {
        cur := {title: defaultTitle, items: []}
        sections.Push(cur)
    }
    state := 0, pendingTitle := ''   ; 0=idle, 1=saw an opening "; ====" line, 2=saw the title line after it
    for line in StrSplit(ReadScriptText(path), '`n') {
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
