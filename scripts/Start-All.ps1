#Requires -Version 7.0
<#
.SYNOPSIS
  Starts 710.DesktopRice's whole stack now (komorebi and 710.ahk, which starts the bar, Flow
  Launcher and ShareX) -- the "on demand" way to run it, for a machine that's on demand
  (installed without -Activate, or switched back with `710sRice deactivate`).

.DESCRIPTION
  Two ways to use this repo (`710sRice activate` / `deactivate` switch between them):
    - Full-time (install.ps1 -Activate, or `710sRice activate`): the stack starts at every
      sign-in (Scheduled Tasks), plus the Windows changes that go with a full-time shell
      (taskbar auto-hide, hardening, Startup delay).
    - On demand (install.ps1 alone, or `710sRice deactivate`): this script when you want the
      stack, and Stop-All.ps1 (or the tray's "Quit 710sRice") when you're done. Nothing
      starts at sign-in and Windows itself isn't changed -- hardening and the Startup delay
      only make sense for a full-time shell.

  Uses the exact launch commands the sign-in tasks use (tools\lib\activation.ps1's
  Get-AutostartComponents: komorebi and 710.ahk), so on-demand and -Activate start things the
  same way. The bar (YASB), Flow Launcher and ShareX have no task: 710.ahk starts them as it
  loads, and when it's already running this asks it to (Start-AhkStartedApps) -- a task's job
  would keep what you open from them from starting programs of their own (config\ahk\710.ahk,
  "The apps 710.ahk starts").

  Never starts anything elevated by accident. Anything started from an admin shell runs
  as admin -- AHK, and every Terminal it opens after it (the trap install -Activate itself
  had, fixed 2026-09-24). So, per component:
    - If it has a task, it fires the task, which starts it at the task's own registered
      level whatever shell this is: non-elevated for 710.ahk, and for komorebi too except in
      elevated tiling mode (install.ps1's default), which is elevated on purpose so it can
      tile admin windows. Every install has a task per component -- an on-demand install
      (no -Activate) registers them with no sign-in trigger just for this -- so this is
      the normal path, from a normal or an admin window alike.
    - Otherwise (its task couldn't be registered, or it's an on-demand install from before
      2026-09-26, when only komorebi got a task, that hasn't been re-run) it starts it
      directly -- and refuses to, from an admin shell. Use a normal PowerShell window, or
      re-run `710sRice install` to get the tasks.

  Taskbar auto-hide is left to you: this checks it and, if it's off, the last line says how
  to turn it on (the stack is built around a hidden taskbar). Stop-All.ps1 reminds you to
  turn it back off. Neither script changes it.

  Then it checks what came up, for up to 30 seconds. A [!!] isn't necessarily a
  failure -- the launchers (scripts\Start-Komorebi.ps1 etc.) keep retrying for their own
  budget (up to 5 minutes for komorebi) and log to %LOCALAPPDATA%\710.DesktopRice\. Re-run
  this, or check those logs, if something's still settling. A component that's already
  running is left alone: each launcher checks first, and 710.ahk starts only what isn't
  running (a second start of Flow would show its window; Stop-All.ps1 leaves Flow running on
  purpose).

.EXAMPLE
  .\scripts\Start-All.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Step-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Step-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Step-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

# Step-Ok/Info/Warn must be defined before this dot-source -- activation.ps1 uses ours
# rather than its own copies (see that file's header).
. (Join-Path $Root 'tools\lib\activation.ps1')

Write-Host "`n== 710.DesktopRice: start all ==" -ForegroundColor Cyan

$components = @(Get-AutostartComponents)
$apps = @(Get-AhkStartedApps | Where-Object Installed)
if ($components.Count -eq 0 -and $apps.Count -eq 0) {
    Step-Warn "No components found installed (komorebi/AutoHotkey/YASB/Flow Launcher/ShareX all missing?) -- run ``.\710sRice.ps1 install`` from the repo folder first."
    exit 1
}
$ahkScript = Join-Path $Root 'config\ahk\710.ahk'
$ahkWasUp = (Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero

$withTask = @($components | Where-Object { Test-Task -TaskName $_.TaskName })
$direct   = @($components | Where-Object { $withTask.Key -notcontains $_.Key })
# Only SUPER+Shift+R's komorebi restart needs the task, but "everything through its task" is
# the simple rule, and it's what makes an admin window OK.
$reRun = "No task for $($direct.Key -join ', ') -- re-run ``710sRice install`` to register $(if ($direct.Count -eq 1) { 'it' } else { 'them' }), so everything starts (and restarts) through its task."
if ($direct.Count -gt 0 -and (Test-IsAdmin)) {
    Step-Warn "This is an admin shell -- $($direct.Key -join ', ') would have to be started directly from it and would run as admin. Run this from a normal PowerShell window instead. Nothing was started."
    Step-Info $reRun
    exit 1
}
# Tasks first: each starts at its own registered level (see the header).
foreach ($c in $withTask) {
    $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName $c.TaskName) 2>&1
    if ($LASTEXITCODE -eq 0) { Step-Ok "$($c.Key): started via its task" }
    else { Step-Warn "$($c.Key): schtasks /Run failed (exit $LASTEXITCODE)" }
}
# No sign-in delays here: those space things out at logon; by hand they'd just be
# waiting.
foreach ($c in $direct) {
    try {
        Start-Process -FilePath $c.Exe -ArgumentList $c.Arguments -WindowStyle Hidden
        Step-Ok "$($c.Key): launched"
    } catch {
        Step-Warn "$($c.Key): failed to launch -- $($_.Exception.Message)"
    }
}
if ($direct.Count -gt 0) { Step-Info $reRun }
# The bar, Flow and ShareX: a 710.ahk that was already running is asked for the ones that are
# down; one that's starting now starts all three as it loads.
if ($apps.Count) {
    if ($ahkWasUp) {
        $asked = Start-AhkStartedApps -NoAhkStart -WaitSeconds 0
        if ($asked.Missing.Count -and -not $asked.NoAhk) { Step-Ok "Asked 710.ahk to start $(@($asked.Missing | ForEach-Object Name) -join ', ')" }
    } elseif ($components.Key -notcontains 'ahk') {
        Step-Warn "$(@($apps | ForEach-Object Name) -join ', ') only start through 710.ahk, and AutoHotkey isn't installed -- run ``710sRice install``."
    }
}

Write-Host "`n-- Checking what came up (up to 30s; see the header if something's still settling) --" -ForegroundColor Cyan
# One check per component, polled once a second until all pass or 30s is up --
# komorebi's launcher alone takes ~10s (it waits for the desktop, then checks komorebi
# survives 8s), and the bar waits for 710.ahk, which waits for the desktop too, so a single
# fixed wait either wastes time or reports too early.
$checks = [ordered]@{
    'komorebi' = @{ Name = 'komorebi'; Test = { [bool](Get-Process komorebi -ErrorAction SilentlyContinue) }; Log = 'komorebi-autostart.log' }
    'ahk'      = @{ Name = '710.ahk';  Test = { (Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero }; Log = 'ahk-autostart.log' }
}
foreach ($a in $apps) {
    $proc = $a.Process
    # The bar's own launcher logs to yasb-autostart.log; 710.ahk logs each start (or why not)
    # to ahk-autostart.log.
    $checks[$a.Key] = @{ Name = $a.Name; Test = { [bool](Get-Process -Name $proc -ErrorAction SilentlyContinue) }.GetNewClosure()
                         Log = if ($a.Key -eq 'yasb') { 'yasb-autostart.log' } else { 'ahk-autostart.log' } }
}
$expected = @($components.Key) + @($apps.Key)
$pending = [System.Collections.Generic.List[string]]::new()
foreach ($k in $checks.Keys) { if ($expected -contains $k) { $pending.Add($k) } }
$deadline = (Get-Date).AddSeconds(30)
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    foreach ($k in @($pending)) { if (& $checks[$k].Test) { [void]$pending.Remove($k) } }
}
# 710.ahk running as admin starts none of the three (it says so in a toast, once).
$ahkAdmin = $false
if (@($pending | Where-Object { $apps.Key -contains $_ }).Count) {
    $ahkPid = try { Get-AhkWindowProcessId -ScriptPath $ahkScript } catch { $null }
    if ($ahkPid) { $ahkAdmin = (Get-ProcessElevation -Id $ahkPid) -eq 'elevated' }
}
foreach ($k in $checks.Keys) {
    if ($expected -notcontains $k) { continue }
    $c = $checks[$k]
    if ($pending -notcontains $k) {
        Step-Ok "$($c.Name) running"
    } elseif ($ahkAdmin -and $apps.Key -contains $k) {
        Step-Warn "$($c.Name) not running -- 710.ahk is running as admin, so it won't start it. Run 710sRice restart from a normal window."
    } else {
        Step-Warn "$($c.Name) not running after 30s -- check %LOCALAPPDATA%\710.DesktopRice\$($c.Log)"
    }
}

try {
    if (-not (Test-TaskbarAutoHide)) {
        Write-Host ''
        Step-Info "Tip: the Windows taskbar isn't set to auto-hide, so it shows alongside the bar. To hide it while you use 710.DesktopRice: Settings > Personalization > Taskbar > Taskbar behaviors > Automatically hide the taskbar. (Stop-All.ps1 reminds you to turn it back off.)"
    }
} catch { }

Write-Host "`nDone." -ForegroundColor Cyan
