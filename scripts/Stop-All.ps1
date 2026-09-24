#Requires -Version 7.0
<#
.SYNOPSIS
  Stops every process 710.DesktopRice's stack may have started (komorebi, YASB,
  window-slots, ShareX, AHK) -- the other half of Start-All.ps1's "on demand" use.

.DESCRIPTION
  A thin wrapper around tools\lib\activation.ps1's Stop-RunningComponents -- the same
  function uninstall.ps1 calls, so there's one place this logic lives. Safe to run any
  time or repeatedly: each component's stop is independent and best-effort, so one that's
  already stopped is a silent no-op. The tray's "Quit 710sRice" stops the same set.

  Only stops processes. It never touches -Activate's autostart/taskbar/hardening state,
  packages, or env vars -- use uninstall.ps1 for an actual uninstall. Flow Launcher and
  Everything keep running; they're ordinary apps you can use without the stack.

  Taskbar: on an on-demand setup (no sign-in tasks), if the taskbar is still set to
  auto-hide, the last line reminds you to turn it back off if you only wanted it while the
  stack ran (Start-All.ps1 suggests turning it on; neither script changes it). Not on an
  -Activate install -- there -Activate set it, and uninstall.ps1 reverts it.

.NOTES
  The AHK stop only matches processes whose command line references THIS repo's
  config\ahk\710.ahk (Win32_Process), never a blanket Stop-Process AutoHotkey64 -- another
  AHK v2 script you run is left alone.

.EXAMPLE
  .\scripts\Stop-All.ps1
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

Write-Host "`n== 710.DesktopRice: stop all ==" -ForegroundColor Cyan
Stop-RunningComponents
Step-Ok 'Done (best-effort -- see any [!!] warnings above for anything that did not stop cleanly).'

try {
    $activated = @(Get-AutostartComponents | Where-Object { Test-Task -TaskName $_.TaskName }).Count -gt 0
    if (-not $activated -and (Test-TaskbarAutoHide)) {
        Write-Host ''
        Step-Info "Reminder: the Windows taskbar is still set to auto-hide. If you only want that while 710.DesktopRice is running, turn it off: Settings > Personalization > Taskbar > Taskbar behaviors > Automatically hide the taskbar."
    }
} catch { }
