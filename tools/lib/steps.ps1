<#
.SYNOPSIS
  install.ps1's steps, in the one order they ever run. Dot-sourced by install.ps1 (which
  checks -Only against it before touching anything), by 710sRice.ps1 (`install -?` lists
  them) and so by doctor's repair plan (tools\lib\doctor.ps1, Get-RepairPlan) -- one list,
  so the three can't drift apart. (claude/cli-plan.md, Stages 2 and 4.)

  Since Group 1 (#12) the list is install's fixed steps plus one step per component
  (tools\components\<id>.ps1), each spliced in right after its After step: Get-InstallStepOrder.
  Loading them costs a little, so only what needs the full list asks for it (install itself,
  `install -?`, the repair plan) -- a plain `710sRice help` never does.
#>

# install's own steps, in the order install runs them -- whatever order `-Only` names them in.
# (flow was one until Group 1 #4: it's a component now, tools\components\flow.ps1, run right after
# wallust; defender until 2026-10-07, tools\components\defender.ps1, right after monitors.)
# (weather was one until Group 1 #1: the Open-Meteo widget needs nothing from install.)
$InstallFixedStepOrder = @('packages', 'upgrade', 'envvars', 'path', 'wallust', 'theme', 'palette',
                           'monitors', 'profile', 'terminal', 'compile', 'tasks', 'windows')

# Steps a plain run never includes -- only -Only runs them. upgrade: doctor's named fix for "older
# than its pin", from the local version probes; a plain run's packages step already brings a
# pinned package below its pin up to it, from what `winget list` shows (Group 1 W7, 2026-09-30 --
# this replaced the Stage 2 rule "install never moves an installed package"). palette: a plain
# run's theme step already themes everything (from the default wallpaper). A component can be
# named-only too (its NamedOnly field).
$InstallFixedNamedOnlySteps = @('upgrade', 'palette')

if (-not (Get-Command Get-RiceComponents -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'components.ps1') }

function Get-InstallStepOrder {
    # Every step, fixed and component, in install's order (Get-RiceStepOrder).
    Get-RiceStepOrder
}

function Get-InstallNamedOnlySteps {
    @($InstallFixedNamedOnlySteps) + @(Get-RiceComponents | Where-Object { $_.NamedOnly } | ForEach-Object { $_.Id })
}
