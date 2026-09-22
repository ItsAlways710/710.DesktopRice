#Requires -Version 7.0
<#
.SYNOPSIS
  Clean uninstall of 710.DesktopRice.

.DESCRIPTION
  Stops every process 710.DesktopRice may have started (komorebi, YASB, the window-slots
  daemon, ShareX, AHK) regardless of whether -Activate was ever used, then reverts
  everything install.ps1 -Activate touches (autostart Scheduled Tasks, native-taskbar
  auto-hide, HKCU registry hardening, Explorer's Startup-delay), everything install.ps1
  applies unconditionally (the pwsh $PROFILE hook, Windows Defender exclusions), the env
  vars and winget pins install.ps1 sets, then removes the packages this repo's own
  install.ps1 installs -- EXCEPT any row versions.md marks Pre-existing? = yes, which is
  left alone unless you pass -Force (see versions.md for what that column means and why
  most rows currently default to protected). -Keep <Install ID> protects additional
  specific packages beyond whatever versions.md already protects.

  Never touches the repo itself (config/, tools/, this script) or anything outside what
  install.ps1 itself touches -- delete the folder yourself if you want it gone too. Does
  not remove config/windows.toml (your saved window-slot preferences) or the wallust-
  generated theming files -- those are your data/output, not install state.

.NOTES
  winarchy's own uninstall.ps1 never stops a running process and never reverts autostart,
  the taskbar, hardening, or the Startup delay at all -- a machine it "uninstalled" from
  could still have komorebi/YASB/AHK running and autostarting at next logon. This script
  closes that gap: stopping is unconditional (first thing, every run, regardless of
  whether this machine ever used -Activate), and every -Activate-gated setting install.ps1
  can apply is reverted here to match, whether or not -Activate was ever actually used on
  this machine (each revert is itself idempotent/self-detecting -- reverting a setting
  that was never applied is a safe no-op, same as install.ps1's own steps being safe to
  re-run).

  -DryRun exists because this script can only really be validated by actually destroying
  a real install -- same reasoning winarchy's own uninstall.ps1 documents for its own
  -DryRun. Use it to review the plan before committing to it.

  Each step is independent (Invoke-Step / Invoke-ActivationRevert catch and report their
  own failure rather than aborting the rest) so one winget hiccup, or one registry key
  that's already gone, doesn't leave everything else half-reverted.

.EXAMPLE
  .\uninstall.ps1                                # stop processes, revert -Activate/autostart/env vars/pins, remove packages
  .\uninstall.ps1 -DryRun                        # show the plan, touch nothing
  .\uninstall.ps1 -Keep AutoHotkey.AutoHotkey    # remove everything else, leave this one installed
  .\uninstall.ps1 -Force                         # also remove the "Pre-existing? yes" rows
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string[]]$Keep = @()
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

function Step-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Step-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Step-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

function Invoke-Step {
    # Runs the step, or just describes it in -DryRun. A step's failure is reported and
    # skipped, never lets it abort the rest of the uninstall (same reasoning as
    # winarchy's own Invoke-Step) -- a partial, honestly-reported uninstall beats
    # stopping halfway through and leaving the machine in an unknown state.
    param([string]$Describe, [scriptblock]$Action, [string]$Done)
    if ($DryRun) { Write-Host "  [ ] $Describe"; return }
    try { & $Action; Step-Ok $Done }
    catch { Step-Warn "$($Describe): $($_.Exception.Message)" }
}

function Invoke-ActivationRevert {
    # Same -DryRun gate as Invoke-Step, but for the tools\lib\activation.ps1 functions
    # below -- those already report their own Step-Ok/Step-Warn per setting/component (see
    # e.g. Set-WindowsHardening, Register-Autostart), so this doesn't also print a
    # redundant "Done" line the way Invoke-Step's $Done parameter would.
    param([string]$Describe, [scriptblock]$Action)
    if ($DryRun) { Write-Host "  [ ] $Describe"; return }
    try { & $Action } catch { Step-Warn "$($Describe): $($_.Exception.Message)" }
}

# Defender exclusions, hardening, taskbar, autostart, the shell-profile hook, and the
# process-stopping helper all live here, shared with install.ps1. Step-Ok/Info/Warn above
# must be defined before this dot-source -- activation.ps1 uses ours rather than its own
# copies.
. (Join-Path $Root 'tools\lib\activation.ps1')

function Get-VersionsTable {
    # Hand-rolled parser for versions.md's one real table -- not a general Markdown
    # parser, scoped to exactly that file's fixed column layout (see versions.md's own
    # "table format is load-bearing" note: Component | Version | Source | Install ID |
    # Pre-existing? | Last touched). Returns an array of @{ Component; Version; Source;
    # InstallId; PreExisting; LastTouched }; PreExisting is $true for "yes" or "yes ?".
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    $inTable = $false
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('|')) { $inTable = $false; continue }
        $cells = @($trimmed.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells[0] -eq 'Component') { $inTable = $true; continue }   # header row
        if ($cells[0] -match '^-+$') { continue }                       # separator row
        if (-not $inTable) { continue }
        if ($cells.Count -lt 6) { continue }
        $rows.Add([pscustomobject]@{
            Component   = $cells[0]
            Version     = $cells[1]
            Source      = $cells[2]
            InstallId   = $cells[3]
            PreExisting = ($cells[4] -match '^\s*yes')
            LastTouched = $cells[5]
        })
    }
    return @($rows)
}

Write-Host "`n== 710.DesktopRice uninstall ==" -ForegroundColor Cyan
if ($DryRun) { Step-Info "DRY RUN: nothing will be changed." }

$versionsPath = Join-Path $Root 'versions.md'
$allRows = @(Get-VersionsTable -Path $versionsPath)
if ($allRows.Count -eq 0) {
    Step-Warn "Could not read versions.md (or it has no table rows) -- package removal will be skipped entirely, to avoid guessing what's safe to remove. Env vars and pins will still be reverted."
}
$wingetRows = @($allRows | Where-Object { $_.Source -eq 'winget' })

# --- 1. Stop any running 710.DesktopRice processes -----------------------------------
# Unconditional -- regardless of whether -Activate/autostart was ever used on this
# machine, install.ps1 -Activate's own "start now" step (or a person starting things by
# hand) can leave komorebi/YASB/window-slots/ShareX/AHK running. Stopped first, before any
# of the registry/task reverts below, so nothing is still actively re-asserting a setting
# (e.g. komorebi re-hiding a taskbar border) while it's being undone.
Write-Host "`n-- Stop running processes --" -ForegroundColor Cyan
Invoke-ActivationRevert "Stop any running 710.DesktopRice processes (komorebi, YASB, window-slots, ShareX, AHK)" {
    Stop-RunningComponents
    Step-Ok 'Running processes stopped (best-effort; a component that was never running is a no-op)'
}

# --- 2. Revert -Activate: autostart, taskbar, hardening, Startup delay ----------------
# Reverted unconditionally too, whether or not -Activate was ever actually used here --
# each of these is self-detecting/idempotent (see NOTES), so reverting a setting that was
# never applied is a safe no-op. winarchy's own uninstall.ps1 does none of this at all.
Write-Host "`n-- Revert autostart / taskbar / hardening / Startup delay --" -ForegroundColor Cyan
Invoke-ActivationRevert 'Unregister autostart (Scheduled Tasks + Startup fallback shortcuts)' {
    Unregister-Autostart
    Step-Ok 'Autostart unregistered'
}
Invoke-ActivationRevert 'Un-hide the native taskbar' {
    if (Set-TaskbarAutoHide -Enabled $false) { Step-Ok 'Native taskbar auto-hide turned off' }
    else { Step-Ok 'Native taskbar was already not set to auto-hide' }
}
Invoke-ActivationRevert 'Revert Windows hardening (HKCU)' {
    $n = Set-WindowsHardening -Revert
    Step-Ok "Windows hardening reverted ($n setting(s) removed, handed back to Windows' own defaults)"
}
Invoke-ActivationRevert "Restore Explorer's Startup app-launch delay" {
    Remove-StartupDelay
    Step-Ok 'Startup app-launch delay setting removed (Explorer falls back to its own ~10s default)'
}

# --- 3. Revert unconditional install.ps1 steps: shell profile, Defender exclusions ----
Write-Host "`n-- Revert shell profile / Defender exclusions --" -ForegroundColor Cyan
Invoke-ActivationRevert 'Remove the pwsh $PROFILE hook' { Remove-ShellProfile }
Invoke-ActivationRevert 'Remove Windows Defender exclusions' { Remove-DefenderExclusions }

# --- 4. Revert env vars -------------------------------------------------------------
Write-Host "`n-- Config environment variables --" -ForegroundColor Cyan
$komorebiConfigHome = Join-Path $Root 'config\komorebi'
$yasbConfigHome     = Join-Path $Root 'config\yasb'
Invoke-Step "Revert KOMOREBI_CONFIG_HOME / YASB_CONFIG_HOME (User scope, only where still pointing at this repo)" {
    # Only clear a var if it's still pointing at THIS repo -- if something else (a
    # newer winarchy run, a manual edit) already moved it elsewhere, that's not this
    # script's to touch. Matches the "last write wins, don't clobber a later write"
    # posture install.ps1's own NOTES already accept for these shared vars.
    if ([Environment]::GetEnvironmentVariable('KOMOREBI_CONFIG_HOME', 'User') -eq $komorebiConfigHome) {
        [Environment]::SetEnvironmentVariable('KOMOREBI_CONFIG_HOME', $null, 'User')
    }
    if ([Environment]::GetEnvironmentVariable('YASB_CONFIG_HOME', 'User') -eq $yasbConfigHome) {
        [Environment]::SetEnvironmentVariable('YASB_CONFIG_HOME', $null, 'User')
    }
} 'Env vars reverted'

# --- 5. Remove winget pins -----------------------------------------------------------
Invoke-Step "Remove winget pins for this repo's core (pinned) packages" {
    foreach ($row in ($wingetRows | Where-Object { $_.Version -ne 'latest' })) {
        winget pin remove --id $row.InstallId 2>$null | Out-Null
    }
} 'Winget pins removed'

# --- 6. Remove packages ---------------------------------------------------------------
Write-Host "`n-- Packages --" -ForegroundColor Cyan
foreach ($row in $wingetRows) {
    $id = $row.InstallId
    if ($Keep -contains $id) {
        Step-Info "$id -- kept (-Keep)"
        continue
    }
    if ($row.PreExisting -and -not $Force) {
        Step-Info "$id -- kept (versions.md marks this Pre-existing?; pass -Force to remove it anyway)"
        continue
    }
    Invoke-Step "Uninstall $id" {
        winget uninstall --id $id --exact --silent 2>$null | Out-Null
    } "$id uninstalled"
}

# --- 7. wallust binary -----------------------------------------------------------------
$wallustRow = $allRows | Where-Object { $_.InstallId -like '*wallust*' } | Select-Object -First 1
$wallustDir = Join-Path $Root 'tools\bin\wallust'
if ($wallustRow -and ($Keep -contains $wallustRow.InstallId)) {
    Step-Info "$($wallustRow.InstallId) -- kept (-Keep)"
} elseif (Test-Path $wallustDir) {
    Invoke-Step "Remove downloaded wallust binary ($wallustDir)" {
        Remove-Item -Recurse -Force $wallustDir
    } 'wallust binary removed'
} else {
    Step-Info "No wallust binary to remove"
}

# --- 8. PSFzf module ----------------------------------------------------------------------
$psfzfRow = $allRows | Where-Object { $_.InstallId -eq 'PSFzf' } | Select-Object -First 1
if ($Keep -contains 'PSFzf') {
    Step-Info "PSFzf -- kept (-Keep)"
} elseif ($psfzfRow -and $psfzfRow.PreExisting -and -not $Force) {
    Step-Info "PSFzf -- kept (versions.md marks this Pre-existing?; pass -Force to remove it anyway)"
} elseif (Get-Module -ListAvailable PSFzf) {
    Invoke-Step "Uninstall PSFzf module" {
        Uninstall-Module PSFzf -AllVersions -Force -ErrorAction Stop
    } 'PSFzf module uninstalled'
} else {
    Step-Info "PSFzf not installed, nothing to remove"
}

# --- 9. Machine-local generated files --------------------------------------------------
# Gitignored, machine-local, always regenerable by install.ps1 -- safe to remove
# unconditionally, no Pre-existing? question applies (nothing here existed before this
# repo did, and it's config data, not a package).
Invoke-Step "Remove machine-local generated files (display-index.local.json, komorebi.json)" {
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Root 'config\komorebi\display-index.local.json')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Root 'config\komorebi\komorebi.json')
} 'Machine-local generated files removed'

Write-Host ''
if ($DryRun) {
    Step-Info 'DRY RUN complete: nothing was changed. Re-run without -DryRun to apply.'
} else {
    Step-Ok 'Uninstall complete. The repo itself (config/, tools/, this script) was left in place -- delete the folder yourself if you want it gone too.'
}
