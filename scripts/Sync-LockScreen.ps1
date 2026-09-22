#Requires -Version 7.0
<#
.SYNOPSIS
  Syncs the Windows lock screen image to whatever the desktop wallpaper currently is.

.DESCRIPTION
  The action script for the '710.DesktopRice\lock-screen-sync' Scheduled Task (registered
  elevated -- RunLevel HighestAvailable -- with no trigger of its own; on-demand only).
  tools\apply-wallust-outputs.ps1 fires it via `schtasks /Run` as a 6th theming leg,
  every time wallust regenerates a palette, which itself is triggered whenever the
  wallpaper changes (see that script and tools\lib\activation.ps1's
  Register-LockScreenSyncTask).

  Reads the CURRENT desktop wallpaper straight from HKCU\Control Panel\Desktop\WallPaper
  -- the same legacy value both SystemParametersInfo(SPI_SETDESKWALLPAPER) and the modern
  IDesktopWallpaper COM API keep updated for compatibility -- so this script takes no
  argument and can never drift out of sync with a stale path passed at trigger time; it
  always syncs to whatever the desktop actually shows right now.

  Writes HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP
  (LockScreenImageStatus/LockScreenImagePath/LockScreenImageUrl) -- the same registry
  surface Enterprise/Education MDM policy uses officially, confirmed via real-world
  precedent to also work when written directly on an unmanaged machine, any edition (see
  claude/winarchy-decoupling-plan.md's Lock-screen sync entry for the sourcing). Requires
  elevation to write HKLM -- this script is only ever meant to run via the elevated task
  above, never invoked directly by a normal user session.

  Known, accepted tradeoff: once this key is set, Windows greys out the manual "choose a
  photo" lock-screen option under Settings -> Personalization -> Lock screen. Deliberate,
  not an oversight -- the whole point is the lock screen always matching the wallpaper
  automatically, not offering a separately-chosen one.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$wallpaperPath = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper' -ErrorAction Stop).WallPaper
if (-not $wallpaperPath -or -not (Test-Path $wallpaperPath)) {
    Write-Warning "Sync-LockScreen: no current wallpaper found at '$wallpaperPath' -- nothing to sync."
    exit 1
}

$cspPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
if (-not (Test-Path $cspPath)) { New-Item -Path $cspPath -Force | Out-Null }
Set-ItemProperty -Path $cspPath -Name 'LockScreenImageStatus' -Value 1 -Type DWord
Set-ItemProperty -Path $cspPath -Name 'LockScreenImagePath' -Value $wallpaperPath -Type String
Set-ItemProperty -Path $cspPath -Name 'LockScreenImageUrl' -Value $wallpaperPath -Type String

Write-Host "Lock screen synced to: $wallpaperPath"
