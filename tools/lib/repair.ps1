<#
.SYNOPSIS
  `710sRice doctor -repair` -- doctor's checks, the fix behind every [XX] that doesn't need
  you, then the checks again. Dot-sourced by 710sRice.ps1 after activation.ps1, packages.ps1
  and doctor.ps1 (it uses all three) -- never run directly. Runs in the admin window: the row
  is Admin Required.

.DESCRIPTION
  What it runs is doctor's own plan (Get-RepairPlan, doctor.ps1) -- the very list doctor's
  closing lines preview, printed again here before anything happens. No confirmation: typing
  -repair and saying yes to UAC were the two yeses (and `710sRice update` will run this
  unattended). The plan, in order:
    1. the install steps, as ONE `install.ps1 -Only <steps>` run, in install's order
    2. everything else in the plan (tiling, the stack, reload) -- not yet: commit 5 of Stage 4
       adds them; until then they're listed as left for you
  Never: theme (the default-wallpaper reset) or weather (needs someone at the keyboard), and
  never an [!!] or [..] line -- those are the user's call, or plain facts.

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

function Invoke-RepairPlan {
    # Runs one round's plan. Nothing here stops the rest: a fix that fails is reported, and
    # the check that follows says what's still wrong.
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
    # Stage 4, commit 4: the install steps only. Commit 5 runs the rest of the plan.
    $rest = @($Plan.Lines | Where-Object { $_ -notlike '710sRice install -Only *' })
    if ($rest.Count) {
        Write-Host ''
        foreach ($l in $rest) { Write-Host "  [..] $l -- not done by repair yet; run it yourself" -ForegroundColor Cyan }
    }
}

function Invoke-RiceRepair {
    <# `710sRice doctor -repair`. Returns the number of [XX] left -- 710sRice's exit code. #>
    Write-Host ''
    Write-Host '  Checking...' -ForegroundColor DarkGray
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
