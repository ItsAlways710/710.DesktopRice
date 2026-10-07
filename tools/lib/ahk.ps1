<#
.SYNOPSIS
  Talking to the running 710.ahk: finding its window by its title, posting it one of the messages
  it listens for (config\ahk\710.ahk's OnMessage hooks), and the process behind it. Loaded by
  tools\lib\activation.ps1. Only functions.
#>

function Find-AhkWindow {
    <# The hidden main window of the AHK process running -ScriptPath, or [IntPtr]::Zero.
       AHK titles that window "<full script path> - AutoHotkey v2.x", so the title is how we
       tell 710.ahk apart from any other AHK script. Found by window rather than by
       Win32_Process because a normal shell can't read a UI Access process's command line;
       window titles, on the other hand, are readable across that boundary (open-main-menu.ahk
       finds 710.ahk the same way). #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    Initialize-AhkWindowNative
    $hwnd = [IntPtr]::Zero
    while ($true) {
        # [NullString]::Value, NOT $null: PowerShell hands $null to a .NET string parameter
        # as "" -- and FindWindowEx(..., "") only matches windows with an EMPTY title, so
        # the first build of this never found 710.ahk (Stop-All left it running, 2026-09-25).
        $hwnd = [Win710.AhkWindow]::FindWindowEx([IntPtr]::Zero, $hwnd, 'AutoHotkey', [NullString]::Value)
        if ($hwnd -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        $sb = [System.Text.StringBuilder]::new(1024)
        [void][Win710.AhkWindow]::GetWindowText($hwnd, $sb, $sb.Capacity)
        if ($sb.ToString().IndexOf($ScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $hwnd }
    }
}

function Send-AhkMessage {
    <# Posts the registered window message -Name ('710sRice.Quit', '710sRice.ReloadStack',
       '710sRice.StartApps' with -WParam) to 710.ahk -- see the OnMessage hooks next to
       OpenMainMenu in config\ahk\710.ahk, each let through UIPI there because AHK runs with UI
       Access. $true if a 710.ahk window was found and the post went through, $false otherwise
       (AHK not running, as far as the caller cares). Fire-and-forget: a post doesn't wait for
       AHK to act on it. #>
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$Name, [int]$WParam = 0)
    $hwnd = Find-AhkWindow -ScriptPath $ScriptPath
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    $msg = [Win710.AhkWindow]::RegisterWindowMessage($Name)
    return [Win710.AhkWindow]::PostMessage($hwnd, $msg, [IntPtr]$WParam, [IntPtr]::Zero)
}

function Send-AhkQuit {
    <# Asks 710.ahk to quit ('710sRice.Quit'). $false = no 710.ahk window found; the caller's
       kill fallback covers the rest. #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    Send-AhkMessage -ScriptPath $ScriptPath -Name '710sRice.Quit'
}

function Initialize-AhkWindowNative {
    if (-not ('Win710.AhkWindow' -as [type])) {
        Add-Type -Namespace Win710 -Name AhkWindow -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern uint RegisterWindowMessage(string lpString);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
'@
    }
}

function Get-AhkWindowProcessId {
    <# The process id behind 710.ahk's window (Find-AhkWindow), or $null when it isn't running.
       How `710sRice doctor` tells which exe runs 710.ahk (UI Access or not) and reads its
       elevation -- by the window, not by process name, so another AHK script can't pass for it. #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    $hwnd = Find-AhkWindow -ScriptPath $ScriptPath
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $procId = [uint32]0
    [void][Win710.AhkWindow]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    if ($procId) { [int]$procId } else { $null }
}
