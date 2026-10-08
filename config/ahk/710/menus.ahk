; Part of 710.ahk: Tray + main menu -- the menus' items (Capture, Tiling) and their state.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

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
; and YASB sections); Doctor runs `710sRice doctor` in a new Terminal window
; (RunDoctor, below). Capture's action strings are Sharex()'s real ShareX CLI
; switches (ShareX's own HotkeyType names), not winarchy's old
; Winarchy('screenshot ...') CLI pass-through. All thirteen of winarchy's
; entries, in its order: the 09-22 rewrite kept only the eight with a hotkey
; and dropped Repeat last region, Scrolling capture, Colour picker, Pin to
; screen and Ruler -- back since the winarchy port audit (2026-10-01).
CaptureItems := [
    {text: 'Region',                 hint: 'SUPER+Shift+S', action: (*) => Sharex('RectangleRegion')},
    {text: 'Active window',          hint: 'SUPER+Shift+W', action: (*) => Sharex('ActiveWindow')},
    {text: 'Full screen',            hint: 'SUPER+Shift+P', action: (*) => Sharex('PrintScreen')},
    {text: 'Repeat last region',                            action: (*) => Sharex('LastRegion')},
    {text: 'Scrolling capture',                             action: (*) => Sharex('ScrollingCapture')},
    {text: 'Record',                 hint: 'SUPER+Shift+V', action: (*) => Sharex('ScreenRecorder')},
    {text: 'Stop recording',         hint: 'SUPER+Ctrl+V',  action: (*) => Sharex('StopScreenRecording')},
    {text: 'Record as GIF',          hint: 'SUPER+Shift+G', action: (*) => Sharex('ScreenRecorderGIF')},
    {text: 'Text from screen (OCR)', hint: 'SUPER+Ctrl+O',  action: (*) => Sharex('OCR')},
    {text: 'Scan QR code',           hint: 'SUPER+Ctrl+Q',  action: (*) => Sharex('QRCodeScanRegion')},
    {text: 'Colour picker',                                 action: (*) => Sharex('ScreenColorPicker')},
    {text: 'Pin to screen',                                 action: (*) => Sharex('PinToScreen')},
    {text: 'Ruler',                                         action: (*) => Sharex('Ruler')} ]

TilingItems := [
    {text: 'Quick add rule...',                          action: (*) => QuickAddRule()},
    {text: 'Remove a rule...',                           action: (*) => RemoveRuleMenu()},
    {text: 'Edit my rules...',                           action: (*) => EditMyRules()},
    {text: 'Manage this window',                         action: (*) => Komorebic('manage')},
    {text: 'Unmanage this window',                        action: (*) => Komorebic('unmanage')},
    {text: 'Toggle tiling this workspace', hint: 'SUPER+Shift+Z', action: (*) => Komorebic('toggle-tiling')},
    {text: 'New windows: stack / tile',                   action: (*) => Komorebic('toggle-window-container-behaviour')},
    {text: 'Title bars',                                  action: (*) => Komorebic('toggle-title-bars')},
    {text: 'Mouse follows focus',                         action: (*) => Komorebic('toggle-mouse-follows-focus')},
    {text: 'Restore hidden windows',                      action: (*) => Komorebic('restore-windows')} ]

; Built fresh each open (not a static array) so Game mode / Stay awake show
; their CURRENT state ("Game mode . on") -- winarchy's OnOff() wording, short
; enough to leave room for the key hint column.
OnOff(flag) => Chr(0xB7) ' ' (FileExist(flag) ? 'on' : 'off')
; Game mode's "on" = the manual switch, OR a game focused right now (GameWatch's
; GameModeActive: games.toml + your [[game]]s, or a fullscreen window). Until
; Group 1 the menu showed the switch alone -- nothing read the detected state
; (winarchy fed it only to its accent watcher, which this repo dropped). The
; item still flips the switch.
GameModeText() {
    global GameFlag, GameModeActive
    return 'Game mode ' Chr(0xB7) ' ' ((GameModeActive || FileExist(GameFlag)) ? 'on' : 'off')
}
