<#
.SYNOPSIS
  The tiling mode: komorebi elevated (the default -- admin windows tile too) or not. Chosen by
  install's switches (-ElevatedTiling / -NoElevatedTiling) or `710sRice tiling`, remembered per
  machine, read when komorebi's task is registered (Get-KomorebiRunLevel, tools\steps\tasks.ps1);
  doctor's tiling line; `710sRice tiling` itself (its rows, and repair's `tiling <mode>`: they use
  the dispatcher's own Write-RiceError and $script:RiceExit). Loaded by tools\lib\activation.ps1.
  Only functions.
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
        return New-DoctorResult -Id 'tiling' -Status 'XX' -Text "Tiling mode: $saved -- but the running komorebi $(if ($running -eq 'elevated') { 'is elevated' } else { "isn't" }) (it started before the change)" `
            -Fix '710sRice restart' -Repair 'restart'
    }
    New-DoctorResult -Id 'tiling' -Status 'OK' -Text "Tiling mode: $mode -- komorebi's task and the running komorebi agree"
}

# --- 710sRice tiling: status, elevated, normal (the dispatcher's rows; repair's `tiling <mode>`) ---
function Get-RiceLevelText { param($Level) if ($Level -eq 'HighestAvailable' -or $Level -eq 'elevated') { 'elevated' } else { 'not elevated' } }

function Show-RiceTilingStatus {
    # Three answers that can disagree: what's saved, what komorebi's task will start it as,
    # and what's running now. The saved mode only reaches the task through install or
    # `tiling elevated|normal`, and the task only reaches komorebi at its next start.
    $saved   = Get-TilingMode
    $isSaved = Test-Path -LiteralPath (Get-TilingModePath)
    $task    = Get-ComponentTaskInfo -TaskName 'komorebi'
    $running = Get-ProcessElevation -Name 'komorebi'
    $taskText = if (-not $task) { 'none -- run `710sRice install` first' }
                else { "$(Get-RiceLevelText $task.RunLevel), $(if ($task.AtLogOn) { 'starts at sign-in' } else { 'on demand (no sign-in start)' })" }
    $runText  = switch ($running) {
        'elevated'    { 'elevated' }
        'normal'      { 'not elevated' }
        'not running' { 'not running' }
        default       { "couldn't tell" }
    }
    Write-Host ''
    Write-Host ('    {0,-20}{1}' -f 'Tiling mode:', "$saved$(if (-not $isSaved) { ' (the default)' })")
    Write-Host ('    {0,-20}{1}' -f "komorebi's task:", $taskText)
    Write-Host ('    {0,-20}{1}' -f 'Running komorebi:', $runText)
    Write-Host ''
    if ($task -and (Get-RiceLevelText $task.RunLevel) -ne (Get-RiceLevelText $saved)) {
        Step-Warn "komorebi's task doesn't match the saved mode -- ``710sRice tiling $saved`` re-registers it."
    } elseif ($task -and $running -in 'elevated', 'normal' -and (Get-RiceLevelText $running) -ne (Get-RiceLevelText $task.RunLevel)) {
        Step-Info 'Takes effect at komorebi''s next start: `710sRice restart` (or sign out and in).'
    }
}

function Set-RiceTilingMode {
    # `tiling elevated|normal` (already admin by now): save the mode, then re-register ONLY
    # komorebi's task, in the kind it already is -- sign-in (an -Activate'd machine) or on
    # demand. Same mode as before: say so and re-register anyway, which also repairs a task
    # that drifted from the saved mode. A running komorebi is left alone.
    param([ValidateSet('elevated', 'normal')][string]$Mode)
    $task = Get-ComponentTaskInfo -TaskName 'komorebi'
    if (-not $task) { throw 'komorebi has no scheduled task yet -- run `710sRice install` first. Nothing was changed.' }
    $before = Get-TilingMode
    $null = Resolve-TilingMode -Elevated:($Mode -eq 'elevated') -Normal:($Mode -eq 'normal')
    if ($before -eq $Mode) { Step-Info "Tiling mode is already $Mode -- re-registering komorebi's task to match anyway." }
    else { Step-Ok "Tiling mode: $before -> $Mode" }
    if ($task.AtLogOn) { Register-Autostart -Key 'komorebi' } else { Register-OnDemandTasks -Key 'komorebi' }
    $after = Get-ComponentTaskInfo -TaskName 'komorebi'
    if (-not $after -or (Get-RiceLevelText $after.RunLevel) -ne (Get-RiceLevelText $Mode)) {
        Write-RiceError "komorebi's task still isn't $Mode (see above). The saved mode is $Mode now, so ``710sRice tiling $Mode`` again retries just the task."
        $script:RiceExit = 1
        return
    }
    $running = Get-ProcessElevation -Name 'komorebi'
    if ($running -in 'elevated', 'normal' -and (Get-RiceLevelText $running) -ne (Get-RiceLevelText $Mode)) {
        Step-Info "komorebi is still running $(if ($running -eq 'elevated') { 'elevated' } else { 'non-elevated' }) -- the new mode takes effect at its next start: ``710sRice restart`` (or sign out and in)."
    }
}
