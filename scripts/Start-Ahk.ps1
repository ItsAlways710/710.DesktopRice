# Start-Ahk.ps1 -- starts the AHK dispatcher waiting for the shell to be ready, with
# retries. No-op if 710.ahk is already running (another AutoHotkey script doesn't count).
# Ported from winarchy's scripts/Start-Ahk.ps1 @ 4574fc7.

param(
    [Parameter(Mandatory)][string]$AhkExe,
    [Parameter(Mandatory)][string]$ScriptPath
)

$exe    = $AhkExe
$script = $ScriptPath
$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'ahk-autostart.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# Log cap: past 1 MB this log becomes <name>.old (replacing the previous one) and a fresh
# one starts -- so at most ~2 MB, and the last chunk of history is always kept. Same rule
# in every 710.DesktopRice log writer (plan doc, open item 20).
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }

Add-Type -Namespace Win710 -Name FgAhk -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
'@

function Test-ForegroundReady {
    [bool]((Get-Process explorer -ErrorAction SilentlyContinue) -and `
           ([Win710.FgAhk]::GetForegroundWindow() -ne [System.IntPtr]::Zero))
}

function Write-Log([string]$m) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Out-File -FilePath $log -Append -Encoding utf8
}

# 710.ahk's own window, found by its title: AutoHotkey titles a script's hidden main window
# "<full script path> - AutoHotkey v2.x" -- the lookup 710sRice uses (Find-AhkWindow,
# tools\lib\ahk.ps1). Until 2026-10-06 any AutoHotkey64 / AutoHotkey64_UIA process
# counted, so another AutoHotkey v2 script you run kept 710.ahk from starting at all: at
# sign-in, `710sRice start` and `restart`, and an update's restart of an older 710.ahk. The
# title finds either build (AutoHotkey64_UIA.exe is what the tasks start, UI Access -- plan doc
# Open item 36; plain AutoHotkey64.exe the per-user-install fallback), so a running 710.ahk never
# gets a second one on top, whose #SingleInstance can't close a UIA instance anyway -- just a
# popup and an early exit. A title is readable across the UI Access boundary; a UIA process's
# command line isn't, from here. (No two of these race: the ahk task ignores a second run while
# one is still going.) FindWindowEx's title is NULL as IntPtr.Zero: PowerShell hands $null to a
# string parameter as "", which only matches windows with an empty title.
Add-Type -Namespace Win710 -Name AhkWin -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern System.IntPtr FindWindowEx(System.IntPtr parent, System.IntPtr childAfter, string className, System.IntPtr windowName);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
'@

function Test-AhkRunning {
    $hwnd = [System.IntPtr]::Zero
    while ($true) {
        $hwnd = [Win710.AhkWin]::FindWindowEx([System.IntPtr]::Zero, $hwnd, 'AutoHotkey', [System.IntPtr]::Zero)
        if ($hwnd -eq [System.IntPtr]::Zero) { return $false }
        $title = New-Object System.Text.StringBuilder 1024
        [void][Win710.AhkWin]::GetWindowText($hwnd, $title, $title.Capacity)
        if ($title.ToString().IndexOf($script, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
}

$exeName = Split-Path $exe -Leaf
if (-not (Test-Path $exe)) { Write-Log "$exeName not found at $exe; aborting."; exit 1 }
if (Test-AhkRunning) { Write-Log '710.ahk already running; nothing to do.'; exit 0 }

# Belt-and-suspenders: clears any Claude Code sub-session flags this launcher process
# itself inherited, in addition to 710.ahk's own EnvSet('CLAUDE_CODE_CHILD_SESSION') /
# EnvSet('CLAUDECODE') at its own startup (see config/ahk/710.ahk).
Remove-Item Env:CLAUDE_CODE_CHILD_SESSION, Env:CLAUDECODE -ErrorAction SilentlyContinue

Write-Log '--- startup (autostart) ---'

# A 710.ahk that won't load -- a key user.ahk defines again, a typo there -- would stop every attempt
# below on AutoHotkey's error box. AutoHotkey's own check first (tools\lib\ahk-load.ps1), and why
# goes in this log instead; 710sRice doctor says the same, and what to do.
. (Join-Path $PSScriptRoot '..\tools\lib\ahk-load.ps1')
$load = Test-AhkScriptLoads -AhkExe $exe -ScriptPath $script
if ($load.Loaded -eq $false) {
    Write-Log "710.ahk won't load -- $(Format-AhkLoadError $load (Split-Path -Parent $PSScriptRoot)). Not started: 710sRice doctor says what to do."
    exit 1
}

$overallDeadline = (Get-Date).AddMinutes(2)
$attempt = 0
while ((Get-Date) -lt $overallDeadline) {
    if (Test-AhkRunning) { Write-Log '710.ahk running; done.'; exit 0 }
    $attempt++

    while ((Get-Date) -lt $overallDeadline -and -not (Test-ForegroundReady)) { Start-Sleep -Milliseconds 500 }

    Write-Log "attempt ${attempt}: launching $exeName"
    try {
        $p = Start-Process -FilePath $exe -ArgumentList "`"$script`"" -WindowStyle Hidden -PassThru
    } catch {
        Write-Log "attempt ${attempt}: failed to launch: $($_.Exception.Message)"
        Start-Sleep -Seconds 2
        continue
    }

    # Start-Process = ShellExecute, which the UIA exe needs (AutoHotkey's docs: a UIA exe
    # can't be started via CreateProcess). Liveness is 710.ahk's window (Test-AhkRunning)
    # rather than $p.HasExited: a normal process can be refused access to a UI Access process
    # (found live: Stop-Process on one is 'Access is denied'), so the handle can't be trusted.
    Start-Sleep -Seconds 3
    if (Test-AhkRunning) { Write-Log "attempt ${attempt}: 710.ahk up after 3s. OK."; exit 0 }

    $code = try { $p.ExitCode } catch { '?' }
    Write-Log "attempt ${attempt}: no 710.ahk after 3s (exit code '$code')."
    Start-Sleep -Seconds 2
}

Write-Log "2 minute budget exhausted; 710.ahk never came up."
exit 1
