#Requires AutoHotkey v2.0
#NoTrayIcon
; send-command.ahk <name> -- asks the running 710.ahk to run one of its commands. The Start-menu
; commands ("710sRice Doctor", ... in Start Menu\Programs\710sRice, made by
; tools\components\commands.ps1) run it, so Flow Launcher finds them by name. The names are
; 710.ahk's RiceCommands list (menu, reload-stack, doctor, game-mode-on, game-mode-off,
; screenshot-region, screenshot-window, screen-recording, stop-recording, text-from-screen).
;
; The same door as open-main-menu.ahk (see there): a registered window message,
; '710sRice.Command.<name>', posted to 710.ahk's hidden window -- no synthetic keypress, nothing
; else reacts to it -- after passing on our right to take the foreground (the menu needs it; we
; were just started from a click in Flow). 710.ahk not running: a toast says so, instead of the
; click doing nothing.

name := A_Args.Length ? A_Args[1] : ''
DetectHiddenWindows(true)
SetTitleMatchMode(2)
target := WinExist('\config\ahk\710.ahk ahk_class AutoHotkey')
if !target {
    try TraySetIcon(A_ScriptDir '\..\..\assets\logo\710rice.ico')
    A_IconHidden := false
    TrayTip("710sRice isn't running -- 710sRice start (or sign out and in) starts it", '710sRice')
    Sleep(5000)
    ExitApp(1)
}
DllCall('AllowSetForegroundWindow', 'UInt', WinGetPID(target))
PostMessage(DllCall('RegisterWindowMessage', 'Str', '710sRice.Command.' name, 'UInt'), 0, 0, , target)
ExitApp()
