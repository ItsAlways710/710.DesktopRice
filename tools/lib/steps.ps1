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

# Steps a plain run never includes -- only -Only runs them. upgrade: install never moves an
# installed package unless asked (user, 2026-09-26: "upgrade must be named"). palette: a plain
# run's theme step already themes everything (from the default wallpaper).
$InstallNamedOnlySteps = @('upgrade', 'palette')
