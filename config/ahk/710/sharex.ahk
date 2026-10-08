; Part of 710.ahk: ShareX -- Sharex() and the capture keys.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; ShareX
; ============================================================================
; Direct, bypasses winarchy's CLI/module entirely. A running ShareX takes the action from this
; second start and the second start exits; with none running, this start IS ShareX -- this
; script's own, so it's refused as admin like StartShareX (see "The apps 710.ahk starts").
ShareXExe := FileExist(A_ProgramFiles "\ShareX\ShareX.exe")
    ? A_ProgramFiles "\ShareX\ShareX.exe"
    : (FileExist(EnvGet('ProgramFiles(x86)') "\ShareX\ShareX.exe") ? EnvGet('ProgramFiles(x86)') "\ShareX\ShareX.exe" : "")

Sharex(action) {
    global ShareXExe
    if !ShareXExe {
        TrayTip('ShareX is not installed (winget install ShareX.ShareX)', '710sRice')
        return
    }
    if !ProcessExist('ShareX.exe') && !AppStartAllowed('ShareX')
        return
    Run('"' ShareXExe '" -' action, , 'Hide')
}

#+s::Sharex('RectangleRegion')                    ; region capture
#+w::Sharex('ActiveWindow')                        ; active window capture
#+p::Sharex('PrintScreen')                         ; fullscreen capture
#+v::Sharex('ScreenRecorder')                      ; screen recording
#^v::Sharex('StopScreenRecording')                 ; stop recording
#^q::Sharex('QRCodeScanRegion')                     ; decode a QR on screen
#^o::Sharex('OCR')                                  ; text from screen
#+g::Sharex('ScreenRecorderGIF')                    ; GIF recording
