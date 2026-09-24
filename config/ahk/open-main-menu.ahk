#Requires AutoHotkey v2.0
#NoTrayIcon
; Asks the running 710.ahk to open its main menu -- the SUPER+Alt+Space palette.
; Run by YASB's home widget "Main Menu" entry (config\yasb\config.yaml); YASB can
; only launch programs, it can't call into 710.ahk directly.
;
; Posts a registered window message ('710sRice.OpenMainMenu') to 710.ahk's hidden
; main window instead of faking the key combo: no synthetic Win keypress (which
; can leave the Start menu or a stuck Win key behind), and nothing else reacts
; to it. 710.ahk answers it with OpenMainMenu() -- see OnMessage there.
;
; The palette needs to take the foreground, and Windows only lets a process do
; that if the one that has it allows it. We were just started from a click in
; YASB, so we can pass that on to 710.ahk (AllowSetForegroundWindow) first.
; Silently does nothing if 710.ahk isn't running.

DetectHiddenWindows(true)
SetTitleMatchMode(2)
target := WinExist('\config\ahk\710.ahk ahk_class AutoHotkey')
if !target
    ExitApp()
DllCall('AllowSetForegroundWindow', 'UInt', WinGetPID(target))
PostMessage(DllCall('RegisterWindowMessage', 'Str', '710sRice.OpenMainMenu', 'UInt'), 0, 0, , target)
ExitApp()
