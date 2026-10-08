<#
.SYNOPSIS
  Moving a pinned package that's below its pin up to exactly its pin (Invoke-MoveToPin): its app
  stopped first, pin remove -> winget upgrade --version <pin> -> pin add, the app started again
  if it was running. Install's packages step and its upgrade step both run it. Uses the stack's
  helpers (tools\lib\ahk.ps1, apps.ps1, tasks.ps1, stack.ps1's Start-AhkStartedApps) and the
  caller's $Root. Loaded by tools\lib\activation.ps1. Only functions.
#>

# --- Upgrading a pinned package to its pin (install's upgrade step) ---------------------
# Each pinned app is stopped before winget touches it (a running app locks its files) and
# started again afterwards through its own task -- only if it was running before, and never
# directly from install's admin window (the task runs at its own level). Flow has its own
# task since Group 1 #4 (its root Flow.Launcher.exe survives an upgrade; the versioned app
# folder doesn't). Everything is left to its own installer, which stops and restarts its
# service itself.

function Get-PinnedAppTask {
    # The autostart task that starts this row's app (komorebi, 710.ahk), or $null.
    param($Row)
    switch ($Row.InstallId) {
        'LGUG2Z.komorebi'             { 'komorebi' }
        'AutoHotkey.AutoHotkey'       { 'ahk' }
        default                       { $null }
    }
}

function Get-PinnedAppAhkKey {
    # This row's app when 710.ahk is what starts it (Get-AhkStartedApps: the bar, Flow), or $null.
    param($Row)
    switch ($Row.InstallId) {
        'AmN.yasb'                    { 'yasb' }
        'Flow-Launcher.Flow-Launcher' { 'flow' }
        default                       { $null }
    }
}

function Stop-PinnedApp {
    <# Stops this row's app if it's running; $true when it was. komorebi through its own
       `komorebic stop` first (a clean stop saves its layouts), YASB and Flow killed (the YASB
       watchdog in 710.ahk already holds off while winget.exe runs), 710.ahk asked to quit --
       the same message tray Quit uses -- then killed if it's still there (install's admin
       window can end the UI Access process; see Stop-RunningComponents). #>
    param($Row)
    switch ($Row.InstallId) {
        'LGUG2Z.komorebi' {
            if (-not (Get-Process komorebi -ErrorAction SilentlyContinue)) { return $false }
            $komorebic = Get-KomorebicExe   # next to komorebi.exe first, then PATH (W6)
            if ($komorebic) { try { & $komorebic stop 2>$null | Out-Null } catch { } }
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Process komorebi -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            Stop-Process -Name komorebi -Force -ErrorAction SilentlyContinue
            return $true
        }
        'AmN.yasb' {
            if (-not (Get-Process yasb -ErrorAction SilentlyContinue)) { return $false }
            Stop-Process -Name yasb -Force -ErrorAction SilentlyContinue
            return $true
        }
        'AutoHotkey.AutoHotkey' {
            $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
            if ((Find-AhkWindow -ScriptPath $ahkScript) -eq [IntPtr]::Zero) { return $false }
            [void](Send-AhkQuit -ScriptPath $ahkScript)
            $deadline = (Get-Date).AddSeconds(3)
            while ((Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            try {
                Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe' OR Name = 'AutoHotkey64_UIA.exe'" -ErrorAction Stop |
                    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ahkScript) } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            } catch { }
            return $true
        }
        'Flow-Launcher.Flow-Launcher' {
            if (-not (Get-Process Flow.Launcher -ErrorAction SilentlyContinue)) { return $false }
            Stop-Process -Name Flow.Launcher -Force -ErrorAction SilentlyContinue
            return $true
        }
        default { return $false }
    }
}

function Invoke-PinnedUpgrade {
    <# One pinned package, older than its pin, to exactly its pin: pin remove -> winget
       upgrade --version <pin> -> pin add -- the route the AutoHotkey 2.0.28 bump took by hand
       (2026-09-23). A per-user package (Flow) that winget refuses from an admin window runs
       again as the user (Invoke-WingetAsUser). The pin always goes back on, even when the
       upgrade fails -- a pinned package is never left unpinned. Returns winget's exit code
       ($null = the un-elevated run was still going after 3 minutes). #>
    param($Row)
    $id  = $Row.InstallId
    $src = @(Get-WingetSourceArgs $Row)
    $pinRemove = @('pin', 'remove', '--id', $id, '--exact') + $src
    $pinAdd    = @('pin', 'add', '--id', $id, '--exact') + $src
    winget @pinRemove 2>$null | Out-Null
    try {
        $upgradeArgs = @('upgrade', '--id', $id, '--exact', '--version', $Row.Version, '--silent',
                         '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + $src
        # To the screen, not the output stream: this function returns winget's exit code and
        # nothing else. (Its first Dell run returned winget's progress lines along with the
        # code -- the upgrade itself went through, the report after it crashed; 2026-09-26.)
        winget @upgradeArgs | Out-Host
        $code = $LASTEXITCODE
        if ($code -eq $WingetAdminProhibited) {
            Step-Info "$id is installed for this user only -- upgrading it un-elevated ..."
            $code = Invoke-WingetAsUser -Arguments $upgradeArgs
        }
        return $code
    } finally {
        winget @pinAdd 2>$null | Out-Null
    }
}

function Invoke-MoveToPin {
    <# One pinned package that's BELOW its pin, moved up to exactly its pin -- the one routine
       install's packages step (what `winget list` shows is older than the pin: Group 1 W7) and
       the upgrade step (what the probe reads is older) both run, so they can't differ. Stops
       the app if it's running (Stop-PinnedApp), pin remove -> winget upgrade --version <pin> ->
       pin add (Invoke-PinnedUpgrade -- as the user for a per-user package, Flow), reads the
       version again, then starts the app again if it was running before: komorebi and 710.ahk
       through their own tasks, the bar and Flow by asking 710.ahk (Start-AhkStartedApps -- only
       it starts them; never 710.ahk itself for them: on an on-demand machine between sessions
       that would start half the stack). Never
       down: callers only come here for a package below its pin, never for one newer than it
       (no downgrades -- doctor's [!!] says how to go back). Prints its own lines. $true when the package ended at
       its pin (a restart-to-finish counts); $false when it didn't -- the caller counts that as
       not installed (W2). #>
    param([Parameter(Mandatory)]$Row, [string]$From)
    $name = $Row.Component
    Step-Info "$name $From -> $($Row.Version) (its pin) ..."
    $ok = $false
    # One package going wrong is that package's [XX], never the end of the step: whatever was
    # stopped still gets started again below.
    $wasRunning = $false
    try {
        $wasRunning = Stop-PinnedApp $Row
        $code    = Invoke-PinnedUpgrade $Row
        $outcome = Get-WingetOutcome $code
        $after   = Get-PackageVersion $Row
        $atPin   = $after.Probe -and (Compare-PinVersion $after.Version $Row.Version) -eq 0
        if ($outcome -eq 'failed') {
            Write-Host "  [XX] $($name): winget exited $(Format-WingetCode $code) -- still $(if ($after.Version) { $after.Version } else { $From }) (pin put back)" -ForegroundColor Red
        } elseif ($outcome -eq 'restart') {
            Step-Warn "$name $From -> $($Row.Version) -- restart Windows to finish its setup"
            $ok = $true
        } elseif ($atPin) {
            Step-Ok "$name $From -> $($after.Version)"
            $ok = $true
        } elseif (-not $after.Probe -and $outcome -eq 'ok') {
            # No local probe for this row: winget's own word is all there is.
            Step-Ok "$name $From -> $($Row.Version)"
            $ok = $true
        } elseif ($outcome -eq 'timeout' -and $after.Installed) {
            Step-Warn "$($name): the un-elevated upgrade was still running after 3 minutes -- it reports $($after.Version) so far; check again once it's done."
        } else {
            Write-Host "  [XX] $($name): winget finished, but it reports '$($after.Version)', not $($Row.Version)" -ForegroundColor Red
        }
    } catch {
        # Invoke-PinnedUpgrade puts the pin back itself (finally), whatever went wrong.
        Write-Host "  [XX] $($name): $($_.Exception.Message)" -ForegroundColor Red
    }
    $task = Get-PinnedAppTask $Row
    $ahkKey = Get-PinnedAppAhkKey $Row
    if ($wasRunning -and $ahkKey) {
        $apps = Start-AhkStartedApps -Keys $ahkKey -NoAhkStart -WaitSeconds 15
        if ($apps.NoAhk) { Step-Warn "$name was running, but 710.ahk -- the only thing that starts it -- isn't, so it stays closed: 710sRice start brings it back." }
        elseif ($apps.Missing.Count) { Step-Warn "$($name): 710.ahk was asked to start it again, but it isn't up after 15 s -- 710sRice logs shows why." }
        else { Step-Ok "$($name): started again by 710.ahk" }
    } elseif ($wasRunning -and $task) {
        if (Test-Task -TaskName $task) {
            $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName $task) 2>&1
            if ($LASTEXITCODE -eq 0) { Step-Ok "$($name): started again through its task" }
            else { Step-Warn "$($name): its task didn't start (schtasks exit $LASTEXITCODE) -- 710sRice start brings it back." }
        } else {
            Step-Warn "$($name) was running but has no task -- 710sRice start brings it back."
        }
    } elseif ($wasRunning) {
        Step-Info "$name was closed for the upgrade -- it starts again the next time you open it."
    }
    $ok
}
