; Part of 710.ahk: Stay awake.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; Stay awake
; ============================================================================
AwakeFlag := StateDir "\stay-awake.flag"
; The flag survives this process; SetThreadExecutionState doesn't -- Windows drops it
; the moment AHK exits (Reload(), 710sRice stop/start, a reboot). So every start puts
; it back, and the menu's "on" stays true.
if FileExist(AwakeFlag)
    DllCall('SetThreadExecutionState', 'UInt', 0x80000003)   ; ES_CONTINUOUS | SYSTEM | DISPLAY

ToggleStayAwake() {
    global AwakeFlag
    if FileExist(AwakeFlag) {
        DllCall('SetThreadExecutionState', 'UInt', 0x80000000)   ; ES_CONTINUOUS
        FileDelete(AwakeFlag)
        TrayTip('Stay awake: off', '710sRice')
    } else {
        ; ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
        DllCall('SetThreadExecutionState', 'UInt', 0x80000003)
        FileAppend('', AwakeFlag)
        TrayTip('Stay awake: on', '710sRice')
    }
}

#^w::ToggleStayAwake()             ; keep the machine awake
