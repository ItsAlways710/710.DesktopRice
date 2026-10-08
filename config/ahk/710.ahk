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

; This script's sections are files of their own in config\ahk\710\ (docs\map.md says what's
; in each), #Included here in their old order. AutoHotkey reads them as though they were pasted
; in at this spot -- global code and all, so the order matters. SUPER+K reads them the same way
; (ReadScriptText, 710\keymap.ahk).
#Include 710\komorebi.ahk
#Include 710\komorebi-keys.ahk
#Include 710\sharex.ahk
#Include 710\apps.ahk
#Include 710\palette.ahk
#Include 710\keymap.ahk
#Include 710\system-menu.ahk
#Include 710\terminal.ahk
#Include 710\flow.ahk
#Include 710\stay-awake.ahk
#Include 710\game-mode.ahk
#Include 710\started-apps.ahk
#Include 710\yasb-watchdog.ahk
#Include 710\monitor-watcher.ahk
#Include 710\screens.ahk
#Include 710\quick-rule.ahk
#Include 710\menus.ahk
#Include 710\palette-profiles.ahk
#Include 710\main-menu.ahk
#Include 710\stack-control.ahk

; ============================================================================
; User overrides (config\ahk\user.ahk, gitignored -- per-machine only, same
; pattern as winarchy's own user.ahk: survives a `git pull` updating this
; file, the same way winarchy's version survives `winarchy update`)
; ============================================================================
#Include *i %A_ScriptDir%\user.ahk
