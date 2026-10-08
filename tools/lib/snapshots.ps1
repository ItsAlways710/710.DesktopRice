<#
.SYNOPSIS
  Saving what was there before 710sRice changed it: the original-state snapshots uninstall puts
  back, single registry values in a form that can be restored, and reg.exe exports of whole keys
  (backups\, a safety net for a person). Loaded by tools\lib\activation.ps1. Only functions.
#>

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

# --- Original-state snapshots (true "restore to before 710.DesktopRice" on uninstall) --
# Different problem from Backup-RegistryKey above and from the hardening/taskbar revert
# pattern in tools\lib\fulltime.ps1: those settings don't exist on a stock Windows install, so
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
