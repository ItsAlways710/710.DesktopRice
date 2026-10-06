<#
.SYNOPSIS
  The component loader (Group 1 #12): one file per app in tools\components\<id>.ps1, each
  returning one hashtable -- its install step, what uninstall puts back and its doctor checks.
  Dot-sourced by tools\lib\steps.ps1 and tools\lib\activation.ps1
  -- never run directly. Only functions here: nothing is loaded until something asks.

.DESCRIPTION
  Modelled on the palette targets (tools\palette\targets\, Get-PaletteTargets): the files are run
  in name order, each is checked, and a broken one THROWS -- loud, never skipped: an install,
  uninstall or doctor that silently lost an app's step would be worse than one that stops and
  says which file is wrong. The fields are documented in tools\components\README.md.

  Each component is one install step named by its Id, spliced into install's order right after
  its After step (a fixed step, or another component's Id; ties by Id) -- Get-RiceStepOrder, read
  through tools\lib\steps.ps1's Get-InstallStepOrder by install, `710sRice install -?` and
  doctor's repair plan. So `710sRice install -Only <id>` works, and repair orders a component's
  fix like any step. (claude/group1-plan.md, #12.)
#>

# The repo root, and the loader's fixed lists, as FUNCTIONS -- never script-scoped variables.
# This file is dot-sourced once per process when a script finds the loader already defined
# (tools\lib\steps.ps1 / activation.ps1 skip it then), and PowerShell's `$script:` means the
# CALLER's script scope at call time: the 710sRice command loads this file, then runs
# install.ps1 / uninstall.ps1 / Start-All.ps1 in place, and inside those `$script:` variables set
# here were empty -- every `710sRice install` stopped with "Cannot bind argument to parameter
# 'Path' because it is null" (found on the Dell, Group 1's final test, 2026-10-01). $PSScriptRoot
# inside a function is the file that DEFINES it (tools\lib), whoever calls.
function Get-RiceComponentsRoot { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

# doctor.ps1's group titles (Get-DoctorGroups) -- a component's Group must be one of them.
function Get-RiceComponentGroups {
    @('Repo and command', 'Packages and pins', 'Stack', 'Tasks and tiling mode',
      'Generated configs', 'Integrations', 'Conflicts and leftovers')
}
# (Autostart -- a component's own sign-in task -- went 2026-10-06: Flow, the only one, is started
# by 710.ahk now, and a task's job is what broke it. A file that still has one is told so.)
function Get-RiceComponentFields { @('Id', 'Label', 'After', 'Install', 'Uninstall', 'Check', 'Group', 'NamedOnly', 'Functions') }

function Get-RiceComponentsDir { Join-Path (Get-RiceComponentsRoot) 'tools\components' }

function Get-RiceFixedSteps {
    # install's fixed steps (tools\lib\steps.ps1), loaded here when the caller hasn't.
    if (-not (Get-Variable -Name InstallFixedStepOrder -ErrorAction SilentlyContinue)) {
        . (Join-Path (Get-RiceComponentsRoot) 'tools\lib\steps.ps1')
    }
    $InstallFixedStepOrder
}

function Get-RiceComponents {
    <# Every component, checked, in file-name order (cached; -Refresh reads the files again). Each
       definition gains File (its path). Throws, naming the file, on: no hashtable, an Id that
       isn't the file's name or clashes with a fixed step, a missing Label / After, a field this
       loader doesn't know (a typo must not vanish quietly), a field of the wrong kind, an After
       that names no step, or Afters that go round in a circle. #>
    param([switch]$Refresh)
    if ($script:RiceComponentCache -and -not $Refresh) { return $script:RiceComponentCache }
    $fixed = @(Get-RiceFixedSteps)
    $dir = Get-RiceComponentsDir
    $list = [System.Collections.Generic.List[object]]::new()
    $files = if (Test-Path -LiteralPath $dir) { @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object Name) } else { @() }
    foreach ($f in $files) {
        $where = "tools\components\$($f.Name)"
        $def = & $f.FullName
        if ($def -isnot [System.Collections.IDictionary]) { throw "$where doesn't return a component definition (a hashtable)" }
        foreach ($k in @($def.Keys)) {
            if ("$k" -eq 'Autostart') { throw "$where : Autostart is gone (2026-10-06) -- an app gets no sign-in task of its own; 710.ahk starts the ones you open programs from (config\ahk\710.ahk, ""The apps 710.ahk starts"")" }
            if ("$k" -notin (Get-RiceComponentFields)) { throw "$where has a field this loader doesn't know: '$k' (the fields: $((Get-RiceComponentFields) -join ', '))" }
        }
        if ("$($def.Id)" -ne $f.BaseName) { throw "$where says its Id is '$($def.Id)' -- it has to be the file's own name, '$($f.BaseName)'" }
        if ($def.Id -notmatch '^[a-z][a-z0-9-]*$') { throw "$where : an Id is lower-case letters, digits and dashes ('$($def.Id)')" }
        if ($def.Id -in $fixed) { throw "$where : '$($def.Id)' is already one of install's own steps" }
        foreach ($k in 'Label', 'After') { if (-not ($def[$k] -is [string]) -or -not $def[$k].Trim()) { throw "$where needs $k (text)" } }
        foreach ($k in 'Install', 'Uninstall', 'Check', 'Functions') { if ($def.Contains($k) -and $def[$k] -isnot [scriptblock]) { throw "$where : $k has to be a scriptblock" } }
        if ($def.Contains('Group') -and "$($def.Group)" -notin (Get-RiceComponentGroups)) { throw "$where : Group '$($def.Group)' isn't one of doctor's groups ($((Get-RiceComponentGroups) -join ', '))" }
        if ($def.Contains('NamedOnly') -and $def.NamedOnly -isnot [bool]) { throw "$where : NamedOnly is `$true or `$false" }
        if (-not $def.Contains('Group')) { $def.Group = 'Integrations' }
        if (-not $def.Contains('NamedOnly')) { $def.NamedOnly = $false }
        $def.File = $f.FullName
        $list.Add($def)
    }
    # After: a fixed step or another component, and every chain ends at a fixed step.
    $ids = @($list | ForEach-Object { $_.Id })
    foreach ($c in $list) {
        if ($c.After -notin $fixed -and $c.After -notin $ids) { throw "tools\components\$($c.Id).ps1 : After '$($c.After)' names no install step or component" }
        $seen = @($c.Id); $at = $c.After
        while ($at -notin $fixed) {
            if ($at -in $seen) { throw "tools\components: the After fields go round in a circle ($(($seen + $at) -join ' -> '))" }
            $seen += $at
            $at = ($list | Where-Object { $_.Id -eq $at } | Select-Object -First 1).After
        }
    }
    $script:RiceComponentCache = @($list)
    $script:RiceComponentCache
}

function Get-RiceComponent {
    param([Parameter(Mandatory)][string]$Id)
    Get-RiceComponents | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

function Get-RiceStepOrder {
    <# install's fixed steps with every component step spliced in right after its After step --
       and a component's own followers right after it -- ties by Id. #>
    $fixed = @(Get-RiceFixedSteps)
    $comps = @(Get-RiceComponents)
    $out = [System.Collections.Generic.List[string]]::new()
    $emit = $null
    $emit = {
        param($step)
        $out.Add($step)
        foreach ($c in @($comps | Where-Object { $_.After -eq $step } | Sort-Object { $_.Id })) { & $emit $c.Id }
    }
    foreach ($s in $fixed) { & $emit $s }
    @($out)
}

function Invoke-RiceComponentPart {
    <# Runs one of a component's parts -- Install, Uninstall or Check -- with its $Ctx: the
       component's own Functions (if any) are dot-sourced here first, so the part (a child of
       this scope) sees them, the same as the helpers of whoever called this. Its output is the
       part's output (Check's doctor results). #>
    param([Parameter(Mandatory)]$Component, [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall', 'Check')][string]$Part, $Ctx)
    if ($Component.Functions) { . $Component.Functions }
    & $Component[$Part] $Ctx
}

function New-RiceComponentContext {
    <# The $Ctx a component's Install / Uninstall / Check gets. FullTime = the machine's mode
       (install passes -Activate's answer; everything else asks Test-FullTimeMachine). Never
       throws: a mode or admin check that fails reads as "no" -- a context must never be what
       stops an uninstall or a doctor run. #>
    param([bool]$OnlyRun = $false, [bool]$DryRun = $false, $FullTime = $null)
    if ($null -eq $FullTime) { try { $FullTime = [bool](Test-FullTimeMachine) } catch { $FullTime = $false } }
    $admin = try { [bool](Test-IsAdmin) } catch { $false }
    [pscustomobject]@{
        Root     = Get-RiceComponentsRoot
        OnlyRun  = $OnlyRun
        FullTime = [bool]$FullTime
        IsAdmin  = $admin
        DryRun   = $DryRun
    }
}
