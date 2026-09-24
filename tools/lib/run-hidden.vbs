' run-hidden.vbs -- launches a command line with no visible window and no waiting.
'
' Used by tools\lib\activation.ps1's Get-AutostartComponents (via ConvertTo-HiddenLaunch)
' as the Scheduled Task's own Action for the powershell-hosted autostart components
' (komorebi/yasb/ahk). WHY: Task Scheduler launching powershell.exe directly
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
' the real long-running processes (komorebi.exe and the others) themselves get
' launched -- those are still Start-Process -WindowStyle Hidden calls made from inside the
' launcher scripts, unchanged and already working; this only replaces how Task Scheduler
' launches those launcher scripts in the first place.
'
' Argument: %1 = path to a small two-line plain-text "launch spec" file, written by
' tools\lib\activation.ps1's ConvertTo-HiddenLaunch. Line 1 = the target executable's full
' path. Line 2 = its full argument string, exactly as it would appear on that exe's own
' command line (quotes and all).
'
' Why a spec FILE instead of Exe/Arguments directly on this script's own command line (the
' original design, changed 2026-09-23): the original approach backslash-escaped embedded
' double quotes into this script's command line ("same convention Win32 command-line
' parsing already uses"). That assumption was never actually verified and was wrong --
' confirmed live via a real run-hidden.log entry plus a byte-exact `od -c` dump: WSH's own
' command-line parser does NOT support backslash-escaped quotes the way
' CommandLineToArgvW/MSVCRT does. A `\"` sequence comes through as a literal backslash plus
' an ORDINARY (unescaped) quote-toggle, not a literal `"` -- so a quoted -File path arrived
' at powershell.exe mangled (stray leading/trailing backslashes, no quotes at all), which
' powershell.exe can't resolve as a real path. It failed silently every time this ran for
' real: Task Scheduler still reported Last Result 0 (see the logging note below -- that's
' this script's own exit code, unaffected), and the launched script never got far enough to
' write even its own first log line. A spec file sidesteps WSH's command-line parsing for
' the actual payload entirely -- this script's own command line now only ever contains one
' plain, quote-free file path.
'
' Logging added 2026-09-23: Task Scheduler's own "Last Result" for the calling task only
' reflects THIS script's (wscript.exe's) exit code, not the launched process's -- and since
' objShell.Run below is fire-and-forget (bWaitOnReturn=False, by design, see above), Task
' Scheduler reports success (0) even when the launch itself silently fails, or the launched
' script never reaches its own first log line. Every invocation writes a line to
' run-hidden.log (shared across all four autostart components, same %LOCALAPPDATA%\
' 710.DesktopRice\ folder the launched scripts already log to and the spec files live in)
' right before calling Run, and a second line if Run itself throws, or if the spec file
' itself can't be read -- so a future silent failure shows up as either "no launch line at
' all" (this script/Task Scheduler's own action never fired) or "launch line present,
' target script's own log never followed" (the child died/stalled before logging anything),
' instead of nothing. Logging happens synchronously but cheaply (one small text append)
' before/after the async Run call, so it does not change this script's own no-wait,
' no-console-flash behavior.
Dim q, fso, wshShell, logDir, logPath, ts, specPath, specFile, exePath, argString

q = Chr(34)

Set wshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

logDir = wshShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\710.DesktopRice"
On Error Resume Next
If Not fso.FolderExists(logDir) Then fso.CreateFolder(logDir)
On Error Goto 0
logPath = logDir & "\run-hidden.log"

' Log cap: past 1 MB, run-hidden.log becomes run-hidden.log.old (replacing the previous
' one) -- same rule as every other 710.DesktopRice log (plan doc, open item 20). All four
' launches can reach this at the same moment at logon; whichever loses that race just
' fails quietly here and appends to the fresh file.
On Error Resume Next
If fso.FileExists(logPath) Then
    If fso.GetFile(logPath).Size > 1048576 Then
        If fso.FileExists(logPath & ".old") Then fso.DeleteFile logPath & ".old", True
        fso.MoveFile logPath, logPath & ".old"
    End If
End If
On Error Goto 0

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

specPath = WScript.Arguments(0)

On Error Resume Next

Err.Clear
Set specFile = fso.OpenTextFile(specPath, 1, False) ' 1 = ForReading
If Err.Number <> 0 Then
    WriteHiddenLaunchLog "ERROR: couldn't open spec file " & q & specPath & q & ": 0x" & Hex(Err.Number) & " " & Err.Description
    On Error Goto 0
    WScript.Quit 1
End If

Err.Clear
exePath = specFile.ReadLine()
argString = specFile.ReadLine()
specFile.Close
If Err.Number <> 0 Then
    WriteHiddenLaunchLog "ERROR: couldn't read spec file " & q & specPath & q & ": 0x" & Hex(Err.Number) & " " & Err.Description
    On Error Goto 0
    WScript.Quit 1
End If

On Error Goto 0

WriteHiddenLaunchLog "launching: " & q & exePath & q & " " & argString

On Error Resume Next
wshShell.Run q & exePath & q & " " & argString, 0, False
If Err.Number <> 0 Then
    WriteHiddenLaunchLog "ERROR: Run failed, 0x" & Hex(Err.Number) & " " & Err.Description
End If
On Error Goto 0
