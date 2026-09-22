#Requires -Version 7.0
<#
.SYNOPSIS
  Idempotent installer for 710.DesktopRice.

.DESCRIPTION
  - Installs required components via winget. Core components (komorebi, YASB, AutoHotkey,
    Flow Launcher) are pinned to the versions in versions.md and winget-pinned so a general
    `winget upgrade --all` elsewhere on the machine can't silently move them out from under
    this repo's tested config.
  - Registers KOMOREBI_CONFIG_HOME / YASB_CONFIG_HOME (User scope) pointing at this repo,
    and mirrors them into the current process so the rest of this run sees them too.
  - Installs wallust (tools/install-wallust.ps1) if it's missing or behind its pin.
  - Runs `komorebic.exe monitor-information` and writes this machine's real monitor
    identity to config/komorebi/display-index.local.json (gitignored, machine-local) --
    see that file's consumer, tools/compile-komorebi-rules.ps1, for why this can never be
    a tracked file. Safe to skip (a fresh install before komorebi has ever run on this
    machine simply won't have this yet; re-run install.ps1 once komorebi is up to pick it
    up, or run tools/compile-komorebi-rules.ps1 -Force... see NOTES).
  - Runs tools/setup-flow-launcher.ps1 (only meaningful once Flow Launcher has been run at
    least once; that script warns and no-ops cleanly if it hasn't).
  - Regenerates config/komorebi/komorebi.json (tools/compile-komorebi-rules.ps1) so a
    fresh clone or a pin bump lands in a ready-to-use compiled config.
  - Safe to re-run: only touches what's missing or behind its pin. `git pull` then
    `.\install.ps1` is this repo's update mechanism -- there's no separate "check for
    updates" feature by design (see claude/winarchy-decoupling-plan.md).

.NOTES
  Deliberately does NOT start or restart komorebi/YASB/AHK, does not register autostart,
  does not touch the taskbar, and does not add Windows Defender exclusions. winarchy does
  all of these behind its own -Activate flag; this repo hasn't reviewed or aligned on any
  of them yet, so this installer stays coexistence-only until that's an explicit, separate
  decision. See "Next steps" at the end of a run for the exact command to (re)launch
  komorebi with this repo's config once you're ready to do that by hand.

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
  script re-reads Machine+User PATH into $env:Path after the package loop specifically so
  monitor-information (below) can find a just-installed komorebic.exe without requiring a
  second run.

.EXAMPLE
  .\install.ps1                # install/update everything this repo owns
  .\install.ps1 -SkipPackages  # skip the winget loop; still does env vars / wallust /
                                # display-index / Flow setup / recompile
#>
[CmdletBinding()]
param(
    [switch]$SkipPackages
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

function Step-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Step-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Step-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

Write-Host "`n== 710.DesktopRice install ==" -ForegroundColor Cyan

# --- 1. Packages (winget) -----------------------------------------------------------
# Core = pinned (winget pin add, so a general `winget upgrade --all` elsewhere on the
# machine can't move these out from under a tested config). Versions mirror versions.md;
# if you bump one here, bump it there too.
$CorePins = [ordered]@{
    'LGUG2Z.komorebi'             = '0.1.41'
    'AmN.yasb'                    = '2.0.7'
    'AutoHotkey.AutoHotkey'       = '2.0.26'
    'Flow-Launcher.Flow-Launcher' = '2.1.3'
}
# Required, not pinned -- always installed at whatever winget currently offers.
$RequiredPackages = @(
    'ShareX.ShareX',
    'Microsoft.WindowsTerminal',
    'DEVCOM.JetBrainsMonoNerdFont',
    'Starship.Starship',
    'junegunn.fzf',
    'ajeetdsouza.zoxide',
    'eza-community.eza',
    'sharkdp.bat',
    'voidtools.Everything'
)

if (-not $SkipPackages) {
    Write-Host "`n-- Packages (winget) --" -ForegroundColor Cyan
    $allPackages = [ordered]@{}
    foreach ($id in $CorePins.Keys) { $allPackages[$id] = $CorePins[$id] }
    foreach ($id in $RequiredPackages) { if (-not $allPackages.Contains($id)) { $allPackages[$id] = $null } }

    foreach ($id in $allPackages.Keys) {
        $pinVersion = $allPackages[$id]
        $listed = winget list --id $id --exact --accept-source-agreements 2>$null | Out-String
        $alreadyInstalled = $listed -match [regex]::Escape($id)
        if ($alreadyInstalled) {
            Step-Ok "$id already installed"
        } else {
            Step-Info "Installing $id ..."
            $wingetArgs = @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
            if ($pinVersion) { $wingetArgs += @('--version', $pinVersion) }
            winget @wingetArgs
            if ($LASTEXITCODE -ne 0) {
                Step-Warn "winget install $id exited with code $LASTEXITCODE -- check the output above."
            }
        }
        if ($pinVersion) {
            winget pin add --id $id 2>$null | Out-Null
        }
    }

    # Re-read PATH from the registry into this process. Without this, a component that
    # was just installed for the first time above (e.g. komorebi) won't be found by
    # Get-Command until a new terminal is opened -- see NOTES.
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')

    # PSFzf: the PowerShell-side fzf keybindings/integration module, separate from the
    # junegunn.fzf winget package above (that's just the fzf binary). PSGallery, not
    # winget -- no pin, always latest, matching this project's own decided practice
    # (mirrors winarchy's own real behavior: it never pinned this one either).
    Write-Host "`n-- PSFzf (PowerShell module) --" -ForegroundColor Cyan
    if (Get-Module -ListAvailable PSFzf) {
        Step-Ok "PSFzf already installed"
    } else {
        Step-Info "Installing PSFzf (PSGallery) ..."
        try {
            Install-Module PSFzf -Scope CurrentUser -Force -ErrorAction Stop
            Step-Ok "PSFzf installed"
        } catch {
            Step-Warn "Could not install PSFzf: $($_.Exception.Message)"
        }
    }
} else {
    Step-Info "Skipping package installation (-SkipPackages)"
}

# --- 2. Config env vars: repo is the source of truth --------------------------------
Write-Host "`n-- Config environment variables --" -ForegroundColor Cyan
$komorebiConfigHome = Join-Path $Root 'config\komorebi'
$yasbConfigHome     = Join-Path $Root 'config\yasb'
[Environment]::SetEnvironmentVariable('KOMOREBI_CONFIG_HOME', $komorebiConfigHome, 'User')
[Environment]::SetEnvironmentVariable('YASB_CONFIG_HOME', $yasbConfigHome, 'User')
$env:KOMOREBI_CONFIG_HOME = $komorebiConfigHome
$env:YASB_CONFIG_HOME     = $yasbConfigHome
Step-Ok "KOMOREBI_CONFIG_HOME = $komorebiConfigHome"
Step-Ok "YASB_CONFIG_HOME     = $yasbConfigHome"

# --- 3. wallust -----------------------------------------------------------------------
Write-Host "`n-- wallust --" -ForegroundColor Cyan
$WallustPinnedVersion = '4.1.0-alpha'
$wallustExe = Join-Path $Root 'tools\bin\wallust\wallust.exe'
$wallustUpToDate = $false
if (Test-Path $wallustExe) {
    try {
        $verOut = & $wallustExe --version 2>$null | Out-String
        if ($verOut -match [regex]::Escape($WallustPinnedVersion)) { $wallustUpToDate = $true }
    } catch { }
}
if ($wallustUpToDate) {
    Step-Ok "wallust $WallustPinnedVersion already installed"
} else {
    Step-Info "Installing wallust $WallustPinnedVersion ..."
    try {
        & (Join-Path $Root 'tools\install-wallust.ps1')
        Step-Ok "wallust installed"
    } catch {
        Step-Warn "wallust install failed: $($_.Exception.Message) -- continuing without it. Re-run install.ps1, or tools\install-wallust.ps1 directly, once network access allows it."
    }
}

# --- 4. Monitor identity (display_index_preferences) ----------------------------------
Write-Host "`n-- Monitor identity (display_index_preferences) --" -ForegroundColor Cyan

function Get-MonitorDisplayIndexPreferences {
    # Runs `komorebic.exe monitor-information` and builds a display_index_preferences map
    # (array-index -> serial_number_id) from the real, live result on THIS machine. Never
    # writes a guessed or partial map: returns $null (and warns) if komorebic isn't found,
    # the call fails, the output can't be parsed, or no monitor has a usable
    # serial_number_id -- compile-komorebi-rules.ps1 simply omits the key in that case and
    # komorebi falls back to Windows' own enumeration order for that session.
    #
    # Deliberately invoked directly (not via Get-Command komorebic.exe first) and the
    # CommandNotFoundException caught instead: Get-Command's Application-type resolution
    # proved unreliable for finding a freshly-PATH'd .exe when this script was built and
    # tested (see the local pwsh sandbox notes in the plan doc) -- direct invocation with
    # a catch is both simpler and the more portable way to ask "is this on PATH".
    try {
        $raw = & 'komorebic.exe' monitor-information 2>$null
    } catch [System.Management.Automation.CommandNotFoundException] {
        Step-Warn "komorebic.exe not found on PATH -- skipping display_index_preferences (install komorebi first, or open a new terminal / re-run install.ps1 so PATH picks it up)."
        return $null
    } catch {
        Step-Warn "komorebic.exe monitor-information failed: $($_.Exception.Message) -- skipping display_index_preferences."
        return $null
    }
    if (-not $raw) {
        Step-Warn "komorebic.exe monitor-information returned no output -- skipping display_index_preferences."
        return $null
    }
    try {
        $parsed = ($raw -join "`n") | ConvertFrom-Json
    } catch {
        $dumpPath = Join-Path $env:TEMP 'monitor-information.raw.txt'
        ($raw -join "`n") | Set-Content -Path $dumpPath -Encoding UTF8
        Step-Warn "Could not parse komorebic.exe monitor-information output as JSON -- skipping display_index_preferences. Raw output saved to $dumpPath for inspection."
        return $null
    }
    $monitors = @($parsed)
    if ($monitors.Count -eq 0) {
        Step-Warn "komorebic.exe monitor-information reported zero monitors -- skipping display_index_preferences."
        return $null
    }
    if ($monitors.Count -gt 4) {
        Step-Warn "$($monitors.Count) monitors detected; this repo's design supports 4, using the first 4 in reported order."
        $monitors = $monitors[0..3]
    }
    $map = [ordered]@{}
    for ($i = 0; $i -lt $monitors.Count; $i++) {
        $serial = $monitors[$i].serial_number_id
        if ([string]::IsNullOrWhiteSpace($serial)) {
            Step-Warn "Monitor index $i has no serial_number_id in komorebic's output -- leaving it out (display_index_preferences will be incomplete for this monitor)."
            continue
        }
        $map["$i"] = "$serial"
    }
    if ($map.Count -eq 0) {
        Step-Warn "No monitor had a usable serial_number_id -- skipping display_index_preferences entirely."
        return $null
    }
    $map
}

$displayIndexPath = Join-Path $Root 'config\komorebi\display-index.local.json'
$displayMap = Get-MonitorDisplayIndexPreferences
if ($displayMap) {
    $displayMap | ConvertTo-Json | Set-Content -Path $displayIndexPath -Encoding UTF8
    Step-Ok "Wrote $($displayMap.Count) monitor(s) to $displayIndexPath"
} else {
    Step-Info "Not written this run -- config/komorebi/komorebi.json will simply omit display_index_preferences (fine before komorebi has ever run here); re-run .\install.ps1 later to pick it up."
}

# --- 5. Flow Launcher setup -------------------------------------------------------------
Write-Host "`n-- Flow Launcher --" -ForegroundColor Cyan
& (Join-Path $Root 'tools\setup-flow-launcher.ps1')
if ($LASTEXITCODE -ne 0) {
    Step-Info "Flow Launcher setup skipped this run (see message above) -- harmless if Flow hasn't been run yet; re-run .\install.ps1 after its first launch."
}

# --- 6. Recompile komorebi.json ----------------------------------------------------------
Write-Host "`n-- Compiling komorebi.json --" -ForegroundColor Cyan
& (Join-Path $Root 'tools\compile-komorebi-rules.ps1')

# --- Done -----------------------------------------------------------------------------
Write-Host "`n== Install complete ==" -ForegroundColor Cyan
Write-Host "This script did not start or restart komorebi/YASB/AHK (coexistence mode -- see NOTES)."
Write-Host "To load this repo's config into a running komorebi, in a NEW terminal (so it sees the"
Write-Host "env vars just registered):"
Write-Host ""
Write-Host "    komorebic.exe stop" -ForegroundColor DarkGray
Write-Host "    Start-Process komorebi.exe -WindowStyle Hidden -ArgumentList '--config',`"$Root\config\komorebi\komorebi.json`"" -ForegroundColor DarkGray
Write-Host ""
