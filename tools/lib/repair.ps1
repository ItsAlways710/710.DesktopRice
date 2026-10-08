<#
.SYNOPSIS
  `710sRice doctor -repair` -- doctor's checks, the fix behind every [XX] that doesn't need
  you, then the checks again. Dot-sourced by 710sRice.ps1 after activation.ps1, doctor.ps1 and
  stack-commands.ps1 (it uses all three) -- never run directly. Runs in the admin window: the row
  is Admin Required.

.DESCRIPTION
  What it runs is doctor's own plan (Get-RepairPlan, doctor.ps1) -- the very list doctor's
  closing lines preview, printed again here before anything happens. No confirmation: typing
  -repair and saying yes to UAC were the two yeses (and `710sRice update` will run this
  unattended). The plan, in order -- each part the very code of the 710sRice command it
  names, run in place:
    1. the install steps, as ONE `install.ps1 -Only <steps>` run, in install's order
    2. `tiling <mode>` (not when the tasks step ran: it registers komorebi's task anyway)
    3. the stack: `restart`, or else each component that's down started -- komorebi and
       710.ahk through their tasks, the bar, Flow and ShareX by asking 710.ahk -- and waited
       for, then `reload bar` for two YASBs
    4. `reload` -- after the starts, so 710.ahk is back to run it
  then a note when the config env vars changed under a running komorebi / YASB, and a wait
  for everything that was running when repair began to be up again before the re-check.
  Never: theme (the default-wallpaper reset), and
  never an [!!] or [..] line -- those are facts repair can't or mustn't change.

  Rounds: after the fixes the checks run again. A fix can uncover a problem the first round
  couldn't see (a package the packages step just installed has no task yet -- doctor skips
  what isn't installed), so any [XX] the first round didn't have a fix for gets a second
  round, same machinery. One the first round tried and is still [XX] is never retried, and
  there's never a third round. The last check is the final report -- doctor's full report --
  and the exit code is its [XX] count, doctor's own meaning.

  (claude/cli-plan.md, Stage 4: Topics 1-4.)
#>

function Get-RepairLookText {
    # Doctor's "N things worth a look (!!)." for a report, or $null when there are none.
    param($Report)
    $w = @($Report.All | Where-Object { $_.Status -eq '!!' }).Count
    if ($w) { "$(Get-DoctorPlural $w 'thing' 'things') worth a look (!!)." }
}

function Write-RepairProblems {
    # A round's problems: the ones the plan fixes without their fix line (the plan below says
    # what happens), the ones it leaves WITH theirs, saying why.
    param([object[]]$Problems, $Plan)
    foreach ($r in $Problems) {
        $line = $r.PSObject.Copy()
        $line.Fix = ''
        Write-DoctorResult $line
        if ($Plan.NeedsYou -contains $r) {
            Write-Host "       needs you -- repair leaves it: $($r.Fix)" -ForegroundColor Yellow
        } elseif ($Plan.Unknown -contains $r) {
            Write-Host "       repair can't fix this one: $($r.Fix)" -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host '  Repair plan:' -ForegroundColor Yellow
    foreach ($l in $Plan.Lines) { Write-Host "    $l" -ForegroundColor Yellow }
}

# --- The stack: what's up, starting what's down -------------------------------------------------
function Test-RepairKomorebiLauncherBusy {
    # Start-Komorebi.ps1 still at work: its own steps after komorebi.exe appears (the 8 s
    # survival check, the monitor map on a first start + the recompile komorebi hot-reloads,
    # borders, refocus) aren't done -- checking now would catch them halfway, and a second
    # round would race them. Same test reload-stack.ps1's Wait-KomorebiLauncher uses. Can't
    # tell (no CIM) = not busy.
    try {
        [bool]@(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains('Start-Komorebi.ps1') }).Count
    } catch { $false }
}

function Get-RepairStackState {
    # The stack components that are up right now, by key: komorebi / YASB / ShareX / Flow by
    # process, 710.ahk by its window (its process name can't tell it from another AHK v2 script).
    # komorebi counts once its launcher has finished too (Test-RepairKomorebiLauncherBusy).
    $ahk = Join-Path $Root 'config\ahk\710.ahk'
    @(
        if ((Get-Process komorebi -ErrorAction SilentlyContinue) -and -not (Test-RepairKomorebiLauncherBusy)) { 'komorebi' }
        if (Get-Process yasb -ErrorAction SilentlyContinue) { 'yasb' }
        $w = try { Find-AhkWindow -ScriptPath $ahk } catch { [IntPtr]::Zero }   # can't tell = not up
        if ($w -and $w -ne [IntPtr]::Zero) { 'ahk' }
        if (Get-Process ShareX -ErrorAction SilentlyContinue) { 'sharex' }
        if (Get-Process Flow.Launcher -ErrorAction SilentlyContinue) { 'flow' }
    )
}

function Wait-RepairComponents {
    # Waits (up to $Seconds) until every one of $Keys is up; returns the ones that still aren't.
    param([string[]]$Keys, [int]$Seconds = 60)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        $up = @(Get-RepairStackState)
        $missing = @($Keys | Where-Object { $up -notcontains $_ })
        if (-not $missing.Count -or (Get-Date) -ge $deadline) { return $missing }
        Start-Sleep -Milliseconds 500
    }
}

function Start-RepairComponents {
    # The components that are down: komorebi and 710.ahk through their own tasks -- the same
    # `schtasks /Run` 710sRice start fires, so each one comes up at its task's run level
    # whatever this (admin) window is -- and the bar, Flow and ShareX by asking 710.ahk
    # (Start-AhkStartedApps; only it starts them, at its own level -- never this window's). Then
    # waited for: komorebi's launcher alone takes ~10 s (more on a first start, when it writes
    # the monitor map), and the re-check mustn't catch one halfway up. Up to 60 s -- a repair
    # takes as long as it takes (user, 2026-09-27).
    param([string[]]$Keys)
    Write-Host "`n-- Starting what's down --" -ForegroundColor Cyan
    $taskOf = @{}
    foreach ($c in @(Get-AutostartComponents -NoWrite)) { $taskOf[$c.Key] = $c.TaskName }
    $appKeys = @(Get-AhkStartedApps | ForEach-Object Key)
    $fired = @(foreach ($k in @($Keys | Where-Object { $appKeys -notcontains $_ })) {
        $name = Get-DoctorComponentName $k
        if (-not $taskOf[$k] -or -not (Test-Task -TaskName $taskOf[$k])) {
            Step-Warn "$($name): no task to start it with -- 710sRice install -Only tasks registers it"
            continue
        }
        $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName $taskOf[$k]) 2>&1
        if ($LASTEXITCODE -ne 0) { Step-Warn "$($name): its task didn't run (schtasks exit $LASTEXITCODE)"; continue }
        $k
    })
    # The bar, Flow, ShareX: asked of 710.ahk, which is started first through its task if it
    # isn't up yet (fired above, or not) -- and starts all three as it loads. The wait below is
    # the one that counts.
    $asked = @()
    $viaAhk = @($Keys | Where-Object { $appKeys -contains $_ })
    if ($viaAhk.Count) {
        $r = Start-AhkStartedApps -Keys $viaAhk -WaitSeconds 0
        if ($r.NoAhk) {
            foreach ($k in $viaAhk) { Step-Warn "$(Get-DoctorComponentName $k): only 710.ahk starts it, and 710.ahk isn't running and has no task to start it with -- 710sRice install -Only tasks registers it" }
        } else { $asked = $viaAhk }
    }
    $started = @($fired) + @($asked)
    if (-not $started.Count) { return }
    $missing = @(Wait-RepairComponents $started 60)
    foreach ($k in $fired) {
        $name = Get-DoctorComponentName $k
        if ($missing -contains $k) { Step-Warn "$($name): its task fired, but it isn't up after 60 s -- 710sRice logs shows why" }
        else { Step-Ok "$($name): started through its task, running" }
    }
    foreach ($k in $asked) {
        $name = Get-DoctorComponentName $k
        if ($missing -contains $k) { Step-Warn "$($name): 710.ahk was asked to start it, but it isn't up after 60 s -- 710sRice logs shows why" }
        else { Step-Ok "$($name): started by 710.ahk, running" }
    }
}

function Invoke-RepairPlan {
    # Runs one round's plan. Nothing here stops the rest: a fix that fails is reported, and
    # the check that follows says what's still wrong. Everything goes to the screen
    # (Out-Host): this function's output must stay empty -- see the install call.
    param($Plan)
    if ($Plan.Steps.Count) {
        # In place, in this (admin) window, with install's own output -- the same run as
        # `710sRice install -Only <steps>`. install.ps1 only ever `exit`s from its own scope.
        # Out-Host: anything a step leaves on the pipeline (install-wallust.ps1 ends with
        # `wallust --version`) goes to the screen, not into repair's return value -- which is
        # 710sRice's exit code (plan doc gotcha: a native command's output inside a function).
        try { & (Join-Path $Root 'install.ps1') -Only $Plan.Steps | Out-Host }
        catch { Write-Host "  [!!] install stopped: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    # The rest is the dispatcher's own code for each command (tools\lib\stack-commands.ps1;
    # repair runs inside 710sRice.ps1): the same thing as typing the command, from this same
    # admin window.
    if ($Plan.Tiling) {
        # Only saves the mode and re-registers komorebi's task; a running komorebi keeps its
        # level until it restarts (the re-check's [!!] says `710sRice restart`).
        Write-Host "`n-- Tiling mode --" -ForegroundColor Cyan
        try { Set-RiceTilingMode $Plan.Tiling | Out-Host }
        catch { Step-Warn "tiling $($Plan.Tiling): $($_.Exception.Message)" }
    }
    if ($Plan.Restart) {
        Write-Host "`n-- Restarting the stack --" -ForegroundColor Cyan
        try { Invoke-RiceRestart | Out-Host } catch { Step-Warn "restart: $($_.Exception.Message)" }
    } else {
        if ($Plan.Start.Count) {
            try { Start-RepairComponents $Plan.Start | Out-Host } catch { Step-Warn "starting what's down: $($_.Exception.Message)" }
        }
        if ($Plan.ReloadBar) {
            Write-Host "`n-- The bar --" -ForegroundColor Cyan
            try { Invoke-RiceReloadBar | Out-Host } catch { Step-Warn "reload bar: $($_.Exception.Message)" }
        }
    }
    if ($Plan.Reload) {
        # After the starts: `reload` goes through 710.ahk, which may just have come back.
        Write-Host "`n-- Reload --" -ForegroundColor Cyan
        try { Invoke-RiceReload | Out-Host } catch { Step-Warn "reload: $($_.Exception.Message)" }
    }
    # The config env vars are read at start: a komorebi / YASB already running keeps the old
    # folders until it restarts, and doctor can't see that (it reads the registry). A planned
    # restart has already taken care of it.
    if ($Plan.Steps -contains 'envvars' -and -not $Plan.Restart -and
        @(Get-RepairStackState | Where-Object { $_ -in 'komorebi', 'yasb' }).Count) {
        Write-Host ''
        Step-Info 'komorebi and YASB read the config env vars at start -- 710sRice restart picks them up'
    }
}

function Invoke-RiceRepair {
    <# `710sRice doctor -repair`. Returns the number of [XX] left -- 710sRice's exit code. #>
    Write-Host ''
    Write-Host '  Checking...' -ForegroundColor DarkGray
    # What's up now: before each re-check, these are waited for (an upgrade starts what it
    # stopped again -- through its task, or by asking 710.ahk -- and only waits 15 s at most).
    $upBefore = @(Get-RepairStackState)
    $report = Get-DoctorReport
    $title  = $report.Header.Title -replace '^710sRice doctor', '710sRice doctor -repair'
    $plan   = Get-RepairPlan $report.All

    # Nothing wrong, or nothing repair can do about it: the report is the answer.
    if (-not $plan.Lines.Count) {
        $left = Write-DoctorReport $report -Title $title -NoClosing
        $look = Get-RepairLookText $report
        Write-Host ''
        if (-not $left) {
            Write-Host "  Nothing to repair. $(if ($look) { $look } else { 'All good.' })" -ForegroundColor $(if ($look) { 'Yellow' } else { 'Green' })
        } else {
            $parts = @(
                if ($plan.NeedsYou.Count) { "$($plan.NeedsYou.Count) $(if ($plan.NeedsYou.Count -eq 1) { 'needs' } else { 'need' }) you" }
                if ($plan.Unknown.Count)  { "$($plan.Unknown.Count) it can't fix" }
            )
            Write-Host "  Nothing repair can fix: $(Get-DoctorPlural $left 'problem' 'problems') -- $($parts -join ', '); $(if ($left -eq 1) { 'its fix is above' } else { 'each has its fix above' })." -ForegroundColor Red
        }
        Write-Host ''
        return $left
    }

    Write-Host ''
    Write-Host "== $title ==" -ForegroundColor Cyan
    $seen  = [ordered]@{}   # every problem either round saw, by check Id
    $tried = @{}            # every problem a round had a fix for
    foreach ($round in 1, 2) {
        if ($round -eq 1) {
            $shown = $plan.Problems
            Write-Host ''
            Write-Host "  Found $(Get-DoctorPlural $shown.Count 'problem' 'problems'):" -ForegroundColor Red
        } else {
            # The problems the plan fixes now, plus any new one it leaves (the rest were
            # already listed in round 1).
            $shown = @($plan.Problems | Where-Object { $plan.Fixable -contains $_ -or -not $seen.Contains($_.Id) })
            Write-Host ''
            Write-Host "  Round 2 -- the first round uncovered $($plan.Fixable.Count) more:" -ForegroundColor Red
        }
        foreach ($r in $plan.Problems) { $seen[$r.Id] = $true }
        foreach ($r in $plan.Fixable)  { $tried[$r.Id] = $true }
        Write-RepairProblems $shown $plan
        Invoke-RepairPlan $plan

        # Settle: whatever was up when repair began is up again before it's checked.
        $upNow = @(Get-RepairStackState)
        $gone  = @($upBefore | Where-Object { $upNow -notcontains $_ })
        if ($gone.Count) {
            Write-Host ''
            Write-Host "  Waiting for $(@($gone | ForEach-Object { Get-DoctorComponentName $_ }) -join ', ') to come back up..." -ForegroundColor DarkGray
            $null = Wait-RepairComponents $upBefore 60
        }
        Write-Host ''
        Write-Host '  Checking again...' -ForegroundColor DarkGray
        $report = Get-DoctorReport
        if ($round -eq 2) { break }
        # Round 2 gets what round 1 had no fix for; a problem it tried is never retried.
        $plan = Get-RepairPlan @($report.All | Where-Object { $_.Status -ne 'XX' -or -not $tried.ContainsKey($_.Id) })
        if (-not $plan.Lines.Count) { break }
    }

    # The final report, then how it went. A problem that only turned up in the last check
    # counts too (as one not repaired), so "N of M" never reads as all done while one's left.
    $leftCount = Write-DoctorReport $report -NoClosing
    $left      = @($report.All | Where-Object { $_.Status -eq 'XX' })
    foreach ($r in $left) { $seen[$r.Id] = $true }
    $total     = $seen.Count
    $fixed     = $total - @($left | Where-Object { $seen.Contains($_.Id) }).Count
    $look      = Get-RepairLookText $report
    Write-Host ''
    $done = if ($fixed -eq $total) {
                switch ($total) { 1 { 'Repaired the problem.' } 2 { 'Repaired both problems.' } default { "Repaired all $total problems." } }
            } else { "Repaired $fixed of $(Get-DoctorPlural $total 'problem' 'problems')." }
    if (-not $leftCount) {
        Write-Host "  $done $(if ($look) { $look } else { 'All good.' })" -ForegroundColor $(if ($look) { 'Yellow' } else { 'Green' })
    } else {
        # What's left, by why: it needs you; repair tried and it's still broken; anything else
        # (repair had no fix for it, or it turned up only in the last check) wasn't repaired.
        $needsYou    = @($left | Where-Object { $_.NeedsYou }).Count
        $stillBroken = @($left | Where-Object { -not $_.NeedsYou -and $tried.ContainsKey($_.Id) }).Count
        $other       = $left.Count - $needsYou - $stillBroken
        $parts = @(
            if ($needsYou)    { "$needsYou $(if ($needsYou -eq 1) { 'needs' } else { 'need' }) you" }
            if ($stillBroken) { "$stillBroken still broken after repair" }
            if ($other)       { "$other not repaired" }
        )
        $what = if ($leftCount -eq 1) { 'its fix is above' } else { 'each has its fix above' }
        Write-Host "  $done Left: $($parts -join ', ') -- $what.$(if ($look) { " $look" })" -ForegroundColor Red
    }
    Write-Host ''
    $leftCount
}
