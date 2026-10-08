; Part of 710.ahk: Terminal -- SUPER+Return.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Terminal
; ============================================================================
#Enter::LaunchOnCursorMonitor('wt.exe', 'ahk_class CASCADIA_HOSTING_WINDOW_CLASS')  ; Windows Terminal
                                    ; Windows Terminal (SUPER+Enter) -- WezTerm dropped, matches the
                                    ; user's own user.ahk override on winarchy. Forces the new window
                                    ; onto the cursor's monitor -- see LaunchOnCursorMonitor() above.
#!Enter::LaunchAdminTerminal()      ; admin Windows Terminal (UAC prompt)
                                    ; SUPER+Alt+Enter -- Alt for Admin. See LaunchAdminTerminal() above.
