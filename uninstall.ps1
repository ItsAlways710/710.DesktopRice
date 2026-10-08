#Requires -Version 7.0
<#
.SYNOPSIS
  Clean uninstall of 710.DesktopRice.

.DESCRIPTION
  Stops every process 710.DesktopRice may have started (komorebi, YASB, ShareX, AHK; Flow
  Launcher is stopped by its own revert, below) regardless of whether -Activate was
  ever used, then reverts
  everything install.ps1 -Activate touches (autostart Scheduled Tasks, native-taskbar
  auto-hide, HKCU registry hardening, Explorer's Startup-delay, and the retired lock-screen
  sync task and its policy key if a machine from before 2026-09-28 still has them),
  everything install.ps1 applies unconditionally (the pwsh $PROFILE hook, Windows Defender
  exclusions, the desktop wallpaper, your lock-screen picture, Windows accent
  color/dark-mode, Windows Terminal's colorScheme/theme/default shell, Flow Launcher's
  theme, and each component's own changes -- tools\components\: Flow Launcher's keywords,
  identity toggles, query box and its own sign-in start), the env vars, the `710sRice`
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
  change -- see tools\lib\snapshots.ps1's "Original-state snapshots" section), not reset
  to some assumed default and not left as whatever this repo last set them to. So are
  full time's taskbar auto-hide, hardening values and Startup delay, from the copy
  `710sRice activate` (or install -Activate) saves when a machine goes full-time
  (Restore-FullTimeWindowsSettings, shared with `710sRice deactivate`); a machine made
  full-time before 710sRice saved one has them deleted instead, back to Windows' defaults,
  and an on-demand machine's are left alone -- 710sRice never changed them there.

  Last, it deletes 710sRice's own folder, %LOCALAPPDATA%\710.DesktopRice: the logs and
  what's left of its state there.

  Never touches the repo itself (config/, tools/, this script) or anything outside what
  install.ps1 itself touches -- delete the folder yourself if you want it gone too. Does
  not remove the wallust-generated palette files under config/wallust/generated/ -- those
  are your data/output, not install state.

.NOTES
  winarchy's own uninstall.ps1 never stops a running process, never reverts autostart, the
  taskbar, hardening, or the Startup delay, and never restores wallpaper/accent/Terminal/
  Flow settings either -- a machine it "uninstalled" from could still have komorebi/YASB/
  AHK running and autostarting at next logon, with every cosmetic change left behind
  permanently. This script closes both gaps: stopping is unconditional (first thing, every
  run, regardless of whether this machine ever used -Activate), and every real Windows
  setting install.ps1 / tools\apply-wallust-outputs.ps1 / full time change gets its exact
  prior value put back rather than just being abandoned -- and only those: a setting
  710sRice never changed here is left as it is (restoring a snapshot that was never taken is
  a no-op, same as install.ps1's own steps being safe to re-run).

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

# PATH as a new window would get it (Machine + User, from the registry): a window opened before
# the install has none of the stack's folders on its PATH, and the stop below needs komorebic /
# yasbc (winarchy ca66652, Group 1 W6; they're also looked for next to their apps now).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

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
    # Same -DryRun gate as Invoke-Step, but for the functions tools\lib\activation.ps1 loads
    # below -- those already report their own Step-Ok/Step-Warn per setting/component (see
    # e.g. Set-WindowsHardening, Register-Autostart), so this doesn't also print a
    # redundant "Done" line the way Invoke-Step's $Done parameter would.
    param([string]$Describe, [scriptblock]$Action)
    if ($DryRun) { Write-Host "  [ ] $Describe"; return }
    try { & $Action } catch { Step-Warn "$($Describe): $($_.Exception.Message)" }
}

# The libraries and the steps' modules (tools\lib\activation.ps1 loads them all), shared
# with install.ps1. Step-Ok/Info/Warn above must be defined before this dot-source -- the
# libraries use ours rather than their own copies.
. (Join-Path $Root 'tools\lib\activation.ps1')

Write-Host "`n== 710.DesktopRice uninstall ==" -ForegroundColor Cyan
if ($DryRun) { Step-Info "DRY RUN: nothing will be changed." }

# The components (tools\components\<id>.ps1, Group 1 #12; activation.ps1 loaded the loader),
# read before anything changes: a broken component file stops the uninstall here, not halfway.
# Their context is taken now too -- FullTime reads the sign-in tasks, which section 2 deletes.
try {
    $RiceComponents = @(Get-RiceComponents)
    $ComponentCtx = New-RiceComponentContext -DryRun ([bool]$DryRun)
} catch {
    Write-Host "  [XX] $($_.Exception.Message) -- nothing was changed." -ForegroundColor Red
    exit 1
}

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
# Autostart is removed unconditionally (removing a task that isn't there is a no-op). The
# Windows settings are only put back where 710sRice changed them -- see below. winarchy's own
# uninstall.ps1 does none of this at all.
Write-Host "`n-- Revert autostart / taskbar / hardening / Startup delay --" -ForegroundColor Cyan
Invoke-ActivationRevert 'Unregister autostart (Scheduled Tasks + Startup fallback shortcuts)' {
    Unregister-Autostart
    Step-Ok 'Autostart unregistered'
}
Invoke-ActivationRevert 'Remove the retired lock-screen sync task and its policy key' { Undo-LockScreenSync }
# Taskbar auto-hide, the hardening values and the Startup delay: put back as they were before
# this machine went full-time, from the copy `710sRice activate` (or install -Activate) saved.
# No copy on a full-time machine (made full-time before 710sRice saved one): deleted -- auto-hide
# off, each value removed, which hands it to Windows' own default (what this section always
# did). No copy on an on-demand machine: left alone -- 710sRice never changed them there, so
# they're yours or Windows' (the mode is the one read at the top, before the tasks went). One
# Explorer restart if anything changed, the tray icons' choices kept around it
# (Restore-FullTimeWindowsSettings in tools\lib\fulltime.ps1, shared with `710sRice
# deactivate`). It prints its own lines, its -DryRun ones included; section 10 deletes the copy.
try { Restore-FullTimeWindowsSettings -DryRun:$DryRun -FullTime $ComponentCtx.FullTime }
catch { Step-Warn "Put back the taskbar / Windows settings / Startup delay: $($_.Exception.Message)" }

# --- 3. Revert unconditional install.ps1 steps: shell profile,
#        wallpaper/accent/Terminal/Flow theming ----------------------------------------
# All of Section 4/8/9's effects below are also unconditional -- install.ps1 reaches them
# whether or not -Activate was used -- so, like the shell profile hook, they're reverted
# here regardless of -Activate history. Each Restore-* function is its own safe no-op if
# the thing it covers was never actually snapshotted on this machine (see
# tools\lib\snapshots.ps1, "Original-state snapshots", for the full design). Windows Terminal
# and Defender's exclusions are components (tools\components\), reverted below.
Write-Host "`n-- Revert shell profile --" -ForegroundColor Cyan
Invoke-ActivationRevert 'Remove the pwsh $PROFILE hook' { Remove-ShellProfile }

# The theme's reverts: tools\steps\theme.ps1; the lock screen's: tools\lib\lockscreen.ps1.
Write-Host "`n-- Revert wallpaper / lock screen / accent color / Flow Launcher --" -ForegroundColor Cyan
Invoke-ActivationRevert 'Restore original desktop wallpaper' { Undo-Wallpaper }
# After section 2's hardening revert: Restore-LockScreenPicture writes back the Spotlight /
# Slideshow settings from before 710sRice, and hardening's revert must not undo them.
Invoke-ActivationRevert 'Restore original lock-screen picture' { Undo-LockScreenPicture -WasFullTime $ComponentCtx.FullTime }
Invoke-ActivationRevert 'Restore original Windows accent color / dark-mode settings' { Undo-WindowsAccent }
Invoke-ActivationRevert 'Restore Flow Launcher''s own theme (Palette Profiles themed it)' { Undo-FlowTheme }

# Each component's own revert (its Uninstall: restore from its snapshots, remove what it
# added), the last one install runs first -- before the env vars and packages below go, like
# the restores above. Each through Invoke-ActivationRevert: -DryRun lists it, a failure never
# stops the rest.
$componentReverts = @($RiceComponents | Where-Object { $_.Uninstall })
if ($componentReverts.Count) {
    Write-Host "`n-- Revert components --" -ForegroundColor Cyan
    $componentOrder = @(Get-RiceStepOrder)
    foreach ($component in @($componentReverts | Sort-Object { $componentOrder.IndexOf($_.Id) } -Descending)) {
        Invoke-ActivationRevert "Revert $($component.Label)" { Invoke-RiceComponentPart -Component $component -Part Uninstall -Ctx $ComponentCtx }
    }
}

# --- 4. Revert env vars -------------------------------------------------------------
Write-Host "`n-- Config environment variables --" -ForegroundColor Cyan
Invoke-Step "Revert KOMOREBI_CONFIG_HOME / YASB_CONFIG_HOME / DESKTOPRICE_HOME (User scope, only where still pointing at this repo)" { Undo-ConfigEnvVars } 'Env vars reverted'
# The old weather widget's variables (Group 1 #1: unused since the bar's weather moved to
# Open-Meteo) -- install's envvars step removes them too; whatever is still there goes.
$oldWeather = @('YASB_WEATHER_API_KEY', 'YASB_WEATHER_LOCATION' | Where-Object { Get-UserEnvVar $_ })
if ($oldWeather.Count) {
    Invoke-Step "Remove the old weather variables ($($oldWeather -join ', '))" {
        foreach ($name in $oldWeather) { Remove-UserEnvVar $name }
    } "Old weather variables removed ($($oldWeather -join ', '))"
}

# The 710sRice command: only this clone's bin\ comes off the user PATH; every other entry is
# written back exactly as stored (Remove-UserPathEntry). Reports its own result line, hence
# Invoke-ActivationRevert (same -DryRun gate, no extra "done" line) rather than Invoke-Step.
$riceBin = Join-Path $Root 'bin'
Invoke-ActivationRevert "Remove $(ConvertTo-SafePath $riceBin) from your user PATH (the 710sRice command)" { Undo-RiceCommandPath -RiceBin $riceBin }

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
    if ($id -like '*NerdFont*') {
        # The font goes: no Windows Terminal profile may still name it (Clear-TerminalNerdFontFaces,
        # tools\lib\terminal.ps1), and it goes through Windows Installer told to close nothing
        # (Invoke-MsiUninstall, tools\lib\msi.ps1) -- winget's silent uninstall had Restart
        # Manager shut down the Terminal running this very uninstall (B2 and T5, 2026-10-01).
        if ($DryRun) { Write-Host "  [ ] Point any Windows Terminal profile still on the Nerd Font back to Terminal's own font" }
        else {
            try {
                $moved = @(Clear-TerminalNerdFontFaces)
                if ($moved.Count) {
                    Step-Ok "Windows Terminal: $($moved -join ', ') still used the JetBrainsMono Nerd Font -- back to Terminal's own font before it's removed"
                    Start-Sleep -Seconds 2   # Terminal re-reads its settings by itself; let it, before the font goes
                }
            } catch { Step-Warn "Windows Terminal's font couldn't be checked before removing the Nerd Font: $($_.Exception.Message)" }
        }
    }
    if ($DryRun) { Write-Host "  [ ] Uninstall $id"; continue }
    if ($id -like '*NerdFont*') {
        $msi = $null
        try { $msi = Get-MsiProductCode -DisplayName '^JetBrainsMono Nerd Font' } catch { }
        if ($msi) {
            try {
                $code = Invoke-MsiUninstall -ProductCode $msi
                if ($code -eq 0)        { Step-Ok "$id uninstalled (Windows Installer, closing nothing)" }
                elseif ($code -eq 3010) { Step-Ok "$id uninstalled (Windows Installer, closing nothing) -- a program still had the font open (this Windows Terminal, likely), so its files go at your next restart: restart before installing 710sRice again" }
                elseif ($code -eq 1605) { Step-Info "$id -- not installed, nothing to remove" }
                else                    { Step-Warn "$id -- Windows Installer couldn't remove it (exit $code); 'winget uninstall --id $id' by hand shows why (it may close Windows Terminal)" }
            } catch { Step-Warn "Uninstall $($id): $($_.Exception.Message)" }
            continue
        }
        # No Windows Installer entry for it (installed some other way, or not at all): winget, below.
    }
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

# --- 8. PowerShell modules (versions.md's psgallery rows: PSFzf, DisplayConfig) -----------
# Until 2026-10-05 this named PSFzf; every psgallery row now goes through the same questions.
foreach ($moduleRow in @($allRows | Where-Object { $_.Source -eq 'psgallery' })) {
    $module = $moduleRow.InstallId
    if ($moduleRow.System) {
        Step-Info "$module -- kept (versions.md marks it system: never removed by uninstall)"
    } elseif ($Keep -contains $module) {
        Step-Info "$module -- kept (-Keep)"
    } elseif ($moduleRow.PreExisting -and -not $Force) {
        Step-Info "$module -- kept (versions.md marks this Pre-existing?; pass -Force to remove it anyway)"
    } elseif (Get-Module -ListAvailable $module) {
        Invoke-Step "Uninstall $module module" {
            Uninstall-Module $module -AllVersions -Force -ErrorAction Stop
        } "$module module uninstalled"
    } else {
        Step-Info "$module not installed, nothing to remove"
    }
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
    # The Screens menu's snapshot and its last switch's result (tools\screens.ps1).
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA '710.DesktopRice\screens.tsv')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA '710.DesktopRice\screens-result.txt')
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

# --- 10. 710sRice's own folder, logs included -------------------------------------------
# %LOCALAPPDATA%\710.DesktopRice: the logs (`710sRice logs`), the launch records, what's left of
# the original-state snapshots and anything else 710sRice kept there. Each Restore-* function
# above already deletes its own snapshot once it has used it -- except full time's Windows
# settings (full-time-settings.json), which Restore-FullTimeWindowsSettings leaves for its
# caller on purpose -- and one never used (Restore-LockScreenPolicy skipped in a shell that
# wasn't elevated, say) would only go stale: a future install snapshots fresh state again. Last,
# so every step above can still write here. Until 2026-10-05 only the snapshot folder went and
# the logs stayed (the user's call, after reviewing Godzilla's uninstall). A file something
# still holds open stays, and is named as left.
Invoke-Step "Remove 710sRice's own folder (%LOCALAPPDATA%\710.DesktopRice: logs, snapshots, state)" {
    $own = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
    Remove-Item -LiteralPath $own -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $own) {
        $left = @(Get-ChildItem -LiteralPath $own -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        throw "in use, so left: $($left -join ', ') -- delete %LOCALAPPDATA%\710.DesktopRice after a restart"
    }
} "710sRice's own folder removed (%LOCALAPPDATA%\710.DesktopRice)"

Write-Host ''
if ($DryRun) {
    Step-Info 'DRY RUN complete: nothing was changed. Re-run without -DryRun to apply.'
} else {
    Step-Ok 'Uninstall complete. The repo itself (config/, tools/, this script) was left in place -- delete the folder yourself if you want it gone too.'
}
