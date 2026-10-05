#Requires -Version 7.0
<#
.SYNOPSIS
  The screens menu's helper (710.ahk: the bar's monitor button, SUPER+Alt+Space > Screens).
  -Snapshot writes what Windows says about every connected screen to
  %LOCALAPPDATA%\710.DesktopRice\screens.tsv, which the menu reads.

.DESCRIPTION
  Why a snapshot: the menu opens at once from a small file instead of waiting about a second for
  a cold pwsh and the DisplayConfig module every time. 710.ahk takes one when it starts and again
  3 s after the last display or device change (a scale change arrives as one too), so it's
  current by the time a menu opens.

  The DisplayConfig module (versions.md; MartinGC94, MIT; Windows' own CCD display APIs) reads the
  screens. Every connected one is listed, on or off -- Get-DisplayInfo's Active says which.

  The file: a header line, then one tab-separated line per screen.
    # 710sRice screens v1 <time>
    id <TAB> on <TAB> main <TAB> scale <TAB> steps <TAB> name
  id     DisplayConfig's DisplayId (what its commands take)
  on     1 or 0 (Active)
  main   1 or 0 (Primary)
  scale  the current scale in percent; empty while the screen is off (Windows only scales a
         screen that's on) or when its scale couldn't be read
  steps  the scales Windows allows for that screen, comma-separated, from 100 up to its maximum;
         empty while it's off
  name   its name as Windows has it, or "Display <id>"
  Something failed (DisplayConfig missing, or it threw): the header line ends in
  " error: <why>" and no screen lines follow, so the menu says why instead of listing stale
  screens. Written to a temp file first and moved over the old one, so the menu never reads half
  a file.

  Exit codes: 0 = written; 1 = written with an error line; 2 = no -Snapshot (usage).
#>
param([switch]$Snapshot)

$ErrorActionPreference = 'Stop'
if (-not $Snapshot) { Write-Host 'Usage: screens.ps1 -Snapshot'; exit 2 }

$stateDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$out = Join-Path $stateDir 'screens.tsv'

function Write-Snapshot([string[]]$Lines) {
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $tmp = "$out.tmp"
    [IO.File]::WriteAllLines($tmp, $Lines, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $out -Force
}

# Windows' scale steps, as DisplayConfig's DpiScale has them: 100 is always the smallest, and a
# screen allows every step up to its MaxScale.
$scaleSteps = 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

try {
    Import-Module DisplayConfig -ErrorAction Stop
} catch {
    Write-Snapshot @("# 710sRice screens v1 $stamp error: The DisplayConfig module isn't installed -- 710sRice install -Only packages")
    exit 1
}

try {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# 710sRice screens v1 $stamp")
    foreach ($d in @(Get-DisplayInfo)) {
        $scale = ''
        $steps = ''
        if ($d.Active) {
            # One screen whose scale can't be read is listed without one, rather than losing the
            # whole list.
            try {
                $s = Get-DisplayScale -DisplayId $d.DisplayId
                $scale = "$($s.CurrentScale)"
                $steps = @($scaleSteps | Where-Object { $_ -le $s.MaxScale }) -join ','
            } catch {
                $scale = ''
                $steps = ''
            }
        }
        $name = "$($d.DisplayName)" -replace '[\t\r\n]+', ' '
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Display $($d.DisplayId)" }
        $lines.Add((@($d.DisplayId, [int][bool]$d.Active, [int][bool]$d.Primary, $scale, $steps, $name.Trim()) -join "`t"))
    }
    Write-Snapshot $lines
    exit 0
} catch {
    $why = ("$($_.Exception.Message)" -replace '[\t\r\n]+', ' ').Trim()
    Write-Snapshot @("# 710sRice screens v1 $stamp error: Couldn't read the screens: $why")
    exit 1
}
