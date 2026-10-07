#Requires -Version 7.0
<#
.SYNOPSIS
  Idempotent installer for 710.DesktopRice.

.DESCRIPTION
  - Installs what versions.md lists (its table is the one list -- tools\lib\packages.ps1
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
# repair plan all read. The step bodies are further down, in $Steps; this part only decides
# which of them run -- before anything is touched, so a bad command line changes nothing.
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

# Hardening, taskbar, autostart and the shell-profile hook live here or in the libraries it
# loads, shared with uninstall.ps1's matching revert steps. Step-Ok/Info/Warn above must be
# defined before this dot-source -- activation.ps1 uses ours rather than its own copies.
. (Join-Path $Root 'tools\lib\activation.ps1')
# versions.md's table and the winget helpers (after activation.ps1 -- see its header).
. (Join-Path $Root 'tools\lib\packages.ps1')

Write-Host "`n== 710.DesktopRice install ==" -ForegroundColor Cyan
if ($OnlyRun) { Step-Info "Running only: $($RunSteps -join ', ')" }

# The wallust binary: installed by the wallust step, used by the theme step -- which can
# run without it (-Only theme), so it's found here rather than in either.
$wallustExe = Join-Path $Root 'tools\bin\wallust\wallust.exe'

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

$Steps['packages'] = {
    # --- 1. Packages (winget) -----------------------------------------------------------
    # versions.md is the one list of what's installed and at which version (read through
    # tools\lib\packages.ps1; nothing here keeps a copy). A row with a version number is a
    # pin: installed at exactly that version and winget-pinned, so a general
    # `winget upgrade --all` elsewhere on the machine can't move it out from under this
    # repo's tested config. A `latest` row is installed unpinned and takes its own updates
    # (PowerShell 7 among them -- every script here only needs >= 7.0, and no scheduled task
    # names a pwsh path: they start Windows PowerShell, whose path never moves, and whatever
    # needs PS7 looks it up when it runs). Source `msstore`
    # = winget from the Store source (PowerShell 7's Store/MSIX build -- see versions.md).
    # The github-release row (wallust) is the wallust step's; psgallery rows are below.
    $versionRows = @(Get-VersionsTable -Path (Join-Path $Root 'versions.md'))
    $wingetRows  = @($versionRows | Where-Object { Test-WingetRow $_ })

    if (-not $SkipPackages) {
        Write-Host "`n-- Packages (winget) --" -ForegroundColor Cyan
        if ($wingetRows.Count -eq 0) {
            # Never guess what to install -- uninstall refuses the same way.
            Write-Host "  [XX] versions.md has no package table -- nothing installed" -ForegroundColor Red
            $NotInstalled.Add("every package (versions.md has no package table)")
        }

        # Some installers drop a Desktop shortcut (Flow Launcher and ShareX -- seen on the
        # 2026-09-24 reinstall test; Flow's installer has no option to skip it). Note which
        # shortcuts are on the Desktop (yours and the shared Public one) before installing,
        # and afterwards remove only the ones that appeared in between -- any you already had,
        # even for these same apps, are left alone. Uninstall needs nothing: both
        # uninstallers remove their own shortcut.
        $desktopDirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        function Get-DesktopShortcuts {
            foreach ($dir in $desktopDirs) {
                Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object FullName
            }
        }
        $shortcutsBefore = @(Get-DesktopShortcuts)

        foreach ($row in $wingetRows) {
            $id = $row.InstallId
            $pinVersion = if (Test-PinnedRow $row) { $row.Version } else { $null }
            # Every call names its source (Get-WingetSourceArgs): winget's own for winget rows,
            # the Store for PowerShell 7's msstore row -- never both (W1).
            $sourceArgs = @(Get-WingetSourceArgs $row)
            $listArgs = @('list', '--id', $id, '--exact', '--accept-source-agreements') + $sourceArgs
            $listed = @(winget @listArgs 2>$null)
            $alreadyInstalled = ($listed | Out-String) -match [regex]::Escape($id)
            if ($alreadyInstalled) {
                # A pinned package below its pin goes up to it (W7; user, 2026-09-30: "install
                # should always update pinned packages to pin, that's what the pin is for") --
                # never down: newer than the pin is left alone, doctor's [!!] and your call. The
                # version is the one this same `winget list` shows (the token after the ID), so
                # an AutoHotkey 1.1 that winget lists is moved to 2.0.28 instead of pinned at 1.1.
                $have = Get-WingetListedVersion -Lines $listed -Id $id
                $cmp  = if ($pinVersion -and $have) { Compare-PinVersion $have $pinVersion } else { $null }
                if ($cmp -eq -1) {
                    if (-not (Invoke-MoveToPin -Row $row -From $have)) { $NotInstalled.Add("$($row.Component) (still $have, not its pin $pinVersion)") }
                } elseif ($cmp -eq 1) {
                    Step-Ok "$id already installed ($have -- newer than its pin $pinVersion, left alone)"
                } else {
                    Step-Ok "$id already installed"
                }
            } else {
                $wingetArgs = @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
                if ($pinVersion) { $wingetArgs += @('--version', $pinVersion) }
                $wingetArgs += $sourceArgs
                $how = ''
                if ($PerUserPackages -contains $id -and (Test-IsAdmin)) {
                    # Installed for you only (Flow, into %LOCALAPPDATA%), so installed un-elevated --
                    # the one-shot task uninstall and the upgrade step already use for it. Run from
                    # this admin window, its own setup first re-launches itself un-elevated through
                    # Explorer, and on the Dell that hand-off crashed (final test T7, 2026-10-01:
                    # Flow-Launcher-Setup.exe c0000005, 0.6 s in, after two Explorer restarts --
                    # Squirrel's Setup uses Explorer's shell-windows object without checking it got one).
                    Step-Info "Installing $id (installed for you only -- un-elevated; a winget window shows briefly) ..."
                    $how = ' (un-elevated)'
                    try { $code = Invoke-WingetAsUser -Arguments ($wingetArgs + '--disable-interactivity') -TimeoutSeconds 600 }
                    catch {
                        Step-Warn "$($_.Exception.Message) -- installing it from this window instead"
                        $how = ''
                        winget @wingetArgs
                        $code = $LASTEXITCODE
                    }
                } else {
                    Step-Info "Installing $id ..."
                    winget @wingetArgs
                    $code = $LASTEXITCODE
                }
                # Restart-required and already-there are installed too (W2, winarchy c5053b9);
                # anything else is a package that didn't install -- the run finishes every step
                # and then says so and exits 1.
                switch (Get-WingetOutcome $code) {
                    'ok'      { Step-Ok "$id installed$how" }
                    'restart' { Step-Warn "$id installed$how -- restart Windows to finish its setup" }
                    'timeout' {
                        Write-Host "  [XX] $($id): the un-elevated install was still running after 10 minutes -- 'winget list --id $id' once it's done; 710sRice doctor -repair tries again" -ForegroundColor Red
                        $NotInstalled.Add($row.Component)
                    }
                    default {
                        $where = if ($how) { "winget ran in its own window -- 'winget install --id $id' from a normal PowerShell window shows why" } else { 'check the output above' }
                        Write-Host "  [XX] $($id): winget install exited $(Format-WingetCode $code)$how -- $where" -ForegroundColor Red
                        $NotInstalled.Add($row.Component)
                    }
                }
            }
            if ($pinVersion) {
                $pinArgs = @('pin', 'add', '--id', $id, '--exact') + $sourceArgs
                winget @pinArgs 2>$null | Out-Null
            }
        }

        $newShortcuts = @(Get-DesktopShortcuts | Where-Object { $shortcutsBefore -notcontains $_ })
        $removed = @(foreach ($lnk in $newShortcuts) {
            try { Remove-Item -LiteralPath $lnk -Force; Split-Path $lnk -Leaf }
            catch { Step-Warn "Couldn't remove the desktop shortcut $(ConvertTo-SafePath $lnk): $($_.Exception.Message)" }
        })
        if ($removed.Count -gt 0) { Step-Ok "Removed the desktop shortcut(s) the installers added: $($removed -join ', ')" }

        # Re-read PATH from the registry into this process. Without this, a component that
        # was just installed for the first time above (e.g. komorebi) won't be found by
        # Get-Command until a new terminal is opened -- see NOTES.
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')

        # PowerShell modules (PSGallery rows -- PSFzf: the PowerShell-side fzf
        # keybindings/integration, separate from the junegunn.fzf winget package above,
        # which is just the fzf binary; DisplayConfig: the Screens menu's, tools\screens.ps1).
        # No pin, always latest, matching this project's own
        # decided practice (winarchy never pinned it either).
        foreach ($row in @($versionRows | Where-Object { $_.Source -eq 'psgallery' })) {
            $module = $row.InstallId
            Write-Host "`n-- $module (PowerShell module) --" -ForegroundColor Cyan
            if (Get-Module -ListAvailable $module) {
                Step-Ok "$module already installed"
            } else {
                Step-Info "Installing $module (PSGallery) ..."
                try {
                    Install-Module $module -Scope CurrentUser -Force -ErrorAction Stop
                    Step-Ok "$module installed"
                } catch {
                    Write-Host "  [XX] Could not install $($module): $($_.Exception.Message)" -ForegroundColor Red
                    $NotInstalled.Add($row.Component)
                }
            }
        }
    } else {
        Step-Info "Skipping package installation (-SkipPackages)"
    }
}

$Steps['upgrade'] = {
    # --- upgrade: pinned packages older than their pin, to the pin (named-only) ----------
    # Pinned winget rows only (a version number in versions.md): `latest` rows are unpinned
    # so a normal `winget upgrade --all` moves them; wallust is the wallust step's job.
    # Installed versions come from the local probes in tools\lib\packages.ps1 (doctor reads
    # the same ones). Newer than the pin = left alone (the user's call -- e.g. a hand upgrade
    # being tried before versions.md is bumped); older = stop the app, pin remove -> winget
    # upgrade --version <pin> -> pin add, check, start it again if it was running -- komorebi
    # and 710.ahk through their tasks, the bar and Flow by asking 710.ahk (Invoke-MoveToPin).
    Write-Host "`n-- Upgrade pinned packages --" -ForegroundColor Cyan
    $pinnedRows = @(@(Get-VersionsTable -Path (Join-Path $Root 'versions.md')) | Where-Object { (Test-WingetRow $_) -and (Test-PinnedRow $_) })
    if ($pinnedRows.Count -eq 0) {
        Write-Host "  [XX] versions.md has no pinned packages -- nothing to upgrade to" -ForegroundColor Red
    }
    foreach ($row in $pinnedRows) {
        $name   = $row.Component
        $before = Get-PackageVersion $row
        if (-not $before.Probe) { Step-Warn "$($name): no version probe for $($row.InstallId) yet -- left alone"; continue }
        if (-not $before.Installed) { Step-Info "$name isn't installed -- the packages step installs it (at its pin)"; continue }
        $cmp = Compare-PinVersion $before.Version $row.Version
        if ($null -eq $cmp) { Step-Warn "$($name): couldn't read its version ('$($before.Version)') -- left alone"; continue }
        if ($cmp -eq 0) { Step-Ok "$name $($before.Version) -- at its pin"; continue }
        if ($cmp -gt 0) { Step-Warn "$name $($before.Version) is newer than its pin $($row.Version) -- left alone"; continue }
        # The same routine the packages step runs for one below its pin (packages.ps1).
        if (-not (Invoke-MoveToPin -Row $row -From $before.Version)) { $NotInstalled.Add("$name (not at its pin $($row.Version))") }
    }
}

$Steps['envvars'] = {
    # --- 2. Config env vars: repo is the source of truth --------------------------------
    Write-Host "`n-- Config environment variables --" -ForegroundColor Cyan
    $komorebiConfigHome = Join-Path $Root 'config\komorebi'
    $yasbConfigHome     = Join-Path $Root 'config\yasb'
    [Environment]::SetEnvironmentVariable('KOMOREBI_CONFIG_HOME', $komorebiConfigHome, 'User')
    [Environment]::SetEnvironmentVariable('YASB_CONFIG_HOME', $yasbConfigHome, 'User')
    # The repo root. config\yasb\config.yaml builds every path it needs from this through
    # YASB's own $env: expansion (the wallpaper folder, the wallust/apply-outputs commands, the
    # home menu entry) instead of hard-coding C:\710.DesktopRice -- clone the repo anywhere.
    [Environment]::SetEnvironmentVariable('DESKTOPRICE_HOME', $Root, 'User')
    $env:KOMOREBI_CONFIG_HOME = $komorebiConfigHome
    $env:YASB_CONFIG_HOME     = $yasbConfigHome
    $env:DESKTOPRICE_HOME     = $Root
    # Shown as %USERPROFILE%\... when the clone lives under the user's folders (ConvertTo-SafePath).
    Step-Ok "KOMOREBI_CONFIG_HOME = $(ConvertTo-SafePath $komorebiConfigHome)"
    Step-Ok "YASB_CONFIG_HOME     = $(ConvertTo-SafePath $yasbConfigHome)"
    Step-Ok "DESKTOPRICE_HOME     = $(ConvertTo-SafePath $Root)"
    # The old weather widget's two variables (weatherapi.com's key and a location), unused since
    # the bar's weather moved to Open-Meteo (Group 1 #1: no account, no key -- the location is
    # picked in the widget). A key shouldn't sit in the environment, so they go. Names only.
    foreach ($name in 'YASB_WEATHER_API_KEY', 'YASB_WEATHER_LOCATION') {
        if (Get-UserEnvVar $name) {
            Remove-UserEnvVar $name
            Step-Ok "$name removed (the weather widget doesn't use it any more)"
        }
    }
}

$Steps['path'] = {
    # --- 2c. PATH: the 710sRice command --------------------------------------------------
    # bin\ holds one file, 710sRice.cmd -- a one-line shim that runs 710sRice.ps1 with pwsh -- so
    # `710sRice <command>` works from any PS7 window opened from now on. Add-UserPathEntry keeps
    # every other user PATH entry exactly as stored (%VARS% and all), appends ours, writes it back
    # as REG_EXPAND_SZ and tells Explorer; it also adds bin\ to this window. A failure here
    # only costs the shortcut, so it warns instead of stopping the install.
    Write-Host "`n-- 710sRice command --" -ForegroundColor Cyan
    $riceBin = Join-Path $Root 'bin'
    try {
        if (Add-UserPathEntry -Dir $riceBin) {
            Step-Ok "710sRice command: $(ConvertTo-SafePath $riceBin) added to your PATH (open a new PS7 window to use it)"
        } else {
            Step-Ok '710sRice command: already on your PATH'
        }
    } catch {
        Step-Warn "710sRice command: couldn't add $riceBin to your PATH -- $($_.Exception.Message)"
    }
}

$Steps['wallust'] = {
    # --- 3. wallust -----------------------------------------------------------------------
    Write-Host "`n-- wallust --" -ForegroundColor Cyan
    # The pin is versions.md's wallust row (github-release: no winget package exists).
    $wallustRow = @(Get-VersionsTable -Path (Join-Path $Root 'versions.md')) | Where-Object { $_.InstallId -like '*wallust*' } | Select-Object -First 1
    $WallustPinnedVersion = if ($wallustRow) { $wallustRow.Version } else { $null }
    $wallustUpToDate = $false
    if (-not $WallustPinnedVersion) {
        Step-Warn 'versions.md has no wallust row -- wallust not checked or installed.'
        $wallustUpToDate = $true   # nothing to install it at; the theme step says so if it's missing
    } elseif (Test-Path $wallustExe) {
        try {
            $verOut = & $wallustExe --version 2>$null | Out-String
            if ($verOut -match [regex]::Escape($WallustPinnedVersion)) { $wallustUpToDate = $true }
        } catch { }
    }
    if ($wallustUpToDate) {
        if ($WallustPinnedVersion) { Step-Ok "wallust $WallustPinnedVersion already installed" }
    } else {
        Step-Info "Installing wallust $WallustPinnedVersion ..."
        try {
            & (Join-Path $Root 'tools\install-wallust.ps1') -Version $WallustPinnedVersion
            Step-Ok "wallust installed"
        } catch {
            Write-Host "  [XX] wallust install failed: $($_.Exception.Message) -- the rest of the install carries on without it." -ForegroundColor Red
            $NotInstalled.Add('wallust')
        }
    }

    # wallust.toml is generated from a tracked template with this repo's real location filled
    # in (wallust's template targets must be absolute paths). Before section 4's `wallust run`.
    & (Join-Path $Root 'tools\write-wallust-config.ps1')
    if ($LASTEXITCODE -ne 0) { Step-Warn 'wallust.toml not written (see message above) -- wallpaper theming will fail until it is.' }
    else { Step-Ok 'wallust.toml current' }
}

$Steps['theme'] = {
    # --- 4. Default theme (wallpaper + everything themed from it) -------------------------
    # EVERY run, no "already themed?" check (user's call, 2026-09-23 -- the old check skipped
    # this whenever the current wallpaper came from assets\wallpapers, which could leave e.g.
    # Windows Terminal on whatever uninstall had restored it to). Sets
    # assets\wallpapers\710Default001.png as the desktop wallpaper and runs the exact same
    # wallpaper pipeline (tools\apply-wallust-outputs.ps1) YASB's Wallpapers widget runs on every
    # real wallpaper change (see config\yasb\config.yaml's run_after) -- so komorebi borders, the
    # Windows accent color, Windows Terminal and your lock-screen picture all end up themed to
    # it too, via the one real code path rather than a second, parallel "first theme"
    # implementation.
    Write-Host "`n-- Default theme --" -ForegroundColor Cyan
    $defaultWallpaper = Join-Path $Root 'assets\wallpapers\710Default001.png'

    if (-not (Test-Path $defaultWallpaper)) {
        Step-Warn "Default wallpaper not found at $(ConvertTo-SafePath $defaultWallpaper) -- skipping the default theme."
    } elseif (-not (Test-Path $wallustExe) -or -not (Test-Path (Join-Path $Root 'config\wallust\wallust.toml'))) {
        # The wallust step installs both; -Only theme on its own can find them missing.
        Step-Warn "wallust isn't set up (no wallust.exe or wallust.toml) -- skipping the default theme.$(if ($OnlyRun) { ' Add the wallust step: 710sRice install -Only wallust,theme' })"
    } else {
        try {
            # One-time snapshot of whatever wallpaper was here before -- Set-DesktopWallpaper
            # below is about to overwrite it, and uninstall.ps1's Restore-OriginalWallpaper
            # needs this to put the real original back, not just delete our own value (both in
            # tools\lib\wallpaper.ps1).
            Save-OriginalWallpaper
            Set-DesktopWallpaper -Path $defaultWallpaper
            Step-Ok "Desktop wallpaper set to $(ConvertTo-SafePath $defaultWallpaper)"

            # The wallpaper pipeline itself, in-process (install already needs PS7), with the
            # chosen palette profile -- Default on a fresh install. It prints what it themed
            # (komorebi only if it's up), the lock screen included.
            & (Join-Path $Root 'tools\apply-wallust-outputs.ps1') -Image $defaultWallpaper
            switch ($LASTEXITCODE) {
                0       { Step-Ok 'Default wallpaper themed (details above).' }
                2       { Step-Warn 'Default wallpaper themed, but not everything took (see above) -- 710sRice doctor says what.' }
                default { Step-Warn "The default wallpaper is up, but its theme wasn't applied (see above)." }
            }
        } catch {
            Step-Warn "Could not apply the default theme: $($_.Exception.Message)"
        }
    }
}

$Steps['palette'] = {
    # --- palette: the current wallpaper's colours, re-applied (named-only) ---------------
    # The opposite of theme: no wallpaper change. Runs exactly what YASB's wallpaper widget
    # runs after every change (the pipeline, config\yasb\config.yaml's run_after) on the
    # wallpaper that's up now (Get-CurrentWallpaper -- the value Set-LockScreen.ps1 reads).
    # Same image, same profile, same palette (wallust caches it per image), so on a healthy
    # machine nothing visibly changes -- it's the fix for missing or stale theme files (the
    # bar's and menus' colours, the prompt, Flow's theme, Terminal's scheme). It never falls
    # back to the default wallpaper: that's the theme step, the reset.
    Write-Host "`n-- Palette (current wallpaper) --" -ForegroundColor Cyan
    $currentWallpaper = Get-CurrentWallpaper
    if (-not $currentWallpaper -or -not (Test-Path -LiteralPath $currentWallpaper)) {
        Step-Warn "The current wallpaper ($(if ($currentWallpaper) { ConvertTo-SafePath $currentWallpaper } else { 'none set' })) is gone -- pick one with SUPER+W; that re-themes everything from it."
    } elseif (-not (Test-Path $wallustExe) -or -not (Test-Path (Join-Path $Root 'config\wallust\wallust.toml'))) {
        Step-Warn "wallust isn't set up (no wallust.exe or wallust.toml) -- add the wallust step: 710sRice install -Only wallust,palette"
    } else {
        try {
            & (Join-Path $Root 'tools\apply-wallust-outputs.ps1') -Image $currentWallpaper
            switch ($LASTEXITCODE) {
                0       { Step-Ok "Palette re-applied from the current wallpaper ($(Split-Path -Leaf $currentWallpaper)) -- details above." }
                2       { Step-Warn 'Palette re-applied, but not everything took (see above) -- 710sRice doctor says what.' }
                default { Step-Warn "Palette not re-applied (see above) -- the theme on screen is unchanged." }
            }
        } catch {
            Step-Warn "Could not re-apply the palette: $($_.Exception.Message)"
        }
    }
}

$Steps['monitors'] = {
    # --- 5. Monitor identity (display_index_preferences) ----------------------------------
    # komorebic can only report monitors while komorebi is running, so on a fresh install
    # (komorebi never started yet) this can't work -- scripts\Start-Komorebi.ps1 writes the
    # file itself the first time komorebi comes up and it's missing. Here it's a refresh:
    # re-running install.ps1 while komorebi is up picks up a monitor change.
    Write-Host "`n-- Monitor identity (display_index_preferences) --" -ForegroundColor Cyan
    try { & (Join-Path $Root 'tools\write-display-index.ps1') }
    catch { Write-Warning $_.Exception.Message; $global:LASTEXITCODE = 1 }
    switch ($LASTEXITCODE) {
        0       { Step-Ok 'Monitor order pinned (display-index.local.json)' }
        2       { Step-Info "komorebi isn't running yet -- it writes this itself the first time it starts." }
        default { Step-Warn "Monitor order not written (see above) -- komorebi.json will omit display_index_preferences; komorebi falls back to Windows' own monitor order." }
    }
}

$Steps['profile'] = {
    # --- 7. Shell profile hook ($PROFILE -> config\pwsh\profile.ps1) -------------------------
    # Also unconditional -- winarchy calls Install-WinarchyShellProfile in its own install.ps1
    # outside the -Activate block too. Idempotent; snapshots the previous $PROFILE to a .bak
    # alongside it before changing anything.
    # `$PROFILE literally: the hook line below names the real file (as %USERPROFILE%\...), and
    # an expanded $PROFILE printed both the user name and the wrong file -- the hook goes into
    # profile.ps1 (every host), not Microsoft.PowerShell_profile.ps1.
    Write-Host "`n-- Shell profile (`$PROFILE hook) --" -ForegroundColor Cyan
    Install-ShellProfile
}

$Steps['compile'] = {
    # --- 10. Recompile komorebi.json -----------------------------------------------------------
    Write-Host "`n-- Compiling komorebi.json --" -ForegroundColor Cyan
    & (Join-Path $Root 'tools\compile-komorebi-rules.ps1')
}

$Steps['tasks'] = {
    # --- 10b. Tiling mode (elevated komorebi or not) -------------------------------------------
    # Resolved (switch -> remembered -> default 'elevated') and remembered here; the task
    # registration just below reads it back through Get-KomorebiRunLevel.
    Write-Host "`n-- Tiling mode --" -ForegroundColor Cyan
    $tiling = Resolve-TilingMode -Elevated:$ElevatedTiling -Normal:$NoElevatedTiling
    $tilingWhy = switch ($tiling.Source) { 'switch' { 'set by this run' } 'remembered' { 'remembered from a previous install' } default { 'the default' } }
    if ($tiling.Mode -eq 'elevated') {
        Step-Ok "Elevated tiling ($tilingWhy): komorebi runs elevated, so admin windows tile too. Opt out with -NoElevatedTiling."
    } else {
        Step-Ok "Non-elevated tiling ($tilingWhy): admin windows float. Opt back in with -ElevatedTiling."
    }
    if ($tiling.Changed -and (Get-Process komorebi -ErrorAction SilentlyContinue)) {
        Step-Info 'komorebi is already running in the old mode -- the new one takes effect when it next starts: sign out and back in, or run `710sRice restart`.'
    }

    # --- 11a. Tasks: komorebi's and 710.ahk's, in the machine's mode -------------------------
    # (The bar's, Flow's and ShareX's old tasks go here too, whichever branch runs:
    # Register-Autostart / Register-OnDemandTasks call Remove-RetiredStartTasks. 710.ahk starts
    # those three now -- see config\ahk\710.ahk, "The apps 710.ahk starts".)
    if ($Activate) {
        Write-Host "`n-- Activate --" -ForegroundColor Cyan
        Register-Autostart
    } elseif (Test-FullTimeMachine) {
        # Already full-time from an earlier -Activate: re-register so the tasks pick up any
        # change to how components are launched (a newer launcher script, a moved clone),
        # without switching modes.
        Write-Host "`n-- Activate --" -ForegroundColor Cyan
        Step-Info 'Autostart is active: re-registering to pick up any startup changes...'
        Register-Autostart
    } else {
        # On-demand: komorebi and 710.ahk still get their tasks (no trigger), so Start-All.ps1
        # and SUPER+Shift+R start each one at its task's own level -- the same as -Activate,
        # from any window (Register-OnDemandTasks).
        # The closing lines say how to switch to full-time (`710sRice activate`).
        if (-not $OnlyRun) {
            Step-Info 'On demand: packages, config, theming, Defender, the profile hook and Flow are applied; nothing starts at sign-in, and the taskbar, hardening and Startup delay are left as they are.'
        }
        Register-OnDemandTasks
    }

    # --- 11c. The lock screen: the old sync retired, your picture set once when needed --------
    # (tools\lib\lockscreen.ps1; doctor's fix for the old sync is `-Only tasks`).
    Install-LockScreen
}

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
