#Requires -Version 7.0
<#
.SYNOPSIS
  Idempotent installer for 710.DesktopRice.

.DESCRIPTION
  - Installs what versions.md lists (its table is the one list -- tools\lib\versions.ps1
    reads it). Rows with a version number (komorebi, YASB, AutoHotkey, Flow Launcher,
    Everything, wallust) are installed at that version, and the winget ones winget-pinned so
    a general `winget upgrade --all` elsewhere on the machine can't silently move them out
    from under this repo's tested config; one already installed below its pin is brought up
    to it (never down). `latest` rows install unpinned. Every winget call names its source
    (`--source winget`, or `msstore` for PowerShell 7).
  - Registers KOMOREBI_CONFIG_HOME / YASB_CONFIG_HOME / DESKTOPRICE_HOME (User scope)
    pointing at this repo, and mirrors them into the current process so the rest of this
    run sees them too. DESKTOPRICE_HOME (the repo root) is what config\yasb\config.yaml's
    own paths are built from ($env:DESKTOPRICE_HOME), so the repo can live anywhere.
  - Puts <repo>\bin on the user PATH (bin\710sRice.cmd, the `710sRice` command) --
    written raw as REG_EXPAND_SZ so the user's other %VAR% PATH entries keep expanding
    (Add-UserPathEntry in tools\lib\userenv.ps1). Works in this window at once, and in
    any PS7 window opened after the run.
  - Installs wallust (tools/install-wallust.ps1) if it's missing or behind its pin.
  - Refreshes this machine's real monitor identity in
    config/komorebi/display-index.local.json (gitignored, machine-local) via
    tools/write-display-index.ps1 -- only possible while komorebi is running. On a fresh
    install it isn't yet, and scripts/Start-Komorebi.ps1 writes the file itself the first
    time komorebi starts (see tools/compile-komorebi-rules.ps1 for why it can never be a
    tracked file).
  - Sets up Flow Launcher (tools/components/flow.ps1): its search keywords and identity
    toggles, and its own "start on system startup" switched off -- 710.ahk starts it (at
    sign-in on a full-time machine, with `710sRice start` on an on-demand one). A Flow that has
    never run is started once first, as you, so it creates its settings -- one install sets it
    up.
  - Regenerates config/komorebi/komorebi.json (tools/compile-komorebi-rules.ps1) so a
    fresh clone or a pin bump lands in a ready-to-use compiled config.
  - Safe to re-run: only touches what's missing or behind its pin. `git pull` then
    `.\install.ps1` is this repo's update mechanism -- there's no separate "check for
    updates" feature by design (see claude/winarchy-decoupling-plan.md).

  STEPS. Each of the above is a named step, always run in this order:
    packages  upgrade  envvars  path  wallust  theme  palette  monitors
    profile  compile  tasks  windows
  plus one step per component (tools\components\<id>.ps1, named by its Id), each right after
  the step it names (Group 1 #12; `710sRice install -?` lists the whole order): flow right
  after wallust, defender after monitors, terminal after profile, and the others.
  A plain run does every step but upgrade and palette (windows only with -Activate) -- the
  same run as always, default wallpaper and theme included. Its packages step brings a pinned
  package that's below its versions.md pin up to it, and never moves one down or touches an
  unpinned one (Group 1 W7). Those two only run when named: upgrade does the same move for
  what the local version probes read (doctor's fix for "older than its pin"); palette
  re-applies the CURRENT wallpaper's colours (no wallpaper change). A package that doesn't
  install leaves the run going: the closing lines list it, and the run exits 1 (W2).
  -Only <step>[,<step>...] runs just those, in the
  same order, in whatever mode the machine is already in (a full-time machine's tasks stay
  sign-in tasks; windows does nothing on an on-demand machine); it takes no other switch
  and starts nothing afterwards. `710sRice doctor` names the step that fixes what it
  finds, and doctor -repair runs those steps -- never theme, the default-wallpaper reset.
  (claude/cli-plan.md, Stage 2.)

.NOTES
  Windows Defender exclusions, the pwsh $PROFILE hook, and Flow Launcher's setup are
  applied unconditionally on every run (matching winarchy's own install.ps1 @
  4574fc7, tag v1.4.0 -- none of these are gated behind -Activate upstream either).

  -Activate registers autostart (Scheduled Tasks At-LogOn: komorebi and AHK -- 710.ahk starts
  YASB, Flow Launcher and ShareX as it loads; their own tasks, until 2026-10-06, are removed),
  hides the native taskbar, applies HKCU-only Windows hardening (no Bing
  search / ad suggestions / Copilot-Widgets-TaskView buttons / Start recommendations),
  zeroes Explorer's Startup app-launch delay, and starts everything right away. Without
  -Activate, none of that happens -- packages, config, theming, Defender exclusions, the
  profile hook and Flow's setup are still applied, but nothing autostarts and the
  taskbar/hardening/Startup-delay registry settings are left alone. komorebi and AHK still
  get their Scheduled Tasks, just with no sign-in trigger, so `710sRice start` (the closing
  lines of a run say so) starts the stack on demand the same way sign-in would.

  Switching an installed machine, without this whole run (its theme step puts the default
  wallpaper back every time): `710sRice activate` / `710sRice deactivate`. A -Activate run
  on a machine that isn't full-time yet is that same switch, by the same rules: it saves your
  Windows settings before changing them (deactivate and uninstall put them back), and stops a
  running stack before its windows step, starting it again at the end. A plain re-run never
  changes the mode; the closing lines say which it is and the command that switches it.

  KOMOREBI_CONFIG_HOME is a single shared User-scope environment variable that winarchy's
  own startup path also reads and never resets -- if winarchy is still installed on this
  machine, whichever installer set it last wins for every *new* terminal/process opened
  after that (an existing PowerShell session keeps whatever value it already loaded; see
  the PATH-refresh note below for why that matters even within this very script). Not
  resolved further than "last write wins" here; worth real thought if winarchy and this
  repo need to coexist on one machine for a long stretch. Until winarchy is uninstalled
  from a machine (see plan doc, build sequence item 17), re-run .\install.ps1 after any
  winarchy update/reinstall to reclaim this variable.

  PATH refresh: a component winget just installed in *this* run (e.g. komorebi, on a
  first-ever install) won't be found by Get-Command in *this* process until PATH is
  re-read from the registry -- `setx`/winget only affect newly opened processes, a lesson
  this project already paid for once (see plan doc's KOMOREBI_CONFIG_HOME section). This
  script re-reads Machine+User PATH into $env:Path after the package loop so later steps
  can find just-installed exes without requiring a second run.

  Elevated tiling (plan doc Open item 37): by default komorebi's task runs elevated
  (HighestAvailable), so admin windows tile like everything else -- only komorebi; AHK
  runs with UI Access instead and nothing it launches is elevated. -NoElevatedTiling opts
  out (komorebi non-elevated, admin windows float); -ElevatedTiling opts back in. The
  choice is remembered per machine (%LOCALAPPDATA%\710.DesktopRice\tiling-mode.txt) and
  only changes when one of those switches is passed; uninstall forgets it. Registering
  an elevated task needs an admin shell. An install without -Activate registers every
  component's task with no sign-in trigger, so Start-All.ps1 starts them the same way.
  Security trade-off: see the README.

.EXAMPLE
  .\install.ps1                # install/update everything this repo owns
  .\install.ps1 -Activate      # ...and full-time: autostart + hide taskbar + harden + start now
  .\install.ps1 -SkipPackages  # skip the winget loop; still does env vars / wallust /
                                # display-index / Flow setup / recompile
  .\install.ps1 -NoElevatedTiling   # komorebi non-elevated from now on (remembered)
  .\install.ps1 -ElevatedTiling     # back to the default: komorebi elevated (remembered)
  .\install.ps1 -Only path          # just put the 710sRice command back on PATH
  .\install.ps1 -Only tasks,flow    # re-register the tasks, redo Flow's settings
#>
[CmdletBinding()]
param(
    [switch]$Activate,
    [switch]$SkipPackages,
    [switch]$ElevatedTiling,
    [switch]$NoElevatedTiling,
    [string[]]$Only
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# Before anything else, so a contradictory command line changes nothing at all.
if ($ElevatedTiling -and $NoElevatedTiling) {
    Write-Host "  [XX] -ElevatedTiling and -NoElevatedTiling contradict each other -- pick one. Nothing was changed." -ForegroundColor Red
    exit 1
}

# --- The steps -------------------------------------------------------------------------
# Every step, in the one order they ever run in (see STEPS above), and the two only -Only
# runs -- from tools\lib\steps.ps1, the one list install, `710sRice install -?` and doctor's
# repair plan all read. The steps are in $Steps, below (their bodies in tools\steps\); this part
# only decides which run -- before anything is touched, so a bad command line changes nothing.
. (Join-Path $Root 'tools\lib\steps.ps1')
# Install's fixed steps plus one step per component (tools\components\<id>.ps1, Group 1 #12),
# each right after its After step. A broken component file stops the run here, before anything.
try {
    $StepOrder      = @(Get-InstallStepOrder)
    $NamedOnlySteps = @(Get-InstallNamedOnlySteps)
    $Components     = @{}
    foreach ($c in @(Get-RiceComponents)) { $Components[$c.Id] = $c }
} catch {
    Write-Host "  [XX] $($_.Exception.Message) -- nothing was changed." -ForegroundColor Red
    exit 1
}
$OnlyRun = $PSBoundParameters.ContainsKey('Only')
if ($OnlyRun) {
    # Through the 710sRice shim or its admin relaunch, `-Only path,envvars` arrives as ONE
    # string (both go through pwsh -File) -- same as uninstall's -Keep. Split it here.
    $wanted = @($Only | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    $unknown = @($wanted | Where-Object { $StepOrder -notcontains $_ } | Select-Object -Unique)
    if ($Activate -or $SkipPackages -or $ElevatedTiling -or $NoElevatedTiling) {
        # -Only fixes steps in the mode the machine is already in; changing modes is
        # `710sRice activate` / `deactivate` (or `710sRice tiling elevated|normal`).
        Write-Host "  [XX] -Only runs single steps and takes no other switches -- nothing was changed." -ForegroundColor Red
        exit 1
    }
    if ($wanted.Count -eq 0 -or $unknown.Count -gt 0) {
        $what = if ($unknown.Count) { "Unknown step$(if ($unknown.Count -gt 1) { 's' }): $($unknown -join ', ')" } else { '-Only needs at least one step' }
        Write-Host "  [XX] $what -- the steps are: $($StepOrder -join ', '). Nothing was changed." -ForegroundColor Red
        exit 1
    }
    $RunSteps = @($StepOrder | Where-Object { $wanted -contains $_ })
} else {
    # A plain run: every step but the named-only ones, and windows only with -Activate -- a
    # plain re-run has never touched the taskbar or hardening. (-SkipPackages is the packages
    # step's own business.)
    $RunSteps = @($StepOrder | Where-Object { $NamedOnlySteps -notcontains $_ -and ($_ -ne 'windows' -or $Activate) })
}

function Step-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Step-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Step-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

# The libraries and the steps' modules (tools\lib\activation.ps1 loads them all), shared with
# uninstall.ps1's matching revert steps. Step-Ok/Info/Warn above must be defined before this
# dot-source -- the libraries use ours rather than their own copies.
. (Join-Path $Root 'tools\lib\activation.ps1')

Write-Host "`n== 710.DesktopRice install ==" -ForegroundColor Cyan
if ($OnlyRun) { Step-Info "Running only: $($RunSteps -join ', ')" }

# The machine's mode before this run changes anything -- read here, before the steps, since
# the tasks step registers the sign-in tasks part-way through a -Activate run. A -Activate run on a
# machine that isn't full-time yet switches it, by `710sRice activate`'s rules: your Windows
# settings saved first, right here, before any step (no copy, no switch: a plain run, failed at
# its end); the stack stopped before the windows step changes them, started again at the end.
$WasFullTime = try { [bool](Test-FullTimeMachine) } catch { $false }
$StackRestarted = $NotSwitched = $false
if ($Activate -and -not $WasFullTime -and -not (Save-FullTimeSettingsOnActivate)) { $NotSwitched = $true; $Activate = $false; $RunSteps = @($RunSteps | Where-Object { $_ -ne 'windows' }) }

$Steps = [ordered]@{}

# What didn't install (Group 1 W2): a winget install that failed, a pinned package left below
# its pin, a PowerShell module (PSFzf, DisplayConfig), wallust. The run still finishes every
# step; the closing lines list these and the run exits 1. "Core" = every versions.md row --
# doctor's own rule (a missing package is its [XX]), so install's exit code and doctor's
# verdict can't disagree (provisional, the user's call 2026-09-30: open for discussion if it
# ever gets in the way). Restart-required and already-installed count as installed.
$NotInstalled = [System.Collections.Generic.List[string]]::new()

# The fixed steps: each one's body is in its module, tools\steps\<step>.ps1 (packages and upgrade
# share packages.ps1, theme and palette theme.ps1), and gets what it needs of this run.
$Steps['packages'] = { Install-PackagesStep -SkipPackages $SkipPackages -NotInstalled $NotInstalled }
$Steps['upgrade']  = { Install-UpgradeStep -NotInstalled $NotInstalled }
$Steps['envvars']  = { Install-EnvVarsStep }
$Steps['path']     = { Install-PathStep }
$Steps['wallust']  = { Install-WallustStep -NotInstalled $NotInstalled }
$Steps['theme']    = { Install-ThemeStep -OnlyRun $OnlyRun }
$Steps['palette']  = { Install-PaletteStep }
$Steps['monitors'] = { Install-MonitorsStep }
$Steps['profile']  = { Install-ProfileStep }
$Steps['compile']  = { Install-CompileStep }
$Steps['tasks']    = { Install-TasksStep -Activate $Activate -OnlyRun $OnlyRun -ElevatedTiling $ElevatedTiling -NoElevatedTiling $NoElevatedTiling }

$Steps['windows'] = {
    # --- 11b. Windows settings: taskbar, hardening, Startup delay (full-time machines) ---
    # (tools\lib\fulltime.ps1). It says when it stopped the stack: the start-now block below
    # starts it again.
    if (Install-FullTimeWindowsSettings -OnlyRun $OnlyRun -Activate $Activate -WasFullTime $WasFullTime) { $StackRestarted = $true }
}

function Invoke-ComponentStep {
    # A component's step (tools\components\<id>.ps1): its section header, then its Install with
    # the run's $Ctx -- the machine's mode is -Activate's answer, else Test-FullTimeMachine, read
    # once per run (the tasks step keeps that mode, so it's the same before and after it). A
    # component that throws is that component's line, never the end of the install.
    param($Component)
    Write-Host "`n-- $($Component.Label) --" -ForegroundColor Cyan
    if (-not $Component.Install) { Step-Info "$($Component.Label): nothing to install"; return }
    if ($null -eq $script:ComponentFullTime) {
        $script:ComponentFullTime = if ($Activate) { $true } else { try { [bool](Test-FullTimeMachine) } catch { $false } }
    }
    $ctx = New-RiceComponentContext -OnlyRun $OnlyRun -FullTime $script:ComponentFullTime
    try { Invoke-RiceComponentPart -Component $Component -Part Install -Ctx $ctx }
    catch { Write-Host "  [XX] $($Component.Label): $($_.Exception.Message)" -ForegroundColor Red }
}
$script:ComponentFullTime = $null

# --- Run the steps ---------------------------------------------------------------------
# Dot-sourced, so every step runs in this script's own scope -- exactly as the sections
# did before they were steps (the theme step still sees what the wallust step set up). A
# component's step is its Install (Invoke-ComponentStep).
foreach ($step in $RunSteps) {
    if ($Components.ContainsKey($step)) { Invoke-ComponentStep $Components[$step] }
    else { . $Steps[$step] }
}

# --- Start now (a full install -Activate only) -------------------------------------------
# Through komorebi's and 710.ahk's own tasks, never from this elevated shell -- 710.ahk starts the
# bar, Flow and ShareX (Start-StackFromTasks in tools\lib\stack.ps1 -- `710sRice activate`
# starts the stack the same way).
if ($Activate -and -not $OnlyRun) {
    Start-StackFromTasks
    if ($StackRestarted) {
        Step-Info 'Chrome, the Claude app and other Chromium apps can pick up an extra title bar when the bar restarts -- focus the app and press SUPER+Ctrl+C to redraw it.'
    }
}

# --- Done -----------------------------------------------------------------------------
if ($OnlyRun) {
    Write-Host "`n== Done: $($RunSteps -join ', ') ==" -ForegroundColor Cyan
} else {
    Write-Host "`n== Install complete ==" -ForegroundColor Cyan
    # Which way this machine runs now, and the command that switches it -- the same lines
    # `710sRice activate` / `deactivate` end with.
    Write-RiceModeLines
}
# A -Activate that couldn't switch, or something that didn't install (W2): say what, fail the run.
if ($NotSwitched) { Write-FullTimeNotSwitched; if (-not $NotInstalled.Count) { exit 1 } }
if ($NotInstalled.Count) {
    Write-Host ''
    Write-Host "  [XX] Not installed: $($NotInstalled -join ', ') -- 710sRice doctor shows what's missing; 710sRice doctor -repair tries again" -ForegroundColor Red
    exit 1
}
