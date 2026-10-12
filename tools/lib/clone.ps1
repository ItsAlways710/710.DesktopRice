<#
.SYNOPSIS
  This clone and GitHub: doctor's git calls and its lines about the clone -- the header, the
  update check, local changes. Dot-sourced by tools\lib\doctor.ps1, and so by everything that
  loads doctor (the doctor, doctor -repair and update rows); tools\lib\update.ps1 uses these
  too -- never run directly.

.DESCRIPTION
  Moved out of doctor.ps1 whole, before the release work changed it (the covenant: docs\map.md).
  Read-only, like doctor: every git call here is --no-optional-locks or one that never writes.
#>

# --- git's text, made safe to show ------------------------------------------------------------

function ConvertTo-DoctorGitText {
    # A line of git's as it can be shown: control characters out, the user's profile folders
    # hidden (ConvertTo-SafeText -- git names the repo's full path in some messages: "detected
    # dubious ownership in repository at 'C:/Users/<name>/...'") and the remote's URL left out
    # ("unable to access 'https://github.com/<owner>/...'" -- a fork's carries its owner's name).
    param([string]$Text)
    (ConvertTo-SafeText ("$Text" -replace '[\x00-\x1F\x7F]', '')) -replace "'?\w+://[^\s']+'?", 'origin'
}

function Get-DoctorFirstLine {
    # The first non-empty line of $Text, git's "fatal: " / "error: " prefix dropped, made safe to
    # show (ConvertTo-DoctorGitText).
    param([string]$Text)
    $line = @("$Text" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
    ConvertTo-DoctorGitText ("$line" -replace '^(fatal|error): ', '')
}

# --- git: the header, the update line, local changes -------------------------------------------

function Get-DoctorGit {
    # git.exe, or $null. Only an application -- never an alias or function of the same name.
    (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}

function Invoke-DoctorGit {
    # A quick, local, read-only git call, in this process: Ok (exit 0) and its stdout Lines.
    # The arguments come as one array of strings, so nothing in them (-e, -1) can be mistaken
    # for a PowerShell parameter on the way. Captured, so nothing reaches the caller's output.
    param([Parameter(Mandatory)][string]$Git, [Parameter(Mandatory)][string[]]$GitArgs)
    $out = & $Git --no-optional-locks -C $Root @GitArgs 2>$null
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Lines = @($out) }
}

function Get-DoctorGitEnvironment {
    @{ GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'never' }
}

function Start-DoctorGitJobs {
    # The two slow git calls, started now: `ls-remote` (asks GitHub which commit master is) and
    # `status` (walks every tracked file). $null jobs when there's no git or no clone -- Reason
    # says which, for the report.
    $git = Get-DoctorGit
    $state = [pscustomobject]@{ Git = $git; Reason = $null; Remote = $null; Status = $null }
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { $state.Reason = 'not a git clone'; return $state }
    if (-not $git) { $state.Reason = "git isn't installed"; return $state }
    $env = Get-DoctorGitEnvironment
    $state.Remote = Start-DoctorProcess -Exe $git -Environment $env -Arguments @('--no-optional-locks', '-C', $Root, 'ls-remote', 'origin', 'master')
    $state.Status = Start-DoctorProcess -Exe $git -Environment $env -Arguments @('--no-optional-locks', '-C', $Root, 'status', '--porcelain', '--untracked-files=no')
    $state
}

function Get-DoctorHeader {
    # "710sRice doctor -- d23988d, 2026-09-26", plus the branch when it isn't master. Also
    # hands back HEAD's full hash for the update check.
    param($GitState)
    $h = [pscustomobject]@{ Title = '710sRice doctor'; Head = $null }
    if ($GitState.Reason) { return $h }
    $log = Invoke-DoctorGit $GitState.Git @('log', '-1', '--format=%h%n%cs%n%H')
    if (-not $log.Ok -or $log.Lines.Count -lt 3) { return $h }
    $h.Head  = $log.Lines[2]
    $h.Title = "710sRice doctor -- $($log.Lines[0]), $($log.Lines[1])"
    $branch = "$((Invoke-DoctorGit $GitState.Git @('branch', '--show-current')).Lines)".Trim()
    if (-not $branch) { $h.Title += ' (detached HEAD)' }
    elseif ($branch -ne 'master') { $h.Title += " (branch $branch)" }
    $h
}

function Get-DoctorUpdateResult {
    # This clone against GitHub's master, from `git ls-remote origin master`. Nothing is
    # fetched, so a commit GitHub has and this clone has never seen can only be "newer"; one it
    # has seen (the last pull or push brought it) gets an exact count from `rev-list`.
    param($GitState, [string]$Head)
    if ($GitState.Reason) { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates or local changes ($($GitState.Reason))" }
    $r = Wait-DoctorProcess -Job $GitState.Remote -TimeoutSeconds 10
    if ($r.TimedOut)       { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates (no answer from GitHub in 10 s)" }
    if ($r.ExitCode -ne 0) { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates ($(Get-DoctorFirstLine $r.Err))" }
    $remote = ("$($r.Out)".Trim() -split '\s+')[0]
    if (-not $remote) { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates (GitHub has no master branch)" }
    if (-not $Head)   { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates (can't read this clone's commit)" }
    if ($remote -eq $Head) { return New-DoctorResult -Id 'update' -Status 'OK' -Text 'Up to date with GitHub' }

    # `710sRice update` pulls, then repairs from the new version (tools\lib\update.ps1).
    $newer = @{ Id = 'update'; Status = '!!'; Text = 'Newer version on GitHub'; Fix = '710sRice update' }
    if (-not (Invoke-DoctorGit $GitState.Git @('cat-file', '-e', "$remote^{commit}")).Ok) { return New-DoctorResult @newer }
    $rl = Invoke-DoctorGit $GitState.Git @('rev-list', '--left-right', '--count', "$Head...$remote")
    $counts = "$($rl.Lines)".Trim() -split '\s+'
    if (-not $rl.Ok -or $counts.Count -ne 2) { return New-DoctorResult @newer }
    $ahead, $behind = [int]$counts[0], [int]$counts[1]
    if ($ahead -eq 0 -and $behind -eq 0) { return New-DoctorResult -Id 'update' -Status 'OK' -Text 'Up to date with GitHub' }
    if ($ahead -eq 0) {
        $newer.Text += " -- $(Get-DoctorPlural $behind 'commit behind' 'commits behind')"
        return New-DoctorResult @newer
    }
    if ($behind -eq 0) {
        return New-DoctorResult -Id 'update' -Status '..' -Text "Ahead of GitHub -- $(Get-DoctorPlural $ahead 'commit' 'commits') not pushed"
    }
    New-DoctorResult -Id 'update' -Status '!!' -Text "Your copy and GitHub have both moved -- a git pull won't fast-forward" `
        -Detail "$(Get-DoctorPlural $ahead 'commit' 'commits') here that GitHub doesn't have, $behind on GitHub that $(if ($behind -eq 1) { "isn't" } else { "aren't" }) here" `
        -Fix 'git pull --rebase, then 710sRice doctor -repair'   # update won't merge or rebase for you
}

function Get-DoctorLocalChangesResult {
    # Tracked files edited in place. `710sRice update` refuses to pull over any of them (git
    # itself only refuses when an incoming commit touches one), so the user's own tweaks belong
    # in the files git ignores (user.ahk, rules.local.toml, user.ps1). update reuses this check.
    param($GitState)
    if ($GitState.Reason) { return $null }   # the update line already said why
    $r = Wait-DoctorProcess -Job $GitState.Status -TimeoutSeconds 10
    if ($r.TimedOut)       { return New-DoctorResult -Id 'local-changes' -Status '..' -Text "Couldn't check for local changes (git status took over 10 s)" }
    if ($r.ExitCode -ne 0) { return New-DoctorResult -Id 'local-changes' -Status '..' -Text "Couldn't check for local changes ($(Get-DoctorFirstLine $r.Err))" }
    # --porcelain: two status letters and a space, then the path ("old -> new" for a rename).
    $files = @("$($r.Out)" -split "`r?`n" | Where-Object { $_.Length -gt 3 } | ForEach-Object { $_.Substring(3) })
    if (-not $files.Count) { return New-DoctorResult -Id 'local-changes' -Status 'OK' -Text 'No tracked files changed locally' }
    $shown = @($files | Select-Object -First 8)
    if ($files.Count -gt $shown.Count) { $shown += "... and $($files.Count - $shown.Count) more" }
    New-DoctorResult -Id 'local-changes' -Status '!!' `
        -Text "$(Get-DoctorPlural $files.Count 'tracked file' 'tracked files') changed locally -- 710sRice update won't pull over $(if ($files.Count -eq 1) { 'it' } else { 'them' })" `
        -Detail $shown -Fix 'move your edits into user.ahk / rules.local.toml / user.ps1, or git stash'
}
