; Part of 710.ahk: Power / system menu -- SUPER+Esc.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

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
