; Part of 710.ahk: SUPER+Shift+R's reload, Quit 710sRice, SUPER+Ctrl+R's restart.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; SUPER+Shift+R. tools\reload-stack.ps1 does the actual stack work (compile
; rules, keep live layouts across komorebi's reload, wallust borders -> YASB stopped
; when it has to restart); this just runs it, says how it went,
; and then restarts THIS script -- the one step the PS script can't do itself
; without killing its own caller, and the reason AHK goes last. The restarted script
; starts the bar again as it loads (StartApps, "The apps 710.ahk starts"). RunWait only
; parks this hotkey's thread, so every other hotkey stays live meanwhile.
; Exit codes are reload-stack.ps1's: 0 ok, 1 rules didn't compile (nothing
; was touched, so AHK isn't restarted either), 2 partial (see the log).
ReloadStack(note := '', *) {
    static running := false
    if running                  ; double-tap while the first one's mid-flight
        return
    running := true
    TrayTip('Reloading stack...', '710sRice')
    script := RepoRoot '\tools\reload-stack.ps1'
    try {
        code := RunWait('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' script '"', , 'Hide')
    } catch as e {
        running := false
        TrayTip('Reload could not start: ' e.Message, '710sRice')
        return
    }
    if (code = 1) {
        running := false
        TrayTip((note != '' ? note ', but ' : '') 'rules failed to compile -- nothing reloaded (see reload-stack.log)', '710sRice')
        return
    }
    ; `note` lets a caller (Quick add rule) say what just changed; empty for a plain SUPER+Shift+R
    TrayTip((note != '' ? note '. ' : '') (code = 0 ? 'Stack reloaded' : 'Reloaded, with errors (see reload-stack.log)'), '710sRice')
    Sleep(1500)                 ; let the toast land before this process swaps itself out
    Reload()
}

QuitStack() {
    ; Ordered, non-elevated stop -- the same set as scripts\Stop-All.ps1
    ; (Stop-RunningComponents in tools\lib\stack.ps1): komorebi, the
    ; bar/capture tools, AHK last. Flow Launcher isn't touched -- this script
    ; only starts it; it's an ordinary app you can keep using without the stack.
    try Komorebic('stop')
    try RunWait('taskkill /IM yasb.exe /F', , 'Hide')
    try RunWait('taskkill /IM ShareX.exe /F', , 'Hide')
    ExitApp()
}

; SUPER+Ctrl+R: `710sRice restart` -- the WHOLE stack, every time (SUPER+Shift+R only
; restarts what changed). The restart's Stop-All stops this very script, so it runs in a
; hidden pwsh of its own that outlives us, and two toasts bracket it: this one before, and
; the NEW 710.ahk -- started by that same restart -- saying how it went (ReportRestart, at
; load). -Command "& '...'" makes it an ordinary shell to 710sRice, so its "Press Enter to
; close" can never wait on a window nobody can see. Everything it prints lands in
; restart-hotkey.log in the logs folder, then an exit=N line; the report renames it
; restart-hotkey.last.log. Single quotes in a path are doubled for PowerShell's '...'.
RestartLog := EnvGet('LOCALAPPDATA') '\710.DesktopRice\restart-hotkey.log'

RestartStack(*) {
    global RepoRoot, RestartLog
    ; A double-tap: one's already under way (a fresh log with no exit line yet).
    try {
        if FileExist(RestartLog) && DateDiff(A_Now, FileGetTime(RestartLog, 'M'), 'Seconds') < 120
            && !InStr(FileRead(RestartLog, 'UTF-8'), 'exit=')
            return
    }
    ps1 := StrReplace(RepoRoot '\710sRice.ps1', "'", "''")
    log := StrReplace(RestartLog, "'", "''")
    TrayTip('Restarting the whole stack...', '710sRice')
    try Run(Format('pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& {1}{2}{1} restart *> {1}{3}{1}; Add-Content -LiteralPath {1}{3}{1} ({1}exit={1} + $LASTEXITCODE)"'
        , "'", ps1, log), , 'Hide')
    catch as e
        TrayTip('Restart could not start: ' e.Message, '710sRice')
}

; At load: if SUPER+Ctrl+R started the restart that started us, say how it went once it's
; done (Start-All is still finishing ShareX and its waits when 710.ahk comes up). A log
; older than 10 minutes is a leftover (a restart cut short by a sign-out, say): set aside
; quietly, no toast.
try {
    if FileExist(RestartLog) {
        if DateDiff(A_Now, FileGetTime(RestartLog, 'M'), 'Seconds') > 600
            FileMove(RestartLog, RegExReplace(RestartLog, '\.log$', '.last.log'), 1)
        else
            SetTimer(ReportRestart, 500)
    }
}

ReportRestart() {
    global RestartLog
    static started := A_TickCount
    try text := FileRead(RestartLog, 'UTF-8')
    catch
        return                  ; still being written -- try again next tick
    if !RegExMatch(text, 'm)^exit=(-?\d+)', &m) {
        if (A_TickCount - started < 120000)
            return
        msg := "The restart hasn't finished after 2 minutes -- see restart-hotkey.log (710sRice logs)"
    } else if (m[1] = 0 && !RegExMatch(text, '\[(XX|!!)\]'))
        msg := 'Stack restarted'
    else
        msg := 'Stack restarted, with problems -- run 710sRice doctor'
    SetTimer(ReportRestart, 0)
    TrayTip(msg, '710sRice')
    try FileMove(RestartLog, RegExReplace(RestartLog, '\.log$', '.last.log'), 1)
}
