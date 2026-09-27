#Requires -Version 7.0
<#
.SYNOPSIS
  Idempotent installer for 710.DesktopRice.

.DESCRIPTION
  - Installs what versions.md lists (its table is the one list -- tools\lib\packages.ps1
    reads it). Rows with a version number (komorebi, YASB, AutoHotkey, Flow Launcher,
    Everything, wallust) are installed at that version, and the winget ones winget-pinned so
    a general `winget upgrade --all` elsewhere on the machine can't silently move them out
    from under this repo's tested config. `latest` rows install unpinned.
  - Registers KOMOREBI_CONFIG_HOME / YASB_CONFIG_HOME / DESKTOPRICE_HOME (User scope)
    pointing at this repo, and mirrors them into the current process so the rest of this
    run sees them too. DESKTOPRICE_HOME (the repo root) is what config\yasb\config.yaml's
    own paths are built from ($env:DESKTOPRICE_HOME), so the repo can live anywhere.
  - Puts <repo>\bin on the user PATH (bin\710sRice.cmd, the `710sRice` command) --
    written raw as REG_EXPAND_SZ so the user's other %VAR% PATH entries keep expanding
    (Add-UserPathEntry in tools\lib\activation.ps1). Works in this window at once, and in
    any PS7 window opened after the run.
  - Installs wallust (tools/install-wallust.ps1) if it's missing or behind its pin.
  - Refreshes this machine's real monitor identity in
    config/komorebi/display-index.local.json (gitignored, machine-local) via
    tools/write-display-index.ps1 -- only possible while komorebi is running. On a fresh
    install it isn't yet, and scripts/Start-Komorebi.ps1 writes the file itself the first
    time komorebi starts (see tools/compile-komorebi-rules.ps1 for why it can never be a
    tracked file).
  - Runs tools/setup-flow-launcher.ps1 (only meaningful once Flow Launcher has been run at
    least once; that script warns and no-ops cleanly if it hasn't).
  - Regenerates config/komorebi/komorebi.json (tools/compile-komorebi-rules.ps1) so a
    fresh clone or a pin bump lands in a ready-to-use compiled config.
  - Safe to re-run: only touches what's missing or behind its pin. `git pull` then
    `.\install.ps1` is this repo's update mechanism -- there's no separate "check for
    updates" feature by design (see claude/winarchy-decoupling-plan.md).

  STEPS. Each of the above is a named step, always run in this order:
    packages  upgrade  envvars  weather  path  wallust  theme  palette  monitors
    defender  profile  terminal  flow  compile  tasks  windows
  A plain run does every step but upgrade and palette (windows only with -Activate) -- the
  same run as always, default wallpaper and theme included, and no installed package ever
  moved. Those two only run when named: upgrade moves a pinned package that's older than its
  versions.md pin up to it; palette re-applies the CURRENT wallpaper's colours (no
  wallpaper change). -Only <step>[,<step>...] runs just those, in the
  same order, in whatever mode the machine is already in (a full-time machine's tasks stay
  sign-in tasks; windows does nothing on an on-demand machine); it takes no other switch
  and starts nothing afterwards. `710sRice doctor` names the step that fixes what it
  finds, and doctor -repair runs those steps -- never theme, the default-wallpaper reset.
  (claude/cli-plan.md, Stage 2.)

.NOTES
  Windows Defender exclusions, the pwsh $PROFILE hook, and Flow Launcher's Everything
  plugin are applied unconditionally on every run (matching winarchy's own install.ps1 @
  4574fc7, tag v1.4.0 -- none of these are gated behind -Activate upstream either).

  -Activate registers autostart (Scheduled Tasks At-LogOn: komorebi, YASB, ShareX, AHK),
  hides the native taskbar, applies HKCU-only Windows hardening (no Bing
  search / ad suggestions / Copilot-Widgets-TaskView buttons / Start recommendations),
  zeroes Explorer's Startup app-launch delay, and starts everything right away. Without
  -Activate, none of that happens -- packages, config, theming, Defender exclusions, the
  profile hook and Everything plugin are still applied, but nothing autostarts and the
  taskbar/hardening/Startup-delay registry settings are left alone. Each component still
  gets its Scheduled Task, just with no sign-in trigger, so `710sRice start` (the closing
  lines of a run say so) starts the stack on demand the same way sign-in would.

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
  .\install.ps1 -Activate      # ...and autostart + hide taskbar + harden + start now
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
# Every step, in the one order they ever run in (see STEPS above). The step bodies are
# further down, in $Steps; this part only decides which of them run -- before anything is
# touched, so a bad command line changes nothing.
$StepOrder = @('packages', 'upgrade', 'envvars', 'weather', 'path', 'wallust', 'theme', 'palette',
               'monitors', 'defender', 'profile', 'terminal', 'flow', 'compile', 'tasks', 'windows')
# Steps a plain run never includes -- only -Only runs them. upgrade: install never moves an
# installed package unless asked (user, 2026-09-26: "upgrade must be named"). palette: a plain
# run's theme step already themes everything (from the default wallpaper).
$NamedOnlySteps = @('upgrade', 'palette')
$OnlyRun = $PSBoundParameters.ContainsKey('Only')
if ($OnlyRun) {
    # Through the 710sRice shim or its admin relaunch, `-Only path,envvars` arrives as ONE
    # string (both go through pwsh -File) -- same as uninstall's -Keep. Split it here.
    $wanted = @($Only | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    $unknown = @($wanted | Where-Object { $StepOrder -notcontains $_ } | Select-Object -Unique)
    if ($Activate -or $SkipPackages -or $ElevatedTiling -or $NoElevatedTiling) {
        # -Only fixes steps in the mode the machine is already in; changing modes is a plain
        # `install -Activate` or `710sRice tiling elevated|normal`.
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

# Defender exclusions, hardening, taskbar, autostart, and the shell-profile hook all live
# here, shared with uninstall.ps1's matching revert steps. Step-Ok/Info/Warn above must be
# defined before this dot-source -- activation.ps1 uses ours rather than its own copies.
. (Join-Path $Root 'tools\lib\activation.ps1')
# versions.md's table and the winget helpers (after activation.ps1 -- see its header).
. (Join-Path $Root 'tools\lib\packages.ps1')

Write-Host "`n== 710.DesktopRice install ==" -ForegroundColor Cyan
if ($OnlyRun) { Step-Info "Running only: $($RunSteps -join ', ')" }

# The wallust binary: installed by the wallust step, used by the theme step -- which can
# run without it (-Only theme), so it's found here rather than in either.
$wallustExe = Join-Path $Root 'tools\bin\wallust\wallust.exe'

$Steps = [ordered]@{}

$Steps['packages'] = {
    # --- 1. Packages (winget) -----------------------------------------------------------
    # versions.md is the one list of what's installed and at which version (read through
    # tools\lib\packages.ps1; nothing here keeps a copy). A row with a version number is a
    # pin: installed at exactly that version and winget-pinned, so a general
    # `winget upgrade --all` elsewhere on the machine can't move it out from under this
    # repo's tested config. A `latest` row is installed unpinned and takes its own updates
    # (PowerShell 7 among them -- every script here only needs >= 7.0, and the tasks launch
    # it through the version-independent WindowsApps alias, Get-PwshPath). Source `msstore`
    # = winget from the Store source (PowerShell 7's Store/MSIX build -- see versions.md).
    # The github-release row (wallust) is the wallust step's; psgallery rows are below.
    $versionRows = @(Get-VersionsTable -Path (Join-Path $Root 'versions.md'))
    $wingetRows  = @($versionRows | Where-Object { Test-WingetRow $_ })

    if (-not $SkipPackages) {
        Write-Host "`n-- Packages (winget) --" -ForegroundColor Cyan
        if ($wingetRows.Count -eq 0) {
            # Never guess what to install -- uninstall refuses the same way.
            Write-Host "  [XX] versions.md has no package table -- nothing installed" -ForegroundColor Red
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
            $sourceArgs = @(Get-WingetSourceArgs $row)
            $listArgs = @('list', '--id', $id, '--exact', '--accept-source-agreements') + $sourceArgs
            $listed = (winget @listArgs 2>$null) | Out-String
            $alreadyInstalled = $listed -match [regex]::Escape($id)
            if ($alreadyInstalled) {
                Step-Ok "$id already installed"
            } else {
                Step-Info "Installing $id ..."
                $wingetArgs = @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
                if ($pinVersion) { $wingetArgs += @('--version', $pinVersion) }
                $wingetArgs += $sourceArgs
                winget @wingetArgs
                if ($LASTEXITCODE -ne 0) {
                    Step-Warn "winget install $id exited with code $LASTEXITCODE -- check the output above."
                }
            }
            if ($pinVersion) {
                $pinArgs = @('pin', 'add', '--id', $id) + $sourceArgs
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
        # which is just the fzf binary). No pin, always latest, matching this project's own
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
                    Step-Warn "Could not install $($module): $($_.Exception.Message)"
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
    # upgrade --version <pin> -> pin add, check, restart it through its task if it was
    # running (Stop-PinnedApp / Invoke-PinnedUpgrade).
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

        Step-Info "$name $($before.Version) -> $($row.Version) ..."
        # One package going wrong is that package's [XX], never the end of the step: the
        # rest still get checked, and whatever was stopped still gets started again below.
        $wasRunning = $false
        try {
            $wasRunning = Stop-PinnedApp $row
            $code  = Invoke-PinnedUpgrade $row
            $after = Get-PackageVersion $row
            if ($null -ne $code -and $code -ne 0) {
                Write-Host "  [XX] $($name): winget exited $(Format-WingetCode $code) -- still $($after.Version) (pin put back)" -ForegroundColor Red
            } elseif ((Compare-PinVersion $after.Version $row.Version) -eq 0) {
                Step-Ok "$name $($before.Version) -> $($after.Version)"
            } elseif ($null -eq $code -and $after.Installed) {
                Step-Warn "$($name): the un-elevated upgrade was still running after 3 minutes -- it reports $($after.Version) so far; check again once it's done."
            } else {
                Write-Host "  [XX] $($name): winget finished, but it reports '$($after.Version)', not $($row.Version)" -ForegroundColor Red
            }
        } catch {
            # Invoke-PinnedUpgrade puts the pin back itself (finally), whatever went wrong.
            Write-Host "  [XX] $($name): $($_.Exception.Message)" -ForegroundColor Red
        }
        $task = Get-PinnedAppTask $row
        if ($wasRunning -and $task) {
            if (Test-Task -TaskName $task) {
                $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName $task) 2>&1
                if ($LASTEXITCODE -eq 0) { Step-Ok "$($name): started again through its task" }
                else { Step-Warn "$($name): its task didn't start (schtasks exit $LASTEXITCODE) -- 710sRice start brings it back." }
            } else {
                Step-Warn "$($name) was running but has no task -- 710sRice start brings it back."
            }
        } elseif ($wasRunning) {
            Step-Info "$name was closed for the upgrade -- it starts again the next time you open it."
        }
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
    Step-Ok "KOMOREBI_CONFIG_HOME = $komorebiConfigHome"
    Step-Ok "YASB_CONFIG_HOME     = $yasbConfigHome"
    Step-Ok "DESKTOPRICE_HOME     = $Root"
}

$Steps['weather'] = {
    # --- 2b. Weather widget (optional) ----------------------------------------------------
    # YASB's weather widget reads its API key and location from these two per-user variables
    # ($env:... in config\yasb\config.yaml) -- kept out of this public repo on purpose. They
    # belong to the person, not the repo: install only fills in what's missing, never echoes
    # what's stored, and uninstall.ps1 leaves both alone -- so a reinstall finds them already
    # set and asks nothing. Enter skips; an unattended run (no one to answer) skips quietly.
    Write-Host "`n-- Weather widget (optional) --" -ForegroundColor Cyan
    $canAsk = [Environment]::UserInteractive -and -not ([Environment]::GetCommandLineArgs() -contains '-NonInteractive')
    $weatherVars = @(
        @{ Name = 'YASB_WEATHER_API_KEY';  Prompt = 'weatherapi.com API key (free at https://www.weatherapi.com) -- Enter to skip' },
        @{ Name = 'YASB_WEATHER_LOCATION'; Prompt = 'Weather location -- zip/postal code or city name -- Enter to skip' }
    )
    $weatherMissing = $false
    foreach ($v in $weatherVars) {
        if ([Environment]::GetEnvironmentVariable($v.Name, 'User')) { Step-Ok "$($v.Name) already set"; continue }
        $answer = ''
        if ($canAsk) { try { $answer = "$(Read-Host "  $($v.Prompt)")".Trim() } catch { $answer = '' } }
        if ($answer) {
            [Environment]::SetEnvironmentVariable($v.Name, $answer, 'User')
            Set-Item -Path "env:$($v.Name)" -Value $answer
            Step-Ok "$($v.Name) set"
        } else {
            $weatherMissing = $true
            Step-Info "$($v.Name) not set -- skipped."
        }
    }
    if ($weatherMissing) {
        Step-Info 'The weather widget shows an error until both are set -- run `710sRice install -Only weather`, or `setx` them yourself (see README).'
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
            Step-Ok "710sRice command: $riceBin added to your PATH (open a new PS7 window to use it)"
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
            Step-Warn "wallust install failed: $($_.Exception.Message) -- continuing without it. Re-run install.ps1, or tools\install-wallust.ps1 directly, once network access allows it."
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
    # wallust + apply-wallust-outputs.ps1 pipeline YASB's Wallpapers widget runs on every real
    # wallpaper change (see config\yasb\config.yaml's run_after) -- so komorebi borders, the
    # Windows accent color, Windows Terminal, and (once -Activate registers its Scheduled Task
    # a few sections down) the lock screen all end up themed to it too, via the one real
    # code path rather than a second, parallel "first theme" implementation.
    Write-Host "`n-- Default theme --" -ForegroundColor Cyan
    $defaultWallpaper = Join-Path $Root 'assets\wallpapers\710Default001.png'

    if (-not (Test-Path $defaultWallpaper)) {
        Step-Warn "Default wallpaper not found at $defaultWallpaper -- skipping the default theme."
    } elseif (-not (Test-Path $wallustExe) -or -not (Test-Path (Join-Path $Root 'config\wallust\wallust.toml'))) {
        # The wallust step installs both; -Only theme on its own can find them missing.
        Step-Warn "wallust isn't set up (no wallust.exe or wallust.toml) -- skipping the default theme.$(if ($OnlyRun) { ' Add the wallust step: 710sRice install -Only wallust,theme' })"
    } else {
        try {
            # One-time snapshot of whatever wallpaper was here before -- Set-DesktopWallpaper
            # below is about to overwrite it, and uninstall.ps1's Restore-OriginalWallpaper
            # needs this to put the real original back, not just delete our own value (both in
            # tools\lib\activation.ps1).
            Save-OriginalWallpaper
            Set-DesktopWallpaper -Path $defaultWallpaper
            Step-Ok "Desktop wallpaper set to $defaultWallpaper"

            & $wallustExe run $defaultWallpaper --config-dir (Join-Path $Root 'config\wallust') 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "wallust run exited with code $LASTEXITCODE" }
            # In-process, not a separate `pwsh -File` call -- install.ps1 itself already
            # requires PS7 (see this file's #Requires line), so there's no PATH/process
            # resolution to worry about; a plain call-operator invocation is simplest.
            & (Join-Path $Root 'tools\apply-wallust-outputs.ps1')
            # apply-wallust-outputs.ps1 prints exactly which legs ran (komorebi borders only if
            # komorebi is up); the lock screen follows once -Activate registers its sync task.
            Step-Ok "Default theme applied (details above)."
        } catch {
            Step-Warn "Could not apply the default theme: $($_.Exception.Message)"
        }
    }
}

$Steps['palette'] = {
    # --- palette: the current wallpaper's colours, re-applied (named-only) ---------------
    # The opposite of theme: no wallpaper change. Runs exactly what YASB's wallpaper widget
    # runs after every change (its two run_after lines in config\yasb\config.yaml) on the
    # wallpaper that's up now (Get-CurrentWallpaper -- the value Sync-LockScreen.ps1 reads).
    # Same image, same palette (wallust caches it per image), so on a healthy machine nothing
    # visibly changes -- it's the fix for missing or stale generated theme files
    # (colors.json, wallust_colors.css, starship.toml, Terminal's scheme). It never falls
    # back to the default wallpaper: that's the theme step, the reset.
    Write-Host "`n-- Palette (current wallpaper) --" -ForegroundColor Cyan
    $currentWallpaper = Get-CurrentWallpaper
    if (-not $currentWallpaper -or -not (Test-Path -LiteralPath $currentWallpaper)) {
        Step-Warn "The current wallpaper ($(if ($currentWallpaper) { ConvertTo-SafePath $currentWallpaper } else { 'none set' })) is gone -- pick one with SUPER+W; that re-themes everything from it."
    } elseif (-not (Test-Path $wallustExe) -or -not (Test-Path (Join-Path $Root 'config\wallust\wallust.toml'))) {
        Step-Warn "wallust isn't set up (no wallust.exe or wallust.toml) -- add the wallust step: 710sRice install -Only wallust,palette"
    } else {
        try {
            & $wallustExe run $currentWallpaper --config-dir (Join-Path $Root 'config\wallust') 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "wallust run exited with code $LASTEXITCODE" }
            & (Join-Path $Root 'tools\apply-wallust-outputs.ps1')
            Step-Ok "Palette re-applied from the current wallpaper ($(Split-Path -Leaf $currentWallpaper)) -- details above."
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

$Steps['defender'] = {
    # --- 6. Windows Defender exclusions (unconditional) --------------------------------------
    # Not gated behind -Activate -- matches winarchy's own install.ps1 exactly (Set-
    # WinarchyDefenderExclusions runs unconditionally there too). Needs elevation; warns and
    # skips (doesn't fail the install) if this shell isn't elevated -- see tools/lib/
    # activation.ps1.
    Write-Host "`n-- Windows Defender exclusions --" -ForegroundColor Cyan
    Set-DefenderExclusions
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

$Steps['terminal'] = {
    # --- 8. Windows Terminal: default shell (PowerShell 7) -----------------------------------
    # One-time preference, not a per-wallpaper concern -- deliberately NOT folded into
    # tools/apply-wallust-outputs.ps1 (which re-runs on every wallpaper change and would
    # silently re-clobber a manual change back to this every time). Looked up by `source`
    # rather than a hardcoded GUID: Windows Terminal auto-generates the PowerShellCore dynamic
    # profile once it detects pwsh.exe, and while its GUID is deterministic/stable across
    # machines in practice, matching on `source` here means this doesn't silently break if
    # that assumption is ever wrong on a machine (Godzilla, eventually) this hasn't been
    # verified against yet.
    Write-Host "`n-- Windows Terminal default shell --" -ForegroundColor Cyan
    $wtSettingsCandidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    $wtSettingsPath = $wtSettingsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($wtSettingsPath) {
        $wt = Get-Content $wtSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $pwshProfile = @($wt['profiles']['list']) | Where-Object { $_['source'] -eq 'Windows.Terminal.PowershellCore' } | Select-Object -First 1
        if ($pwshProfile -and $pwshProfile['guid']) {
            if ($wt['defaultProfile'] -ne $pwshProfile['guid']) {
                # One-time snapshot of whatever the default profile was before -- separate
                # label from apply-wallust-outputs.ps1's own 'terminal-colorscheme' snapshot
                # (see Restore-WindowsTerminalSettings in tools\lib\activation.ps1 for why two
                # labels, not one) since this is the only place that ever touches this field.
                Save-OriginalState -Label 'terminal-defaultprofile' -Data @{
                    Existed = $wt.ContainsKey('defaultProfile')
                    Value   = $wt['defaultProfile']
                }
                $wt['defaultProfile'] = $pwshProfile['guid']
                $wt | ConvertTo-Json -Depth 50 | Set-Content -Path $wtSettingsPath -Encoding UTF8
                Step-Ok "Windows Terminal default profile set to PowerShell 7 ($($pwshProfile['guid']))"
            } else {
                Step-Ok 'Windows Terminal default profile already PowerShell 7'
            }
        } else {
            Step-Warn "No PowerShell 7 profile found in Windows Terminal's settings.json yet -- open Terminal once (it generates this profile the first time it sees pwsh.exe on PATH), then run ``710sRice install -Only terminal``."
        }
    } else {
        Step-Warn 'Windows Terminal settings.json not found -- default shell not set (install/launch Windows Terminal first).'
    }
}

$Steps['flow'] = {
    # --- 9. Flow Launcher setup (settings + Everything plugin) -------------------------------
    Write-Host "`n-- Flow Launcher --" -ForegroundColor Cyan
    # Reset first: $LASTEXITCODE only changes when a native exe runs or a script calls `exit`,
    # so without this the check below could read a failure left over from an earlier,
    # unrelated step (e.g. write-display-index.ps1's exit 2 when komorebi isn't running yet)
    # and print a false "skipped".
    $global:LASTEXITCODE = 0
    & (Join-Path $Root 'tools\setup-flow-launcher.ps1')
    if ($LASTEXITCODE -ne 0) {
        Step-Info "Flow Launcher setup skipped this run (see message above) -- harmless if Flow hasn't been run yet; run ``710sRice install -Only flow`` after its first launch."
    }
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

    # --- 11a. Tasks: every component's, in the machine's mode ------------------------------
    if ($Activate) {
        Write-Host "`n-- Activate --" -ForegroundColor Cyan
        Register-Autostart
        Register-LockScreenSyncTask
        # Fire it once right now rather than waiting for a future wallpaper change -- on a
        # fresh install, the theme step already set the default wallpaper before this task
        # existed to catch it, so without this the lock screen would stay unsynced until the
        # next real wallpaper change. Best-effort: if the task didn't register above (not
        # elevated, no pwsh), Test-Task is false and this is a silent no-op.
        if (Test-Task -TaskName 'lock-screen-sync') {
            & schtasks.exe /Run /TN (Get-TaskFullName -TaskName 'lock-screen-sync') *> $null
        }
    } elseif (Test-FullTimeMachine) {
        # Already full-time from an earlier -Activate: re-register so the tasks pick up any
        # change to how components are launched (a newer launcher script, a moved clone),
        # without switching modes.
        Write-Host "`n-- Activate --" -ForegroundColor Cyan
        Step-Info 'Autostart is active: re-registering to pick up any startup changes...'
        $hadLockScreen = Test-Task -TaskName 'lock-screen-sync'
        Register-Autostart
        # A full-time machine always has its lock-screen sync task -- including one that went
        # missing (doctor's fix for that is `-Only tasks`). Fired only when it had to be made
        # again, so the lock screen catches up; a working one is left alone, as before.
        Register-LockScreenSyncTask
        if (-not $hadLockScreen -and (Test-Task -TaskName 'lock-screen-sync')) {
            & schtasks.exe /Run /TN (Get-TaskFullName -TaskName 'lock-screen-sync') *> $null
        }
    } else {
        # On-demand: every component still gets its task (no trigger), so Start-All.ps1,
        # SUPER+Shift+R and the bar watchdog start each one at its task's own level -- the
        # same as -Activate, from any window (Register-OnDemandTasks).
        if (-not $OnlyRun) {
            Step-Info 'Not -Activate: packages/config/theming/Defender/profile/Flow are applied, but autostart, the taskbar, hardening and the Startup delay are untouched.'
        }
        Register-OnDemandTasks
        if (-not $OnlyRun) {
            Step-Info 'Run `710sRice install -Activate` when ready to make this repo the active shell experience.'
        }
    }
}

$Steps['windows'] = {
    # --- 11b. Windows settings: taskbar, hardening, Startup delay (full-time machines) ---
    # A plain run only gets here with -Activate. -Only windows gets here on any machine, and
    # these settings only belong to a full-time one.
    if ($OnlyRun -and -not (Test-FullTimeMachine)) {
        Write-Host "`n-- Windows settings --" -ForegroundColor Cyan
        Step-Info 'Nothing to do (on-demand machine) -- these settings are only for a full-time install (710sRice install -Activate).'
    } else {
        if ($OnlyRun) { Write-Host "`n-- Windows settings --" -ForegroundColor Cyan }

        # Snapshot tray-icon promotions before either kill below -- Explorer's own forced
        # restart(s) can reset every app's "always show this icon" preference, not just this
        # repo's own (see Backup-TrayIconPromotions in tools\lib\activation.ps1). Restored
        # once both kills are done and Explorer's confirmed back up from the second one.
        $trayIconBackup = Backup-TrayIconPromotions

        # Both only change settings; Explorer is restarted ONCE below if either did (see
        # Restart-Explorer -- two back-to-back restarts left the desktop blank, 2026-09-24).
        $needExplorerRestart = $false
        try {
            if (Set-TaskbarAutoHide -Enabled $true) { Step-Ok 'Native taskbar set to auto-hide'; $needExplorerRestart = $true }
            else { Step-Ok 'Native taskbar already set to auto-hide' }
        } catch { Step-Warn "Could not set the taskbar to auto-hide: $($_.Exception.Message)" }

        try {
            $n = Set-WindowsHardening
            Step-Ok "Windows hardening applied ($n setting(s) changed: no Bing search, ad suggestions, Copilot/Widgets/Task View buttons, Start recommendations)"
            if ($n -gt 0) { $needExplorerRestart = $true }
        } catch { Step-Warn "Could not apply Windows hardening: $($_.Exception.Message)" }

        if ($needExplorerRestart) {
            if (Restart-Explorer) { Step-Ok 'Explorer restarted once to apply the taskbar/hardening changes' }
            else { Step-Warn "Explorer didn't come back after its restart -- sign out and back in (Ctrl+Alt+Del) to get the desktop back." }
        }
        Restore-TrayIconPromotions -BackupFile $trayIconBackup

        try {
            Set-StartupDelay
            Step-Ok 'Startup app-launch delay removed (StartupDelayInMSec=0)'
        } catch { Step-Warn "Could not remove the Startup app-launch delay: $($_.Exception.Message)" }
    }
}

# --- Run the steps ---------------------------------------------------------------------
# Dot-sourced, so every step runs in this script's own scope -- exactly as the sections
# did before they were steps (the theme step still sees what the wallust step set up).
foreach ($step in $RunSteps) { . $Steps[$step] }

# --- Start now (a full install -Activate only) -------------------------------------------
if ($Activate -and -not $OnlyRun) {
    Step-Info 'Starting services...'
    # Started through each component's own autostart task (schtasks /Run), never launched
    # directly from this shell. -Activate needs an elevated shell, and anything started
    # from one runs elevated: an elevated AHK makes every Terminal it opens elevated, and
    # non-elevated komorebi can't tile elevated windows (the 2026-09-23 admin-AHK incident;
    # this block used to Start-Process the launchers itself, found 2026-09-24 before the
    # full reinstall test). The tasks run at their own registered level whatever shell fires
    # them -- LeastPrivilege, except komorebi's in elevated tiling mode -- the
    # same path logon and SUPER+Shift+R use, so "start now" and "start at next sign-in"
    # stay one code path. A component whose task couldn't be registered (Register-
    # Autostart fell back to a Startup shortcut) is started from that shortcut only when
    # this shell is NOT elevated; elevated, it says so and waits for the next sign-in.
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $startupDir = [Environment]::GetFolderPath('Startup')
    foreach ($c in @(Get-AutostartComponents)) {
        if (Test-Task -TaskName $c.TaskName) {
            $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName $c.TaskName) 2>&1
            if ($LASTEXITCODE -eq 0) { Step-Ok "$($c.Key): started via its autostart task" }
            else { Step-Warn "$($c.Key): schtasks /Run failed (exit $LASTEXITCODE) -- it will start at the next sign-in." }
            continue
        }
        $lnk = Join-Path $startupDir $c.LnkName
        if ((Test-Path $lnk) -and -not $elevated) {
            Start-Process $lnk
            Step-Ok "$($c.Key): started via its Startup shortcut (no task)"
        } elseif (Test-Path $lnk) {
            Step-Warn "$($c.Key): only a Startup shortcut, no task -- not starting it from this elevated shell (it would run elevated); it starts at the next sign-in."
        } else {
            Step-Warn "$($c.Key): no autostart task or Startup shortcut -- not started."
        }
    }
    Step-Ok 'Services starting in the background (see %LOCALAPPDATA%\710.DesktopRice\*-autostart.log if one seems to not have come up).'
}

# --- Done -----------------------------------------------------------------------------
if ($OnlyRun) {
    Write-Host "`n== Done: $($RunSteps -join ', ') ==" -ForegroundColor Cyan
} else {
    Write-Host "`n== Install complete ==" -ForegroundColor Cyan
    if (-not $Activate) {
        Write-Host "This run didn't start the stack or touch autostart/taskbar/hardening. To run it now (on demand):"
        Write-Host ""
        Write-Host "    710sRice start" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "Or run ``710sRice install -Activate`` to start it at every sign-in."
    }
}
