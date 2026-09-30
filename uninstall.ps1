#Requires -Version 7.0
<#
.SYNOPSIS
  Clean uninstall of 710.DesktopRice.

.DESCRIPTION
  Stops every process 710.DesktopRice may have started (komorebi, YASB, ShareX, AHK, and a
  retired window-slots daemon if one is still running) regardless of whether -Activate was
  ever used, then reverts
  everything install.ps1 -Activate touches (autostart Scheduled Tasks, native-taskbar
  auto-hide, HKCU registry hardening, Explorer's Startup-delay, and the retired lock-screen
  sync task and its policy key if a machine from before 2026-09-28 still has them),
  everything install.ps1 applies unconditionally (the pwsh $PROFILE hook, Windows Defender
  exclusions, the desktop wallpaper, your lock-screen picture, Windows accent
  color/dark-mode, Windows Terminal's colorScheme/theme/default shell, Flow Launcher's
  ActionKeyword merge/identity toggles/Everything plugin), the env vars, the `710sRice`
  command's user-PATH entry (<repo>\bin, only that exact entry) and winget pins
  install.ps1 sets, then removes the packages this repo's own install.ps1 installs --
  EXCEPT any row versions.md marks Pre-existing? = yes, which is left alone unless you
  pass -Force, and the `system` rows (PowerShell 7, Windows Terminal), which it never
  removes, -Force included (see versions.md for what that column means). A Pre-existing?
  value that isn't yes / no / system stops the uninstall before it changes anything.
  -Keep <Install ID> protects additional specific packages beyond whatever versions.md
  already protects.

  A genuine before-710.DesktopRice restore, not just a removal of what this repo added:
  the wallpaper, lock screen, accent color and Windows Terminal settings are restored to
  their exact real prior values (snapshotted once, the first time each was ever about to
  change -- see tools\lib\activation.ps1's "Original-state snapshots" section), not reset
  to some assumed default and not left as whatever this repo last set them to.

  Never touches the repo itself (config/, tools/, this script) or anything outside what
  install.ps1 itself touches -- delete the folder yourself if you want it gone too. Does
  not remove config/windows.toml (your saved window-slot preferences) or the wallust-
  generated palette files under config/wallust/generated/ -- those are your data/output,
  not install state.

.NOTES
  winarchy's own uninstall.ps1 never stops a running process, never reverts autostart, the
  taskbar, hardening, or the Startup delay, and never restores wallpaper/accent/Terminal/
  Flow settings either -- a machine it "uninstalled" from could still have komorebi/YASB/
  AHK running and autostarting at next logon, with every cosmetic change left behind
  permanently. This script closes both gaps: stopping is unconditional (first thing, every
  run, regardless of whether this machine ever used -Activate), every -Activate-gated
  setting install.ps1 can apply is reverted here to match whether or not -Activate was
  ever actually used, and every real Windows setting install.ps1/tools\apply-wallust-
  outputs.ps1 change gets its exact prior value put back rather than just being abandoned
  (each revert is itself idempotent/self-detecting -- reverting a setting that was never
  applied, or restoring a snapshot that was never taken, is a safe no-op, same as
  install.ps1's own steps being safe to re-run).

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

# -Keep A,B: typed at a PS7 prompt that's already two values, but through the 710sRice command
# (its shim, and its admin relaunch -- both `pwsh -File`) it arrives as ONE string 'A,B', which
# would protect nothing. Winget IDs never contain a comma, so split every value on them.
$Keep = @($Keep | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

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
# versions.md's table (Get-VersionsTable) and the winget helpers -- exit codes,
# Format-WingetCode, Invoke-WingetAsUser -- shared with install.ps1 (after activation.ps1).
. (Join-Path $Root 'tools\lib\packages.ps1')

Write-Host "`n== 710.DesktopRice uninstall ==" -ForegroundColor Cyan
if ($DryRun) { Step-Info "DRY RUN: nothing will be changed." }

$versionsPath = Join-Path $Root 'versions.md'
$allRows = @(Get-VersionsTable -Path $versionsPath)
if ($allRows.Count -eq 0) {
    Step-Warn "Could not read versions.md (or it has no table rows) -- package removal will be skipped entirely, to avoid guessing what's safe to remove. Env vars and pins will still be reverted."
}
$wingetRows = @($allRows | Where-Object { Test-WingetRow $_ })   # winget + msstore rows

# --- 1. Stop any running 710.DesktopRice processes -----------------------------------
# Unconditional -- regardless of whether -Activate/autostart was ever used on this
# machine, install.ps1 -Activate's own "start now" step (or a person starting things by
# hand) can leave komorebi/YASB/ShareX/AHK running. Stopped first, before any
# of the registry/task reverts below, so nothing is still actively re-asserting a setting
# (e.g. komorebi re-hiding a taskbar border) while it's being undone.
Write-Host "`n-- Stop running processes --" -ForegroundColor Cyan
Invoke-ActivationRevert "Stop any running 710.DesktopRice processes (komorebi, YASB, ShareX, AHK)" {
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
Invoke-ActivationRevert 'Remove the retired lock-screen sync task and its policy key' {
    # Only a machine from before 2026-09-28 has them; your lock-screen picture itself is put
    # back in section 3, after the hardening revert below.
    if (-not (Remove-RetiredLockScreenSync)) { Step-Info 'No old lock-screen sync task or policy key on this machine.' }
}
# Snapshot tray-icon promotions before either kill below -- see Backup-TrayIconPromotions
# in tools\lib\activation.ps1 for why. Skipped under -DryRun (neither kill happens, so
# there's nothing to protect and nothing to restore).
$trayIconBackup = $null
if (-not $DryRun) { $trayIconBackup = Backup-TrayIconPromotions }

# Both only change settings; Explorer is restarted ONCE below if either did (see
# Restart-Explorer in tools\lib\activation.ps1 -- two back-to-back restarts left the
# desktop blank). $script: because Invoke-ActivationRevert runs these in a child scope.
$script:needExplorerRestart = $false
Invoke-ActivationRevert 'Un-hide the native taskbar' {
    if (Set-TaskbarAutoHide -Enabled $false) { Step-Ok 'Native taskbar auto-hide turned off'; $script:needExplorerRestart = $true }
    else { Step-Ok 'Native taskbar was already not set to auto-hide' }
}
Invoke-ActivationRevert 'Revert Windows hardening (HKCU)' {
    $n = Set-WindowsHardening -Revert
    Step-Ok "Windows hardening reverted ($n setting(s) removed, handed back to Windows' own defaults)"
    if ($n -gt 0) { $script:needExplorerRestart = $true }
}

if (-not $DryRun) {
    if ($script:needExplorerRestart) {
        if (Restart-Explorer) { Step-Ok 'Explorer restarted once to apply the taskbar/hardening changes' }
        else { Step-Warn "Explorer didn't come back after its restart -- sign out and back in (Ctrl+Alt+Del) to get the desktop back." }
    }
    Restore-TrayIconPromotions -BackupFile $trayIconBackup
}
Invoke-ActivationRevert "Restore Explorer's Startup app-launch delay" {
    Remove-StartupDelay
    Step-Ok 'Startup app-launch delay setting removed (Explorer falls back to its own ~10s default)'
}

# --- 3. Revert unconditional install.ps1 steps: shell profile, Defender exclusions,
#        wallpaper/accent/Terminal/Flow theming ----------------------------------------
# All of Section 4/8/9's effects below are also unconditional -- install.ps1 reaches them
# whether or not -Activate was used -- so, like the shell profile hook and Defender
# exclusions, they're reverted here regardless of -Activate history. Each Restore-*
# function (tools\lib\activation.ps1) is its own safe no-op if the thing it covers was
# never actually snapshotted on this machine (see that file's "Original-state snapshots"
# section header for the full design).
Write-Host "`n-- Revert shell profile / Defender exclusions --" -ForegroundColor Cyan
Invoke-ActivationRevert 'Remove the pwsh $PROFILE hook' { Remove-ShellProfile }
Invoke-ActivationRevert 'Remove Windows Defender exclusions' { Remove-DefenderExclusions }

Write-Host "`n-- Revert wallpaper / lock screen / accent color / Windows Terminal / Flow Launcher --" -ForegroundColor Cyan
Invoke-ActivationRevert 'Restore original desktop wallpaper' {
    if (Restore-OriginalWallpaper) { Step-Ok 'Desktop wallpaper restored to whatever it was before this repo ever set a default' }
    else { Step-Info 'This repo never actually changed the wallpaper on this machine (already using one of its own) -- nothing to restore.' }
}
# After section 2's hardening revert: Restore-LockScreenPicture writes back the Spotlight /
# Slideshow settings from before 710sRice, and hardening's revert must not undo them.
Invoke-ActivationRevert 'Restore original lock-screen picture' {
    switch (Restore-LockScreenPicture) {
        'restored' { Step-Ok 'Lock-screen picture restored to what it was before this repo ever set it' }
        'default'  { Step-Ok "Lock screen set to Windows' own default picture -- the one you had before is gone" }
        'failed'   { Step-Warn 'Lock-screen picture not put back -- pick one in Settings > Personalization > Lock screen.' }
        default    { Step-Info 'This repo never set the lock screen on this machine -- nothing to restore.' }
    }
}
Invoke-ActivationRevert 'Restore original Windows accent color / dark-mode settings' {
    if (Restore-WindowsAccent) { Step-Ok 'Windows accent color and light/dark-mode settings restored' }
    else { Step-Info 'tools\apply-wallust-outputs.ps1 never actually ran on this machine -- nothing to restore.' }
}
Invoke-ActivationRevert 'Restore original Windows Terminal colorScheme / theme / default shell' {
    if (Restore-WindowsTerminalSettings) { Step-Ok 'Windows Terminal settings restored' }
    else { Step-Info 'Windows Terminal was never actually themed or had its default shell changed on this machine -- nothing to restore.' }
}
Invoke-ActivationRevert 'Restore original Flow Launcher settings + remove the Everything plugin' {
    if (Restore-FlowLauncherSettings) { Step-Ok 'Flow Launcher settings restored (keywords, identity, Explorer file search) and any legacy Everything plugin removed' }
    else { Step-Info 'setup-flow-launcher.ps1 never actually changed anything on this machine -- nothing to restore.' }
}
Invoke-ActivationRevert 'Restore Flow Launcher''s own theme (Palette Profiles themed it)' {
    if (Restore-FlowTheme) { Step-Ok "Flow Launcher's theme put back and 710sRice.xaml removed" }
    else { Step-Info 'Flow Launcher was never themed by the palette -- nothing to restore.' }
}

# --- 4. Revert env vars -------------------------------------------------------------
Write-Host "`n-- Config environment variables --" -ForegroundColor Cyan
$komorebiConfigHome = Join-Path $Root 'config\komorebi'
$yasbConfigHome     = Join-Path $Root 'config\yasb'
Invoke-Step "Revert KOMOREBI_CONFIG_HOME / YASB_CONFIG_HOME / DESKTOPRICE_HOME (User scope, only where still pointing at this repo)" {
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
    if ([Environment]::GetEnvironmentVariable('DESKTOPRICE_HOME', 'User') -eq $Root) {
        [Environment]::SetEnvironmentVariable('DESKTOPRICE_HOME', $null, 'User')
    }
} 'Env vars reverted'

# The 710sRice command: only this clone's bin\ comes off the user PATH; every other entry is
# written back exactly as stored (Remove-UserPathEntry). Reports its own result line, hence
# Invoke-ActivationRevert (same -DryRun gate, no extra "done" line) rather than Invoke-Step.
$riceBin = Join-Path $Root 'bin'
Invoke-ActivationRevert "Remove $(ConvertTo-SafePath $riceBin) from your user PATH (the 710sRice command)" {
    if (Remove-UserPathEntry -Dir $riceBin) {
        Step-Ok "710sRice command: $(ConvertTo-SafePath $riceBin) removed from your PATH"
    } else {
        Step-Info "710sRice command: wasn't on your PATH"
    }
}

# --- 5. Remove winget pins -----------------------------------------------------------
Invoke-Step "Remove winget pins for this repo's core (pinned) packages" {
    # Every exit code checked: this step used to discard winget's output AND its exit
    # code, so it said "removed" no matter what. "No pin for that package" counts as
    # done -- the goal is no pin, however we got there.
    $failed = @()
    foreach ($row in ($wingetRows | Where-Object { Test-PinnedRow $_ })) {
        $pinArgs = @('pin', 'remove', '--id', $row.InstallId, '--exact') + @(Get-WingetSourceArgs $row)
        winget @pinArgs 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $WingetNoPin) {
            $failed += "$($row.InstallId) ($(Format-WingetCode $LASTEXITCODE))"
        }
    }
    if ($failed) { throw "winget couldn't remove the pin for: $($failed -join ', ') -- 'winget pin list' shows what's left" }
} 'Winget pins removed'

# --- 6. Remove packages ---------------------------------------------------------------
Write-Host "`n-- Packages --" -ForegroundColor Cyan
foreach ($row in $wingetRows) {
    $id = $row.InstallId
    if ($row.System) {
        # versions.md's `system` rows (PowerShell 7 -- this very uninstall runs on it, and a
        # fresh install needs it first -- and Windows Terminal, part of Windows 11): installed
        # if missing, never removed here, -Force included (user, 2026-09-30: "Keep both, always").
        Step-Info "$($row.Component) -- kept (versions.md marks it system: never removed by uninstall, -Force included). To remove it anyway: Settings > Apps > Installed apps."
        continue
    }
    if ($Keep -contains $id) {
        Step-Info "$id -- kept (-Keep)"
        continue
    }
    if ($row.PreExisting -and -not $Force) {
        Step-Info "$id -- kept (versions.md marks this Pre-existing?; pass -Force to remove it anyway)"
        continue
    }
    if ($DryRun) { Write-Host "  [ ] Uninstall $id"; continue }
    # Not Invoke-Step: the result line depends on winget's exit code (this used to discard
    # it and print "uninstalled" regardless -- Flow Launcher was never actually removed).
    try {
        $uninstallArgs = @('uninstall', '--id', $id, '--exact', '--silent', '--disable-interactivity') + @(Get-WingetSourceArgs $row)
        winget @uninstallArgs 2>$null | Out-Null
        $code = $LASTEXITCODE
        $how  = ''
        if ($code -eq $WingetAdminProhibited) {
            # Installed for this user only -- winget won't remove it from an elevated shell.
            Step-Info "$id is installed for this user only -- removing it un-elevated ..."
            $code = Invoke-WingetAsUser -Arguments $uninstallArgs
            $how  = ' (un-elevated)'
        }
        if ($null -eq $code)                  { Step-Warn "$id -- the un-elevated uninstall was still running after 3 minutes; check 'winget list --id $id' once it's done" }
        elseif ($code -eq 0)                  { Step-Ok "$id uninstalled$how" }
        elseif ($code -eq $WingetNotInstalled) { Step-Info "$id -- not installed, nothing to remove" }
        else                                  { Step-Warn "$id -- winget uninstall failed$how (exit $(Format-WingetCode $code)); 'winget uninstall --id $id' by hand shows why" }
    }
    catch { Step-Warn "Uninstall $($id): $($_.Exception.Message)" }
}

# --- 7. wallust binary -----------------------------------------------------------------
$wallustRow = $allRows | Where-Object { $_.InstallId -like '*wallust*' } | Select-Object -First 1
$wallustDir = Join-Path $Root 'tools\bin\wallust'
if ($wallustRow -and $wallustRow.System) {
    Step-Info "wallust -- kept (versions.md marks it system: never removed by uninstall)"
} elseif ($wallustRow -and ($Keep -contains $wallustRow.InstallId)) {
    Step-Info "$($wallustRow.InstallId) -- kept (-Keep)"
} elseif (Test-Path $wallustDir) {
    Invoke-Step "Remove downloaded wallust binary (tools\bin\wallust)" {
        Remove-Item -Recurse -Force $wallustDir
    } 'wallust binary removed'
} else {
    Step-Info "No wallust binary to remove"
}

# --- 8. PSFzf module ----------------------------------------------------------------------
$psfzfRow = $allRows | Where-Object { $_.InstallId -eq 'PSFzf' } | Select-Object -First 1
if ($psfzfRow -and $psfzfRow.System) {
    Step-Info "PSFzf -- kept (versions.md marks it system: never removed by uninstall)"
} elseif ($Keep -contains 'PSFzf') {
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
Invoke-Step "Remove machine-local generated files (display-index.local.json, komorebi.json, wallust.toml, menu-colors.css, tiling-mode.txt, the palette-profile choice, the palette editor's scratch folder)" {
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Root 'config\komorebi\display-index.local.json')
    # The remembered elevated/non-elevated tiling choice -- uninstall forgets it, so a
    # fresh install starts from the default again (plan doc Open item 37).
    Remove-Item -Force -ErrorAction SilentlyContinue (Get-TilingModePath)
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Root 'config\komorebi\komorebi.json')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Root 'config\wallust\wallust.toml')
    # Palette Profiles: the menus' colours file, and which profile is chosen (forgotten like the
    # tiling mode -- a fresh install starts on Default) plus how the last theme run went. The
    # profiles themselves are YOURS and stay (below).
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Root 'config\ahk\menu-colors.css')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA '710.DesktopRice\palette-profile.txt')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA '710.DesktopRice\palette-status.json')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA '710.DesktopRice\theme-inputs.sha256')
    # How the last lock-screen set went (tools\lib\lockscreen.ps1's record, doctor's).
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA '710.DesktopRice\lockscreen.json')
    # The palette editor's own wallust config and its last preview palette.
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA '710.DesktopRice\palette-editor')
} 'Machine-local generated files removed'

# Your palette profiles and scheme files are user data, like rules.local.toml and user.ahk:
# left in place (a reinstall finds them in the menu again), and said so.
$yourProfiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'config\palettes') -Filter 'profile*.json' -File -ErrorAction SilentlyContinue)
$yourSchemes  = @(Get-ChildItem -LiteralPath (Join-Path $Root 'config\palettes\schemes') -File -ErrorAction SilentlyContinue)
if ($yourProfiles.Count -or $yourSchemes.Count) {
    Step-Info "Your palette profiles ($($yourProfiles.Count)) and scheme files ($($yourSchemes.Count)) in config\palettes are left in place -- they're yours; delete them if you want them gone."
}

# --- 10. Original-state snapshot folder --------------------------------------------------
# Each Restore-* function above already deletes its own snapshot file once it's actually
# used one; this just cleans up the (should now be empty) folder itself, and any snapshot
# that was never consumed (e.g. Restore-LockScreenPolicy skipped because this shell wasn't
# elevated) so a future re-install snapshots fresh state again rather than restoring an
# increasingly stale one. -Force -ErrorAction SilentlyContinue rather than checking
# "empty first": a leftover unconsumed snapshot is still safe to just delete here, since
# its only purpose was this uninstall run.
Invoke-Step "Remove original-state snapshot folder" {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA '710.DesktopRice\original-state')
} 'Original-state snapshot folder removed'

Write-Host ''
if ($DryRun) {
    Step-Info 'DRY RUN complete: nothing was changed. Re-run without -DryRun to apply.'
} else {
    Step-Ok 'Uninstall complete. The repo itself (config/, tools/, this script) was left in place -- delete the folder yourself if you want it gone too.'
}
