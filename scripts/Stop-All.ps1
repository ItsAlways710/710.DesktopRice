#Requires -Version 7.0
<#
.SYNOPSIS
  Stops every process 710.DesktopRice's stack may have started (komorebi, YASB,
  window-slots, ShareX, AHK) -- whether started by Start-All.ps1, by hand, by -Activate's
  autostart, or by Winarchy (same binaries/process names, regardless of whose config
  launched them).

.DESCRIPTION
  A thin wrapper around tools\lib\activation.ps1's Stop-RunningComponents -- the exact
  same function uninstall.ps1 calls, reused here rather than duplicated so there's only
  one place this logic lives to keep correct. Safe to run any time or repeatedly: each
  component's stop is independent and best-effort (see Stop-RunningComponents' own doc
  comment), so an already-stopped or never-started component is a silent no-op, not a
  failure.

  Companion to Start-All.ps1 -- built for the dev loop of bringing the stack up and down
  repeatedly while testing config\ahk\710.ahk, NOT a substitute for uninstall.ps1: this
  only stops processes, it never touches -Activate's registry/taskbar/hardening state,
  winget packages, or env vars. Use uninstall.ps1 for an actual uninstall.

.NOTES
  The AHK stop is scoped to processes whose command line references THIS repo's own
  config\ahk\710.ahk specifically (Win32_Process match, not a blanket Stop-Process -Name
  AutoHotkey64) -- so if Winarchy's own AHK dispatcher is running under a different
  script, this won't touch it. Check `Get-Process AutoHotkey64` yourself if you need to
  be sure nothing else is still alive before starting 710.DesktopRice's own.

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
# rather than its own copies (see that file's header).
. (Join-Path $Root 'tools\lib\activation.ps1')

Write-Host "`n== 710.DesktopRice: stop all ==" -ForegroundColor Cyan
Stop-RunningComponents
Step-Ok 'Done (best-effort -- see any [!!] warnings above for anything that did not stop cleanly).'
