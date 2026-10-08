<#
.SYNOPSIS
  The tiling mode: komorebi elevated (the default -- admin windows tile too) or not. Chosen by
  install's switches (-ElevatedTiling / -NoElevatedTiling) or `710sRice tiling`, remembered per
  machine, read when komorebi's task is registered (Get-KomorebiRunLevel, tools\steps\tasks.ps1);
  doctor's tiling line. Loaded by tools\lib\activation.ps1. Only functions.
#>

# --- Tiling mode: elevated komorebi or not (plan doc Open item 37) ------------------------
# "elevated" (the default): komorebi's task runs HighestAvailable, so komorebi can see and
# tile admin windows -- a non-elevated komorebi can't even read their process, let alone
# move them. "normal": LeastPrivilege like everything else; admin windows float. Only
# komorebi ever runs elevated -- AHK runs with UI Access instead, so what it launches stays
# normal. The choice is remembered per machine and only changes when install.ps1 gets
# -ElevatedTiling or -NoElevatedTiling; uninstall forgets it.
# Security, accepted and documented (README): an elevated task whose launch chain reads
# user-writable files -- including komorebi's own komorebi.ps1/.ahk loading from its config
# folder -- is a silent route to admin for anything already running as you.
function Get-TilingModePath { Join-Path $env:LOCALAPPDATA '710.DesktopRice\tiling-mode.txt' }

function Get-TilingMode {
    <# 'elevated' or 'normal'; the remembered value, else the default ('elevated'). #>
    $path = Get-TilingModePath
    if (Test-Path $path) {
        $v = (Get-Content $path -Raw -ErrorAction SilentlyContinue)
        if ($v) { $v = $v.Trim() }
        if ($v -in 'elevated', 'normal') { return $v }
    }
    'elevated'
}

function Get-KomorebiRunLevel {
    if ((Get-TilingMode) -eq 'elevated') { 'HighestAvailable' } else { 'LeastPrivilege' }
}

function Resolve-TilingMode {
    <# install.ps1's switch -> remembered -> default, in that order. Writes the result back
       (so a first install remembers the default too) and returns Mode, Source
       ('switch' / 'remembered' / 'default') and Changed (vs. what was remembered before). #>
    param([switch]$Elevated, [switch]$Normal)
    $path = Get-TilingModePath
    $before = $null
    if (Test-Path $path) {
        $b = (Get-Content $path -Raw -ErrorAction SilentlyContinue)
        if ($b) { $b = $b.Trim() }
        if ($b -in 'elevated', 'normal') { $before = $b }
    }
    if ($Elevated) { $mode = 'elevated'; $source = 'switch' }
    elseif ($Normal) { $mode = 'normal'; $source = 'switch' }
    elseif ($before) { $mode = $before; $source = 'remembered' }
    else { $mode = 'elevated'; $source = 'default' }
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    Set-Content -Path $path -Value $mode -Encoding ascii
    [pscustomobject]@{ Mode = $mode; Source = $source; Changed = ($null -ne $before -and $before -ne $mode) }
}

# --- Doctor's check: the tiling line in Tasks and tiling mode -------------------------------------
function Test-DoctorTilingMode {
    # Three answers that should agree: the saved mode, komorebi's task, the running komorebi.
    # The saved mode reaches the task through `710sRice tiling <mode>` (or install), and the
    # task reaches komorebi at its next start -- `710sRice restart`.
    $saved = Get-TilingMode
    $mode  = if (Test-Path -LiteralPath (Get-TilingModePath)) { $saved } else { "$saved (the default)" }
    $t = Get-ComponentTaskInfo -TaskName 'komorebi'
    if (-not $t) { return New-DoctorResult -Id 'tiling' -Status '..' -Text "Tiling mode: $mode -- komorebi has no task yet" }
    $taskMode = if ($t.RunLevel -eq 'HighestAvailable') { 'elevated' } else { 'normal' }
    if ($taskMode -ne $saved) {
        return New-DoctorResult -Id 'tiling' -Status 'XX' -Text "Tiling mode: $saved is saved, but komorebi's task runs $(if ($taskMode -eq 'elevated') { 'elevated' } else { 'non-elevated' })" `
            -Fix "710sRice tiling $saved" -Repair "tiling:$saved"
    }
    $running = Get-ProcessElevation -Name 'komorebi'
    if ($running -notin 'elevated', 'normal') {
        return New-DoctorResult -Id 'tiling' -Status 'OK' -Text "Tiling mode: $mode -- komorebi's task agrees ($(if ($running -eq 'not running') { "komorebi isn't running" } else { "couldn't read the running komorebi" }))"
    }
    if ($running -ne $taskMode) {
        return New-DoctorResult -Id 'tiling' -Status '!!' -Text "Tiling mode: $saved -- but the running komorebi $(if ($running -eq 'elevated') { 'is elevated' } else { "isn't" }) (it started before the change)" `
            -Fix '710sRice restart'
    }
    New-DoctorResult -Id 'tiling' -Status 'OK' -Text "Tiling mode: $mode -- komorebi's task and the running komorebi agree"
}
