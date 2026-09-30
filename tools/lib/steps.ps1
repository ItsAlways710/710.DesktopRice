<#
.SYNOPSIS
  install.ps1's steps, in the one order they ever run. Dot-sourced by install.ps1 (which
  checks -Only against it before touching anything), by 710sRice.ps1 (`install -?` lists
  them) and so by doctor's repair plan (tools\lib\doctor.ps1, Get-RepairPlan) -- one list,
  so the three can't drift apart. Plain variables only: nothing to load, nothing to run.
  (claude/cli-plan.md, Stages 2 and 4.)
#>

# Every step, in the order install runs them -- whatever order `-Only` names them in.
$InstallStepOrder = @('packages', 'upgrade', 'envvars', 'weather', 'path', 'wallust', 'theme', 'palette',
                      'monitors', 'defender', 'profile', 'terminal', 'flow', 'compile', 'tasks', 'windows')

# Steps a plain run never includes -- only -Only runs them. upgrade: doctor's named fix for "older
# than its pin", from the local version probes; a plain run's packages step already brings a
# pinned package below its pin up to it, from what `winget list` shows (Group 1 W7, 2026-09-30 --
# this replaced the Stage 2 rule "install never moves an installed package"). palette: a plain
# run's theme step already themes everything (from the default wallpaper).
$InstallNamedOnlySteps = @('upgrade', 'palette')
