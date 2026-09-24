#Requires -Version 7.0
<#
.SYNOPSIS
  Starts 710.DesktopRice's whole stack now (komorebi, YASB, window-slots, ShareX, AHK) --
  the "on demand" way to run it, for a machine installed WITHOUT -Activate.

.DESCRIPTION
  Two ways to use this repo:
    - install.ps1 -Activate: the stack starts at every sign-in (Scheduled Tasks), plus the
      Windows changes that go with a full-time shell (taskbar auto-hide, hardening,
      Startup delay).
    - install.ps1 alone, then this script when you want the stack, and Stop-All.ps1 (or
      the tray's "Quit 710sRice") when you're done. Nothing starts at sign-in and Windows
      itself isn't changed -- hardening and the Startup delay only make sense for a
      full-time shell.

  Uses the exact launch commands the sign-in tasks use (tools\lib\activation.ps1's
  Get-AutostartComponents), so on-demand and -Activate start things the same way.

  Never starts the stack elevated. Anything started from an admin shell runs as admin --
  AHK, and every Terminal it opens after it, and non-elevated komorebi can't tile those
  windows (the trap install -Activate itself had, fixed 2026-09-24). So:
    - If the sign-in tasks exist (an -Activate install), it fires them, which always
      starts things non-elevated -- fine from any shell.
    - Otherwise it starts each component directly, and refuses to run from an admin
      shell. Use a normal PowerShell window.

  Taskbar auto-hide is left to you: this checks it and, if it's off, the last line says how
  to turn it on (the stack is built around a hidden taskbar). Stop-All.ps1 reminds you to
  turn it back off. Neither script changes it.

  Then one short wait-and-check pass reports what came up. A [!!] isn't necessarily a
  failure -- the launchers (scripts\Start-Komorebi.ps1 etc.) keep retrying for their own
  budget (up to 5 minutes for komorebi) and log to %LOCALAPPDATA%\710.DesktopRice\. Re-run
  this, or check those logs, if something's still settling. A component that's already
  running is left alone (each launcher checks first).

.NOTES
  The AHK check is a plain `Get-Process AutoHotkey64` -- it can't tell 710.ahk apart from
  another AHK v2 script you might run. Fine for "did something come up".

.EXAMPLE
  .\scripts\Start-All.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Step-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Step-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Step-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

# Step-Ok/Info/Warn must be defined before this dot-source -- activation.ps1 uses ours
# rather than its own copies (see that file's header).
. (Join-Path $Root 'tools\lib\activation.ps1')
# For the final Test-WindowSlotsRunning check. PS7-only syntax inside, hence #Requires.
. (Join-Path $Root 'tools\lib\window-slots.ps1')

Write-Host "`n== 710.DesktopRice: start all ==" -ForegroundColor Cyan

$components = @(Get-AutostartComponents)
if ($components.Count -eq 0) {
    Step-Warn "No components found installed (komorebi/YASB/window-slots/ShareX/AHK all missing?) -- run .\install.ps1 first."
    exit 1
}

$viaTasks = @($components | Where-Object { Test-Task -TaskName $_.TaskName }).Count -eq $components.Count
if ($viaTasks) {
    # -Activate install: the sign-in tasks are LeastPrivilege, so this is safe elevated too.
    foreach ($c in $components) {
        $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName $c.TaskName) 2>&1
        if ($LASTEXITCODE -eq 0) { Step-Ok "$($c.Key): started via its sign-in task" }
        else { Step-Warn "$($c.Key): schtasks /Run failed (exit $LASTEXITCODE)" }
    }
} else {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Step-Warn "This is an admin shell -- everything started from here would run as admin (and komorebi couldn't tile what AHK opens). Run this from a normal PowerShell window instead. Nothing was started."
        exit 1
    }
    # No sign-in delays here: those space things out at logon; by hand they'd just be
    # waiting (window-slots' was 10s).
    foreach ($c in $components) {
        try {
            Start-Process -FilePath $c.Exe -ArgumentList $c.Arguments -WindowStyle Hidden
            Step-Ok "$($c.Key): launched"
        } catch {
            Step-Warn "$($c.Key): failed to launch -- $($_.Exception.Message)"
        }
    }
}

Write-Host "`n-- Checking what came up (short wait; see the header if something's still settling) --" -ForegroundColor Cyan
Start-Sleep -Seconds 5

if ($components.Key -contains 'komorebi') {
    if (Get-Process komorebi -ErrorAction SilentlyContinue) { Step-Ok 'komorebi running' }
    else { Step-Warn 'komorebi not running yet -- check %LOCALAPPDATA%\710.DesktopRice\komorebi-autostart.log' }
}
if ($components.Key -contains 'yasb') {
    if (Get-Process yasb -ErrorAction SilentlyContinue) { Step-Ok 'YASB running' }
    else { Step-Warn 'YASB not running yet -- check %LOCALAPPDATA%\710.DesktopRice\yasb-autostart.log' }
}
if ($components.Key -contains 'window-slots') {
    if (Test-WindowSlotsRunning) { Step-Ok 'window-slots running' }
    else { Step-Warn 'window-slots not running yet -- check %LOCALAPPDATA%\710.DesktopRice\window-slots.log' }
}
if ($components.Key -contains 'sharex') {
    if (Get-Process ShareX -ErrorAction SilentlyContinue) { Step-Ok 'ShareX running' }
    else { Step-Warn 'ShareX not running yet' }
}
if ($components.Key -contains 'ahk') {
    if (Get-Process AutoHotkey64 -ErrorAction SilentlyContinue) { Step-Ok '710.ahk running (an AutoHotkey64 process -- see NOTES)' }
    else { Step-Warn '710.ahk not running yet -- check %LOCALAPPDATA%\710.DesktopRice\ahk-autostart.log' }
}

try {
    if (-not (Test-TaskbarAutoHide)) {
        Write-Host ''
        Step-Info "Tip: the Windows taskbar isn't set to auto-hide, so it shows alongside the bar. To hide it while you use 710.DesktopRice: Settings > Personalization > Taskbar > Taskbar behaviors > Automatically hide the taskbar. (Stop-All.ps1 reminds you to turn it back off.)"
    }
} catch { }

Write-Host "`nDone." -ForegroundColor Cyan
