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
  Windows Defender exclusions, the pwsh $PROFILE hook, and Flow Launcher's Everything
  plugin are applied unconditionally on every run (matching winarchy's own install.ps1 @
  4574fc7, tag v1.4.0 -- none of these are gated behind -Activate upstream either).

  -Activate registers autostart (Scheduled Tasks At-LogOn: komorebi, YASB, window-slots,
  ShareX, AHK), hides the native taskbar, applies HKCU-only Windows hardening (no Bing
  search / ad suggestions / Copilot-Widgets-TaskView buttons / Start recommendations),
  zeroes Explorer's Startup app-launch delay, and starts everything right away. Without
  -Activate, none of that happens -- packages, config, theming, Defender exclusions, the
  profile hook and Everything plugin are still applied, but nothing autostarts and the
  taskbar/hardening/Startup-delay registry settings are left alone. See "Next steps" at
  the end of a run for the exact command to (re)launch komorebi with this repo's config
  by hand instead.

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
  .\install.ps1 -Activate      # ...and autostart + hide taskbar + harden + start now
  .\install.ps1 -SkipPackages  # skip the winget loop; still does env vars / wallust /
                                # display-index / Flow setup / recompile
#>
[CmdletBinding()]
param(
    [switch]$Activate,
    [switch]$SkipPackages
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

function Step-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Step-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Step-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

# Defender exclusions, hardening, taskbar, autostart, and the shell-profile hook all live
# here, shared with uninstall.ps1's matching revert steps. Step-Ok/Info/Warn above must be
# defined before this dot-source -- activation.ps1 uses ours rather than its own copies.
. (Join-Path $Root 'tools\lib\activation.ps1')

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
    # Everything is the engine behind Flow's file search (SUPER+S: Explorer plugin on the
    # Everything index) -- the two are one system now, so it's pinned like Flow: updating
    # either should be a deliberate, tested step (user's call, 2026-09-23). Same versions
    # winarchy pins for both (versions.lock.toml @ 90fbdfe).
    'voidtools.Everything'        = '1.4.1.1032'
}
# Required, not pinned -- always installed at whatever winget currently offers.
# PowerShell 7 lives here, not in $CorePins: unpinned 2026-09-23 at the user's request so
# it can take its own updates (every script here only needs >= 7.0, and the autostart /
# lock-screen tasks launch it via the version-independent WindowsApps alias -- see
# tools\lib\activation.ps1's Get-PwshPath -- so an update can't break them).
$RequiredPackages = @(
    '9MZ1SNWT0N5D',   # PowerShell 7 -- msstore source, see $PackageSources below
    'ShareX.ShareX',
    'Microsoft.WindowsTerminal',
    'DEVCOM.JetBrainsMonoNerdFont',
    'Starship.Starship',
    'junegunn.fzf',
    'ajeetdsouza.zoxide',
    'eza-community.eza',
    'sharkdp.bat'
)
# Per-package winget source override. Every package above resolves through winget's
# default (community) source except PowerShell 7 -- Dell's own install is the Store/MSIX
# build, which lives in the msstore source, not the traditional MSI package under
# Microsoft.PowerShell (see versions.md's PowerShell 7 note for how that was confirmed).
# uninstall.ps1 keeps a matching copy of this table; if you add another msstore-sourced
# package here, add it there too.
$PackageSources = @{
    '9MZ1SNWT0N5D' = 'msstore'   # PowerShell 7
}

if (-not $SkipPackages) {
    Write-Host "`n-- Packages (winget) --" -ForegroundColor Cyan
    $allPackages = [ordered]@{}
    foreach ($id in $CorePins.Keys) { $allPackages[$id] = $CorePins[$id] }
    foreach ($id in $RequiredPackages) { if (-not $allPackages.Contains($id)) { $allPackages[$id] = $null } }

    foreach ($id in $allPackages.Keys) {
        $pinVersion = $allPackages[$id]
        $source = $PackageSources[$id]
        $listArgs = @('list', '--id', $id, '--exact', '--accept-source-agreements')
        if ($source) { $listArgs += @('--source', $source) }
        $listed = (winget @listArgs 2>$null) | Out-String
        $alreadyInstalled = $listed -match [regex]::Escape($id)
        if ($alreadyInstalled) {
            Step-Ok "$id already installed"
        } else {
            Step-Info "Installing $id ..."
            $wingetArgs = @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
            if ($pinVersion) { $wingetArgs += @('--version', $pinVersion) }
            if ($source) { $wingetArgs += @('--source', $source) }
            winget @wingetArgs
            if ($LASTEXITCODE -ne 0) {
                Step-Warn "winget install $id exited with code $LASTEXITCODE -- check the output above."
            }
        }
        if ($pinVersion) {
            $pinArgs = @('pin', 'add', '--id', $id)
            if ($source) { $pinArgs += @('--source', $source) }
            winget @pinArgs 2>$null | Out-Null
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

# --- 4. First-run default theme (wallpaper + lock screen) -----------------------------
# Only on a genuine first run: if the current desktop wallpaper is already one of this
# repo's own (assets\wallpapers\*), a previous install.ps1 run -- or the person themselves,
# picking a different one from that same folder -- already themed this machine; leave it
# alone rather than stomping a deliberate choice on every re-run. Otherwise, set
# assets\wallpapers\710Default001.png as the desktop wallpaper and run the exact same
# wallust + apply-wallust-outputs.ps1 pipeline YASB's Wallpapers widget runs on every real
# wallpaper change (see config\yasb\config.yaml's run_after) -- so komorebi borders, the
# Windows accent color, Windows Terminal, and (once -Activate registers its Scheduled Task
# a few sections down) the lock screen all end up themed to it too, via the one real
# code path rather than a second, parallel "first theme" implementation.
Write-Host "`n-- First-run default theme --" -ForegroundColor Cyan
$defaultWallpaper = Join-Path $Root 'assets\wallpapers\710Default001.png'
$wallpaperRepoDir = Join-Path $Root 'assets\wallpapers'
$currentWallpaper = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper' -ErrorAction SilentlyContinue).WallPaper

if ($currentWallpaper -and $currentWallpaper.StartsWith($wallpaperRepoDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    Step-Ok "Wallpaper already set from this repo's own set ($currentWallpaper) -- leaving it as-is."
} elseif (-not (Test-Path $defaultWallpaper)) {
    Step-Warn "Default wallpaper not found at $defaultWallpaper -- skipping first-run theme."
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
        Step-Ok "Default theme applied (komorebi borders, Windows accent, Windows Terminal, and the lock screen once -Activate registers its sync task)."
    } catch {
        Step-Warn "Could not apply the first-run default theme: $($_.Exception.Message)"
    }
}

# --- 5. Monitor identity (display_index_preferences) ----------------------------------
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

# --- 6. Windows Defender exclusions (unconditional) --------------------------------------
# Not gated behind -Activate -- matches winarchy's own install.ps1 exactly (Set-
# WinarchyDefenderExclusions runs unconditionally there too). Needs elevation; warns and
# skips (doesn't fail the install) if this shell isn't elevated -- see tools/lib/
# activation.ps1.
Write-Host "`n-- Windows Defender exclusions --" -ForegroundColor Cyan
Set-DefenderExclusions

# --- 7. Shell profile hook ($PROFILE -> config\pwsh\profile.ps1) -------------------------
# Also unconditional -- winarchy calls Install-WinarchyShellProfile in its own install.ps1
# outside the -Activate block too. Idempotent; snapshots the previous $PROFILE to a .bak
# alongside it before changing anything.
Write-Host "`n-- Shell profile ($PROFILE hook) --" -ForegroundColor Cyan
Install-ShellProfile

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
        Step-Warn "No PowerShell 7 profile found in Windows Terminal's settings.json yet -- open Terminal once (it generates this profile the first time it sees pwsh.exe on PATH), then re-run .\install.ps1."
    }
} else {
    Step-Warn 'Windows Terminal settings.json not found -- default shell not set (install/launch Windows Terminal first).'
}

# --- 9. Flow Launcher setup (settings + Everything plugin) -------------------------------
Write-Host "`n-- Flow Launcher --" -ForegroundColor Cyan
& (Join-Path $Root 'tools\setup-flow-launcher.ps1')
if ($LASTEXITCODE -ne 0) {
    Step-Info "Flow Launcher setup skipped this run (see message above) -- harmless if Flow hasn't been run yet; re-run .\install.ps1 after its first launch."
}

# --- 10. Recompile komorebi.json -----------------------------------------------------------
Write-Host "`n-- Compiling komorebi.json --" -ForegroundColor Cyan
& (Join-Path $Root 'tools\compile-komorebi-rules.ps1')

# --- 11. Activate: autostart, taskbar, hardening, Startup delay, start now (-Activate) ---
if ($Activate) {
    Write-Host "`n-- Activate --" -ForegroundColor Cyan

    Register-Autostart
    Register-LockScreenSyncTask
    # Fire it once right now rather than waiting for a future wallpaper change -- on a
    # fresh install, Section 4 already set the default wallpaper/theme before this task
    # existed to catch it, so without this the lock screen would stay unsynced until the
    # next real wallpaper change. Best-effort: if the task didn't register above (not
    # elevated, no pwsh), Test-Task is false and this is a silent no-op.
    if (Test-Task -TaskName 'lock-screen-sync') {
        & schtasks.exe /Run /TN (Get-TaskFullName -TaskName 'lock-screen-sync') *> $null
    }

    # Snapshot tray-icon promotions before either kill below -- Explorer's own forced
    # restart(s) can reset every app's "always show this icon" preference, not just this
    # repo's own (see Backup-TrayIconPromotions in tools\lib\activation.ps1). Restored
    # once both kills are done and Explorer's confirmed back up from the second one.
    $trayIconBackup = Backup-TrayIconPromotions

    try {
        if (Set-TaskbarAutoHide -Enabled $true) { Step-Ok 'Native taskbar set to auto-hide' }
        else { Step-Ok 'Native taskbar already set to auto-hide' }
    } catch { Step-Warn "Could not set the taskbar to auto-hide: $($_.Exception.Message)" }

    try {
        $n = Set-WindowsHardening
        Step-Ok "Windows hardening applied ($n setting(s) changed: no Bing search, ad suggestions, Copilot/Widgets/Task View buttons, Start recommendations)"
    } catch { Step-Warn "Could not apply Windows hardening: $($_.Exception.Message)" }

    Wait-ExplorerRunning
    Restore-TrayIconPromotions -BackupFile $trayIconBackup

    try {
        Set-StartupDelay
        Step-Ok 'Startup app-launch delay removed (StartupDelayInMSec=0)'
    } catch { Step-Warn "Could not remove the Startup app-launch delay: $($_.Exception.Message)" }

    Step-Info 'Starting services...'
    # Direct launcher invocation, not `komorebic start`/`yasbc start` -- the same
    # resilient scripts the Scheduled Tasks use, so "start now" and "start at next logon"
    # are one code path instead of two (komorebic start in particular is the flaky one;
    # see scripts/Start-Komorebi.ps1's own header for why).
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Get-KomorebiExe) {
        Start-Process $ps -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$Root\scripts\Start-Komorebi.ps1`""
        )
    }
    $yasbc = (Get-Command yasbc -ErrorAction SilentlyContinue)?.Source
    if ($yasbc) {
        Start-Process $ps -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$Root\scripts\Start-Yasb.ps1`"",
            '-YasbExe', "`"$yasbc`"", '-YasbConfigHome', "`"$Root\config\yasb`""
        )
    }
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if ((Get-KomorebiExe) -and $pwsh) {
        # window-slots needs real pwsh (PS7-only syntax -- see tools/lib/window-slots.ps1's
        # own `?.` usage) to even parse, so it can't be launched directly under the legacy
        # $ps host used above for komorebi/YASB. Same trampoline as the Scheduled Task
        # action in tools/lib/activation.ps1's Get-AutostartComponents: the hidden legacy
        # powershell.exe host just launches pwsh hidden in turn. Bug fix, not a new
        # pattern -- this immediate "start now" launch had drifted from the already-correct
        # Scheduled Task version and would otherwise crash on launch with a silent parse
        # error (nothing redirects this Start-Process call's output).
        $slots = Join-Path $Root 'scripts\Start-WindowSlots.ps1'
        $inner = "Start-Process -FilePath '$pwsh' -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$slots'"
        Start-Process $ps -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-Command', "`"$inner`""
        )
    }
    $sharexExe = Get-ShareXExe
    if ($sharexExe) { Start-Process $sharexExe -ArgumentList '-silent' }
    $ahkExe = Get-AhkExe
    if ($ahkExe) {
        Remove-Item Env:CLAUDE_CODE_CHILD_SESSION, Env:CLAUDECODE -ErrorAction SilentlyContinue
        Start-Process $ps -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$Root\scripts\Start-Ahk.ps1`"",
            '-AhkExe', "`"$ahkExe`"", '-ScriptPath', "`"$Root\config\ahk\710.ahk`""
        )
    }
    Step-Ok 'Services launching in the background (see %LOCALAPPDATA%\710.DesktopRice\*-autostart.log if one seems to not have come up).'
} else {
    # Migration path: if autostart was already active from a previous -Activate run,
    # re-register it so it picks up any change to how components are launched (e.g. a
    # newer launcher script) without switching modes. If it was never active
    # (coexistence-only), nothing is touched. Lock-screen sync follows the same idea,
    # tracked separately since it isn't one of Get-AutostartStatus's 5 components.
    $autostart = Get-AutostartStatus
    $lockScreenActive = Test-Task -TaskName 'lock-screen-sync'
    if ((@($autostart.Values | Where-Object { $_ }).Count -gt 0) -or $lockScreenActive) {
        Write-Host "`n-- Activate --" -ForegroundColor Cyan
        Step-Info 'Autostart is active: re-registering to pick up any startup changes...'
        Register-Autostart
        if ($lockScreenActive) { Register-LockScreenSyncTask }
    } else {
        Step-Info 'Not -Activate: packages/config/theming/Defender/profile/Flow are applied, but autostart, the taskbar, hardening and the Startup delay are untouched.'
        Step-Info 'Run .\install.ps1 -Activate when ready to make this repo the active shell experience.'
    }
}

# --- Done -----------------------------------------------------------------------------
Write-Host "`n== Install complete ==" -ForegroundColor Cyan
if (-not $Activate) {
    Write-Host "This run did not start or restart komorebi/YASB/AHK, or touch autostart/taskbar/hardening."
    Write-Host "To load this repo's config into a running komorebi by hand, in a NEW terminal (so it sees"
    Write-Host "the env vars just registered):"
    Write-Host ""
    Write-Host "    komorebic.exe stop" -ForegroundColor DarkGray
    Write-Host "    Start-Process komorebi.exe -WindowStyle Hidden -ArgumentList '--config',`"$Root\config\komorebi\komorebi.json`"" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Or re-run with -Activate to have this script do all of that (plus autostart) for you."
}
