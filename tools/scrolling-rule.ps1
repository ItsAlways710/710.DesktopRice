#Requires -Version 7.0
<#
.SYNOPSIS
  Scrolling beside another screen: when komorebi's screens have changed, every workspace in
  komorebi's Scrolling layout on a screen with another screen to its left or right goes to
  Columns -- komorebi would put the windows that scroll off that screen on its neighbour.

.DESCRIPTION
  The rule (his, 2026-10-06; its shape 2026-10-08): Scrolling only on a screen with no other
  screen beside it -- "beside" meaning their heights overlap at all, so one above or below
  doesn't count. SUPER+Alt+L checks it before it switches (config\ahk\710\scrolling.ahk, the
  same test as Test-SideNeighbour below); the bar's layout button and SUPER+Shift+L are YASB's
  and komorebi's own and don't (his call). This covers what the key can't: a screen that gets a
  neighbour later.

  Two callers, the same run:
    - 710.ahk, once a display change has settled: 2 s after its monitor watcher's 8 s nudge
      (config\ahk\710\monitor-watcher.ahk), so komorebi has recounted the screens.
    - scripts\Start-Komorebi.ps1 (-AfterStart), last thing after every komorebi start: komorebi
      brings back the layouts it saved at its last clean stop, so screens changed while it was
      stopped would otherwise keep a Scrolling beside a screen.
  It acts only when komorebi's screens -- how many, where, how big, in komorebi's order -- differ
  from the ones it saw last time (scrolling-screens.json in the logs folder; none yet counts as
  different). So a "devices changed" with nothing changed (Godzilla logs one about every ten
  minutes), or a restart on the same screens, leaves a Scrolling picked from the bar alone. The
  rectangles are komorebi's own (`komorebic state`: each monitor's size, whose right and bottom
  are the WIDTH and HEIGHT -- komorebi-layouts rect.rs), never mixed with Windows' numbers.

  Each switch is a line in display-changes.log (710sRice logs). scrolling-rule.txt holds the
  toast: 710.ahk shows it when this exits 10, and -AfterStart asks a running 710.ahk to show it
  ('710sRice.ScrollingSwitched').

  Exit codes: 0 = nothing to switch (the screens it already checked, or nothing in Scrolling
  beside a screen); 10 = switched at least one; 1 = komorebi couldn't be read (not running,
  paused, no answer) or a switch failed -- the record stays as it was, so the next run still
  sees the change.
#>
[CmdletBinding()]
param([switch]$AfterStart)
$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'display-changes.log'
$record = Join-Path $logDir 'scrolling-screens.json'
$toast  = Join-Path $logDir 'scrolling-rule.txt'
$when   = if ($AfterStart) { 'after komorebi started' } else { 'after a display change' }

function Write-DisplayLog([string]$Message) {
    # 710.ahk's DisplayLogLine format (710.ahk caps the file). A line lost to a clash with it is no harm.
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        "{0}  scrolling rule ({1}): {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $when, $Message |
            Out-File -LiteralPath $log -Append -Encoding utf8
    } catch { }
}

function Write-StateFile([string]$Path, [string]$Text) {
    # Whole or not at all: a temp file moved over the old one, so a reader never sees half of it.
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Text + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-SideNeighbour($Screens, [int]$Index) {
    # Another screen whose height overlaps this one's at all: it's to the left or the right.
    $me = $Screens[$Index]
    for ($i = 0; $i -lt $Screens.Count; $i++) {
        if ($i -eq $Index) { continue }
        $o = $Screens[$i]
        if ($o.Top -lt $me.Top + $me.Height -and $me.Top -lt $o.Top + $o.Height) { return $true }
    }
    $false
}

# Where winget installs it (reload-stack.ps1 looks the same way); PATH as a fallback.
$komorebic = Join-Path $env:ProgramFiles 'komorebi\bin\komorebic.exe'
if (-not (Test-Path -LiteralPath $komorebic)) { $komorebic = (Get-Command komorebic -ErrorAction SilentlyContinue)?.Source }

$state = $null
if ($komorebic -and (Get-Process komorebi -ErrorAction SilentlyContinue)) {
    try {
        $raw = & $komorebic state 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) { $state = ($raw -join "`n") | ConvertFrom-Json }
    } catch { $state = $null }
}
$mons = @(if ($state) { $state.monitors.elements })
if (-not $mons.Count) {
    Write-DisplayLog "couldn't read komorebi's screens -- nothing checked"
    exit 1
}
if ($state.is_paused) {
    # Paused, komorebi ignores a layout change: look again at the next change or start.
    Write-DisplayLog 'komorebi is paused -- nothing checked'
    exit 1
}

$screens = @(foreach ($m in $mons) {
    [pscustomobject]@{ Left = [int]$m.size.left; Top = [int]$m.size.top; Width = [int]$m.size.right; Height = [int]$m.size.bottom }
})
$now = ConvertTo-Json -InputObject $screens -Compress   # -InputObject keeps even one screen a list
$last = $null
try { if (Test-Path -LiteralPath $record) { $last = (Get-Content -LiteralPath $record -Raw).Trim() } } catch { $last = $null }
if ($last -ceq $now) { exit 0 }   # the screens it already checked

$switched = [System.Collections.Generic.List[string]]::new()
$failed = $false
for ($mi = 0; $mi -lt $mons.Count; $mi++) {
    if (-not (Test-SideNeighbour $screens $mi)) { continue }
    $wss = @($mons[$mi].workspaces.elements)
    for ($wi = 0; $wi -lt $wss.Count; $wi++) {
        if ($wss[$wi].layout.Default -ne 'Scrolling') { continue }
        $name = if ($wss[$wi].name) { $wss[$wi].name } else { "$($mi + 1)-$($wi + 1)" }
        $said = ''
        try { $said = (& $komorebic workspace-layout $mi $wi columns 2>&1) -join ' ' } catch { $said = $_.Exception.Message; $global:LASTEXITCODE = 1 }
        if ($LASTEXITCODE -eq 0) {
            $switched.Add($name)
            Write-DisplayLog "workspace $name has a screen beside it now -- switched from Scrolling to Columns"
        } else {
            $failed = $true
            Write-DisplayLog "workspace $name has a screen beside it now, but couldn't be switched to Columns: $said"
        }
    }
}
if ($failed) { exit 1 }   # the record stays as it was: the next run tries again

try { Write-StateFile $record $now }
catch { Write-DisplayLog "couldn't save the screens it checked ($($_.Exception.Message)) -- it looks again next time" }
if (-not $switched.Count) { exit 0 }

$list = $switched -join ', '
$text = if ($switched.Count -eq 1) { "Workspace $list switched from Scrolling to Columns: there's a screen beside it now" }
        else { "Workspaces $list switched from Scrolling to Columns: there's a screen beside them now" }
try { Write-StateFile $toast $text }
catch { Write-DisplayLog "couldn't write the toast ($($_.Exception.Message))" }
if ($AfterStart) {
    # 710.ahk shows the toast. Not running (yet), or from before this message: the log has the switch.
    try {
        . (Join-Path $Root 'tools\lib\ahk.ps1')
        $null = Send-AhkMessage -ScriptPath (Join-Path $Root 'config\ahk\710.ahk') -Name '710sRice.ScrollingSwitched'
    } catch { Write-DisplayLog "couldn't ask 710.ahk for the toast ($($_.Exception.Message))" }
}
exit 10
