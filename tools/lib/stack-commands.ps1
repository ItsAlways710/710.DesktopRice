<#
.SYNOPSIS
  `710sRice restart`, `reload` and `reload bar`: the stack stopped and started again (=
  SUPER+Ctrl+R), reloaded through 710.ahk's own ReloadStack() (= SUPER+Shift+R), or just the bar
  restarted. Dot-sourced by 710sRice.ps1's restart, reload and reload bar rows, and by doctor
  -repair's (tools\lib\repair.ps1 runs them), after tools\lib\activation.ps1: they use the
  libraries that loads and the dispatcher's own Invoke-RiceScript, Write-RiceError, Step-Ok /
  Info / Warn and $script:RiceExit. Functions, and reload-stack.log's path.
#>

# --- reload / reload bar -------------------------------------------------------------------------
$RiceReloadLog = Join-Path $env:LOCALAPPDATA '710.DesktopRice\reload-stack.log'

function Read-RiceLogFrom {
    # Everything written to the log since byte $Offset. A log that's now SHORTER than that got
    # rotated to .old -- which reload-stack.ps1 only does at the very start of a run, before its
    # first line -- so then all of it is new. Opened share-everything: a run may be appending.
    param([string]$Path, [long]$Offset)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                 [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $sr = [System.IO.StreamReader]::new($fs)   # disposing the reader closes the file too
    try {
        if ($fs.Length -lt $Offset) { $Offset = 0 }
        $null = $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $sr.ReadToEnd()
    } finally { $sr.Dispose() }
}

function Get-RiceReloadOutcome {
    # The first full reload that ENDS in $Text: its exit code, as reload-stack.ps1 gives it,
    # and its log lines (from its header, when that's in $Text too). $null while none has. A
    # `reload bar` run (-BarOnly) that happens to finish in between is skipped -- its 'done.'
    # isn't ours.
    param([string]$Text)
    $lines = @("$Text" -split "`r?`n" | Where-Object { $_ })
    $inBar = $false
    $start = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = $lines[$i] -replace '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  ', ''
        if ($m -like '--- reload-stack -BarOnly*') { $inBar = $true; continue }
        if ($m -like '--- reload-stack*')          { $inBar = $false; $start = $i; continue }
        $code = if ($m -eq 'done.') { 0 } elseif ($m -like 'done, with failures*') { 2 } elseif ($m -like '1. rule compile FAILED*') { 1 } else { $null }
        if ($null -eq $code) { continue }
        if ($inBar) { $inBar = $false; continue }
        return [pscustomobject]@{ Code = $code; Lines = @($lines[$start..$i]) }
    }
    $null
}

function Write-RiceReloadResult {
    # Same words as 710.ahk's toasts. When it didn't go cleanly, the run's own log lines too.
    param([int]$Code, [string[]]$Lines)
    $script:RiceExit = $Code
    switch ($Code) {
        0       { Step-Ok 'Stack reloaded' }
        1       { Write-RiceError 'Rules failed to compile -- nothing reloaded (see reload-stack.log)' }
        default { Step-Warn 'Reloaded, with errors (see reload-stack.log)' }
    }
    if ($Code -ne 0) { $Lines | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray } }
}

function Wait-RiceAhkReloaded {
    # 710.ahk's ReloadStack() writes reload-stack.log's done. line, shows its toast, waits 1.5 s
    # and only then Reload()s itself -- into a new process. Waits (up to 10 s) for 710.ahk's
    # window to belong to a process other than $OldPid, so whatever runs next meets the reloaded
    # 710.ahk: `doctor -repair`'s re-check caught the old one once and called a `710.ahk changed
    # since it started` it had just fixed "still broken" (2026-09-27, the update test).
    # $true once it has, or when there was nothing to wait for.
    param([Parameter(Mandatory)][string]$ScriptPath, $OldPid)
    if (-not $OldPid) { return $true }
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $now = try { Get-AhkWindowProcessId -ScriptPath $ScriptPath } catch { $null }
        if ($now -and $now -ne $OldPid) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    $false
}

function Invoke-RiceReload {
    # `reload` = SUPER+Shift+R: 710.ahk runs its own ReloadStack() (toasts, double-press guard,
    # its Reload() at the end), we read the result from reload-stack.log -- only what's written
    # after the post, so an older run can't pass for this one. A reload already running when we
    # post: AHK ignores ours and we report that one, which is the one that counts anyway. Then
    # we wait for that Reload() too (Wait-RiceAhkReloaded): "Stack reloaded" means all of it.
    $ahk    = Join-Path $Root 'config\ahk\710.ahk'
    $offset = if (Test-Path -LiteralPath $RiceReloadLog) { (Get-Item -LiteralPath $RiceReloadLog).Length } else { 0 }
    $ahkPid = try { Get-AhkWindowProcessId -ScriptPath $ahk } catch { $null }
    if (Send-AhkMessage -ScriptPath $ahk -Name '710sRice.ReloadStack') {
        Step-Info 'Reloading (same as SUPER+Shift+R)...'
        $deadline = (Get-Date).AddMinutes(2)
        $outcome  = $null
        while (-not $outcome -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
            $outcome = Get-RiceReloadOutcome (Read-RiceLogFrom $RiceReloadLog $offset)
        }
        # A failed rule compile (1) ends ReloadStack() before its Reload(): nothing to wait for.
        $reloaded = if ($outcome -and $outcome.Code -ne 1) { Wait-RiceAhkReloaded $ahk $ahkPid } else { $true }
        if ($outcome) { Write-RiceReloadResult $outcome.Code $outcome.Lines }
        else {
            Step-Warn 'No result in reload-stack.log after 2 minutes -- check its toasts and the log.'
            $script:RiceExit = 2
        }
        if (-not $reloaded) { Step-Warn "710.ahk hasn't reloaded itself 10 s after the stack did -- give it a moment (SUPER+Shift+R if its hotkeys act up)." }
        return
    }
    # No 710.ahk: run the script ourselves (safe from any window: it starts komorebi only
    # through its task, and never the bar), then 710.ahk through its task -- a SUPER+Shift+R
    # leaves a fresh 710.ahk too, and only 710.ahk starts the bar again (as it loads).
    Step-Info "Reloading without 710.ahk (it isn't running)..."
    Invoke-RiceScript 'tools\reload-stack.ps1'
    Write-RiceReloadResult $script:RiceExit (Get-RiceReloadOutcome (Read-RiceLogFrom $RiceReloadLog $offset)).Lines
    if ($script:RiceExit -eq 1) { return }   # nothing was touched
    if ((Start-AhkFromTask) -eq 'none') {
        Step-Warn "710.ahk couldn't be started through its task$(if (-not (Get-Process yasb -ErrorAction SilentlyContinue)) { ', so the bar stays down' }) -- ``710sRice install -Only tasks``, then ``710sRice start``."
        return
    }
    if (-not (Get-YasbcExe)) { Step-Ok '710.ahk started again through its task'; return }
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Get-Process yasb -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (Get-Process yasb -ErrorAction SilentlyContinue) { Step-Ok "710.ahk started again through its task; the bar is up" }
    else { Step-Warn "710.ahk's task ran, but the bar isn't up after 15s -- it may still be starting (see yasb-autostart.log and ahk-autostart.log)." }
}

function Invoke-RiceReloadBar {
    # `reload bar`: reload-stack.ps1 -BarOnly right here stops the bar (no rule compile, no
    # Reload()), then 710.ahk starts it again -- only 710.ahk starts the bar (config\ahk\710.ahk,
    # "The apps 710.ahk starts"), asked through '710sRice.StartApps' (Start-AhkStartedApps,
    # which starts 710.ahk itself through its task first if it isn't running). Any window will
    # do. "Restarted" only once yasb.exe is back: YASB takes a few seconds after the ask.
    $offset = if (Test-Path -LiteralPath $RiceReloadLog) { (Get-Item -LiteralPath $RiceReloadLog).Length } else { 0 }
    Step-Info 'Restarting the bar...'
    Invoke-RiceScript 'tools\reload-stack.ps1' -BarOnly
    switch ($script:RiceExit) {
        0 {
            $apps = Start-AhkStartedApps -Keys 'yasb' -WaitSeconds 15
            if ($apps.NoAhk) {
                Step-Warn "The bar is stopped, and 710.ahk -- the only thing that starts it -- isn't running and couldn't be started through its task. Run 710sRice start."
                $script:RiceExit = 2
            } elseif ($apps.Missing.Count) {
                Step-Warn "Asked 710.ahk to start the bar, but YASB isn't up after 15s -- it may still be starting (see yasb-autostart.log)."
            } else {
                Step-Ok "Bar restarted$(if ($apps.AhkStarted) { ' (710.ahk wasn''t running -- started it too)' })"
            }
            Step-Info 'Chrome, the Claude app and other Chromium apps can pick up an extra title bar when the bar restarts -- focus the app and press SUPER+Ctrl+C to redraw it.'
        }
        3 { Step-Warn 'komorebi is paused -- unpause it first (SUPER+P). A bar started during a pause never connects to komorebi.' }
        default {
            Step-Warn 'Bar restart had errors (see reload-stack.log)'
            ((Read-RiceLogFrom $RiceReloadLog $offset) -split "`r?`n" | Where-Object { $_ }) |
                ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        }
    }
}

# --- restart --------------------------------------------------------------------------------------
function Invoke-RiceRestart {
    # `restart` = stop, then start: the whole stack, every time. SUPER+Shift+R (`reload`) no
    # longer is that -- it restarts komorebi only when a rule was removed, and YASB only when
    # it has to (Chromium apps' extra title bar per bar restart, plan doc #40). In between, it
    # waits until everything has really exited: each launcher leaves alone a component it still
    # sees running, and Stop-All only gives each stop a few hundred ms. Something still up after
    # 10 s (Stop-All has already said why) keeps running as it was; the rest start anyway.
    Invoke-RiceScript 'scripts\Stop-All.ps1'
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    $stillUp = {
        @(
            if (Get-Process komorebi -ErrorAction SilentlyContinue) { 'komorebi' }
            if (Get-Process yasb -ErrorAction SilentlyContinue) { 'YASB' }
            if (Get-Process ShareX -ErrorAction SilentlyContinue) { 'ShareX' }
            if ((Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero) { '710.ahk' }
        )
    }
    $deadline = (Get-Date).AddSeconds(10)
    while (@(& $stillUp).Count -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    $left = @(& $stillUp)
    if ($left.Count) {
        Step-Warn "Still running after 10 s: $($left -join ', ') -- starting the rest; $(if ($left.Count -eq 1) { 'it keeps' } else { 'those keep' }) running as before (not restarted)."
    }
    Invoke-RiceScript 'scripts\Start-All.ps1'
    if ($script:RiceExit -eq 0) {
        Step-Info 'Chrome, the Claude app and other Chromium apps can pick up an extra title bar when the bar restarts -- focus the app and press SUPER+Ctrl+C to redraw it.'
    }
}
