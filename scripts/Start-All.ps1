#Requires -Version 7.0
<#
.SYNOPSIS
  Starts 710.DesktopRice's whole stack now (komorebi, YASB, ShareX, AHK) --
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

  Then it checks what came up, for up to 20 seconds. A [!!] isn't necessarily a
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

Write-Host "`n== 710.DesktopRice: start all ==" -ForegroundColor Cyan

$components = @(Get-AutostartComponents)
if ($components.Count -eq 0) {
    Step-Warn "No components found installed (komorebi/YASB/ShareX/AHK all missing?) -- run .\install.ps1 first."
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
    # waiting.
    foreach ($c in $components) {
        try {
            Start-Process -FilePath $c.Exe -ArgumentList $c.Arguments -WindowStyle Hidden
            Step-Ok "$($c.Key): launched"
        } catch {
            Step-Warn "$($c.Key): failed to launch -- $($_.Exception.Message)"
        }
    }
}

Write-Host "`n-- Checking what came up (up to 20s; see the header if something's still settling) --" -ForegroundColor Cyan
# One check per component, polled once a second until all pass or 20s is up --
# komorebi's launcher alone takes ~10s (it waits for the desktop, then checks komorebi
# survives 8s), so a single fixed wait either wastes time or reports too early.
$checks = [ordered]@{
    'komorebi'     = @{ Name = 'komorebi';     Test = { [bool](Get-Process komorebi -ErrorAction SilentlyContinue) };     Log = 'komorebi-autostart.log' }
    'yasb'         = @{ Name = 'YASB';         Test = { [bool](Get-Process yasb -ErrorAction SilentlyContinue) };         Log = 'yasb-autostart.log' }
    'sharex'       = @{ Name = 'ShareX';       Test = { [bool](Get-Process ShareX -ErrorAction SilentlyContinue) };       Log = $null }
    'ahk'          = @{ Name = '710.ahk';      Test = { [bool](Get-Process AutoHotkey64 -ErrorAction SilentlyContinue) }; Log = 'ahk-autostart.log' }
}
$pending = [System.Collections.Generic.List[string]]::new()
foreach ($k in $checks.Keys) { if ($components.Key -contains $k) { $pending.Add($k) } }
$deadline = (Get-Date).AddSeconds(20)
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    foreach ($k in @($pending)) { if (& $checks[$k].Test) { [void]$pending.Remove($k) } }
}
foreach ($k in $checks.Keys) {
    if ($components.Key -notcontains $k) { continue }
    $c = $checks[$k]
    if ($pending -notcontains $k) {
        Step-Ok ("$($c.Name) running" + $(if ($k -eq 'ahk') { ' (an AutoHotkey64 process -- see NOTES)' }))
    } else {
        Step-Warn ("$($c.Name) not running after 20s" + $(if ($c.Log) { " -- check %LOCALAPPDATA%\710.DesktopRice\$($c.Log)" } else { '' }))
    }
}

try {
    if (-not (Test-TaskbarAutoHide)) {
        Write-Host ''
        Step-Info "Tip: the Windows taskbar isn't set to auto-hide, so it shows alongside the bar. To hide it while you use 710.DesktopRice: Settings > Personalization > Taskbar > Taskbar behaviors > Automatically hide the taskbar. (Stop-All.ps1 reminds you to turn it back off.)"
    }
} catch { }

Write-Host "`nDone." -ForegroundColor Cyan
