#Requires -Version 7.0
<#
.SYNOPSIS
  Brings up 710.DesktopRice's whole stack by hand (komorebi, YASB, window-slots, ShareX,
  AHK) -- the dev-loop companion to testing config\ahk\710.ahk without needing a real
  install.ps1 -Activate run (autostart Scheduled Tasks) first.

.DESCRIPTION
  Not a new implementation of "how to launch each component" -- reuses tools\lib\
  activation.ps1's Get-AutostartComponents wholesale, the exact same Exe/Arguments/Delay
  values -Activate would register as Scheduled Tasks (see that function). Running this is
  therefore also an informal dry-run of those exact launch commands, without touching the
  registry, the taskbar, or Windows hardening -- see uninstall.ps1 for what -Activate
  actually registers, and why exercising that for real is still being held off on.

  Fires each component with Start-Process (hidden) and the same Delay spacing
  Get-AutostartComponents defines (in seconds below), then does one short wait-and-check
  pass and reports what came up. A [!!] here isn't necessarily a failure -- the resilient
  launchers (Start-Komorebi.ps1 etc.) retry for their own budget (up to 5 minutes for
  komorebi) and log to $env:LOCALAPPDATA\710.DesktopRice\*.log; this script's own wait is
  much shorter than that on purpose, so it doesn't sit there for minutes on a slow
  morning. Re-run it, or check the logs, if something's still settling.

  Only starts what's actually present on this machine (Get-AutostartComponents already
  skips a missing component rather than erroring) and never stops anything first -- run
  Stop-All.ps1 first if something else (an earlier run of this script, or Winarchy) might
  already be running under the same process names.

.NOTES
  The final AHK check below is a plain `Get-Process AutoHotkey64` -- coarser than
  Stop-All.ps1's own precise command-line match, so it can't tell 710.ahk apart from any
  other AHK v2 script you might have running. Fine for "did something come up", not
  proof it's THIS repo's dispatcher.

.EXAMPLE
  .\scripts\Stop-All.ps1; .\scripts\Start-All.ps1   # clean switch from whatever was running
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Step-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Step-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Step-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

# Step-Ok/Info/Warn must be defined before this dot-source -- activation.ps1 uses ours
# rather than its own copies (see that file's header). Also brings in Get-AhkExe /
# Get-ShareXExe / Get-KomorebiExe, which Get-AutostartComponents itself relies on.
. (Join-Path $Root 'tools\lib\activation.ps1')
# For the final Test-WindowSlotsRunning check below. PS7-only syntax internally -- see
# this script's own #Requires and that file's header for why it can't run under legacy PS.
. (Join-Path $Root 'tools\lib\window-slots.ps1')

Write-Host "`n== 710.DesktopRice: start all ==" -ForegroundColor Cyan

$components = @(Get-AutostartComponents)
if ($components.Count -eq 0) {
    Step-Warn "No components found installed (komorebi/YASB/window-slots/ShareX/AHK all missing?) -- nothing to start."
    return
}

foreach ($c in $components) {
    $delaySeconds = 0
    if ($c.Delay -match '^PT(\d+)S$') { $delaySeconds = [int]$Matches[1] }
    if ($delaySeconds -gt 0) {
        Step-Info "Waiting ${delaySeconds}s before $($c.Key) (matches its Scheduled Task Delay) ..."
        Start-Sleep -Seconds $delaySeconds
    }
    Step-Info "Launching $($c.Key) ..."
    try {
        Start-Process -FilePath $c.Exe -ArgumentList $c.Arguments -WindowStyle Hidden
    } catch {
        Step-Warn "$($c.Key): failed to launch -- $($_.Exception.Message)"
    }
}

Write-Host "`n-- Checking what came up (short wait; see NOTES if something's still settling) --" -ForegroundColor Cyan
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
    if (Get-Process AutoHotkey64 -ErrorAction SilentlyContinue) { Step-Ok '710.ahk running (AutoHotkey64 process found -- see NOTES above on precision)' }
    else { Step-Warn '710.ahk not running yet -- check %LOCALAPPDATA%\710.DesktopRice\ahk-autostart.log' }
}

Write-Host "`nDone." -ForegroundColor Cyan
