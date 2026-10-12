<#
.SYNOPSIS
  `710sRice update [-Latest | -Release]` -- the newest release from GitHub (official), or master's
  newest commit (bleeding edge), then `710sRice doctor -repair` run from it. Dot-sourced by
  710sRice.ps1 after activation.ps1 and doctor.ps1 (it uses doctor's git helpers --
  tools\lib\clone.ps1, which doctor.ps1 loads -- and, when no files move, doctor's report) --
  never run directly.

.DESCRIPTION
  Two halves (claude/cli-plan.md, Stage 5):
    1. Invoke-RiceUpdate, here, in your window, as you: refuse unless the move can be a clean
       fast-forward (a git clone, on release or master, no tracked file changed, GitHub reachable,
       not diverged) -- nothing changes on a refusal but a switch's saved choice; ask GitHub, fetch;
       show what's coming; fast-forward.
    2. Invoke-RiceUpdateHandOff: `710sRice doctor -repair` in a NEW process started from the
       pulled files, so the new version's checks decide what "healthy" means and its install
       steps do the fixing. From a normal window it's the usual admin window (one UAC prompt,
       its exit code passed on); from an admin window, a child in this same window.
  No files to move (up to date, only ahead of GitHub, the hold, or just a branch switch at the
  same commit): doctor's report, right here -- read-only, no UAC. It still shows what an update
  whose repair never ran left behind.

  Which way it goes: the clone's saved choice (clone.ps1: Get-RiceUpdateWay), official when nothing
  is saved. Official follows GitHub's release branch, which only ever moves to a release tag;
  bleeding edge (-Latest) follows master. -Release goes back to official without a step back: a
  build that a release already includes moves onto release now, and one newer than every release
  stays exactly where it is (the hold) until a release includes it. Bleeding edge from release is
  always forward: release is in master's history. Existing clones are official, on master: their
  first update to this ran their old half 1 (master only, no tags); this one moves them onto
  release, or holds.

  THE OLD CODE RUNS HALF 1. This file, the dispatcher and everything they loaded were read before
  the pull, and nothing is loaded after it -- old code in memory never mixes with new files; half
  2 is always a new process. So a change to half 1 only takes effect from the NEXT update, and
  every copy of half 1 out there, however old, hands off with `710sRice.ps1 --elevated doctor
  -repair` (normal window) or `710sRice.ps1 doctor -repair` (admin window): every future
  dispatcher must keep both working. (Half 1 before 2026-10-12 fetches master only, without tags,
  and refuses any branch but master.)

  Exit code: a refusal, or a hand-off that didn't run, 1; no files moved, doctor's [XX] count;
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

function Test-RiceOwnOrigin {
    # Is origin this repo, ItsAlways710/710.DesktopRice on GitHub (its URL as configured)? Only then
    # does update link a release's page: a fork's would be its owner's, and named here.
    param([Parameter(Mandatory)][string]$Git)
    "$((Invoke-DoctorGit $Git @('config', '--get', 'remote.origin.url')).Lines)".Trim() -match '^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)ItsAlways710/710\.DesktopRice(\.git)?/?$'
}

function Invoke-RiceUpdate {
    <# Half 1. $args: nothing, -Latest or -Release, checked before anything happens. Returns Exit
       (710sRice's exit code) and HandOff ($true: files moved -- the caller runs
       Invoke-RiceUpdateHandOff next, as a statement of its own, so the new process writes straight
       to this console). Everything on screen goes through Write-Host. #>
    $done = { param([int]$Exit) [pscustomobject]@{ Exit = $Exit; HandOff = $false } }

    # --- The switches: any other option, or both, and nothing happens ------------------------------
    $switch = $null
    foreach ($a in $args) {
        $o = "$a"
        if ($o -notin '-Latest', '-Release') {
            Write-RiceError "Unknown option '$o' for update"
            Show-RiceCommandHelp 'update'
            return & $done 1
        }
        if ($switch -and $switch -ne $o) {
            Write-RiceError '-Latest and -Release contradict each other -- pick one. Nothing was changed.'
            return & $done 1
        }
        $switch = $o
    }
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
    # A switch is saved first, so it holds even when this run then refuses (the line says so).
    $nothing = 'nothing changed'
    if ($switch) {
        $want = if ($switch -eq '-Latest') { 'bleeding-edge' } else { 'official' }
        $had  = Get-RiceUpdateWay $git
        # A failed write reaches the refusal below, not a throw, even with a profile's
        # $PSNativeCommandUseErrorActionPreference = $true (off in this one call's own scope).
        $null = & { $PSNativeCommandUseErrorActionPreference = $false; & $git -C $Root config --local 710srice.updates $want 2>$null }
        if ($LASTEXITCODE -ne 0) { Write-UpdateRefusal "Couldn't save the choice in this clone's git config -- nothing changed"; return & $done 1 }
        $what = if ($want -eq 'official') { @('Official', 'updates take releases only') } else { @('Bleeding edge', "each update takes master's newest commit") }
        Write-Host "  [OK] $(if ($had -eq $want) { "$($what[0]), as it was: $($what[1])" } else { "$($what[0]) from now on: $($what[1]) (saved in this clone)" })" -ForegroundColor Green
        $nothing = 'nothing else changed'
    }
    $way    = Get-RiceUpdateWay $git
    $target = if ($way -eq 'official') { 'release' } else { 'master' }
    $branch = "$((Invoke-DoctorGit $git @('branch', '--show-current')).Lines)".Trim()
    if ($branch -notin 'release', 'master') {
        $where = if ($branch) { "on branch $branch" } else { 'on a detached HEAD' }
        $to    = if ($target -eq 'master' -or -not ((Get-RiceRef $git 'refs/heads/release') -or (Get-RiceRef $git 'refs/remotes/origin/release'))) { 'master' } else { 'release' }
        Write-UpdateRefusal "This copy is $where -- update follows GitHub's $target ($(if ($way -eq 'official') { 'official' } else { 'bleeding edge' }))" -Fix "git switch $to, then 710sRice update"
        return & $done 1
    }
    # Any tracked file changed: doctor's own check (same list, same fix), as a refusal.
    $status = Start-DoctorProcess -Exe $git -Environment (Get-DoctorGitEnvironment) `
                  -Arguments @('--no-optional-locks', '-C', $Root, 'status', '--porcelain', '--untracked-files=no')
    $local = Get-DoctorLocalChangesResult ([pscustomobject]@{ Reason = $null; Status = $status })
    if ($local.Status -ne 'OK') {
        $local.Status = 'XX'
        if ($local.Text -like "Couldn't*") { $local.Text += " -- $nothing" }
        Write-DoctorResult $local
        return & $done 1
    }

    # --- GitHub (Topic 2: 4-5) ---------------------------------------------------------------------
    # Which branches and releases it has (a GitHub with no release yet is fine), then a fetch of
    # just those and the release tags: it moves this clone's origin/master and origin/release
    # along (normal git); nothing else changes yet. The fetch downloads, so it gets longer than the
    # ask -- and a cap, because a stalled connection could otherwise hang here for good.
    Write-Host '  Checking GitHub...' -ForegroundColor DarkGray
    $ask = Invoke-UpdateGit $git (@('ls-remote', 'origin') + (Get-RiceRemoteRefNames)) -TimeoutSeconds 60
    if ($ask.TimedOut) { Write-UpdateRefusal "Couldn't reach GitHub (no answer in a minute) -- $nothing"; return & $done 1 }
    if ($ask.ExitCode -ne 0) { Write-UpdateRefusal "Couldn't reach GitHub ($($ask.Why)) -- $nothing"; return & $done 1 }
    $remote = ConvertFrom-RiceRemoteRefs $ask.Lines
    $specs = @(
        if ($remote.Master)  { '+refs/heads/master:refs/remotes/origin/master' }
        if ($remote.Release) { '+refs/heads/release:refs/remotes/origin/release' }
        '+refs/tags/v*:refs/tags/v*'
    )
    $fetch = Invoke-UpdateGit $git (@('fetch', '--no-tags', 'origin') + $specs) -TimeoutSeconds 120
    if ($fetch.TimedOut) { Write-UpdateRefusal "Couldn't reach GitHub (no answer in 2 minutes) -- $nothing"; return & $done 1 }
    if ($fetch.ExitCode -ne 0) { Write-UpdateRefusal "Couldn't reach GitHub ($($fetch.Why)) -- $nothing"; return & $done 1 }

    # What was fetched is what's followed, the decision included: a release pushed between the ask
    # and the fetch counts.
    if ($remote.Release) { $remote.Release = Get-RiceRef $git 'refs/remotes/origin/release' }
    if ($remote.Master)  { $remote.Master  = Get-RiceRef $git 'refs/remotes/origin/master' }
    $head = Get-RiceRef $git 'HEAD'
    $goal = if ($target -eq 'release') { $remote.Release } else { $remote.Master }
    if (-not $head) { Write-UpdateRefusal "Couldn't read this copy's commit -- $nothing"; return & $done 1 }
    $s = Get-RiceCloneState -Git $git -Head $head -Branch $branch -Remote $remote
    if ($target -eq 'master' -and -not $goal) { Write-UpdateRefusal "GitHub has no master branch -- $nothing"; return & $done 1 }
    $name = if ($goal) { Get-RiceReleaseName $s.Tags $goal }

    # --- Official, and nothing to follow yet, or a build newer than every release: it stays ------
    if ($target -eq 'release' -and -not $goal) {
        Write-Host "  [..] No release on GitHub yet -- this build ($($s.Build.Plain)) stays as it is until the first one; 710sRice update -Latest follows master meanwhile" -ForegroundColor Cyan
        return & $done (Invoke-RiceDoctor)
    }
    if ($s.Held) {
        Write-Host "  [..] $(Get-RiceHoldText $s $name)" -ForegroundColor Cyan
        return & $done (Invoke-RiceDoctor)
    }

    # --- Onto the branch it follows (official from master, bleeding edge from release) -----------
    # Only ever forward. The local branch is made, or moved, to this very commit -- so the switch
    # itself moves no files -- unless it holds commits GitHub's doesn't have.
    $move = $branch -ne $target
    if ($move) {
        $old = Get-RiceRef $git "refs/heads/$target"
        if ($old -and $old -ne $head -and -not (Test-RiceAncestor $git $old $head) -and -not (Test-RiceAncestor $git $old $goal)) {
            Write-UpdateRefusal "This copy's $target branch has commits GitHub's doesn't -- update won't move it ($nothing)" -Fix "git switch $target, then 710sRice update"
            return & $done 1
        }
    }
    $c = Compare-RiceCommits $git $head $goal
    if (-not $c) { Write-UpdateRefusal "Couldn't compare this copy with GitHub's $target -- $nothing"; return & $done 1 }
    if ($c.Ahead -and $c.Behind) {
        Write-UpdateRefusal "Your copy and GitHub's $target have both moved -- update won't merge or rebase for you" `
            -Detail "$(Get-DoctorPlural $c.Ahead 'commit' 'commits') here that GitHub doesn't have, $($c.Behind) on GitHub that $(if ($c.Behind -eq 1) { "isn't" } else { "aren't" }) here" `
            -Fix 'git pull --rebase, then 710sRice doctor -repair'
        return & $done 1
    }
    if ($move) {
        $zero = '0' * $head.Length
        foreach ($step in @(@('update-ref', '-m', "710sRice update: onto $target", "refs/heads/$target", $head, $(if ($old) { $old } else { $zero })),
                            @('branch', "--set-upstream-to=origin/$target", $target),
                            @('symbolic-ref', '-m', "710sRice update: onto $target", 'HEAD', "refs/heads/$target"))) {
            $r = Invoke-UpdateGit $git $step
            if ($r.TimedOut -or $r.ExitCode -ne 0) {
                Write-UpdateRefusal "Couldn't switch to the $target branch ($(if ($r.TimedOut) { 'git took over 30 seconds' } else { $r.Why })) -- no files changed" -Fix 'git status shows where it stands; then 710sRice update'
                return & $done 1
            }
        }
        Write-Host "  [OK] Onto the $target branch -- this copy follows $(if ($target -eq 'release') { 'releases' } else { 'every commit' }) from here" -ForegroundColor Green
    }

    # --- No files to move: doctor's report, right here (Topic 3) ---------------------------------
    if (-not $c.Behind) {
        if ($c.Ahead) { Write-Host "  [..] Nothing to pull -- this copy is $(Get-DoctorPlural $c.Ahead 'commit' 'commits') ahead of GitHub's $target (not pushed)" -ForegroundColor Cyan }
        else { Write-Host "  [OK] $($s.Build.Text) is up to date ($(if ($target -eq 'release') { 'official' } else { 'bleeding edge' }))" -ForegroundColor Green }
        return & $done (Invoke-RiceDoctor)
    }

    # --- The pull: what's coming, then a fast-forward (Topic 5) ------------------------------------
    if ($target -eq 'release') {
        $to = Get-RiceBuild $git $goal $s.Tags
        Write-Host "  [OK] Updating $($s.Build.Text) -> $($to.Text) (official)" -ForegroundColor Green
        $tag = (@($s.Tags | Where-Object { $_.Commit -eq $goal }) | Select-Object -First 1).Tag
        if ($tag -and (Test-RiceOwnOrigin $git)) {
            Write-Host "         What's new: https://github.com/ItsAlways710/710.DesktopRice/releases/tag/$tag" -ForegroundColor DarkGray
        }
    } else {
        $log = Invoke-UpdateGit $git @('log', '--reverse', '--format=%h %s', "HEAD..$goal")
        Write-Host "  [OK] Updating $($s.Build.Short) -> $((Get-RiceBuild $git $goal @()).Short) ($(Get-DoctorPlural $c.Behind 'commit' 'commits'), bleeding edge):" -ForegroundColor Green
        foreach ($l in @($log.Lines | Select-Object -First 15)) {
            Write-Host "         $($l -replace '[\x00-\x1F\x7F]', '')" -ForegroundColor DarkGray
        }
        if ($log.Lines.Count -gt 15) { Write-Host "         ... and $($log.Lines.Count - 15) more" -ForegroundColor DarkGray }
    }

    $merge = Invoke-UpdateGit $git @('merge', '--ff-only', '--quiet', $goal) -TimeoutSeconds 120
    if ($merge.TimedOut -or $merge.ExitCode -ne 0) {
        $why = if ($merge.TimedOut) { 'git took over 2 minutes' } else { $merge.Why }
        $now = Get-RiceRef $git 'HEAD'
        if ($now -eq $head) { Write-UpdateRefusal "Couldn't fast-forward ($why) -- no files changed$(if ($move) { "; this copy is on its $target branch now, at the commit it was on" })" -Detail $merge.More }
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
