#Requires -Version 7.0
<#
.SYNOPSIS
  The screens menu's helper (710.ahk: the bar's monitor button, SUPER+Alt+Space > Screens).
  -Snapshot writes what Windows says about every connected screen to
  %LOCALAPPDATA%\710.DesktopRice\screens.tsv, which the menu reads. -Off and -On turn one screen
  off or back on; -Scale sets its scale.

.DESCRIPTION
  Why a snapshot: the menu opens at once from a small file instead of waiting about a second for
  a cold pwsh and the DisplayConfig module every time. 710.ahk takes one when it starts and again
  3 s after the last display or device change (a scale change arrives as one too), so it's
  current by the time a menu opens.

  The DisplayConfig module (versions.md; MartinGC94, MIT; Windows' own CCD display APIs) reads the
  screens and switches them. Every connected one is listed, on or off -- Get-DisplayInfo's Active
  says which.

  The file: a header line, then one tab-separated line per screen.
    # 710sRice screens v2 <time>
    id <TAB> on <TAB> main <TAB> scale <TAB> steps <TAB> name <TAB> path <TAB> res
  id     DisplayConfig's DisplayId (Settings' numbering, as far as it can tell)
  on     1 or 0 (Active)
  main   1 or 0 (Primary)
  scale  the current scale in percent; empty while the screen is off (Windows only scales a
         screen that's on) or when its scale couldn't be read
  steps  the scales Windows allows for that screen, comma-separated, from 100 up to its maximum;
         empty while it's off
  name   its name as Windows has it, or "Display <id>"
  path   the screen's device path -- that monitor on that connection -- which is how -Off and
         -On find it: DisplayConfig's ids can change as screens come and go. A hardware
         identifier, so it stays in this file and is never printed.
  res    its desktop resolution, WIDTHxHEIGHT, while it's on (710.ahk counts a scale change only at
         the same resolution: a game switching resolution moves the scale reading too)
  Something failed (DisplayConfig missing, or it threw): the header line ends in
  " error: <why>" and no screen lines follow, so the menu says why instead of listing stale
  screens. Written to a temp file first and moved over the old one, so the menu never reads half
  a file. (v1, the menu's first, read-only version, had no path or res column; v2 adds them
  last, so either reader reads either file.)

  -Off turns the screen named by $env:SCREENS_PATH off -- Windows' "Disconnect this display" --
  unless komorebi still has windows on it, on any of that screen's workspaces: then nothing
  changes, and the result file lists them so the menu can ask first. -Anyway skips that check.
  Windows komorebi doesn't manage aren't counted: Windows moves those to the main display itself.
  Never the main display, and never the last screen on. The screens that stay on keep exactly
  where they are (see the end of this file). -On turns it back on -- "Extend desktop to this
  display" -- and Windows puts it back where it was for this set of screens. The path rides in
  the environment, never on a command line (710.ahk's rule for values like this).

  -Scale <percent> sets that screen's scale -- Settings > Display's "Scale" -- to one of the steps
  Windows allows it (the snapshot's steps column). 710.ahk restarts the bar after any scale change,
  this one or one made in Settings (its display-change hook compares the snapshots).

  The result file, %LOCALAPPDATA%\710.DesktopRice\screens-result.txt, written by every -Off,
  -On -Scale: line 1 says what happened; after a 3, one line per window komorebi has there:
  workspace <TAB> exe <TAB> title (none when komorebi didn't answer, so they couldn't be listed).

  Exit codes: 0 = done, or nothing to do; 1 = failed (the result file says why); 2 = usage;
  3 = komorebi has windows on that screen (-Off without -Anyway; nothing changed); 4 = refused:
  the main display, the only screen on, or scaling a screen that's off; 5 = that screen isn't
  connected any more; 6 = turned off, but Windows placed the screens left on (it wouldn't take
  them where they were; the result file says why).
#>
param([switch]$Snapshot, [switch]$Off, [switch]$On, [switch]$Anyway, [int]$Scale)

$ErrorActionPreference = 'Stop'
if (@($Snapshot, $Off, $On, ($Scale -gt 0) | Where-Object { $_ }).Count -ne 1 -or ($Anyway -and -not $Off) -or $Scale -lt 0) {
    Write-Host 'Usage: screens.ps1 -Snapshot | -Off [-Anyway] | -On | -Scale <percent>   (all but -Snapshot: the screen in $env:SCREENS_PATH)'
    exit 2
}

$stateDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$out = Join-Path $stateDir 'screens.tsv'
$resultFile = Join-Path $stateDir 'screens-result.txt'

function Write-StateFile([string]$Path, [string[]]$Lines) {
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllLines($tmp, $Lines, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# One line of text with no tabs or line breaks in it (titles can hold anything).
function Get-Flat([string]$Text) { ("$Text" -replace '[\t\r\n]+', ' ').Trim() }

# Windows' scale steps, as DisplayConfig's DpiScale has them: 100 is always the smallest, and a
# screen allows every step up to its MaxScale.
$scaleSteps = 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$noModule = "The DisplayConfig module isn't installed -- 710sRice install -Only packages"

try {
    Import-Module DisplayConfig -ErrorAction Stop
} catch {
    if ($Snapshot) { Write-StateFile $out @("# 710sRice screens v2 $stamp error: $noModule") }
    else { Write-StateFile $resultFile @($noModule) }
    exit 1
}

if ($Snapshot) {
    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("# 710sRice screens v2 $stamp")
        foreach ($d in @(Get-DisplayInfo)) {
            # Not $scale: PowerShell's names ignore case, so that would be the -Scale parameter,
            # an [int] -- '' would turn into 0.
            $current = ''
            $allowed = ''
            $res = ''
            if ($d.Active) {
                if ($d.Mode) { $res = "$($d.Mode.Width)x$($d.Mode.Height)" }
                # One screen whose scale can't be read is listed without one, rather than losing
                # the whole list.
                try {
                    $s = Get-DisplayScale -DisplayId $d.DisplayId
                    $current = "$($s.CurrentScale)"
                    $allowed = @($scaleSteps | Where-Object { $_ -le $s.MaxScale }) -join ','
                } catch {
                    $current = ''
                    $allowed = ''
                }
            }
            $name = Get-Flat $d.DisplayName
            if (-not $name) { $name = "Display $($d.DisplayId)" }
            $lines.Add((@($d.DisplayId, [int][bool]$d.Active, [int][bool]$d.Primary, $current, $allowed, $name, (Get-Flat $d.DevicePath), $res) -join "`t"))
        }
        Write-StateFile $out $lines
        exit 0
    } catch {
        Write-StateFile $out @("# 710sRice screens v2 $stamp error: Couldn't read the screens: $(Get-Flat $_.Exception.Message)")
        exit 1
    }
}

# --- -Off / -On / -Scale ---------------------------------------------------------------------

# The windows komorebi has on screen $Display, every workspace: {Workspace (1-based), Exe,
# Title}. None when komorebi isn't running (then it has nothing there), or when it has no record
# of the screen. komorebi knows a screen by its device_id: the device path's middle parts (between
# its first and last '#') joined with '-' (komorebi 0.1.41, windows_api.rs
# load_monitor_information) -- else by its GDI name (DISPLAY2). Throws when komorebi is running
# but gives no answer: it drops a request it can't take its lock for within a second (0.1.41,
# process_command.rs), as it can't for a moment while it recounts the screens -- which 710.ahk
# asks it to do 3 and 8 s after every display change -- and komorebic then prints nothing, or
# times out. So it's asked three times, a second apart, and "running, no answer" means "can't
# tell", never "nothing there". Each try has 5 s (komorebic would otherwise wait forever).
function Get-KomorebiWindowsOn($Display) {
    $komorebic = Join-Path $env:ProgramFiles 'komorebi\bin\komorebic.exe'
    if (-not (Test-Path -LiteralPath $komorebic)) {
        $cmd = Get-Command komorebic -ErrorAction SilentlyContinue
        if (-not $cmd) { return }
        $komorebic = $cmd.Source
    }
    $raw = $null
    for ($attempt = 1; $attempt -le 3 -and $null -eq $raw; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds 1 }
        $psi = [System.Diagnostics.ProcessStartInfo]::new($komorebic, 'state')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)   # window titles can be any language
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEndAsync()   # read while it runs: the state is bigger than a pipe's buffer
        $null = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(5000)) {
            try { $p.Kill() } catch { $null = $_ }
            throw "komorebi didn't answer"
        }
        if ($p.ExitCode -eq 0 -and "$($stdout.Result)".Trim()) { $raw = $stdout.Result }
        elseif (-not (Get-Process komorebi -ErrorAction SilentlyContinue)) { return }   # not running: nothing of its there
    }
    if ($null -eq $raw) { throw "komorebi didn't answer" }
    $state = $raw | ConvertFrom-Json
    $parts = @("$($Display.DevicePath)" -split '#')
    $deviceId = if ($parts.Count -ge 3) { $parts[1..($parts.Count - 2)] -join '-' } else { '' }
    $gdi = "$($Display.GdiDeviceName)" -replace '^\\\\\.\\', ''
    $monitors = @($state.monitors.elements)
    $mon = $null
    if ($deviceId) { $mon = $monitors | Where-Object { "$($_.device_id)" -eq $deviceId } | Select-Object -First 1 }
    if (-not $mon -and $gdi) { $mon = $monitors | Where-Object { "$($_.name)" -eq $gdi } | Select-Object -First 1 }
    if (-not $mon) { return }
    $workspaces = @($mon.workspaces.elements)
    for ($j = 0; $j -lt $workspaces.Count; $j++) {
        $ws = $workspaces[$j]
        $windows = [System.Collections.Generic.List[object]]::new()
        foreach ($c in @($ws.containers.elements)) { foreach ($w in @($c.windows.elements)) { $windows.Add($w) } }
        if ($ws.monocle_container) { foreach ($w in @($ws.monocle_container.windows.elements)) { $windows.Add($w) } }
        if ($ws.maximized_window) { $windows.Add($ws.maximized_window) }
        foreach ($w in @($ws.floating_windows.elements)) { $windows.Add($w) }
        foreach ($w in $windows) {
            if ($w) { [pscustomobject]@{ Workspace = $j + 1; Exe = (Get-Flat $w.exe); Title = (Get-Flat $w.title) } }
        }
    }
}

# The screen at $Path as Windows has it right now -- read again right before every action:
# DisplayConfig's ids are positions in its list of connected screens, so an id read earlier can
# name another screen by now (a monitor going to sleep drops out of that list). Exits when it
# isn't connected any more. For -Off, also exits (with what to say) when it mustn't or needn't
# go off: already off, the main display, or the only one on.
function Get-Screen([string]$Path, [switch]$ToTurnOff, $Config) {
    # -Config: read from that DisplayConfig snapshot, so its ids are the ones an action on it uses.
    $all = if ($Config) { @(Get-DisplayInfo -DisplayConfig $Config) } else { @(Get-DisplayInfo) }
    $d = $all | Where-Object { $_.DevicePath -eq $Path } | Select-Object -First 1
    if (-not $d) { Write-StateFile $resultFile @("That screen isn't connected any more"); exit 5 }
    if ($ToTurnOff) {
        $label = Get-Label $d
        if (-not $d.Active) { Write-StateFile $resultFile @("$label is already off"); exit 0 }
        if ($d.Primary) {
            Write-StateFile $resultFile @("$label is the main display, so it stays on (Settings > Display chooses which screen is main)")
            exit 4
        }
        if (@($all | Where-Object { $_.Active }).Count -le 1) {
            Write-StateFile $resultFile @("$label is the only screen on")
            exit 4
        }
    }
    $d
}

function Get-Label($Display) {
    $label = Get-Flat $Display.DisplayName
    if ($label) { $label } else { "Display $($Display.DisplayId)" }
}

try {
    $path = "$env:SCREENS_PATH"
    if (-not $path) { Write-StateFile $resultFile @('No screen named (SCREENS_PATH is empty)'); exit 2 }

    if ($On) {
        $d = Get-Screen $path
        $label = Get-Label $d
        if ($d.Active) { Write-StateFile $resultFile @("$label is already on"); exit 0 }
        Enable-Display -DisplayId $d.DisplayId
        Write-StateFile $resultFile @("$label turned on")
        exit 0
    }

    if ($Scale) {
        $d = Get-Screen $path
        $label = Get-Label $d
        if (-not $d.Active) { Write-StateFile $resultFile @("$label is off -- turn it on to scale it"); exit 4 }
        $now = Get-DisplayScale -DisplayId $d.DisplayId
        $allowed = @($scaleSteps | Where-Object { $_ -le $now.MaxScale })
        if ($allowed -notcontains $Scale) {
            Write-StateFile $resultFile @("$label can't be set to $Scale% (Windows allows $($allowed -join ', '))")
            exit 2
        }
        if ($now.CurrentScale -eq $Scale) { Write-StateFile $resultFile @("$label is already at $Scale%"); exit 0 }
        Set-DisplayScale -DisplayId $d.DisplayId -Scale $Scale
        Write-StateFile $resultFile @("$label set to $Scale%")
        exit 0
    }

    $d = Get-Screen $path -ToTurnOff
    $label = Get-Label $d
    if (-not $Anyway) {
        try {
            $windows = @(Get-KomorebiWindowsOn $d)
        } catch {
            # Can't tell what's there: ask, with no list.
            Write-StateFile $resultFile @("komorebi didn't answer, so the windows on $label couldn't be checked")
            exit 3
        }
        if ($windows.Count) {
            $lines = @("komorebi has $($windows.Count) window$(if ($windows.Count -ne 1) { 's' }) on $label")
            $lines += @($windows | ForEach-Object { "$($_.Workspace)`t$($_.Exe)`t$($_.Title)" })
            Write-StateFile $resultFile $lines
            exit 3
        }
    }
    # Off, with every screen that stays on kept exactly where it is: DisplayConfig takes the
    # current layout, drops this screen (closing the gap it leaves along its row or column),
    # applies that, and Windows saves it as its layout for the screens left. Asking Windows for
    # its remembered layout instead -- Disable-Display on its own -- moved the 27-inch screen from
    # below the main TV to its right on Godzilla (2026-10-05): main + 27-inch was a set of screens
    # Windows had never seen, so it used its default. That's only the fallback now, for a layout
    # Windows won't take (one left with a gap, say). The screen is read again first: asking
    # komorebi took a moment.
    $config = Get-DisplayConfig
    $d = Get-Screen $path -ToTurnOff -Config $config
    try {
        $config | Disable-Display -DisplayId $d.DisplayId | Use-DisplayConfig
    } catch {
        $why = Get-Flat $_.Exception.Message
        $d = Get-Screen $path -ToTurnOff
        Disable-Display -DisplayId $d.DisplayId
        Write-StateFile $resultFile @("$label turned off; Windows placed the screens left on, as it wouldn't keep them where they were ($why)")
        exit 6
    }
    Write-StateFile $resultFile @("$label turned off")
    exit 0
} catch {
    Write-StateFile $resultFile @("Couldn't switch that screen: $(Get-Flat $_.Exception.Message)")
    exit 1
}
