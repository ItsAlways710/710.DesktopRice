<#
.SYNOPSIS
  Shared functions for install.ps1's unconditional steps and its -Activate block, and
  for uninstall.ps1's matching revert steps. Dot-sourced by both -- never run directly.

.DESCRIPTION
  Ported from winarchy (module/Winarchy/Private/Identity.ps1, Hardening.ps1, Taskbar.ps1,
  Autostart.ps1, ShellProfile.ps1, Util.ps1), pinned to origin/main @ 4574fc7 (tag v1.4.0)
  -- NOT Dell's local C:\winarchy checkout, which sat on an old, unpulled commit (cbae6a3)
  plus unrelated local edits and was missing several of these files entirely (Hardening.ps1,
  Taskbar.ps1 didn't exist on disk there at all). See claude/winarchy-decoupling-plan.md for
  the full verification trail.

  Callers (install.ps1 / uninstall.ps1) must already have Step-Ok / Step-Info / Step-Warn
  defined before dot-sourcing this file -- it uses theirs rather than defining its own, to
  avoid two competing copies in the same process.

  net-icon is deliberately NOT ported (see Get-AutostartComponents below and the plan doc):
  it's a different mechanism than our YASB systray's show_network, and with the taskbar
  hidden there's currently no network status shown either way regardless of which we'd pick.

  display_index_preferences (which screen is screen 1-4): install's monitors step keeps the
  stable map in config\komorebi\display-index.local.json (tools\write-display-index.ps1,
  rules in tools\lib\monitors.ps1) -- keyed by serial_number_id, which komorebi's own docs
  (multi-monitor-setup.md) recommend for this key, or the device_id when a screen has no serial
  or shares it. winarchy writes a live, device_id-keyed copy from its window-slots daemon
  instead; that daemon's port was dropped from this repo (Group 1 #7).
#>

# Your lock-screen picture: Invoke-LockScreenSetter and its record (install's tasks step and
# uninstall use them below; the wallpaper pipeline dot-sources the same file).
. (Join-Path $PSScriptRoot 'lockscreen.ps1')

# The components (tools\components\<id>.ps1, Group 1 #12): a component can declare its own
# sign-in task (its Autostart field), which Get-AutostartComponents below picks up. Only
# functions -- nothing is read until something asks.
if (-not (Get-Command Get-RiceComponents -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'components.ps1') }

# --- Paths as they get printed ------------------------------------------------------------
function ConvertTo-SafePath {
    # A path as it can be shown on screen: the user's own profile folders as %LOCALAPPDATA% /
    # %APPDATA% / %USERPROFILE%, never the Windows user name. The repo is public and output
    # gets pasted into issues -- install's and uninstall's lines, doctor's report, repair's
    # (which shows install's). Anything outside those folders comes back as it was.
    param([string]$Path)
    $out = "$Path"
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
        $dir = [Environment]::GetEnvironmentVariable($v)
        if ($dir -and $out.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { return "%$v%$($out.Substring($dir.Length))" }
    }
    $out
}

function ConvertTo-SafeText {
    # ConvertTo-SafePath for a whole message rather than one path: the user's profile folders
    # ANYWHERE in $Text become %LOCALAPPDATA% / %APPDATA% / %USERPROFILE%, written with either
    # slash -- git's messages use C:/Users/<name>/... ("detected dubious ownership in repository
    # at '...'"). The longer folders go first, so %LOCALAPPDATA% wins over %USERPROFILE%; a folder
    # only matches as a whole (C:\Users\bob never eats part of C:\Users\bobby).
    param([string]$Text)
    $out = "$Text"
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
        $dir = [Environment]::GetEnvironmentVariable($v)
        if (-not $dir) { continue }
        $dir = $dir.TrimEnd('\', '/')
        foreach ($form in @($dir, ($dir -replace '\\', '/')) | Select-Object -Unique) {
            $out = [regex]::Replace($out, "$([regex]::Escape($form))(?=[\\/'`"\s:;,)]|$)", "%$v%",
                                    [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }
    $out
}

# --- Registry backup (reg.exe export) -----------------------------------------------
function Backup-RegistryKey {
    <# Exports one registry key (reg.exe export format) to backups/<timestamp>-<label>/.
       Ported from winarchy's Backup-WinarchyRegistryKey (module/Winarchy/Private/Util.ps1
       @ 4574fc7). Returns the backup dir, or $null if the export failed (key didn't exist,
       reg.exe not on PATH, etc.) -- callers proceed either way, this is best-effort. #>
    param([Parameter(Mandatory)][string]$Key, [string]$Label = 'registry')
    $backupsDir = Join-Path $Root 'backups'
    if (-not (Test-Path $backupsDir)) { New-Item -ItemType Directory -Path $backupsDir -Force | Out-Null }
    $dest = Join-Path $backupsDir "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$Label"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $file = Join-Path $dest (($Key -replace '[\\:]', '_') + '.reg')
    $null = reg.exe export $Key $file /y 2>&1
    if ($LASTEXITCODE -ne 0) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue; return $null }
    $dest
}

# --- Tray-icon-promotion snapshot (around the Set-TaskbarAutoHide/Set-WindowsHardening
# double Explorer restart) --------------------------------------------------------------
function Backup-TrayIconPromotions {
    <# Snapshots HKCU\Control Panel\NotifyIconSettings -- Windows' own per-app "always
       show this tray icon" preference store -- via the same reg.exe export mechanism
       Backup-RegistryKey already uses elsewhere in this file. Set-TaskbarAutoHide and
       Set-WindowsHardening both force-restart Explorer, and -- confirmed live on Dell,
       including from a genuinely clean, freshly-rebooted state, not just mid-session
       churn -- Explorer coming back from a forced kill can reset every app's
       icon-promotion preference to hidden, not just this repo's own AHK icon. Call this
       once before either kill; Restore-TrayIconPromotions puts the snapshot back
       afterward. Returns the backup .reg file's path (for Restore-TrayIconPromotions), or
       $null if the key doesn't exist yet or the export failed -- best-effort, never
       blocks the caller. #>
    $key = 'HKCU\Control Panel\NotifyIconSettings'
    if (-not (Test-Path 'HKCU:\Control Panel\NotifyIconSettings')) { return $null }
    $dir = Backup-RegistryKey -Key $key -Label 'tray-icons'
    if (-not $dir) { return $null }
    Join-Path $dir (($key -replace '[\\:]', '_') + '.reg')
}

function Restore-TrayIconPromotions {
    <# Counterpart to Backup-TrayIconPromotions -- reg.exe import of the file that
       function returned, putting back whatever Explorer's own restart(s) reset in every
       app's tray-icon-promotion preference. Call after Explorer is confirmed back up from
       the LAST of the two kills (Wait-ExplorerRunning), not right after the second
       Stop-Process call -- reg.exe import needs Explorer actually running to pick the
       change up live. Best-effort: a missing/null backup path (Backup-TrayIconPromotions
       returned $null, or was never called) is a silent no-op. #>
    param([string]$BackupFile)
    if (-not $BackupFile -or -not (Test-Path $BackupFile)) { return }
    $null = & reg.exe import $BackupFile 2>&1
}

# --- Original-state snapshots (true "restore to before 710.DesktopRice" on uninstall) --
# Different problem from Backup-RegistryKey above and from the hardening/taskbar revert
# pattern further down: those settings don't exist on a stock Windows install, so
# reverting them just means deleting the value. Wallpaper, accent color, the lock screen,
# and Windows Terminal's default shell/colorScheme are NOT like that -- something was
# already there before 710.DesktopRice ever touched it, and a real uninstall needs to put
# that exact something back, not just remove what we added. These functions snapshot
# whatever's about to change, exactly ONCE (gated on the snapshot not already existing --
# a second, third, Nth install.ps1/wallpaper-change run never overwrites an earlier
# snapshot with what is by then already OUR OWN state), into
# %LOCALAPPDATA%\710.DesktopRice\original-state\<label>.json -- machine-local, outside the
# repo entirely, same convention as this repo's autostart logs
# (%LOCALAPPDATA%\710.DesktopRice\*-autostart.log). uninstall.ps1 restores from these and
# deletes each snapshot file once it's been used, so a future re-install starts clean and
# snapshots fresh again rather than restoring an increasingly stale state.
#
# tools\apply-wallust-outputs.ps1 needs this SAME path convention and JSON shape but
# deliberately doesn't dot-source this file (stays dependency-free -- see its own header),
# so it carries a small duplicated copy of Save-OriginalState/Get-RegValueSnapshot rather
# than calling these. Keep both copies in sync if this shape ever changes.
function Get-OriginalStateDir {
    $dir = Join-Path $env:LOCALAPPDATA '710.DesktopRice\original-state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dir
}

function Save-OriginalState {
    <# One-time snapshot: writes <label>.json only if it doesn't already exist. $Data is
       whatever the caller wants restored later -- typically a small hashtable of exactly
       the field(s) about to change, not the whole surrounding file/key. #>
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)]$Data)
    $file = Join-Path (Get-OriginalStateDir) "$Label.json"
    if (Test-Path $file) { return }
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
}

function Get-OriginalState {
    <# Returns the snapshotted hashtable for $Label, or $null if it was never taken --
       callers treat $null as "nothing to restore" (this machine's install never actually
       reached the point of changing this setting), a safe no-op, not a warning. #>
    param([Parameter(Mandatory)][string]$Label)
    $file = Join-Path (Get-OriginalStateDir) "$Label.json"
    if (-not (Test-Path $file)) { return $null }
    Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
}

function Remove-OriginalState {
    param([Parameter(Mandatory)][string]$Label)
    Remove-Item (Join-Path (Get-OriginalStateDir) "$Label.json") -Force -ErrorAction SilentlyContinue
}

function Get-RegValueSnapshot {
    <# One registry value's current Existed/Value/Type (Value/Type both $null if absent) --
       the unit Save-OriginalState snapshots and Set-RegValueFromSnapshot restores, for a
       SINGLE named value, never a whole key -- so restoring never clobbers an unrelated
       sibling value under the same key that changed for some other reason in between
       (e.g. HKCU\Control Panel\Desktop holds a lot more than just WallPaper). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if (-not $item) { return [ordered]@{ Existed = $false; Value = $null; Type = $null } }
    $kind = 'String'
    try { $kind = (Get-Item -Path $Path).GetValueKind($Name).ToString() } catch { }
    [ordered]@{ Existed = $true; Value = $item.$Name; Type = $kind }
}

function Set-RegValueFromSnapshot {
    <# Restores one value from a Get-RegValueSnapshot-shaped hashtable: sets it back if it
       existed before, removes it entirely if it didn't (matching how the hardening revert
       already treats "never existed" -- hand it back to Windows' own default). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Snapshot)
    if (-not $Snapshot.Existed) {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    } else {
        if (-not (Test-Path $Path)) { $null = New-Item -Path $Path -Force }
        Set-ItemProperty -Path $Path -Name $Name -Value $Snapshot.Value -Type $Snapshot.Type -ErrorAction SilentlyContinue
    }
}

function Send-SettingChangeBroadcast {
    <# HWND_BROADCAST + WM_SETTINGCHANGE(<Area>), SMTO_ABORTIFHUNG. The default area,
       "ImmersiveColorSet", makes an accent-color change apply live, no logoff/restart.
       "Environment" tells Explorer to rebuild its environment block from the registry, so
       whatever it launches next (a new Terminal from Start, the Run dialog) sees a changed
       user PATH -- the user-PATH helpers below send that one. Ported inline from
       tools\apply-wallust-outputs.ps1's own copy of this P/Invoke (that script keeps its
       own -- see this file's header note above -- this copy is for Restore-WindowsAccent,
       called from uninstall.ps1, which already dot-sources this file). #>
    param([string]$Area = 'ImmersiveColorSet')
    if (-not ('TenSeven.Native.SettingChange' -as [type])) {
        Add-Type -Namespace TenSeven.Native -Name SettingChange -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    [TenSeven.Native.SettingChange]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, $Area, 2, 1000, [ref]$result) | Out-Null
}

# --- User environment variables ---------------------------------------------------------------
# (Not PATH: that one is read and written raw -- see below.)
function Get-UserEnvVar {
    # A variable as registered for the user (what a new window gets).
    param([Parameter(Mandatory)][string]$Name)
    [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Remove-UserEnvVar {
    # Gone from the user's registered variables and from this process.
    param([Parameter(Mandatory)][string]$Name)
    [Environment]::SetEnvironmentVariable($Name, $null, 'User')
    Remove-Item -Path "env:$Name" -ErrorAction SilentlyContinue
}

function Set-UserEnvVar {
    # Registered for the user (new windows and tasks get it; .NET tells Explorer) and set in this
    # process too.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "env:$Name" -Value $Value
}

# --- User PATH: the 710sRice command -------------------------------------------------------
# install.ps1 puts <repo>\bin on the user PATH (bin\ holds exactly one file, 710sRice.cmd);
# uninstall.ps1 takes it off again. Doctor can use the same helpers later.
#
# The user Path is read and written RAW. GetValue(..., DoNotExpandEnvironmentNames) hands back
# entries like %USERPROFILE%\AppData\Local\Microsoft\WindowsApps exactly as stored, and the
# write goes back as REG_EXPAND_SZ, so they keep expanding. The obvious one-liner --
# [Environment]::Get/SetEnvironmentVariable('Path', ..., 'User') -- returns the values
# already expanded and writes REG_SZ, freezing every %VAR% entry into a fixed path for good.
# winarchy's install.ps1 (section 3) and uninstall.ps1 do exactly that. Not here.
#
# The text work is split out as plain string functions (Add-PathEntryToText,
# Remove-PathEntryFromText) so it can be tested anywhere; only Get-/Set-UserPathRaw touch the
# registry.

function Test-SamePathEntry {
    <# $Entry (a raw PATH entry, %VARS% and all) names the same folder as $Dir: both expanded,
       surrounding quotes/blanks and a trailing \ dropped, case ignored. Deliberately NOT a
       substring match -- C:\710.DesktopRice\bin-old is not C:\710.DesktopRice\bin. #>
    param([string]$Entry, [Parameter(Mandatory)][string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Entry)) { return $false }
    $a = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\')
    $b = [Environment]::ExpandEnvironmentVariables($Dir.Trim().Trim('"')).TrimEnd('\')
    [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

function Add-PathEntryToText {
    <# $Raw with $Dir appended, or $null when $Dir is already in it. Every existing entry --
       order, %VARS%, empty slots, a trailing ; -- stays exactly as written, so removing $Dir
       again gives back the original text byte for byte. #>
    param([AllowEmptyString()][AllowNull()][string]$Raw, [Parameter(Mandatory)][string]$Dir)
    foreach ($entry in ("$Raw" -split ';')) { if (Test-SamePathEntry $entry $Dir) { return $null } }
    if ([string]::IsNullOrEmpty($Raw)) { return $Dir }
    if ($Raw.EndsWith(';')) { return "$Raw$Dir;" }
    "$Raw;$Dir"
}

function Remove-PathEntryFromText {
    <# $Raw minus every entry naming $Dir (a duplicate goes too), or $null when none did.
       Everything else -- order, %VARS%, empty slots, a trailing ; -- stays exactly as
       written. Returns '' when $Dir was the only entry. #>
    param([AllowEmptyString()][AllowNull()][string]$Raw, [Parameter(Mandatory)][string]$Dir)
    $parts = "$Raw" -split ';'
    $kept = @($parts | Where-Object { -not (Test-SamePathEntry $_ $Dir) })
    if ($kept.Count -eq $parts.Count) { return $null }
    $kept -join ';'
}

function Get-UserPathRaw {
    <# The user Path exactly as stored (%VARS% unexpanded); '' when there isn't one. #>
    (Get-Item -Path 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
}

function Set-UserPathRaw {
    <# Writes the user Path back as REG_EXPAND_SZ (Windows' own type for it) -- or removes the
       value when nothing is left -- then tells Explorer. #>
    param([AllowEmptyString()][string]$Raw)
    if ($Raw) {
        Set-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -Value $Raw -Type ExpandString
    } else {
        Remove-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -ErrorAction SilentlyContinue
    }
    Send-SettingChangeBroadcast -Area 'Environment'
}

function Add-UserPathEntry {
    <# Puts $Dir on the user PATH if it isn't there yet (appended last) and on this process's
       PATH too, so it works in the window that ran install. $true if the registry changed. #>
    param([Parameter(Mandatory)][string]$Dir)
    if (-not @(("$env:Path" -split ';') | Where-Object { Test-SamePathEntry $_ $Dir })) {
        $env:Path = "$("$env:Path".TrimEnd(';'));$Dir"
    }
    $new = Add-PathEntryToText -Raw (Get-UserPathRaw) -Dir $Dir
    if ($null -eq $new) { return $false }
    Set-UserPathRaw -Raw $new
    $true
}

function Remove-UserPathEntry {
    <# Takes every entry naming $Dir off the user PATH, and off this process's PATH. Nothing
       matched = no write at all (the value and its type stay untouched). $true if the
       registry changed. #>
    param([Parameter(Mandatory)][string]$Dir)
    $env:Path = @(("$env:Path" -split ';') | Where-Object { -not (Test-SamePathEntry $_ $Dir) }) -join ';'
    $new = Remove-PathEntryFromText -Raw (Get-UserPathRaw) -Dir $Dir
    if ($null -eq $new) { return $false }
    Set-UserPathRaw -Raw $new
    $true
}

function Set-DesktopWallpaper {
    <# SPI_SETDESKWALLPAPER=0x0014, SPIF_UPDATEINIFILE|SPIF_SENDCHANGE=0x03 -- writes
       HKCU\Control Panel\Desktop\WallPaper and applies live, no logoff/restart needed.
       Shared by install.ps1 Section 4 (sets the first-run default) and
       Restore-OriginalWallpaper below (sets it back to whatever was there before). #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('TenSeven.Native.Wallpaper' -as [type])) {
        Add-Type -Namespace TenSeven.Native -Name Wallpaper -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
'@
    }
    $ok = [TenSeven.Native.Wallpaper]::SystemParametersInfo(0x0014, 0, $Path, 0x03)
    if (-not $ok) { throw "SystemParametersInfo returned false (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
}

function Get-CurrentWallpaper {
    <# The desktop wallpaper that's up now: HKCU\Control Panel\Desktop\WallPaper -- the value
       both SystemParametersInfo (Set-DesktopWallpaper) and the IDesktopWallpaper COM API
       that YASB's wallpaper widget uses keep current. scripts\Set-LockScreen.ps1 reads the
       same value when it isn't handed a picture. $null when none is set. Used by install's
       palette and tasks steps. #>
    (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper' -ErrorAction SilentlyContinue).WallPaper
}

function Save-OriginalWallpaper {
    <# One-time snapshot of the wallpaper as it stood before install.ps1 Section 4 ever
       set the repo's default -- called from there, right before the first Set-
       DesktopWallpaper call. #>
    Save-OriginalState -Label 'wallpaper' -Data (Get-RegValueSnapshot -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper')
}

function Restore-OriginalWallpaper {
    <# Reverts Save-OriginalWallpaper -- called from uninstall.ps1. $null from Get-
       OriginalState means install.ps1 never actually reached Section 4's wallpaper-setting
       branch on this machine (already using one of the repo's own wallpapers, or the
       default image was missing) -- safe no-op, not a warning. #>
    $snap = Get-OriginalState -Label 'wallpaper'
    if (-not $snap) { return $false }
    if ($snap.Existed -and $snap.Value) {
        Set-DesktopWallpaper -Path $snap.Value
    }
    Remove-OriginalState -Label 'wallpaper'
    return $true
}

# --- Component discovery (shared by Defender exclusions + autostart) ----------------
function Get-KomorebiExe {
    $found = (Get-Command komorebi.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $found) {
        $found = @("$env:ProgramFiles\komorebi\bin\komorebi.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    $found
}

function Get-KomorebicExe {
    <# komorebic.exe: next to the installed komorebi.exe first, then PATH; $null when neither.
       A window opened before the install doesn't have komorebi on its PATH, and uninstall never
       re-read it -- so `komorebic stop` was skipped and komorebi only force-killed, which leaves
       the windows it had cloaked on other workspaces invisible (base.json's
       window_hiding_behaviour Cloak; its own stop is what restores them). winarchy ca66652,
       Group 1 W6. Used by Stop-RunningComponents and Stop-PinnedApp. #>
    $komorebi = Get-KomorebiExe
    if ($komorebi) {
        $next = Join-Path (Split-Path -Parent $komorebi) 'komorebic.exe'
        if (Test-Path -LiteralPath $next) { return $next }
    }
    (Get-Command komorebic.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}

function Get-YasbcExe {
    <# yasbc.exe (YASB's CLI): next to the installed yasb.exe first (winget puts both in
       Program Files\YASB), then PATH; $null when neither. Same reason as Get-KomorebicExe. #>
    $next = Join-Path "$env:ProgramFiles" 'YASB\yasbc.exe'
    if ($env:ProgramFiles -and (Test-Path -LiteralPath $next)) { return $next }
    (Get-Command yasbc.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}

function Get-AhkExe {
    <# AutoHotkey v2, per-machine or per-user; $null if not installed. Prefers the UI Access
       build (AutoHotkey64_UIA.exe) so 710.ahk's hotkeys still reach an admin window that has
       focus -- without running AHK itself elevated, which would make everything it launches
       elevated too (plan doc, Open item 36). The UIA exe only exists (and only works) in a
       Program Files install -- AutoHotkey's installer creates and signs it there -- so a
       per-user install falls through to the plain exe, same as before. #>
    $found = @(
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64_UIA.exe",
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { $found = (Get-Command AutoHotkey64.exe -ErrorAction SilentlyContinue)?.Source }
    $found
}

function Get-ShareXExe {
    @("$env:ProgramFiles\ShareX\ShareX.exe", "${env:ProgramFiles(x86)}\ShareX\ShareX.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

# --- Windows Defender exclusions (unconditional -- not gated behind -Activate) ------
function Get-DefenderExclusionPaths {
    <# Ported from winarchy's Get-WinarchyDefenderExclusionPaths. Covers the same two lag
       sources: frequent I/O from ShareX/Everything, and Defender scanning komorebic.exe /
       pwsh.exe / this repo's own .ps1 files the first time they're touched per session
       (the "only the first time" lag seen on capture/window-close). Only returns paths
       that actually exist on this machine, plus pwsh.exe (see Get-PwshImagePath). #>
    $komorebic = Get-KomorebiExe
    @(
        (Get-ShareXExe),
        "$env:USERPROFILE\Documents\ShareX",
        "$env:ProgramFiles\Everything\Everything.exe",
        "${env:ProgramFiles(x86)}\Everything\Everything.exe",
        $komorebic,
        $Root
    ) | Where-Object { $_ -and (Test-Path $_) }
    Get-PwshImagePath
}

function Get-PwshImagePath {
    <# The pwsh.exe Defender should exclude: the real image this very process runs from
       ($PSHOME) -- install/uninstall always run under PowerShell 7. Defender matches the
       real image path, which for the Store build is the versioned package folder
       (...\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe\pwsh.exe).
       winarchy (and our port) used `Get-Command pwsh.exe`, which depends on PATH order:
       after install.ps1 re-reads PATH from the registry it finds the per-user App
       Execution Alias instead (%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe) -- seen
       on the 2026-09-24 third install, where that alias is what got excluded, which
       doesn't cover the real binary. No Test-Path: it's the running process's own
       binary, and Test-Path inside Program Files\WindowsApps isn't reliable. #>
    Join-Path $PSHOME 'pwsh.exe'
}

function Get-StalePwshExclusions {
    <# Existing Defender exclusions that are an earlier pwsh.exe of ours, not the current
       one: the per-user alias (what the old Get-Command lookup could add) and any other
       Store-build version folder (left behind when PowerShell updates itself -- its
       folder name carries the version). Only exact pwsh.exe paths in those two places,
       so nothing the person excluded themselves is touched. #>
    param([string[]]$Current)
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    $real  = Get-PwshImagePath
    @($Current | Where-Object {
        $_ -and $_ -ne $real -and (
            $_ -eq $alias -or
            $_ -like "$env:ProgramFiles\WindowsApps\Microsoft.PowerShell_*\pwsh.exe")
    })
}

function Set-DefenderExclusions {
    <# Requires an elevated shell; same not-elevated fallback as the rest of this file:
       warn and skip, never fail the install. Ported from Set-WinarchyDefenderExclusions. #>
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Step-Warn 'Defender exclusions need an elevated shell -- re-run install.ps1 from an admin PowerShell to apply them.'
        return
    }
    $paths = @(Get-DefenderExclusionPaths)
    if ($paths.Count -eq 0) {
        Step-Info 'No ShareX/Everything/komorebi paths found yet to exclude.'
        return
    }
    $current = @((Get-MpPreference).ExclusionPath)
    # An earlier pwsh.exe exclusion (the alias, or a PowerShell version since updated
    # away) is swapped for the current one rather than left to pile up.
    $stale = @(Get-StalePwshExclusions -Current $current)
    if ($stale.Count -gt 0) {
        try {
            Remove-MpPreference -ExclusionPath $stale
            Step-Ok "Old pwsh.exe Defender exclusion(s) removed: $(@($stale | ForEach-Object { ConvertTo-SafePath $_ }) -join ', ')"
        } catch {
            Step-Warn "Could not remove old pwsh.exe Defender exclusion(s): $($_.Exception.Message)"
        }
    }
    $missing = @($paths | Where-Object { $current -notcontains $_ })
    if ($missing.Count -eq 0) {
        Step-Ok 'Defender exclusions already applied'
        return
    }
    try {
        Add-MpPreference -ExclusionPath $missing
        Step-Ok "Defender exclusions added: $(@($missing | ForEach-Object { ConvertTo-SafePath $_ }) -join ', ')"
    } catch {
        Step-Warn "Could not add Defender exclusions: $($_.Exception.Message)"
    }
}

function Remove-DefenderExclusions {
    <# Reverts Set-DefenderExclusions -- called from uninstall.ps1. winarchy's own
       uninstall.ps1 never removes these at all (see plan doc); we go further. Removes
       exactly the paths Get-DefenderExclusionPaths would add (recomputed live, same as
       install time), never the caller's whole ExclusionPath list, so an exclusion the
       person added themselves outside this repo is left alone. Same elevation requirement
       and not-elevated fallback as Set-DefenderExclusions -- warns and skips rather than
       failing the uninstall. #>
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Step-Warn 'Defender exclusions need an elevated shell to remove -- re-run uninstall.ps1 from an admin PowerShell to revert them.'
        return
    }
    $paths = @(Get-DefenderExclusionPaths)
    if ($paths.Count -eq 0) {
        Step-Info 'No Defender exclusion paths to remove (nothing currently found to have excluded).'
        return
    }
    $current = @((Get-MpPreference).ExclusionPath)
    # Plus any earlier pwsh.exe exclusion of ours (see Get-StalePwshExclusions).
    $toRemove = @(@($paths | Where-Object { $current -contains $_ }) + @(Get-StalePwshExclusions -Current $current))
    if ($toRemove.Count -eq 0) {
        Step-Info 'Defender exclusions already absent.'
        return
    }
    try {
        Remove-MpPreference -ExclusionPath $toRemove
        Step-Ok "Defender exclusions removed: $(@($toRemove | ForEach-Object { ConvertTo-SafePath $_ }) -join ', ')"
    } catch {
        Step-Warn "Could not remove Defender exclusions: $($_.Exception.Message)"
    }
}

# --- Registry hardening (HKCU only, -Activate-gated) ---------------------------------
function Get-HardeningSettings {
    <# Ported verbatim (values/keys) from winarchy's Get-WinarchyHardeningSettings
       (module/Winarchy/Private/Hardening.ps1 @ 4574fc7, tag v1.4.0). HKCU only (no admin
       needed), idempotent, and reversible: reverting just deletes the values, which
       hands the setting back to Windows' own default. Turns off Bing web search in the
       Start menu, search-box ad suggestions, Copilot/Widgets/Task-View taskbar buttons,
       Start menu recommendations/account nag, spotlight/lock-screen ads, and the various
       "SubscribedContent" (ContentDeliveryManager) ad/suggestion channels. #>
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
    $cdm = "$base\ContentDeliveryManager"
    $settings = @(
        , @("$base\Search", 'BingSearchEnabled', 0)
        , @("$base\Search", 'SearchboxTaskbarMode', 0)
        , @("$base\Search", 'CortanaConsent', 0)
        , @("$base\SearchSettings", 'IsDynamicSearchBoxEnabled', 0)
        , @("$base\SearchSettings", 'IsAADCloudSearchEnabled', 0)
        , @("$base\SearchSettings", 'IsMSACloudSearchEnabled', 0)
        , @('HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 1)
        , @("$base\Explorer\Advanced", 'TaskbarDa', 0)
        , @("$base\Explorer\Advanced", 'TaskbarMn', 0)
        , @("$base\Explorer\Advanced", 'ShowTaskViewButton', 0)
        , @("$base\Explorer\Advanced", 'ShowCopilotButton', 0)
        , @("$base\Explorer\Advanced", 'Start_IrisRecommendations', 0)
        , @("$base\Explorer\Advanced", 'Start_AccountNotifications', 0)
        , @("$base\Explorer\Advanced", 'ShowSyncProviderNotifications', 0)
        , @("$base\AdvertisingInfo", 'Enabled', 0)
        , @("$base\Privacy", 'TailoredExperiencesWithDiagnosticDataEnabled', 0)
        , @("$base\UserProfileEngagement", 'ScoobeSystemSettingEnabled', 0)
        , @('HKCU:\Control Panel\International\User Profile', 'HttpAcceptLanguageOptOut', 1)
        , @('HKCU:\Software\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsSpotlightFeatures', 1)
    )
    foreach ($name in 'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled',
        'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled',
        'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled', 'RotatingLockScreenEnabled',
        'RotatingLockScreenOverlayEnabled', 'SubscribedContent-310093Enabled', 'SubscribedContent-338387Enabled',
        'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled',
        'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-353698Enabled',
        'SubscribedContent-88000326Enabled') {
        $settings += , @($cdm, $name, 0)
    }
    $settings
}

function Wait-ExplorerRunning {
    <# Waits for Explorer's real shell (the taskbar) to actually be back up before some
       other step force-kills it a second time. Exists because Set-TaskbarAutoHide and
       Set-WindowsHardening both restart Explorer when they change something, and both
       install.ps1 -Activate and uninstall.ps1 call them back-to-back (taskbar, then
       hardening) with no gap in between -- confirmed live on Dell to leave the desktop,
       taskbar and icons completely blank until a manual Explorer restart or a full
       reboot, because the second kill lands while Windows is still bringing the first
       kill's replacement process back up.
       FIRST version of this fix (commit 3b6d3f0) only checked Get-Process explorer --
       NOT enough, confirmed live on Dell a second time (uninstall-run-2, 2026-09-23): a
       process named explorer.exe shows up in the process table almost immediately after
       Windows respawns it, well before Explorer has actually finished initializing and
       created its shell windows. The second kill still landed in that gap and reproduced
       the identical blank-desktop symptom this function exists to prevent. Now checks for
       the real taskbar window (class Shell_TrayWnd, via FindWindow) instead of just the
       process -- that handle only exists once Explorer has genuinely finished standing
       the shell back up, not merely once a process object exists.
       Polls rather than a fixed sleep, same reasoning as scripts\Start-Komorebi.ps1's own
       wait-with-time-budget: however long Explorer actually takes to come back (which
       varies), never longer, never less. Falls through after the timeout even if the
       taskbar never reappears -- best-effort, same posture as every other step in this
       file; the caller's own kill still happens either way, just no longer guaranteed to
       land on an already-healthy shell. #>
    param([int]$TimeoutSeconds = 10)
    if (-not ('Win32Shell.NativeMethods' -as [type])) {
        Add-Type -Namespace Win32Shell -Name NativeMethods -MemberDefinition @'
            [DllImport("user32.dll", CharSet = CharSet.Auto)]
            public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
'@
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ([Win32Shell.NativeMethods]::FindWindow('Shell_TrayWnd', $null) -eq [IntPtr]::Zero) {
        if ((Get-Date) -ge $deadline) { return }
        Start-Sleep -Milliseconds 200
    }
}

function Test-ExplorerShell {
    # True once Explorer's real shell (the taskbar window) exists -- see Wait-ExplorerRunning.
    if (-not ('Win32Shell.NativeMethods' -as [type])) {
        Add-Type -Namespace Win32Shell -Name NativeMethods -MemberDefinition @'
            [DllImport("user32.dll", CharSet = CharSet.Auto)]
            public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
'@
    }
    [Win32Shell.NativeMethods]::FindWindow('Shell_TrayWnd', $null) -ne [IntPtr]::Zero
}

function Restart-Explorer {
    <# The ONE Explorer restart for install -Activate / uninstall (taskbar auto-hide +
       hardening both need it; callers run this once if either changed something). Kills
       Explorer, then waits for Windows (Winlogon's AutoRestartShell) to bring the shell
       back. If it hasn't within the wait, starts it -- through a one-shot LeastPrivilege
       scheduled task, never straight from this shell: install/uninstall run elevated, and
       an Explorer started from an elevated process can come up elevated, which would make
       everything launched from Start/the taskbar elevated (same trap as the admin-AHK
       incident). Returns $true if the shell is back. Added 2026-09-24 after the full
       reinstall test left the desktop blank: Winlogon had restarted the shell after the
       first of two back-to-back kills and didn't after the second. #>
    param([int]$WaitSeconds = 15)
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Wait-ExplorerRunning -TimeoutSeconds $WaitSeconds
    if (Test-ExplorerShell) { return $true }

    $task = Get-TaskFullName -TaskName 'restart-explorer'
    $null = & schtasks.exe /Create /TN $task /TR "$env:WINDIR\explorer.exe" /SC ONCE /ST 23:59 /RL LIMITED /F 2>&1
    $null = & schtasks.exe /Run /TN $task 2>&1
    Wait-ExplorerRunning -TimeoutSeconds $WaitSeconds
    $null = & schtasks.exe /Delete /TN $task /F 2>&1
    Test-ExplorerShell
}

function Start-AsUser {
    <# Starts an app as the signed-in user, NOT elevated, from an elevated install / uninstall /
       repair (Group 1 #12's rule: a component never starts an app from there itself -- it
       would run as admin, like the "ShareX running as admin" doctor already flags). The same
       trick as Restart-Explorer and Invoke-WingetAsUser: a one-shot task, here written with
       New-TaskXml (LeastPrivilege, interactive, Normal priority -- a plain `schtasks /SC ONCE`
       task starts its process BelowNormal, and the app would keep that), fired, then deleted
       once the app has started (deleting a task leaves the process it started running).
       -Process: the process name to wait for -- a NEW one (a copy already running doesn't
       count); without it, it waits for Task Scheduler to report the task started.
       Returns $true once the app has started, $false if it didn't within -TimeoutSeconds
       (or the task couldn't be made). Never throws for a start that didn't happen. #>
    param([Parameter(Mandatory)][string]$Exe, [string]$Arguments = '', [string]$Process,
          [string]$Name, [int]$TimeoutSeconds = 15)
    if (-not $Name) { $Name = if ($Process) { $Process } else { [System.IO.Path]::GetFileNameWithoutExtension($Exe) } }
    $taskName = 'as-user-' + (($Name.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-'))
    $task = Get-TaskFullName -TaskName $taskName
    $before = if ($Process) { @(Get-Process -Name $Process -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) } else { @() }
    $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) "710-task-$taskName.xml"
    try {
        $spec = [pscustomobject]@{ Key = $taskName; Exe = $Exe; Arguments = $Arguments; Delay = 'PT0S' }
        Set-Content -Path $xmlPath -Value (New-TaskXml -Component $spec -User "$env:USERDOMAIN\$env:USERNAME" -NoTrigger) -Encoding Unicode
        $null = & schtasks.exe /Create /TN $task /XML $xmlPath /F 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        $null = & schtasks.exe /Run /TN $task 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ($true) {
            if ($Process) {
                if (@(Get-Process -Name $Process -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id }).Count) { return $true }
            } else {
                # LastTaskResult reads 0x41303 ("has not yet run") until Task Scheduler starts it
                # (see Invoke-WingetAsUser). Where the ScheduledTasks module can't be read, a
                # short wait stands in.
                $result = $null
                try { $result = (Get-ScheduledTaskInfo -TaskPath "\$script:TaskFolder\" -TaskName $taskName -ErrorAction Stop).LastTaskResult } catch { }
                if ($null -eq $result) { Start-Sleep -Seconds 2; return $true }
                if ($result -ne 0x41303) { return $true }
            }
            if ((Get-Date) -ge $deadline) { return $false }
            Start-Sleep -Milliseconds 250
        }
    } finally {
        $null = & schtasks.exe /Delete /TN $task /F 2>&1
        Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-WindowsHardening {
    <# Applies (or, with -Revert, undoes) every setting from Get-HardeningSettings.
       Backs up each touched registry key first (Backup-RegistryKey, label 'hardening').
       Returns the number of settings changed. Does NOT restart Explorer itself (most of
       these values are only read at Explorer startup): the caller runs Restart-Explorer
       once, after this AND Set-TaskbarAutoHide, if either changed anything. Two separate
       restarts back to back left the desktop blank -- three times live on Dell, the last
       on 2026-09-24 even with a wait in between (Winlogon restarted the shell once after
       the first kill, and doesn't retry after a second). #>
    param([switch]$Revert)
    $changed = 0
    if (-not $Revert) {
        foreach ($key in 'Explorer\Advanced', 'ContentDeliveryManager', 'Search', 'SearchSettings') {
            $null = Backup-RegistryKey -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\$key" -Label 'hardening'
        }
    }
    foreach ($setting in Get-HardeningSettings) {
        $path, $name, $value = $setting
        try {
            $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Ignore
            $current = if ($item) { $item.$name }
            if ($Revert) {
                if ($null -eq $current) { continue }
                Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop
            } else {
                if ($current -eq $value) { continue }
                if (-not (Test-Path $path)) { $null = New-Item -Path $path -Force }
                Set-ItemProperty -Path $path -Name $name -Value $value -Type DWord -ErrorAction Stop
            }
            $changed++
        } catch {
            # Widgets button: Windows refuses script writes to TaskbarDa on current builds
            # ("Attempted to perform an unauthorized operation", even elevated), while its
            # own Settings toggle still works. Still tried every run in case a build allows
            # it; when it's refused, say what to do instead of printing the raw error
            # (plan doc item 31, user's pick).
            if ($name -eq 'TaskbarDa' -and ($_.Exception -is [System.UnauthorizedAccessException] -or $_.Exception.Message -match 'unauthorized operation')) {
                $onOff = if ($Revert) { 'back on' } else { 'off' }
                Step-Info "Windows won't let a script change the Widgets button -- turn it $onOff in Settings > Personalization > Taskbar."
            } else {
                Step-Warn "${name}: $($_.Exception.Message)"
            }
        }
    }
    $changed
}

# --- Taskbar auto-hide (-Activate-gated) ----------------------------------------------
function Set-TaskbarAutoHide {
    <# Ported from winarchy's Set-WinarchyTaskbarAutoHide (Taskbar.ps1 @ 4574fc7):
       flips bit 0x01 of StuckRects3's Settings byte array (byte 8), the same bit Windows'
       own "Automatically hide the taskbar" checkbox flips. Idempotent -- returns $false
       and does nothing if the flag already matches $Enabled, so a re-run of install.ps1
       doesn't restart explorer.exe for no reason. Backs up StuckRects3 before changing it.
       Returns $true when it changed something -- the caller then runs Restart-Explorer
       (required for the change to take effect), once, together with any hardening
       change; see Set-WindowsHardening for why it's never two restarts. #>
    param([Parameter(Mandatory)][bool]$Enabled)
    $stuck = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
    $val = (Get-ItemProperty -Path $stuck -Name Settings).Settings
    $flags = if ($Enabled) { $val[8] -bor 0x01 } else { $val[8] -band (-bnot 0x01) }
    if ($flags -eq $val[8]) { return $false }
    $null = Backup-RegistryKey -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' -Label 'taskbar'
    $val[8] = $flags
    Set-ItemProperty -Path $stuck -Name Settings -Value $val
    $true
}

function Test-TaskbarAutoHide {
    <# Read-only: is "Automatically hide the taskbar" on right now? Asks the shell itself
       (SHAppBarMessage ABM_GETSTATE, bit ABS_AUTOHIDE) for the live state; falls back to
       StuckRects3's byte 8 (what Set-TaskbarAutoHide flips) if that call isn't available.
       Used by scripts\Start-All.ps1 / Stop-All.ps1, which only ADVISE on auto-hide for an
       on-demand (no -Activate) setup -- they never change it (user's call, 2026-09-24). #>
    try {
        if (-not ('Win32Shell.AppBar' -as [type])) {
            Add-Type -Namespace Win32Shell -Name AppBar -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct APPBARDATA { public uint cbSize; public System.IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public System.IntPtr lParam; }
[DllImport("shell32.dll")] public static extern System.UIntPtr SHAppBarMessage(uint dwMessage, ref APPBARDATA pData);
"@
        }
        $abd = New-Object 'Win32Shell.AppBar+APPBARDATA'
        $abd.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($abd)
        $state = [Win32Shell.AppBar]::SHAppBarMessage(4, [ref]$abd)   # 4 = ABM_GETSTATE
        return (($state.ToUInt64() -band 1) -ne 0)                     # 1 = ABS_AUTOHIDE
    } catch {
        $val = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' -Name Settings -ErrorAction Stop).Settings
        return (($val[8] -band 0x01) -ne 0)
    }
}

# --- StartupDelayInMSec (-Activate-gated) ---------------------------------------------
function Set-StartupDelay {
    <# Windows staggers Startup-folder/logon app launches by ~10s by default (Explorer's
       own Serialize\StartupDelayInMSec, undocumented but long-established). 0 removes that
       artificial delay -- beneficial here because komorebi/YASB/AHK are all launched at
       logon and a window opened right after login should get tiled promptly rather than
       waiting out Explorer's stagger. Ported from install.ps1's own inline block @ 4574fc7
       (this one was never split into a Private/ function upstream either). #>
    $serialize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'
    if (-not (Test-Path $serialize)) { $null = New-Item $serialize -Force }
    Set-ItemProperty -Path $serialize -Name 'StartupDelayInMSec' -Value 0 -Type DWord
}

function Remove-StartupDelay {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' `
        -Name 'StartupDelayInMSec' -ErrorAction SilentlyContinue
}

# --- Autostart: Scheduled Tasks At-LogOn (-Activate-gated) ---------------------------
# schtasks.exe (native), not the ScheduledTasks module: that module's CIM/MI subsystem is
# broken on some machines ("type initializer for 'Microsoft.Management.Infrastructure.
# Native...'"). schtasks.exe never touches that layer. Ported from winarchy's Autostart.ps1
# @ 4574fc7.
$script:TaskFolder = '710.DesktopRice'

function ConvertTo-HiddenLaunch {
    <# Rewraps an Exe/Arguments pair so the Scheduled Task launches it via
       tools\lib\run-hidden.vbs (WScript.Shell.Run, windowStyle 0) instead of directly. Used
       by the component tasks (Get-AutostartComponents). (The elevated lock-screen-sync task
       started this way too, 2026-09-27 until it was retired on 09-28: Remove-RetiredLockScreenSync.)

       Why: Task Scheduler launching a console-subsystem host (powershell.exe) directly
       with -WindowStyle Hidden still briefly flashes a console at every logon -- confirmed
       live on Dell, 3-4 flashes at boot (one per powershell-hosted autostart component
       below). Windows allocates the console as part of process creation, before
       PowerShell's own startup code has run far enough to read -WindowStyle and hide
       itself -- a well-documented Task Scheduler + PowerShell race, not specific to this
       repo. wscript.exe (unlike cscript.exe) never allocates a console at all, so there's
       nothing to flash; its WScript.Shell.Run requests the hidden window style up front,
       as part of creating the process, not as a hide-after-the-fact race. See
       run-hidden.vbs's own header for the full writeup, including why this is NOT the same
       technique winarchy tried and reverted for komorebi (`conhost --headless`, git log
       d52e515/f088211 -- that killed the child process outright when its detached host
       exited; this script doesn't host/attach the child's console at all).

       Real bug found and fixed 2026-09-23: the original version tried to carry Exe/
       Arguments on run-hidden.vbs's own command line, backslash-escaping embedded double
       quotes ("same convention Win32 command-line parsing already uses"). That assumption
       was never actually verified against WSH's real parser and was wrong -- confirmed
       live via a real run-hidden.log entry plus a byte-exact `od -c` dump: WSH's
       command-line parser does NOT support backslash-escaped quotes; `\"` comes through as
       a literal backslash plus an ORDINARY (unescaped) quote-toggle, not a literal `"`. A
       quoted -File path arrived at powershell.exe mangled
       (`\C:\710.DesktopRice\...\Start-Komorebi.ps1\` -- stray leading/trailing backslashes,
       no quotes at all), which powershell.exe can't resolve as a path -- it failed
       silently, every time this ran for real, including the very scheduled runs this
       feature was supposedly validated against. Task Scheduler still reported Last Result
       0 (that's wscript.exe's own exit code, unaffected -- see run-hidden.vbs's header) and
       the launched script never got far enough to write even its first log line, so this
       had no visible symptom other than "komorebi just isn't running" after logon.

       Fixed by not putting Exe/Arguments on run-hidden.vbs's command line at all: they're
       written to a small two-line plain-text spec file instead (line 1 = Exe, line 2 =
       Arguments, exactly as originally composed, no escaping needed), and only that file's
       own path -- a plain, quote-free, backslash-free-at-the-end Windows path -- is passed
       as run-hidden.vbs's one argument. This sidesteps WSH's command-line parsing for the
       payload entirely; nothing about it needs to be "quoted correctly" for WSH anymore.
       Written once here, at registration/-Activate time; read fresh by run-hidden.vbs on
       every actual fire, including ones long after this PowerShell process has exited (a
       reboot days later, etc.), so it has to be static/persistent, not a live variable --
       same %LOCALAPPDATA%\710.DesktopRice\ folder every other autostart log/state file
       already lives in. #>
    # -NoWrite: work out the same answer without writing the spec file -- `710sRice doctor`
    # compares it with the registered task and the file on disk, and writes nothing.
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Arguments,
        [switch]$NoWrite
    )
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $vbs = Join-Path $Root 'tools\lib\run-hidden.vbs'
    $specDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
    $spec = Join-Path $specDir "launch-$Key.txt"
    if (-not $NoWrite) {
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
        # ASCII, no BOM -- every value written here is a plain Windows path or powershell.exe
        # flag, so there's nothing here that needs Unicode; a BOM would otherwise land as a
        # stray leading character on run-hidden.vbs's own ForReading (ASCII/ANSI) ReadLine.
        Set-Content -LiteralPath $spec -Value @($Exe, $Arguments) -Encoding ASCII
    }
    [pscustomobject]@{
        Exe       = $wscript
        Arguments = "//B `"$vbs`" `"$spec`""
        Spec      = $spec
        SpecLines = @($Exe, $Arguments)
    }
}

function Get-AutostartComponents {
    <# Definition of the 4 autostart components this repo actually uses (komorebi, YASB,
       ShareX, AHK). net-icon is deliberately not ported -- see this file's header comment.
       Returns only the components whose executable is actually present.
       Each item: Key, TaskName, LnkName, Exe, Arguments, Delay (ISO-8601 duration, for the
       LogonTrigger's Delay). The 3 powershell-hosted components (all but ShareX, which
       launches its own GUI exe directly and has no console to begin with) go through
       ConvertTo-HiddenLaunch -- see that function for why; their items also carry Spec (the
       launch-<key>.txt path) and SpecLines (what goes in it).
       -NoWrite: the same answer without writing any launch-<key>.txt -- for `710sRice doctor`
       (read-only) and Get-AutostartStatus, which only need the names.
       Since Group 1 (#12 / #4) a component (tools\components\<id>.ps1) can declare its own task
       with an Autostart field: Key and TaskName = its Id, a GUI exe started directly (no
       run-hidden.vbs), and Process -- the process name that means "already running" (the four
       above leave it $null: their launchers check for themselves). #>
    param([switch]$NoWrite)
    $items = [System.Collections.Generic.List[object]]::new()
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # komorebi.exe direct (not `komorebic start`, which is flaky on some machines --
    # os error 1920, retries in a loop and can hang on launch). Start-Komorebi.ps1 waits
    # for a real foreground window and retries with a time budget; see that script.
    $komorebiExe = Get-KomorebiExe
    if ($komorebiExe) {
        $launcher = Join-Path $Root 'scripts\Start-Komorebi.ps1'
        $hidden = ConvertTo-HiddenLaunch -NoWrite:$NoWrite -Key 'komorebi' -Exe $ps -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
        $items.Add([pscustomobject]@{
            Key = 'komorebi'; TaskName = 'komorebi'; LnkName = '710.DesktopRice komorebi.lnk'
            Exe = $hidden.Exe
            Arguments = $hidden.Arguments
            Delay = 'PT0S'
            Spec = $hidden.Spec; SpecLines = $hidden.SpecLines; Process = $null
        })
    }

    # YASB via its own resilient launcher (waits for shell ready, retries).
    $yasbc = (Get-Command yasbc -ErrorAction SilentlyContinue)?.Source
    if ($yasbc) {
        $launcher = Join-Path $Root 'scripts\Start-Yasb.ps1'
        $yasbHome = Join-Path $Root 'config\yasb'
        $hidden = ConvertTo-HiddenLaunch -NoWrite:$NoWrite -Key 'yasb' -Exe $ps -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" -YasbExe `"$yasbc`" -YasbConfigHome `"$yasbHome`""
        $items.Add([pscustomobject]@{
            Key = 'yasb'; TaskName = 'yasb'; LnkName = '710.DesktopRice YASB.lnk'
            Exe = $hidden.Exe
            Arguments = $hidden.Arguments
            Delay = 'PT0S'
            Spec = $hidden.Spec; SpecLines = $hidden.SpecLines; Process = $null
        })
    }

    # ShareX resident in the tray (-silent: no main window) so the first capture of the
    # day doesn't also pay for the exe's cold start.
    $sharexExe = Get-ShareXExe
    if ($sharexExe) {
        $items.Add([pscustomobject]@{
            Key = 'sharex'; TaskName = 'sharex'; LnkName = '710.DesktopRice ShareX.lnk'
            Exe = $sharexExe
            Arguments = '-silent'
            Delay = 'PT0S'
            Spec = $null; SpecLines = $null; Process = $null
        })
    }

    # AHK dispatcher via its own resilient launcher.
    $ahkExe = Get-AhkExe
    if ($ahkExe) {
        $launcher = Join-Path $Root 'scripts\Start-Ahk.ps1'
        $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
        $hidden = ConvertTo-HiddenLaunch -NoWrite:$NoWrite -Key 'ahk' -Exe $ps -Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" -AhkExe `"$ahkExe`" -ScriptPath `"$ahkScript`""
        $items.Add([pscustomobject]@{
            Key = 'ahk'; TaskName = 'ahk'; LnkName = '710.DesktopRice hotkeys.lnk'
            Exe = $hidden.Exe
            Arguments = $hidden.Arguments
            Delay = 'PT0S'
            Spec = $hidden.Spec; SpecLines = $hidden.SpecLines; Process = $null
        })
    }

    # The components' own tasks (their Autostart field), in install order. Exe returning
    # nothing = not installed, so no task -- the same rule as the four above.
    $order = @(Get-RiceStepOrder)
    foreach ($comp in @(Get-RiceComponents | Where-Object { $_.Contains('Autostart') } | Sort-Object { $order.IndexOf($_.Id) })) {
        $a = $comp.Autostart
        $exe = & $a.Exe
        if (-not $exe) { continue }
        $items.Add([pscustomobject]@{
            Key = $comp.Id; TaskName = $comp.Id; LnkName = "710.DesktopRice $($comp.Label).lnk"
            Exe = "$exe"
            Arguments = "$($a.Arguments)"
            Delay = if ($a.Delay) { "$($a.Delay)" } else { 'PT0S' }
            Spec = $null; SpecLines = $null; Process = "$($a.Process)"
        })
    }

    $items
}

function Get-TaskFullName {
    param([Parameter(Mandatory)][string]$TaskName)
    "\$script:TaskFolder\$TaskName"
}

function Test-Task {
    <# -AtLogOn: only a task that actually starts at sign-in counts. That's what "this
       machine is -Activate'd" means -- an on-demand install has a task for every
       component too (Register-OnDemandTasks, no trigger), and without this check a later
       plain install.ps1 would read them as "autostart is active" and quietly register
       everything to start at sign-in (plan doc Open item 37). #>
    param([Parameter(Mandatory)][string]$TaskName, [switch]$AtLogOn)
    # $null = ... 2>&1 (capture-and-discard), not *> $null (redirect-and-discard): the
    # latter doesn't fully suppress schtasks.exe's own "ERROR: ..." text for a genuinely
    # missing task -- found live tonight when toolspply-wallust-outputs.ps1's own copy
    # of this exact check (same *> $null) leaked that text to the console the first time
    # all night it ever queried a task that truly didn't exist yet. Every earlier call to
    # this function happened to query a task that already existed, so the leak was never
    # actually exercised here until now.
    $full = Get-TaskFullName -TaskName $TaskName
    if ($AtLogOn) {
        $xml = & schtasks.exe /Query /TN $full /XML 2>&1
        return ($LASTEXITCODE -eq 0) -and (($xml -join "`n") -match '<LogonTrigger>')
    }
    $null = & schtasks.exe /Query /TN $full 2>&1
    $LASTEXITCODE -eq 0
}

function Remove-StartupShortcuts {
    $startup = [Environment]::GetFolderPath('Startup')
    Remove-Item (Join-Path $startup '710.DesktopRice *.lnk') -Force -ErrorAction SilentlyContinue
}

function New-StartupShortcut {
    <# Fallback for a component whose Scheduled Task failed to register. #>
    param([Parameter(Mandatory)][object]$Component)
    $startup = [Environment]::GetFolderPath('Startup')
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path $startup $Component.LnkName))
    $lnk.TargetPath = $Component.Exe
    $lnk.Arguments = $Component.Arguments
    $lnk.Save()
}

function Get-StartMenuProgramsDir {
    # Your Start menu's Programs folder (what Flow Launcher's Program plugin indexes). The
    # shell's answer, or its usual place when it has none.
    $sm = [Environment]::GetFolderPath('StartMenu')
    if (-not $sm) { $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu' }
    Join-Path $sm 'Programs'
}

function Save-RiceShortcut {
    <# Writes a .lnk (WScript.Shell): target, arguments, working folder, icon, description. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target, [string]$Arguments = '',
          [string]$WorkingDirectory = '', [string]$Icon = '', [string]$Description = '')
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.WorkingDirectory = $WorkingDirectory
    if ($Icon) { $lnk.IconLocation = $Icon }
    $lnk.Description = $Description
    $lnk.Save()
}

function Read-RiceShortcut {
    <# A .lnk's target, arguments, working folder, icon and description; $null if it isn't there
       or can't be read. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        [pscustomobject]@{ Target = $lnk.TargetPath; Arguments = $lnk.Arguments; WorkingDirectory = $lnk.WorkingDirectory; Icon = $lnk.IconLocation; Description = $lnk.Description }
    } catch { $null }
}

function New-TaskXml {
    <# At-LogOn trigger (per-component Delay), InteractiveToken + LeastPrivilege principal
       (no elevation, interactive session only), IgnoreNew multiple-instances policy, no
       execution time limit, Normal priority. Ported from New-WinarchyTaskXml.
       <Priority>4</Priority> ported from winarchy 2d8c910 (v1.5.0): Task Scheduler's
       default is 7, which starts the task's process at BelowNormal -- and Windows hands
       BelowNormal down to child processes that don't ask for a class, so through our
       wscript -> powershell -> launcher chain komorebi/YASB/AHK all came up BelowNormal
       (winarchy saw delayed retiles under load from exactly this). 4 = Normal. #>
    # -RunLevel HighestAvailable: komorebi in elevated tiling mode (Get-KomorebiRunLevel).
    # -NoTrigger: an on-demand task that never fires on its own -- Start-All.ps1,
    # reload-stack.ps1 and the AHK bar watchdog fire it (Register-OnDemandTasks). Labelled
    # "on demand" rather than "autostart" in Task Scheduler, so the list doesn't lie.
    param([Parameter(Mandatory)][object]$Component, [Parameter(Mandatory)][string]$User,
          [ValidateSet('LeastPrivilege', 'HighestAvailable')][string]$RunLevel = 'LeastPrivilege',
          [switch]$NoTrigger)
    $u = [System.Security.SecurityElement]::Escape($User)
    $cmd = [System.Security.SecurityElement]::Escape($Component.Exe)
    # No arguments = no <Arguments> element (a component's GUI exe may take none -- Flow).
    $argLine = if ("$($Component.Arguments)") { "`n      <Arguments>$([System.Security.SecurityElement]::Escape($Component.Arguments))</Arguments>" } else { '' }
    $delay = if ($Component.Delay) { $Component.Delay } else { 'PT0S' }
    $label = if ($NoTrigger) { 'on demand' } else { 'autostart' }
    $triggers = if ($NoTrigger) { '  <Triggers />' } else { @"
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$u</UserId>
      <Delay>$delay</Delay>
    </LogonTrigger>
  </Triggers>
"@ }
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>710.DesktopRice ${label}: $($Component.Key)</Description>
  </RegistrationInfo>
$triggers
  <Principals>
    <Principal id="Author">
      <UserId>$u</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>$RunLevel</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>4</Priority>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmd</Command>$argLine
    </Exec>
  </Actions>
</Task>
"@
}

function Register-Autostart {
    <# Registers every present component as an At-LogOn Scheduled Task, delay 0 (or per-
       component), unelevated, interactive-session-only. Deletes legacy .lnk files first
       (migration). Idempotent. Falls back to a Startup .lnk for any component whose task
       registration fails.
       -Key: just that one component, and no whole-install cleanup (Startup shortcuts) --
       `710sRice tiling` re-registers komorebi alone. #>
    param([string]$Key)
    if (-not $Key) { Remove-StartupShortcuts }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $components = @(Get-AutostartComponents | Where-Object { -not $Key -or $_.Key -eq $Key })
    if ($components.Count -eq 0) {
        Step-Warn "Autostart: $(if ($Key) { "$Key isn't installed" } else { 'no components installed' })."
        return
    }
    $admin = Test-IsAdmin
    # Only what actually got its task goes in the closing [OK] line (Group 1 #23): a task that
    # couldn't be updated, or a component that fell back to a Startup shortcut, keeps its own
    # warning and isn't listed -- the same pattern as Register-OnDemandTasks.
    $registered = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $components) {
        $runLevel = if ($c.Key -eq 'komorebi') { Get-KomorebiRunLevel } else { 'LeastPrivilege' }
        if ($runLevel -eq 'HighestAvailable' -and -not $admin) {
            # Only an admin can register a task that runs elevated.
            if (Test-Task -TaskName $c.TaskName) {
                Step-Warn "Autostart komorebi: elevated tiling needs an admin PowerShell to register -- its existing task was left as it is. Re-run .\install.ps1 from an admin shell."
                continue
            }
            Step-Warn "Autostart komorebi: elevated tiling needs an admin PowerShell to register -- registering it non-elevated for now (admin windows won't tile). Re-run .\install.ps1 from an admin shell."
            $runLevel = 'LeastPrivilege'
        }
        $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) "710-task-$($c.TaskName).xml"
        try {
            Set-Content -Path $xmlPath -Value (New-TaskXml -Component $c -User $user -RunLevel $runLevel) -Encoding Unicode
            $full = Get-TaskFullName -TaskName $c.TaskName
            & schtasks.exe /Create /TN $full /XML $xmlPath /F *> $null
            if ($LASTEXITCODE -ne 0) { throw "schtasks /Create exited with code $LASTEXITCODE" }
            $registered.Add($c.Key + $(if ($c.Key -eq 'komorebi') { " ($(if ($runLevel -eq 'HighestAvailable') { 'elevated' } else { 'non-elevated' }))" }))
        } catch {
            # The task already exists and just couldn't be UPDATED (typically: it was
            # created from an elevated shell and this run isn't) -- the old task still
            # autostarts the component, so a Startup .lnk on top would launch it twice.
            # Ported from winarchy 2d8c910 (v1.5.0).
            if (Test-Task -TaskName $c.TaskName) {
                Step-Warn "Autostart $($c.Key): couldn't update the existing task ($($_.Exception.Message)); keeping the old one. If it was created elevated: schtasks /Delete /TN `"$(Get-TaskFullName -TaskName $c.TaskName)`" /F (as admin), then re-run."
                continue
            }
            Step-Warn "Autostart $($c.Key): failed to register the task ($($_.Exception.Message)). Falling back to Startup."
            try { New-StartupShortcut -Component $c }
            catch { Step-Warn "Autostart $($c.Key): Startup fallback also failed: $($_.Exception.Message)" }
        } finally {
            Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($registered.Count -gt 0) {
        Step-Ok "Autostart registered (Scheduled Tasks At-LogOn): $($registered -join ', ')"
    }
}

function Unregister-Autostart {
    foreach ($c in Get-AutostartComponents) {
        $full = Get-TaskFullName -TaskName $c.TaskName
        & schtasks.exe /Delete /TN $full /F *> $null
    }
    # A component's task goes even when its app is already gone (Get-AutostartComponents only
    # lists an installed one).
    foreach ($comp in @(Get-RiceComponents | Where-Object { $_.Contains('Autostart') })) {
        if (Test-Task -TaskName $comp.Id) { $null = & schtasks.exe /Delete /TN (Get-TaskFullName -TaskName $comp.Id) /F 2>&1 }
    }
    Remove-StartupShortcuts
}

function Get-ComponentTaskInfo {
    <# A component's task as registered: $null when there is none, else AtLogOn (it has a
       sign-in trigger -- an -Activate'd machine; an on-demand install's tasks have none),
       RunLevel ('HighestAvailable' = runs elevated, 'LeastPrivilege'), Enabled (not switched
       off in Task Scheduler), and the Command / Arguments it runs (`710sRice doctor` compares
       them with what install would register now). Read from `schtasks /Query /XML`, like
       Test-Task -AtLogOn, so it works from a normal window too. #>
    param([Parameter(Mandatory)][string]$TaskName)
    $xml = & schtasks.exe /Query /TN (Get-TaskFullName -TaskName $TaskName) /XML 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = $xml -join "`n"
    $runLevel = if ($text -match '<RunLevel>(\w+)</RunLevel>') { $Matches[1] } else { 'LeastPrivilege' }
    # The XML's own UTF-16 declaration means nothing to an already-decoded string -- dropped
    # before parsing. Element access by name ignores the task namespace.
    $doc = $null
    try { $doc = [xml]($text -replace '^\s*<\?xml[^>]*\?>', '') } catch { }
    $exec = if ($doc) { @($doc.Task.Actions.Exec)[0] } else { $null }
    [pscustomobject]@{
        AtLogOn   = ($text -match '<LogonTrigger>')
        RunLevel  = $runLevel
        Enabled   = -not ($doc -and "$($doc.Task.Settings.Enabled)".Trim() -eq 'false')
        Command   = if ($exec) { "$($exec.Command)" } else { $null }
        Arguments = if ($exec) { "$($exec.Arguments)" } else { $null }
    }
}

function Initialize-ProcessTokenNative {
    if (-not ('Win710.ProcessToken' -as [type])) {
        Add-Type -Namespace Win710 -Name ProcessToken -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out IntPtr token);
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool GetTokenInformation(IntPtr token, int infoClass, out int info, int length, out int returnLength);
[DllImport("kernel32.dll")]
public static extern bool CloseHandle(IntPtr handle);
'@
    }
}

function Get-ProcessElevation {
    <# 'elevated', 'normal', 'not running' or 'unknown', for the first process called -Name
       (`710sRice tiling status` asks about komorebi) or the process -Id (doctor asks about
       710.ahk's). Reads the process token's
       TokenElevation. From a NORMAL window Windows won't hand over an elevated process's
       token at all -- while a same-user normal process's token always opens -- so that
       refusal is itself the answer. From an admin window the token opens either way. #>
    [CmdletBinding(DefaultParameterSetName = 'Name')]
    param([Parameter(Mandatory, ParameterSetName = 'Name', Position = 0)][string]$Name,
          [Parameter(Mandatory, ParameterSetName = 'Id')][int]$Id)
    $p = if ($PSCmdlet.ParameterSetName -eq 'Id') { Get-Process -Id $Id -ErrorAction SilentlyContinue }
         else { Get-Process -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $p) { return 'not running' }
    try { Initialize-ProcessTokenNative } catch { return 'unknown' }
    # PROCESS_QUERY_LIMITED_INFORMATION (0x1000): allowed across elevation levels.
    $h = [Win710.ProcessToken]::OpenProcess(0x1000, $false, $p.Id)
    if ($h -eq [IntPtr]::Zero) { return 'unknown' }
    try {
        $token = [IntPtr]::Zero
        if (-not [Win710.ProcessToken]::OpenProcessToken($h, 0x0008, [ref]$token)) {   # TOKEN_QUERY
            if (Test-IsAdmin) { return 'unknown' }
            return 'elevated'
        }
        try {
            $elevated = 0; $len = 0
            # 20 = TokenElevation: one DWORD, non-zero when the token is elevated.
            if (-not [Win710.ProcessToken]::GetTokenInformation($token, 20, [ref]$elevated, 4, [ref]$len)) { return 'unknown' }
            if ($elevated -ne 0) { 'elevated' } else { 'normal' }
        } finally { [void][Win710.ProcessToken]::CloseHandle($token) }
    } finally { [void][Win710.ProcessToken]::CloseHandle($h) }
}

function Get-AutostartStatus {
    <# Key -> bool (task registered or fallback .lnk present), per component. Reads only:
       the names are all it needs, so no launch-<key>.txt is rewritten on the way. #>
    $startup = [Environment]::GetFolderPath('Startup')
    $status = @{}
    foreach ($c in Get-AutostartComponents -NoWrite) {
        $hasTask = Test-Task -TaskName $c.TaskName -AtLogOn
        $hasLnk = Test-Path (Join-Path $startup $c.LnkName)
        $status[$c.Key] = ($hasTask -or $hasLnk)
    }
    $status
}

function Test-FullTimeMachine {
    # install's long-standing rule for "this machine was -Activate'd": any component with a
    # sign-in task (or its Startup-shortcut fallback). install's tasks step keeps such a machine
    # full-time and -Only windows only acts on one; `710sRice doctor` reads its mode line from
    # the same rule. Moved here from install.ps1 (2026-09-27) so the two can't drift. Read-only.
    # (Until 2026-09-28 the lock-screen sync task counted too; it's retired -- every install sets
    # the lock screen now -- so a leftover one says nothing about the mode.)
    $autostart = Get-AutostartStatus
    @($autostart.Values | Where-Object { $_ }).Count -gt 0
}

function Register-OnDemandTasks {
    <# For an install WITHOUT -Activate: every component's task, with no trigger at all.
       Nothing starts at sign-in; Start-All.ps1 (`710sRice start`), reload-stack.ps1
       (SUPER+Shift+R) and 710.ahk's bar watchdog fire them, so an on-demand stack starts
       and restarts exactly like an -Activate'd one -- each at its task's own run level,
       whatever shell fires it: komorebi at the tiling mode's (elevated by default, and no
       UAC prompt), everything else LeastPrivilege. That's also why `710sRice start` works
       from an admin window here: nothing has to be launched directly from it.
       Until 2026-09-26 only komorebi got one (plan doc Open item 37), so on these installs
       every YASB restart through its task -- SUPER+Shift+R's, the watchdog's -- killed the
       bar and left it down (cli-plan, commit 3a). Test-Task -AtLogOn ignores these tasks,
       so they never make the machine look -Activate'd, and uninstall's Unregister-Autostart
       deletes them like any other component task. -Key: just that one component (the
       `tiling` command re-registers komorebi alone). Idempotent (/F). #>
    param([string]$Key)
    $components = @(Get-AutostartComponents | Where-Object { -not $Key -or $_.Key -eq $Key })
    if ($components.Count -eq 0) {
        Step-Warn "On-demand tasks: $(if ($Key) { "$Key isn't installed" } else { 'no components installed' }) -- nothing registered."
        return
    }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $admin = Test-IsAdmin
    $registered = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $components) {
        $runLevel = if ($c.Key -eq 'komorebi') { Get-KomorebiRunLevel } else { 'LeastPrivilege' }
        if ($runLevel -eq 'HighestAvailable' -and -not $admin) {
            # Same rule as Register-Autostart: only an admin can register a task that runs
            # elevated. Only reachable by running install.ps1 directly from a normal window --
            # `710sRice install` always elevates first.
            if (Test-Task -TaskName $c.TaskName) {
                Step-Warn "On-demand task komorebi: elevated tiling needs an admin PowerShell to register -- its existing task was left as it is. Re-run .\install.ps1 from an admin shell."
                continue
            }
            Step-Warn "On-demand task komorebi: elevated tiling needs an admin PowerShell to register -- registering it non-elevated for now (admin windows won't tile). Re-run .\install.ps1 from an admin shell."
            $runLevel = 'LeastPrivilege'
        }
        $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) "710-task-$($c.TaskName)-ondemand.xml"
        try {
            Set-Content -Path $xmlPath -Value (New-TaskXml -Component $c -User $user -RunLevel $runLevel -NoTrigger) -Encoding Unicode
            $null = & schtasks.exe /Create /TN (Get-TaskFullName -TaskName $c.TaskName) /XML $xmlPath /F 2>&1
            if ($LASTEXITCODE -ne 0) { throw "schtasks /Create exited with code $LASTEXITCODE" }
            $registered.Add($c.Key + $(if ($c.Key -eq 'komorebi') { " ($(if ($runLevel -eq 'HighestAvailable') { 'elevated' } else { 'non-elevated' }))" }))
        } catch {
            # Same split as Register-Autostart: a task that exists but couldn't be UPDATED
            # (typically created from an elevated shell, this run isn't) still works as it is.
            if (Test-Task -TaskName $c.TaskName) {
                Step-Warn "On-demand task $($c.Key): couldn't update the existing task ($($_.Exception.Message)) -- keeping the old one."
            } else {
                Step-Warn "On-demand task $($c.Key): couldn't register it ($($_.Exception.Message)) -- ``710sRice start`` will launch it directly instead (from a normal window only)."
            }
        } finally {
            Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($registered.Count -gt 0) {
        Step-Ok "On-demand tasks registered (no sign-in trigger -- ``710sRice start`` fires them): $($registered -join ', ')"
    }
}

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

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Lock screen: your own lock-screen picture -----------------------------------------
# Since 2026-09-28 the lock screen follows the wallpaper as YOUR lock-screen picture (Windows'
# per-user one), set on every wallpaper change by the pipeline -- scripts\Set-LockScreen.ps1
# through tools\lib\lockscreen.ps1, on every install, with no task and no admin. Before that
# (2026-09-22 .. 09-28) -Activate registered an elevated on-demand task that wrote a machine
# policy (HKLM PersonalizationCSP) pointing at the wallpaper file, and the screen before sign-in
# stayed black after a wallpaper change until the next Win+L (plan doc items 46 and 48). What's
# left of that here: retiring it on a machine that still has it.

function Restore-LockScreenPolicy {
    <# Puts the machine policy the old sync wrote (HKLM PersonalizationCSP) back the way it was,
       from the 'lockscreen-personalizationcsp' snapshot install took when it registered the old
       task. On the usual machine nothing was there before, so the whole key goes (and Settings'
       own lock-screen picker works again); otherwise its three values are restored. A key with
       no snapshot of ours is never touched (a company's policy, say), and a key that's already
       gone is fine. Needs admin (HKLM): warns and skips without it. $true when the snapshot was
       used. #>
    $snap = Get-OriginalState -Label 'lockscreen-personalizationcsp'
    if (-not $snap) { return $false }
    if (-not (Test-IsAdmin)) {
        Step-Warn "The old lock-screen policy key needs an admin window to remove -- run this again from one."
        return $false
    }
    $cspPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    $anyExistedBefore = $snap.LockScreenImageStatus.Existed -or $snap.LockScreenImagePath.Existed -or $snap.LockScreenImageUrl.Existed
    if (-not $anyExistedBefore) {
        Remove-Item -Path $cspPath -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Set-RegValueFromSnapshot -Path $cspPath -Name 'LockScreenImageStatus' -Snapshot $snap.LockScreenImageStatus
        Set-RegValueFromSnapshot -Path $cspPath -Name 'LockScreenImagePath' -Snapshot $snap.LockScreenImagePath
        Set-RegValueFromSnapshot -Path $cspPath -Name 'LockScreenImageUrl' -Snapshot $snap.LockScreenImageUrl
    }
    Remove-OriginalState -Label 'lockscreen-personalizationcsp'
    $true
}

function Remove-RetiredLockScreenSync {
    <# Retires the old lock-screen sync on a machine that still has it: the elevated
       'lock-screen-sync' task, its launch file (launch-lock-screen-sync.txt), and the policy it
       wrote (Restore-LockScreenPolicy). Called by install's tasks step (so -Activate, a plain
       re-run and `710sRice install -Only tasks` -- repair's fix, and so update's) and by
       uninstall. A no-op on a machine that never had it. $true when it removed something:
       install then sets your picture once, since nothing else would before the next wallpaper
       change. #>
    $removed = $false
    if (Test-Task -TaskName 'lock-screen-sync') {
        $null = & schtasks.exe /Delete /TN (Get-TaskFullName -TaskName 'lock-screen-sync') /F 2>&1
        if (Test-Task -TaskName 'lock-screen-sync') {
            Step-Warn "Couldn't remove the retired lock-screen sync task -- run this again from an admin window."
        } else {
            Step-Info 'Removed the retired lock-screen sync task (the lock screen is your own picture now, set on every wallpaper change).'
            $removed = $true
        }
    }
    Remove-Item (Join-Path $env:LOCALAPPDATA '710.DesktopRice\launch-lock-screen-sync.txt') -Force -ErrorAction SilentlyContinue
    if (Restore-LockScreenPolicy) {
        Step-Info "Removed the old lock-screen policy key (put back the way it was before 710sRice) -- it hid your own picture."
        $removed = $true
    }
    $removed
}

function Set-LockScreenToWallpaper {
    <# Your lock-screen picture = the wallpaper that's up now, once, outside a wallpaper change:
       install's tasks step, right after retiring the old sync, or when nothing has set it yet.
       One line either way. #>
    $r = Invoke-LockScreenSetter -Root $Root -Image (Get-CurrentWallpaper)
    $text = ConvertTo-SafeText $r.Message
    switch ($r.ExitCode) {
        0       { Step-Ok "Lock screen $text" }
        2       { Step-Warn "Lock screen $text" }
        default { Step-Warn "Lock screen: $text -- it follows the next wallpaper change (SUPER+W)." }
    }
}

function Get-WindowsLockScreenDefault {
    # Windows' own default lock-screen picture, for when your original is gone: img100.jpg in
    # %WINDIR%\Web\Screen, or the first picture there. $null when there's none.
    $dir = Join-Path $env:WINDIR 'Web\Screen'
    $first = Join-Path $dir 'img100.jpg'
    if (Test-Path -LiteralPath $first -PathType Leaf) { return $first }
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.jpg', '.jpeg', '.png' } | Sort-Object Name |
        Select-Object -First 1 -ExpandProperty FullName
}

function Restore-LockScreenPicture {
    <# Uninstall: your lock screen as it was before 710sRice first set it, from the
       'lockscreen-picture' snapshot scripts\Set-LockScreen.ps1 takes before its first set. The
       picture first -- the original file (Windows reports the original, not a copy), or Windows'
       own default picture when that file is gone -- THEN the Spotlight / Slideshow settings, so it
       doesn't matter whether setting a picture switched them off. If -Activate had already
       switched Spotlight off when the snapshot was taken (Hardened), those two values were its,
       not the original: its own revert (Set-WindowsHardening -Revert) puts them back, so they're
       left alone here. Run after that revert. -> 'restored', 'default' (the original was gone),
       'failed', or $null (nothing ever set here -- nothing to do). #>
    $snap = Get-OriginalState -Label 'lockscreen-picture'
    if (-not $snap) { return $null }
    $img = "$($snap.Image)"
    $result = 'restored'
    if (-not $img -or -not (Test-Path -LiteralPath $img -PathType Leaf)) { $img = Get-WindowsLockScreenDefault; $result = 'default' }
    if ($img) {
        $r = Invoke-LockScreenSetter -Root $Root -Image $img
        if ($r.ExitCode -notin 0, 2) { Step-Warn "Lock-screen picture not put back: $(ConvertTo-SafeText $r.Message)"; $result = 'failed' }
    } else { $result = 'failed' }
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    if (-not $snap.Hardened) {
        foreach ($name in 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled') {
            if ($snap[$name]) { Set-RegValueFromSnapshot -Path $cdm -Name $name -Snapshot $snap[$name] }
        }
    }
    if ($snap.SlideshowEnabled) {
        Set-RegValueFromSnapshot -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen' -Name 'SlideshowEnabled' -Snapshot $snap.SlideshowEnabled
    }
    Remove-OriginalState -Label 'lockscreen-picture'
    Remove-Item -LiteralPath (Get-LockScreenRecordPath) -Force -ErrorAction SilentlyContinue
    $result
}

# --- Stopping running components (uninstall-only; not gated behind -Activate) --------
function Stop-RunningComponents {
    <# Stops every process 710.DesktopRice may have launched, whether or not -Activate/
       autostart was ever registered -- install.ps1's own "start now" step (-Activate) can
       leave these running even after autostart itself is torn down, and a machine that was
       only ever coexisting (no -Activate) may still have been started by hand. winarchy's
       own uninstall.ps1 never stops anything at all (a documented gap this repo closes --
       see plan doc); called unconditionally, first thing, from uninstall.ps1, independent
       of whatever -Activate state the install was left in. Each component is independent
       and best-effort (one failing to stop doesn't block the rest of the uninstall), and
       nothing here touches a process this repo didn't start -- see the AHK note below. #>

    # komorebi: try its own graceful `stop` first (releases window-management hooks,
    # restores window styles/borders) before a hard kill, so a stray leftover style isn't
    # left on a window after uninstall.
    # komorebic next to komorebi.exe first (Get-KomorebicExe): from a window whose PATH predates
    # the install, a PATH lookup found nothing, the graceful stop never ran, and windows komorebi
    # had cloaked on other workspaces stayed invisible after the kill (Group 1 W6).
    if (Get-Process komorebi -ErrorAction SilentlyContinue) {
        $komorebic = Get-KomorebicExe
        if ($komorebic) { try { & $komorebic stop 2>$null | Out-Null; Start-Sleep -Milliseconds 300 } catch { } }
        Stop-Process -Name komorebi -Force -ErrorAction SilentlyContinue
        # In elevated tiling mode komorebi runs as admin: `komorebic stop` still reaches it
        # from a normal shell, but the force-kill fallback can't -- so say so if it's still up.
        Start-Sleep -Milliseconds 300
        if (Get-Process komorebi -ErrorAction SilentlyContinue) {
            Step-Warn 'komorebi is still running (in elevated tiling mode it runs as admin, which a normal shell cannot force-stop). Run this from an admin PowerShell.'
        }
    }

    # YASB: same graceful-stop-then-kill pattern.
    if (Get-Process yasb -ErrorAction SilentlyContinue) {
        $yasbc = Get-YasbcExe
        if ($yasbc) { try { & $yasbc stop 2>$null | Out-Null; Start-Sleep -Milliseconds 300 } catch { } }
        Stop-Process -Name yasb -Force -ErrorAction SilentlyContinue
    }

    # ShareX: no CLI stop -- the resident tray process is all there is to end.
    Stop-Process -Name ShareX -Force -ErrorAction SilentlyContinue

    # AHK, last. 710.ahk runs with UI Access (AutoHotkey64_UIA.exe), and a normal shell
    # (Stop-All.ps1) can't Stop-Process a UIA process -- 'Access is denied', found live
    # 2026-09-25. So: ask it to quit first (710.ahk lets exactly this one message through
    # its UIPI filter), give it a couple of seconds, then fall back to the old kill for
    # anything still standing -- which works from uninstall's admin shell, and for a
    # plain-AutoHotkey64 710.ahk from anywhere. Both steps only ever touch THIS repo's
    # 710.ahk (window title / command line), never a blanket Stop-Process: another AHK v2
    # script the person runs isn't ours to touch.
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    if (Send-AhkQuit -ScriptPath $ahkScript) {
        $deadline = (Get-Date).AddSeconds(2)
        while ((Get-Date) -lt $deadline -and (Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 100
        }
    }
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe' OR Name = 'AutoHotkey64_UIA.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ahkScript) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {
        Step-Warn "Could not check for a running 710.ahk AutoHotkey process (Win32_Process unavailable): $($_.Exception.Message)"
    }
    if ((Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero) {
        Step-Warn '710.ahk is still running (it runs with UI Access, which a normal shell cannot force-stop). Quit it from its tray icon, or run this from an admin PowerShell.'
    }
}

function Find-AhkWindow {
    <# The hidden main window of the AHK process running -ScriptPath, or [IntPtr]::Zero.
       AHK titles that window "<full script path> - AutoHotkey v2.x", so the title is how we
       tell 710.ahk apart from any other AHK script. Found by window rather than by
       Win32_Process because a normal shell can't read a UI Access process's command line;
       window titles, on the other hand, are readable across that boundary (open-main-menu.ahk
       finds 710.ahk the same way). #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    Initialize-AhkWindowNative
    $hwnd = [IntPtr]::Zero
    while ($true) {
        # [NullString]::Value, NOT $null: PowerShell hands $null to a .NET string parameter
        # as "" -- and FindWindowEx(..., "") only matches windows with an EMPTY title, so
        # the first build of this never found 710.ahk (Stop-All left it running, 2026-09-25).
        $hwnd = [Win710.AhkWindow]::FindWindowEx([IntPtr]::Zero, $hwnd, 'AutoHotkey', [NullString]::Value)
        if ($hwnd -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        $sb = [System.Text.StringBuilder]::new(1024)
        [void][Win710.AhkWindow]::GetWindowText($hwnd, $sb, $sb.Capacity)
        if ($sb.ToString().IndexOf($ScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $hwnd }
    }
}

function Send-AhkMessage {
    <# Posts the registered window message -Name ('710sRice.Quit', '710sRice.ReloadStack') to
       710.ahk -- see the OnMessage hooks next to OpenMainMenu in config\ahk\710.ahk, each let
       through UIPI there because AHK runs with UI Access. $true if a 710.ahk window was found
       and the post went through, $false otherwise (AHK not running, as far as the caller
       cares). Fire-and-forget: a post doesn't wait for AHK to act on it. #>
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$Name)
    $hwnd = Find-AhkWindow -ScriptPath $ScriptPath
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    $msg = [Win710.AhkWindow]::RegisterWindowMessage($Name)
    return [Win710.AhkWindow]::PostMessage($hwnd, $msg, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Send-AhkQuit {
    <# Asks 710.ahk to quit ('710sRice.Quit'). $false = no 710.ahk window found; the caller's
       kill fallback covers the rest. #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    Send-AhkMessage -ScriptPath $ScriptPath -Name '710sRice.Quit'
}

function Initialize-AhkWindowNative {
    if (-not ('Win710.AhkWindow' -as [type])) {
        Add-Type -Namespace Win710 -Name AhkWindow -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern uint RegisterWindowMessage(string lpString);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
'@
    }
}

function Get-AhkWindowProcessId {
    <# The process id behind 710.ahk's window (Find-AhkWindow), or $null when it isn't running.
       How `710sRice doctor` tells which exe runs 710.ahk (UI Access or not) and reads its
       elevation -- by the window, not by process name, so another AHK script can't pass for it. #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    $hwnd = Find-AhkWindow -ScriptPath $ScriptPath
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $procId = [uint32]0
    [void][Win710.AhkWindow]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    if ($procId) { [int]$procId } else { $null }
}

# --- Shell profile hook ($PROFILE -> config\pwsh\profile.ps1) ------------------------
# Ported from winarchy's ShellProfile.ps1 @ 4574fc7: a marker-delimited block inserted (or
# updated) in pwsh's CurrentUserAllHosts $PROFILE, idempotent, snapshotting the profile
# before any change (Copy-Item .bak, this repo's own established pattern -- see
# tools/components/flow.ps1 -- rather than winarchy's own New-WinarchySnapshot module).
$script:ProfileMarkerStart = '# >>> managed by 710.DesktopRice >>>'
$script:ProfileMarkerEnd = '# <<< managed by 710.DesktopRice <<<'

function Get-ShellProfilePath {
    # Computed by hand (not $PROFILE) so this works even when the calling session isn't
    # pwsh with $PROFILE populated.
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\profile.ps1'
}

function Get-ShellProfileBlock {
    # The exact block install writes into $PROFILE for this clone -- one definition, read by
    # Install-ShellProfile and by `710sRice doctor` (Get-ShellProfileHookState). The path goes
    # in single quotes, so a ' in it is doubled: a clone under a folder with an apostrophe broke
    # every new PS7 window (winarchy 731a0a1, Group 1 W5). Every other path's block is
    # byte-identical to before; an old unescaped one reads as "points somewhere else" to doctor,
    # whose fix (-Only profile) rewrites it.
    $managed = Join-Path $Root 'config\pwsh\profile.ps1'
    @(
        $script:ProfileMarkerStart
        ". '$($managed.Replace("'", "''"))'"
        $script:ProfileMarkerEnd
    ) -join "`r`n"
}

function Get-ShellProfileHookState {
    <# Read-only, for doctor: 'installed' ($PROFILE holds this clone's block exactly as
       Install-ShellProfile writes it), 'other' (a 710.DesktopRice block pointing somewhere
       else -- a moved clone, say), or 'missing' (no block, or no profile file at all). #>
    $profilePath = Get-ShellProfilePath
    if (-not (Test-Path -LiteralPath $profilePath)) { return 'missing' }
    $existing = Get-Content -LiteralPath $profilePath -Raw
    $pattern = '(?s)' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd)
    if ("$existing" -notmatch $pattern) { return 'missing' }
    if (($Matches[0] -replace '\r?\n', "`r`n") -eq (Get-ShellProfileBlock)) { 'installed' } else { 'other' }
}

function Install-ShellProfile {
    $profilePath = Get-ShellProfilePath
    $block = Get-ShellProfileBlock

    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
    $pattern = '(?s)' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd)

    if ($existing -match $pattern) {
        if (($Matches[0] -replace '\r?\n', "`r`n") -eq $block) {
            Step-Ok "Profile hook already installed: $(ConvertTo-SafePath $profilePath)"
            return
        }
        Copy-Item $profilePath "$profilePath.bak" -Force
        $updated = [regex]::Replace($existing, $pattern, $block.Replace('$', '$$'))
        Set-Content -Path $profilePath -Value $updated -Encoding utf8NoBOM
        Step-Ok "Profile hook updated: $(ConvertTo-SafePath $profilePath) (previous saved to $(ConvertTo-SafePath "$profilePath.bak"))"
        return
    }

    if (Test-Path $profilePath) { Copy-Item $profilePath "$profilePath.bak" -Force }
    else { New-Item -ItemType Directory -Path (Split-Path $profilePath) -Force | Out-Null }
    $newContent = if ($existing.Trim()) { $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n" } else { $block + "`r`n" }
    Set-Content -Path $profilePath -Value $newContent -Encoding utf8NoBOM
    Step-Ok "Profile hook installed: $(ConvertTo-SafePath $profilePath)"
}

function Remove-ShellProfile {
    $profilePath = Get-ShellProfilePath
    if (-not (Test-Path $profilePath)) {
        Step-Info 'No pwsh $PROFILE found; nothing to remove.'
        return
    }
    $existing = Get-Content $profilePath -Raw
    $pattern = '(?s)\r?\n?' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd) + '\r?\n?'
    if ($existing -notmatch $pattern) {
        Step-Info 'Profile hook not present; nothing to remove.'
        return
    }
    Copy-Item $profilePath "$profilePath.bak" -Force
    $updated = [regex]::Replace($existing, $pattern, "`r`n").Trim()
    if ($updated) { Set-Content -Path $profilePath -Value ($updated + "`r`n") -Encoding utf8NoBOM }
    else { Remove-Item $profilePath }
    Step-Ok "Profile hook removed: $(ConvertTo-SafePath $profilePath) (previous saved to $(ConvertTo-SafePath "$profilePath.bak"))"
}

# --- Restoring theming side effects (wallpaper/accent/Terminal/Flow) -- uninstall-only --
# The wallpaper/lock-screen restore functions live next to what they revert, above
# (Restore-OriginalWallpaper near Set-DesktopWallpaper, Restore-LockScreenPicture in the lock
# screen's own section). These three cover the rest of what install.ps1 Section 4
# and tools\apply-wallust-outputs.ps1 change on a real wallpaper/theme apply, plus Flow
# Launcher's theme -- all called from uninstall.ps1. (Flow's own settings are its component's:
# tools\components\flow.ps1.)
function Restore-WindowsAccent {
    <# Reverts the accent-color/dark-mode values tools\apply-wallust-outputs.ps1 sets,
       back to its own 'windows-accent' snapshot (taken there, via a small duplicated
       inline copy of Save-OriginalState/Get-RegValueSnapshot -- see that script and this
       file's header note on why it doesn't dot-source this one). $null means that script
       never actually ran on this machine -- safe no-op. #>
    $snap = Get-OriginalState -Label 'windows-accent'
    if (-not $snap) { return $false }
    $personalize = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $dwm = 'HKCU:\SOFTWARE\Microsoft\Windows\DWM'
    Set-RegValueFromSnapshot -Path $personalize -Name 'AppsUseLightTheme' -Snapshot $snap.Personalize_AppsUseLightTheme
    Set-RegValueFromSnapshot -Path $personalize -Name 'SystemUsesLightTheme' -Snapshot $snap.Personalize_SystemUsesLightTheme
    Set-RegValueFromSnapshot -Path $personalize -Name 'ColorPrevalence' -Snapshot $snap.Personalize_ColorPrevalence
    Set-RegValueFromSnapshot -Path $dwm -Name 'ColorPrevalence' -Snapshot $snap.Dwm_ColorPrevalence
    Set-RegValueFromSnapshot -Path $dwm -Name 'AccentColor' -Snapshot $snap.Dwm_AccentColor
    Set-RegValueFromSnapshot -Path $dwm -Name 'ColorizationColor' -Snapshot $snap.Dwm_ColorizationColor
    Send-SettingChangeBroadcast
    Remove-OriginalState -Label 'windows-accent'
    return $true
}

function Get-NerdFontFace {
    <# The face name Windows Terminal should use for the JetBrainsMono Nerd Font the packages step
       installs (DEVCOM.JetBrainsMonoNerdFont, Nerd Fonts v3: "JetBrainsMono NF"; v2 called it
       "JetBrainsMono Nerd Font"), from the fonts Windows has registered -- $null when it isn't
       installed. Install's terminal step and doctor's check both ask here. #>
    $names = @(Get-InstalledFontNames)
    if (@($names | Where-Object { $_ -match '^JetBrainsMono NF[ (]' }).Count) { return 'JetBrainsMono NF' }
    if (@($names | Where-Object { $_ -match '^JetBrainsMono Nerd Font[ (]' }).Count) { return 'JetBrainsMono Nerd Font' }
    $null
}

function Get-TerminalFontFaces {
    <# Every place Windows Terminal's settings name a font face: profiles.defaults (every profile),
       and each profile in profiles.list that sets its own -- a profile's own face wins over the
       defaults, so those are the faces Terminal draws with. [pscustomobject] Key ('defaults', or
       the profile's guid -- 'name:<name>' without one), Name, Face ($null: the defaults set none). #>
    param($Settings)
    $p = $Settings['profiles']
    if ($p -isnot [System.Collections.IDictionary]) { return }
    $d = $p['defaults']
    $face = if ($d -is [System.Collections.IDictionary] -and $d['font'] -is [System.Collections.IDictionary] -and $d['font'].Contains('face')) { "$($d['font']['face'])" } else { $null }
    [pscustomobject]@{ Key = 'defaults'; Name = 'every profile'; Face = $face }
    foreach ($x in @($p['list'])) {
        if ($x -isnot [System.Collections.IDictionary] -or $x['font'] -isnot [System.Collections.IDictionary] -or -not $x['font'].Contains('face')) { continue }
        $key = if ($x['guid']) { "$($x['guid'])" } else { "name:$($x['name'])" }
        [pscustomobject]@{ Key = $key; Name = "$($x['name'])"; Face = "$($x['font']['face'])" }
    }
}

function Set-TerminalFontFace {
    <# Sets (or, $Face = $null, removes) the font face at one Get-TerminalFontFaces Key in the
       settings hashtable; a font object left empty is removed with it. Leaves size / weight alone. #>
    param($Settings, [string]$Key, [AllowNull()][string]$Face)
    if ($Settings['profiles'] -isnot [System.Collections.IDictionary]) { $Settings['profiles'] = @{} }
    $p = $Settings['profiles']
    $target = if ($Key -eq 'defaults') {
        if ($p['defaults'] -isnot [System.Collections.IDictionary]) { $p['defaults'] = @{} }
        $p['defaults']
    } else {
        @($p['list']) | Where-Object { $_ -is [System.Collections.IDictionary] -and ($(if ($Key.StartsWith('name:')) { "name:$($_['name'])" } else { "$($_['guid'])" }) -eq $Key) } | Select-Object -First 1
    }
    if (-not $target) { return }
    if ($null -eq $Face -or $Face -eq '') {
        if ($target['font'] -is [System.Collections.IDictionary]) {
            $target['font'].Remove('face')
            if (-not $target['font'].Count) { $target.Remove('font') }
        }
    } else {
        if ($target['font'] -isnot [System.Collections.IDictionary]) { $target['font'] = @{} }
        $target['font']['face'] = $Face
    }
}

function Clear-TerminalNerdFontFaces {
    <# uninstall -Force, right before it removes the JetBrainsMono Nerd Font package: any Windows
       Terminal face that still names it (after uninstall put Terminal's own "before" back -- a
       "before" that was already the Nerd Font, winarchy's on the Dell, or yours) goes back to
       Terminal's own font. Removing the font while Terminal draws with it is the likeliest reason
       B2's uninstall window vanished before its exit code (2026-10-01; the Dell's Terminal used it
       then). Returns the names of the places changed (empty: nothing to do; $null: no settings). #>
    $path = @("$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
              "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $path) { return $null }
    $wt = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    $hits = @(Get-TerminalFontFaces $wt | Where-Object { "$($_.Face)" -match '^JetBrainsMono (NF|NFM|NFP|Nerd Font)\b' })
    foreach ($h in $hits) { Set-TerminalFontFace -Settings $wt -Key "$($h.Key)" -Face $null }
    if ($hits.Count) { $wt | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding UTF8 }
    @($hits | ForEach-Object Name)
}

function Test-TerminalUsesScheme {
    # Does any profile draw with colour scheme $Name -- profiles.defaults or one in profiles.list,
    # named directly or as either half of a { light, dark } pair?
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name)
    $p = $Settings['profiles']
    if ($p -isnot [System.Collections.IDictionary]) { return $false }
    foreach ($x in @($p['defaults']) + @($p['list'])) {
        if ($x -isnot [System.Collections.IDictionary] -or -not $x.Contains('colorScheme')) { continue }
        $cs = $x['colorScheme']
        if ($cs -is [System.Collections.IDictionary]) { if ("$($cs['light'])" -eq $Name -or "$($cs['dark'])" -eq $Name) { return $true } }
        elseif ("$cs" -eq $Name) { return $true }
    }
    $false
}

function Restore-WindowsTerminalSettings {
    <# Reverts both Terminal changes back to their own independent snapshots: 'terminal-
       colorscheme' (profiles.defaults.colorScheme/theme/the "wallust" themes[] entry --
       taken by tools\apply-wallust-outputs.ps1's own inline duplicate, same reasoning as
       Restore-WindowsAccent above) and 'terminal-defaultprofile' (taken by install.ps1
       Section 8). Two separate labels, not one, because they're written by two different
       scripts that don't run in a fixed relative order relative to each other over the
       life of an install (Section 4 calls apply-wallust-outputs.ps1 before Section 8 ever
       runs on a first install, but apply-wallust-outputs.ps1 also fires independently on
       every later real wallpaper change) -- combining them into one label would let
       whichever runs first "win" the snapshot and silently drop the other's fields.
       Applies whichever of the two snapshots exist (each is independently optional) to
       the CURRENT settings.json in a single read-modify-write, so anything else the person
       changed in Terminal in between (a new profile, a font tweak) survives. #>
    # (And 'terminal-font' -- the font faces install's terminal step set since 2026-10-01: the
    # defaults' and each profile's own -- applied the same way.)
    $colorSnap = Get-OriginalState -Label 'terminal-colorscheme'
    $profileSnap = Get-OriginalState -Label 'terminal-defaultprofile'
    $fontSnap = Get-OriginalState -Label 'terminal-font'
    if (-not $colorSnap -and -not $profileSnap -and -not $fontSnap) { return $false }

    $wtSettingsCandidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    $wtSettingsPath = $wtSettingsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $wtSettingsPath) {
        Step-Info 'Windows Terminal settings.json not found -- nothing to restore (already gone, or Terminal was never launched).'
        Remove-OriginalState -Label 'terminal-colorscheme'
        Remove-OriginalState -Label 'terminal-defaultprofile'
        Remove-OriginalState -Label 'terminal-font'
        return $true
    }
    $wt = Get-Content $wtSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

    if ($colorSnap) {
        if ($colorSnap.ColorSchemeExisted -and $wt['profiles'] -and $wt['profiles']['defaults'] -is [hashtable]) {
            $wt['profiles']['defaults']['colorScheme'] = $colorSnap.ColorScheme
        } elseif ($wt['profiles'] -and $wt['profiles']['defaults'] -is [hashtable]) {
            $wt['profiles']['defaults'].Remove('colorScheme')
        }
        if ($colorSnap.ThemeKeyExisted) { $wt['theme'] = $colorSnap.Theme }
        elseif ($wt.ContainsKey('theme')) { $wt.Remove('theme') }
        if (-not $colorSnap.WallustThemeEntryExisted -and $wt['themes'] -is [array]) {
            $wt['themes'] = @($wt['themes'] | Where-Object { $_['name'] -ne 'wallust' })
        }
        # The "wallust" colour scheme itself (the palette's Terminal target adds it to schemes[]): gone
        # too once nothing uses it -- the defaults or a profile of its own, as a name or as a light /
        # dark pair. It used to stay in Terminal's scheme list forever (found 2026-10-01). Still
        # used = kept (a "before" that already said wallust -- the Dell's -- or your own pick).
        if ($wt['schemes'] -is [array] -and -not (Test-TerminalUsesScheme -Settings $wt -Name 'wallust')) {
            $wt['schemes'] = @($wt['schemes'] | Where-Object { -not ($_ -is [System.Collections.IDictionary] -and $_['name'] -eq 'wallust') })
        }
        Remove-OriginalState -Label 'terminal-colorscheme'
    }
    if ($profileSnap) {
        if ($profileSnap.Existed) { $wt['defaultProfile'] = $profileSnap.Value }
        elseif ($wt.ContainsKey('defaultProfile')) { $wt.Remove('defaultProfile') }
        Remove-OriginalState -Label 'terminal-defaultprofile'
    }
    if ($fontSnap) {
        # Each face install changed, back as it was (the defaults' and each profile's own; a profile
        # that's gone since is skipped). Faces you set after install on other profiles stay.
        foreach ($f in @($fontSnap.Faces)) { Set-TerminalFontFace -Settings $wt -Key "$($f.Key)" -Face $f.Face }
        Remove-OriginalState -Label 'terminal-font'
    }

    $wt | ConvertTo-Json -Depth 50 | Set-Content -Path $wtSettingsPath -Encoding UTF8
    return $true
}

function Restore-FlowTheme {
    <# Undoes the palette pipeline's Flow target (tools\palette\targets\flow.ps1): Flow's selected
       theme goes back to what it was before (the 'flow-theme' snapshot) and our 710sRice.xaml is
       deleted. Only while Flow is still on ours -- a theme you picked yourself since stays. The
       old theme comes back only if its file still exists (Flow shows an error box at start for a
       theme it can't find -- winarchy's Winarchy.xaml, say, once that's gone); otherwise the key
       goes and Flow uses its own default. Flow is stopped first and NOT relaunched, as in
       the flow component's uninstall (tools\components\flow.ps1). $false when there was nothing
       to undo. #>
    $snap = Get-OriginalState -Label 'flow-theme'
    $flowRoot = Join-Path $env:APPDATA 'FlowLauncher'
    $xaml = Join-Path $flowRoot 'Themes\710sRice.xaml'
    if (-not $snap -and -not (Test-Path -LiteralPath $xaml)) { return $false }
    $flow = @(Get-Process -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)
    if ($flow.Count) {
        $flow | Stop-Process -Force
        $flow | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
    }
    $settingsPath = Join-Path $flowRoot 'Settings\Settings.json'
    if ($snap -and (Test-Path -LiteralPath $settingsPath)) {
        $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ("$($settings['Theme'])" -eq '710sRice') {
            $old = "$($snap.Theme)"
            $oldThere = $old -and (@(Join-Path $flowRoot "Themes\$old.xaml") + @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'FlowLauncher\app-*\Themes') -Filter "$old.xaml" -File -ErrorAction SilentlyContinue | ForEach-Object FullName) |
                        Where-Object { Test-Path -LiteralPath $_ }).Count
            if ($snap.ThemeExisted -and $oldThere) { $settings['Theme'] = $old } else { $settings.Remove('Theme') }
            $settings | ConvertTo-Json -Depth 50 | Set-Content -Path $settingsPath -Encoding UTF8
        }
    }
    Remove-Item -LiteralPath $xaml -Force -ErrorAction SilentlyContinue
    Remove-OriginalState -Label 'flow-theme'
    $true
}
