<#
.SYNOPSIS
  `710sRice update` -- the newest version from GitHub, then `710sRice doctor -repair` run from it.
  Dot-sourced by 710sRice.ps1 after activation.ps1, packages.ps1 and doctor.ps1 (it uses doctor's
  git helpers and, when there's nothing to pull, doctor's report) -- never run directly.

.DESCRIPTION
  Two halves (claude/cli-plan.md, Stage 5):
    1. Invoke-RiceUpdate, here, in your window, as you: refuse unless the pull can be a clean
       fast-forward (a git clone, on master, no tracked file changed, GitHub reachable, not
       diverged) -- nothing changes on a refusal; fetch; show what's coming; fast-forward.
    2. Invoke-RiceUpdateHandOff: `710sRice doctor -repair` in a NEW process started from the
       pulled files, so the new version's checks decide what "healthy" means and its install
       steps do the fixing. From a normal window it's the usual admin window (one UAC prompt,
       its exit code passed on); from an admin window, a child in this same window.
  Nothing to pull (the same commit as GitHub, or only ahead of it): doctor's report, right here --
  read-only, no UAC. It still shows what a pull whose repair never ran left behind.

  THE OLD CODE RUNS HALF 1. This file, the dispatcher and everything they loaded were read before
  the pull, and nothing is loaded after it -- old code in memory never mixes with new files; half
  2 is always a new process. So a change to half 1 only takes effect from the NEXT update, and
  every copy of half 1 out there, however old, hands off with `710sRice.ps1 --elevated doctor
  -repair` (normal window) or `710sRice.ps1 doctor -repair` (admin window): every future
  dispatcher must keep both working.

  Exit code: a refusal, or a hand-off that didn't run, 1; nothing to pull, doctor's [XX] count;
  pulled, repair's [XX] left (0 = updated and healthy).
#>

function Write-UpdateRefusal {
    # Doctor's look for a line that stops the update: [XX], detail lines, fix.
    param([Parameter(Mandatory)][string]$Text, [string[]]$Detail = @(), [string]$Fix = '')
    Write-DoctorResult (New-DoctorResult -Id 'update' -Status 'XX' -Text $Text -Detail $Detail -Fix $Fix)
}

function Invoke-UpdateGit {
    # git in a background process (doctor's: no window, stdin closed, no credential prompt),
    # waited for: TimedOut, ExitCode, Lines (stdout, UTF-8), Why (stderr's first line) and More
    # (up to 5 of its next lines -- a merge names the files it tripped on there), both made safe
    # to show by doctor's ConvertTo-DoctorGitText: no profile folders, no remote URL.
    param([Parameter(Mandatory)][string]$Git, [Parameter(Mandatory)][string[]]$GitArgs, [int]$TimeoutSeconds = 30)
    $job = Start-DoctorProcess -Exe $Git -Environment (Get-DoctorGitEnvironment) `
               -Arguments (@('--no-optional-locks', '-C', $Root) + $GitArgs)
    $r = Wait-DoctorProcess -Job $job -TimeoutSeconds $TimeoutSeconds
    $err = @("$($r.Err)" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    [pscustomobject]@{
        TimedOut = $r.TimedOut
        ExitCode = $r.ExitCode
        Lines    = @("$($r.Out)" -split "`r?`n" | Where-Object { $_ })
        Why      = Get-DoctorFirstLine $r.Err
        More     = @($err | Select-Object -Skip 1 -First 5 | ForEach-Object { ConvertTo-DoctorGitText $_ })
    }
}

function Invoke-RiceUpdate {
    <# Half 1. Returns Exit (710sRice's exit code) and HandOff ($true: pulled -- the caller runs
       Invoke-RiceUpdateHandOff next, as a statement of its own, so the new process writes
       straight to this console). Everything on screen goes through Write-Host. #>
    $done = { param([int]$Exit) [pscustomobject]@{ Exit = $Exit; HandOff = $false } }
    Write-Host ''

    # --- Refusals that need no network (Topic 2: 1-3) -------------------------------------------
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        Write-UpdateRefusal "This copy isn't a git clone -- update needs one" -Fix 'clone the repo with git, the way the README shows'
        return & $done 1
    }
    $git = Get-DoctorGit
    if (-not $git) {
        Write-UpdateRefusal "git isn't installed -- update needs it" -Fix 'winget install --id Git.Git -e, then 710sRice update'
        return & $done 1
    }
    $branch = "$((Invoke-DoctorGit $git @('branch', '--show-current')).Lines)".Trim()
    if ($branch -ne 'master') {
        $where = if ($branch) { "on branch $branch" } else { 'on a detached HEAD' }
        Write-UpdateRefusal "This copy is $where -- update follows GitHub's master" -Fix 'git switch master, then 710sRice update'
        return & $done 1
    }
    # Any tracked file changed: doctor's own check (same list, same fix), as a refusal.
    $status = Start-DoctorProcess -Exe $git -Environment (Get-DoctorGitEnvironment) `
                  -Arguments @('--no-optional-locks', '-C', $Root, 'status', '--porcelain', '--untracked-files=no')
    $local = Get-DoctorLocalChangesResult ([pscustomobject]@{ Reason = $null; Status = $status })
    if ($local.Status -ne 'OK') {
        $local.Status = 'XX'
        if ($local.Text -like "Couldn't*") { $local.Text += ' -- nothing changed' }
        Write-DoctorResult $local
        return & $done 1
    }

    # --- GitHub (Topic 2: 4-5) ---------------------------------------------------------------------
    # The fetch moves this clone's origin/master along (normal git); nothing else changes yet.
    # It downloads, so it gets longer than doctor's ls-remote -- and a cap, because a stalled
    # connection could otherwise hang here for good.
    Write-Host '  Checking GitHub...' -ForegroundColor DarkGray
    $fetch = Invoke-UpdateGit $git @('fetch', '--no-tags', 'origin', '+refs/heads/master:refs/remotes/origin/master') -TimeoutSeconds 120
    if ($fetch.TimedOut) { Write-UpdateRefusal "Couldn't reach GitHub (no answer in 2 minutes) -- nothing changed"; return & $done 1 }
    if ($fetch.ExitCode -ne 0) { Write-UpdateRefusal "Couldn't reach GitHub ($($fetch.Why)) -- nothing changed"; return & $done 1 }

    $remote = 'refs/remotes/origin/master'
    $head   = "$((Invoke-DoctorGit $git @('rev-parse', 'HEAD')).Lines)".Trim()
    $rl     = Invoke-DoctorGit $git @('rev-list', '--left-right', '--count', "HEAD...$remote")
    $counts = "$($rl.Lines)".Trim() -split '\s+'
    if (-not $head -or -not $rl.Ok -or $counts.Count -ne 2) {
        Write-UpdateRefusal "Couldn't compare this copy with GitHub's master -- nothing changed"
        return & $done 1
    }
    $ahead, $behind = [int]$counts[0], [int]$counts[1]
    $short = { param($ref) "$((Invoke-DoctorGit $git @('rev-parse', '--short', $ref)).Lines)".Trim() }

    # --- Nothing to pull (Topic 3): doctor's report, right here ------------------------------------
    if ($behind -eq 0) {
        if ($ahead -eq 0) { Write-Host "  [OK] Already up to date with GitHub ($(& $short 'HEAD'))" -ForegroundColor Green }
        else { Write-Host "  [..] Nothing to pull -- this copy is $(Get-DoctorPlural $ahead 'commit' 'commits') ahead of GitHub (not pushed)" -ForegroundColor Cyan }
        return & $done (Invoke-RiceDoctor)
    }
    if ($ahead -gt 0) {
        Write-UpdateRefusal "Your copy and GitHub have both moved -- update won't merge or rebase for you" `
            -Detail "$(Get-DoctorPlural $ahead 'commit' 'commits') here that GitHub doesn't have, $behind on GitHub that $(if ($behind -eq 1) { "isn't" } else { "aren't" }) here" `
            -Fix 'git pull --rebase, then 710sRice doctor -repair'
        return & $done 1
    }

    # --- The pull: what's coming, then a fast-forward (Topic 5) ------------------------------------
    $from = & $short 'HEAD'
    $to   = & $short $remote
    $log  = Invoke-UpdateGit $git @('log', '--reverse', '--format=%h %s', "HEAD..$remote")
    Write-Host "  [OK] Updating $from -> $to ($(Get-DoctorPlural $behind 'commit' 'commits')):" -ForegroundColor Green
    foreach ($l in @($log.Lines | Select-Object -First 15)) {
        Write-Host "         $($l -replace '[\x00-\x1F\x7F]', '')" -ForegroundColor DarkGray
    }
    if ($log.Lines.Count -gt 15) { Write-Host "         ... and $($log.Lines.Count - 15) more" -ForegroundColor DarkGray }

    $merge = Invoke-UpdateGit $git @('merge', '--ff-only', '--quiet', $remote) -TimeoutSeconds 120
    if ($merge.TimedOut -or $merge.ExitCode -ne 0) {
        $why = if ($merge.TimedOut) { 'git took over 2 minutes' } else { $merge.Why }
        $now = "$((Invoke-DoctorGit $git @('rev-parse', 'HEAD')).Lines)".Trim()
        if ($now -eq $head) { Write-UpdateRefusal "Couldn't fast-forward ($why) -- nothing changed" -Detail $merge.More }
        else { Write-UpdateRefusal "The fast-forward stopped part-way ($why)" -Detail $merge.More -Fix 'git status shows where it stands; then 710sRice doctor -repair' }
        return & $done 1
    }
    Write-Host '  [OK] Pulled -- repairing with the new version' -ForegroundColor Green
    [pscustomobject]@{ Exit = 0; HandOff = $true }
}

function Invoke-RiceUpdateHandOff {
    <# Half 2: `710sRice doctor -repair` in a NEW process, from the pulled files (see the header --
       both forms below are the contract every older update relies on). Sets $script:RiceExit.
       Call it as a statement of its own, never inside an assignment: the admin-window child's
       output then goes straight to this console instead of into a return value. #>
    if (Test-RiceAdmin) {
        # An admin window already: a child in this same window -- no UAC, no second window.
        # `pwsh` by name, as Invoke-RiceElevated does (the Store build's own exe can't always be
        # started directly; the name on PATH can).
        Write-Host ''
        $global:LASTEXITCODE = 0
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root '710sRice.ps1') doctor -repair
        $script:RiceExit = [int]$LASTEXITCODE
        return
    }
    try {
        Invoke-RiceElevated 'doctor' '-repair'   # sets $script:RiceExit (and RiceRelayed)
    } catch {
        $why = if ($_.Exception.Message -match 'UAC was declined') { 'UAC was declined' } else { ConvertTo-SafeText $_.Exception.Message }
        Write-UpdateRefusal "Updated, but the repair didn't run ($why)" -Fix '710sRice doctor -repair'
        $script:RiceExit = 1
    }
}
