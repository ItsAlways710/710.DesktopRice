' run-hidden.vbs -- launches a command line with no visible window and no waiting.
'
' Used by tools\lib\activation.ps1's Get-AutostartComponents (via ConvertTo-HiddenLaunch)
' as the Scheduled Task's own Action for the powershell-hosted autostart components
' (komorebi/yasb/window-slots/ahk). WHY: Task Scheduler launching powershell.exe directly
' with -WindowStyle Hidden still shows a brief console flash at every logon -- confirmed
' live on Dell, 3-4 flashes at every boot (one per powershell-hosted component). Windows
' allocates the console as part of process creation, before PowerShell's own startup code
' has run far enough to read -WindowStyle and hide itself -- a well-documented race, not
' specific to this repo. wscript.exe (this file's own host, unlike cscript.exe) never
' allocates a console at all, so there's nothing to flash; WScript.Shell.Run below requests
' the hidden window style up front, as part of creating the process, not as a hide-after-
' the-fact race.
'
' NOT the same technique winarchy tried and reverted for komorebi (`conhost --headless` --
' see this repo's git log, and winarchy's own commits d52e515/f088211): that hosts the
' child in a detached pseudo-console whose own exit killed komorebi outright (silently
' OFFLINE, komorebic reporting os error 10061, Task Scheduler still reporting Last Result
' 0). This script does not host or attach the child's console at all -- WScript.Shell.Run
' is an ordinary top-level launch, same as double-clicking the exe, so the child's lifetime
' never depends on this script (or wscript.exe) still running. It also doesn't touch how
' the real long-running daemons (komorebi.exe, the window-slots pwsh host) themselves get
' launched -- those are still Start-Process -WindowStyle Hidden calls made from inside the
' launcher scripts, unchanged and already working; this only replaces how Task Scheduler
' launches those launcher scripts in the first place.
'
' Arguments: %1 = the target executable's full path. %2 = its argument string, exactly as
' it would appear on that exe's own command line (quotes and all -- ConvertTo-HiddenLaunch
' escapes them for the trip through THIS script's own command line; WScript.Arguments
' hands them back unescaped, same as any other Windows command-line parsing).
'
' Logging added 2026-09-23: Task Scheduler's own "Last Result" for the calling task only
' reflects THIS script's (wscript.exe's) exit code, not the launched process's -- and since
' objShell.Run below is fire-and-forget (bWaitOnReturn=False, by design, see above), Task
' Scheduler reports success (0) even when the launch itself silently fails, or the launched
' script never reaches its own first log line. Confirmed happening for real: a scheduled run
' of the komorebi task reported Last Result 0 with zero corresponding entry in
' komorebi-autostart.log, while every other run that same day (7+) logged normally -- this
' class of failure is otherwise invisible. Every invocation now writes a line to
' run-hidden.log (shared across all four autostart components, same %LOCALAPPDATA%\
' 710.DesktopRice\ folder the launched scripts already log to) right before calling Run, and
' a second line if Run itself throws -- so a future occurrence shows up as either "no launch
' line at all" (wscript.exe/Task Scheduler's own action never fired) or "launch line present,
' target script's own log never followed" (the child process died or stalled before logging
' anything), instead of nothing. Logging happens synchronously but cheaply (one small text
' append) before/after the async Run call, so it does not change this script's own no-wait,
' no-console-flash behavior.
Dim q, fso, wshShell, logDir, logPath, ts

q = Chr(34)

Set wshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

logDir = wshShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\710.DesktopRice"
On Error Resume Next
If Not fso.FolderExists(logDir) Then fso.CreateFolder(logDir)
On Error Goto 0
logPath = logDir & "\run-hidden.log"

ts = Year(Now) & "-" & Right("0" & Month(Now), 2) & "-" & Right("0" & Day(Now), 2) & " " & _
     Right("0" & Hour(Now), 2) & ":" & Right("0" & Minute(Now), 2) & ":" & Right("0" & Second(Now), 2)

Sub WriteHiddenLaunchLog(msg)
    Dim f
    On Error Resume Next
    Set f = fso.OpenTextFile(logPath, 8, True) ' 8 = ForAppending, create if missing
    If Err.Number = 0 And Not f Is Nothing Then
        f.WriteLine ts & "  " & msg
        f.Close
    End If
    On Error Goto 0
End Sub

WriteHiddenLaunchLog "launching: " & q & WScript.Arguments(0) & q & " " & WScript.Arguments(1)

On Error Resume Next
wshShell.Run q & WScript.Arguments(0) & q & " " & WScript.Arguments(1), 0, False
If Err.Number <> 0 Then
    WriteHiddenLaunchLog "ERROR: Run failed, 0x" & Hex(Err.Number) & " " & Err.Description
End If
On Error Goto 0
