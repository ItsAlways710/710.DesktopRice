<#
.SYNOPSIS
  The loader install.ps1, uninstall.ps1, the 710sRice command's install-side commands and
  Start-All / Stop-All dot-source: the lock screen, the component loader, the shared helpers (one
  small library each) and install's fixed steps (tools\steps\<step>.ps1, one module each: the
  step, what uninstall puts back, doctor's checks). No code of its own -- docs\map.md says what's
  where. Dot-sourced -- never run directly.

.DESCRIPTION
  Callers (install.ps1 / uninstall.ps1) must already have Step-Ok / Step-Info / Step-Warn
  defined before dot-sourcing this file -- the libraries use theirs rather than defining their
  own, to avoid two competing copies in the same process.

  Much of what they hold was ported from winarchy (module/Winarchy/Private/Identity.ps1,
  Hardening.ps1, Taskbar.ps1, Autostart.ps1, ShellProfile.ps1, Util.ps1), pinned to origin/main
  @ 4574fc7 (tag v1.4.0) -- NOT Dell's local C:\winarchy checkout, which sat on an old, unpulled
  commit (cbae6a3) plus unrelated local edits and was missing several of these files entirely
  (Hardening.ps1, Taskbar.ps1 didn't exist on disk there at all). See
  claude/winarchy-decoupling-plan.md for the full verification trail.
#>

# The lock screen, all of it but its setter script: the setter's runner and record (the wallpaper
# pipeline dot-sources the same file), install's and uninstall's parts, doctor's check.
. (Join-Path $PSScriptRoot 'lockscreen.ps1')

# The components (tools\components\<id>.ps1, Group 1 #12). Only functions -- nothing is read
# until something asks.
if (-not (Get-Command Get-RiceComponents -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'components.ps1') }

# The shared helpers, one small library each (docs\map.md says what's in each).
. (Join-Path $PSScriptRoot 'text.ps1')
. (Join-Path $PSScriptRoot 'snapshots.ps1')
. (Join-Path $PSScriptRoot 'userenv.ps1')
. (Join-Path $PSScriptRoot 'wallpaper.ps1')
. (Join-Path $PSScriptRoot 'apps.ps1')
. (Join-Path $PSScriptRoot 'tasks.ps1')
. (Join-Path $PSScriptRoot 'elevation.ps1')
. (Join-Path $PSScriptRoot 'ahk.ps1')
. (Join-Path $PSScriptRoot 'shortcuts.ps1')
. (Join-Path $PSScriptRoot 'explorer.ps1')
. (Join-Path $PSScriptRoot 'fonts.ps1')
. (Join-Path $PSScriptRoot 'terminal.ps1')
. (Join-Path $PSScriptRoot 'fulltime.ps1')
. (Join-Path $PSScriptRoot 'stack.ps1')
. (Join-Path $PSScriptRoot 'tiling.ps1')

# install's fixed steps, one module each (tools\steps\<step>.ps1): the step itself, what uninstall
# puts back, doctor's checks (docs\map.md, Install steps).
. (Join-Path $PSScriptRoot '..\steps\envvars.ps1')
. (Join-Path $PSScriptRoot '..\steps\path.ps1')
. (Join-Path $PSScriptRoot '..\steps\wallust.ps1')
. (Join-Path $PSScriptRoot '..\steps\theme.ps1')
. (Join-Path $PSScriptRoot '..\steps\monitors.ps1')
. (Join-Path $PSScriptRoot '..\steps\profile.ps1')
. (Join-Path $PSScriptRoot '..\steps\compile.ps1')
. (Join-Path $PSScriptRoot '..\steps\tasks.ps1')
