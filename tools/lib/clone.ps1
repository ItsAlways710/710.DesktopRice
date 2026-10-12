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
    # The two slow git calls, started now: `ls-remote` (asks GitHub where master and release are,
    # and which releases it has) and `status` (walks every tracked file). $null jobs when there's
    # no git or no clone -- Reason says which, for the report. Header: Get-DoctorHeader's, which
    # the update check finishes once GitHub has answered.
    $git = Get-DoctorGit
    $state = [pscustomobject]@{ Git = $git; Reason = $null; Remote = $null; Status = $null; Header = $null }
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { $state.Reason = 'not a git clone'; return $state }
    if (-not $git) { $state.Reason = "git isn't installed"; return $state }
    $env = Get-DoctorGitEnvironment
    $state.Remote = Start-DoctorProcess -Exe $git -Environment $env -Arguments (@('--no-optional-locks', '-C', $Root, 'ls-remote', 'origin') + (Get-RiceRemoteRefNames))
    $state.Status = Start-DoctorProcess -Exe $git -Environment $env -Arguments @('--no-optional-locks', '-C', $Root, 'status', '--porcelain', '--untracked-files=no')
    $state
}

function Get-DoctorHeader {
    # "710sRice doctor -- 0.1.0, official": the version, then which way this clone follows (its
    # first line, and what a bug report carries), plus the branch when it's neither release nor
    # master. The update check fills the version and the way in, once GitHub has answered
    # (Get-DoctorUpdateResult); until then it's HEAD's short hash. Head: HEAD's full hash, for the
    # update check.
    param($GitState)
    $h = [pscustomobject]@{ Title = '710sRice doctor'; Head = $null; Branch = ''; Note = '' }
    if ($GitState.Reason) { return $h }
    $GitState.Header = $h
    $log = Invoke-DoctorGit $GitState.Git @('log', '-1', '--format=%h%n%H')
    if (-not $log.Ok -or $log.Lines.Count -lt 2) { return $h }
    $h.Head   = $log.Lines[1]
    $h.Branch = "$((Invoke-DoctorGit $GitState.Git @('branch', '--show-current')).Lines)".Trim()
    $h.Note   = if (-not $h.Branch) { ' (detached HEAD)' } elseif ($h.Branch -notin 'master', 'release') { " (branch $($h.Branch))" } else { '' }
    $h.Title  = "710sRice doctor -- $($log.Lines[0])$($h.Note)"
    $h
}

function Get-DoctorUpdateResult {
    # This clone against the branch it follows on GitHub -- release (official) or master
    # (bleeding edge) -- from Start-DoctorGitJobs' `git ls-remote`; it also finishes doctor's first
    # line (Get-DoctorHeader) with the version and that way. Nothing is fetched, so a commit GitHub
    # has and this clone has never seen can only be newer; one it has seen (the last update or push
    # brought it) gets an exact count from `rev-list`.
    param($GitState, [string]$Head)
    if ($GitState.Reason) { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates or local changes ($($GitState.Reason))" }
    $r = Wait-DoctorProcess -Job $GitState.Remote -TimeoutSeconds 10
    $remote = if (-not $r.TimedOut -and $r.ExitCode -eq 0) { ConvertFrom-RiceRemoteRefs ("$($r.Out)" -split "`r?`n") } else { $null }
    $s = if ($Head) { Get-RiceCloneState -Git $GitState.Git -Head $Head -Branch $GitState.Header.Branch -Remote $remote } else { $null }
    if ($s -and $GitState.Header) { $GitState.Header.Title = "710sRice doctor -- $($s.Build.Text), $($s.WayText)$($GitState.Header.Note)" }
    if ($r.TimedOut)       { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates (no answer from GitHub in 10 s)" }
    if ($r.ExitCode -ne 0) { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates ($(Get-DoctorFirstLine $r.Err))" }
    if (-not $Head)        { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates (can't read this clone's commit)" }

    # `710sRice update` moves this clone along (tools\lib\update.ps1).
    if ($s.Way -eq 'official') {
        if ($s.NoRelease) { return New-DoctorResult -Id 'update' -Status '..' -Text 'No release on GitHub yet -- official starts with the first one (710sRice update -Latest follows master meanwhile)' }
        $branch = "GitHub's release"
        $name   = Get-RiceReleaseName $remote.Tags $s.Release
        $newer  = @{ Id = 'update'; Status = '!!'; Text = "Newer release on GitHub$(if ($name) { " -- $name" })"; Fix = '710sRice update' }
        $c = Compare-RiceCommits $GitState.Git $Head $s.Release
        if (-not $c) { return New-DoctorResult @newer }
        if (-not $c.Ahead -and -not $c.Behind) {
            return New-DoctorResult -Id 'update' -Status 'OK' -Text $(if ($name) { "Up to date -- $name is the newest release" } else { "Up to date with GitHub's release" })
        }
        if (-not $c.Ahead) { $newer.Text += " (this copy: $($s.Build.Text))"; return New-DoctorResult @newer }
        if ($s.Held) { return New-DoctorResult -Id 'update' -Status '..' -Text (Get-RiceHoldText $s $name) }
    } else {
        if (-not $s.Master) { return New-DoctorResult -Id 'update' -Status '..' -Text "Couldn't check for updates (GitHub has no master branch)" }
        $branch = "GitHub's master"
        $newer  = @{ Id = 'update'; Status = '!!'; Text = "Newer version on GitHub's master"; Fix = '710sRice update' }
        $c = Compare-RiceCommits $GitState.Git $Head $s.Master
        if (-not $c) { return New-DoctorResult @newer }
        if (-not $c.Ahead -and -not $c.Behind) { return New-DoctorResult -Id 'update' -Status 'OK' -Text "Up to date with GitHub's master" }
        if (-not $c.Ahead) {
            $newer.Text += " -- $(Get-DoctorPlural $c.Behind 'commit behind' 'commits behind')"
            return New-DoctorResult @newer
        }
    }
    if (-not $c.Behind) {
        return New-DoctorResult -Id 'update' -Status '..' -Text "Ahead of $branch -- $(Get-DoctorPlural $c.Ahead 'commit' 'commits') not pushed"
    }
    New-DoctorResult -Id 'update' -Status '!!' -Text "Your copy and $branch have both moved -- a git pull won't fast-forward" `
        -Detail "$(Get-DoctorPlural $c.Ahead 'commit' 'commits') here that GitHub doesn't have, $($c.Behind) on GitHub that $(if ($c.Behind -eq 1) { "isn't" } else { "aren't" }) here" `
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

# --- The version, and which way updates go ------------------------------------------------------
# A release is a tag vX.Y.Z on master, with the release branch moved up to it (docs\releasing.md);
# the tag is the version. A clone follows release (official: plain `710sRice update`) or master
# (bleeding edge: `710sRice update -Latest`), saved in its own .git\config (710srice.updates) --
# not in the logs folder, which uninstall deletes: the clone outlives an uninstall. Nothing saved
# is official. Official never steps back: a build newer than every release stays where it is (the
# hold) until a release includes it.

function Get-RiceRemoteRefNames {
    # What doctor and update ask GitHub for: the two branches and the release tags.
    'refs/heads/master', 'refs/heads/release', 'refs/tags/v*'
}

function Get-RiceReleaseTags {
    # The release tags (vX.Y.Z) in `show-ref -d` / `ls-remote` lines -- "<hash> refs/tags/v0.1.0",
    # and for an annotated tag also "<hash> refs/tags/v0.1.0^{}", its commit -- newest first: Tag,
    # Version ('0.1.0'), Commit.
    param([string[]]$Lines)
    $found = @{}
    foreach ($l in $Lines) {
        if ("$l" -notmatch '^([0-9a-f]{40,64})\s+refs/tags/(v(\d{1,9})\.(\d{1,9})\.(\d{1,9}))(\^\{\})?\s*$') { continue }
        $t = $found[$Matches[2]]
        if (-not $t) {
            $t = [pscustomobject]@{ Tag = $Matches[2]; Version = "$([int]$Matches[3]).$([int]$Matches[4]).$([int]$Matches[5])"; Commit = $Matches[1]; Peeled = $false }
            $found[$Matches[2]] = $t
        }
        if ($Matches[6]) { $t.Commit = $Matches[1]; $t.Peeled = $true }
        elseif (-not $t.Peeled) { $t.Commit = $Matches[1] }
    }
    @($found.Values | Sort-Object { [version]$_.Version } -Descending)
}

function ConvertFrom-RiceRemoteRefs {
    # `git ls-remote origin <Get-RiceRemoteRefNames>`'s lines: Master and Release (each branch's
    # commit; $null when GitHub has none) and Tags (Get-RiceReleaseTags).
    param([string[]]$Lines)
    $refs = [pscustomobject]@{ Master = $null; Release = $null; Tags = @(Get-RiceReleaseTags $Lines) }
    foreach ($l in $Lines) {
        if ("$l" -match '^([0-9a-f]{40,64})\s+refs/heads/(master|release)\s*$') { $refs.($Matches[2]) = $Matches[1] }
    }
    $refs
}

function Get-RiceReleaseName {
    # The release at $Commit as people know it -- its tag's version, '0.1.0' -- or $null.
    param([object[]]$Tags, [string]$Commit)
    (@($Tags | Where-Object { $_.Commit -eq $Commit }) | Select-Object -First 1).Version
}

function Get-RiceUpdateWay {
    # Which way this clone follows: 'bleeding-edge' when its .git\config says so, else 'official'.
    param([Parameter(Mandatory)][string]$Git)
    if ("$((Invoke-DoctorGit $Git @('config', '--local', '--get', '710srice.updates')).Lines)".Trim() -eq 'bleeding-edge') { 'bleeding-edge' } else { 'official' }
}

function Get-RiceRef {
    # A ref's commit, or $null when there's no such ref.
    param([Parameter(Mandatory)][string]$Git, [Parameter(Mandatory)][string]$Ref)
    $r = Invoke-DoctorGit $Git @('rev-parse', '--verify', '--quiet', "$Ref^{commit}")
    if ($r.Ok) { "$($r.Lines)".Trim() } else { $null }
}

function Test-RiceAncestor {
    # Is $Old in $New's history (the same commit included)? One this clone doesn't have isn't.
    param([Parameter(Mandatory)][string]$Git, [string]$Old, [string]$New)
    if (-not $Old -or -not $New) { return $false }
    (Invoke-DoctorGit $Git @('merge-base', '--is-ancestor', $Old, $New)).Ok
}

function Compare-RiceCommits {
    # $Head against a branch's commit: Ahead (commits only $Head has) and Behind (only the branch
    # has); $null when this clone doesn't have that commit (so it can only be newer) or git can't
    # count.
    param([Parameter(Mandatory)][string]$Git, [string]$Head, [string]$Other)
    if ($Head -eq $Other) { return [pscustomobject]@{ Ahead = 0; Behind = 0 } }
    if (-not (Invoke-DoctorGit $Git @('cat-file', '-e', "$Other^{commit}")).Ok) { return $null }
    $rl = Invoke-DoctorGit $Git @('rev-list', '--left-right', '--count', "$Head...$Other")
    $counts = "$($rl.Lines)".Trim() -split '\s+'
    if (-not $rl.Ok -or $counts.Count -ne 2) { return $null }
    [pscustomobject]@{ Ahead = [int]$counts[0]; Behind = [int]$counts[1] }
}

function Get-RiceBuild {
    # A commit as a version: Text -- '0.1.0' on a release, '0.1.0 + 4 commits (abc1234)' past one,
    # just 'abc1234' when no release is in its history --, Base (the release tag it counts from;
    # the newest one in its history), Count (commits past it) and Short (its short hash). $Tags:
    # Get-RiceReleaseTags', newest first.
    param([Parameter(Mandatory)][string]$Git, [Parameter(Mandatory)][string]$Commit, [object[]]$Tags = @())
    $short = "$((Invoke-DoctorGit $Git @('rev-parse', '--short', $Commit)).Lines)".Trim()
    if (-not $short) { $short = $Commit.Substring(0, [Math]::Min(7, $Commit.Length)) }
    $b = [pscustomobject]@{ Text = $short; Base = $null; Count = 0; Short = $short }
    foreach ($t in $Tags) {
        if ($t.Commit -ne $Commit -and -not (Test-RiceAncestor $Git $t.Commit $Commit)) { continue }
        $b.Base  = $t
        $b.Count = if ($t.Commit -eq $Commit) { 0 } else { [int]"$((Invoke-DoctorGit $Git @('rev-list', '--count', "$($t.Commit)..$Commit")).Lines)".Trim() }
        $b.Text  = if ($b.Count) { "$($t.Version) + $(Get-DoctorPlural $b.Count 'commit' 'commits') ($short)" } else { $t.Version }
        break
    }
    $b
}

function Get-RiceCloneState {
    <# Where this clone stands, for doctor's first line and update. Way ('official' /
       'bleeding-edge', saved) and WayText, as the first line says it: official; official from the
       next release (the hold); official from the first release (GitHub has none yet); bleeding
       edge. Tags: the release tags, newest first -- this clone's, else GitHub's (a clone whose
       update never fetched tags: every clone's first update to this runs the old code, which
       fetches master only). Build: HEAD as a version (Get-RiceBuild). Release / Master: GitHub's
       branches -- from $Remote (ConvertFrom-RiceRemoteRefs), else what the last update fetched;
       $null when unknown. NoRelease: GitHub answered and has no release branch. Held: official,
       not on the release branch, and newer than every release. #>
    param([Parameter(Mandatory)][string]$Git, [Parameter(Mandatory)][string]$Head, [string]$Branch = '', $Remote)
    $local = @(Get-RiceReleaseTags (Invoke-DoctorGit $Git @('show-ref', '-d', '--tags')).Lines)
    $tags  = @(if ($local.Count -or -not $Remote) { $local } else { $Remote.Tags })
    $s = [pscustomobject]@{
        Way = Get-RiceUpdateWay $Git; WayText = ''; Tags = $tags; Build = Get-RiceBuild $Git $Head $tags
        Release = $null; Master = $null; NoRelease = $false; Held = $false
    }
    if ($Remote) { $s.Release = $Remote.Release; $s.Master = $Remote.Master; $s.NoRelease = -not $Remote.Release }
    else { $s.Release = Get-RiceRef $Git 'refs/remotes/origin/release'; $s.Master = Get-RiceRef $Git 'refs/remotes/origin/master' }
    $s.Held = $s.Way -eq 'official' -and $s.Release -and $Branch -ne 'release' -and $s.Release -ne $Head -and (Test-RiceAncestor $Git $s.Release $Head)
    $s.WayText = if ($s.Way -eq 'bleeding-edge') { 'bleeding edge' }
                 elseif ($s.NoRelease) { 'official from the first release' }
                 elseif ($s.Held) { 'official from the next release' }
                 else { 'official' }
    $s
}

function Get-RiceHoldText {
    # The hold, as doctor and update both say it. $ReleaseName: the newest release's version.
    param([Parameter(Mandatory)]$State, [string]$ReleaseName)
    $b = $State.Build
    $build = if ($b.Base -and $b.Count) { "$($b.Base.Version) + $(Get-DoctorPlural $b.Count 'commit' 'commits'), $($b.Short)" } else { $b.Text }
    "Official from the next release: this build ($build) is newer than $(if ($ReleaseName) { $ReleaseName } else { 'the release' }), so it stays until a release includes it"
}

# --- Install runs from a clone ---------------------------------------------------------------------

function Test-RiceInstallClone {
    # Install needs a git clone -- `710sRice update` runs on git. From anywhere else (a Source code
    # download from the Releases page, a copy) this says so, names the one-liner (it clones), and
    # returns $false: the caller stops before anything changes -- the dispatcher before its UAC
    # prompt, install.ps1 at its first line.
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath (Join-Path $Path '.git')) { return $true }
    Write-Host "  [XX] This folder isn't a git clone, so it can't be installed: 710sRice update runs on git. Nothing was changed." -ForegroundColor Red
    Write-Host '       fix: the one-line install clones it -- from a normal PowerShell window:' -ForegroundColor Yellow
    Write-Host '            irm https://raw.githubusercontent.com/ItsAlways710/710.DesktopRice/release/boot.ps1 | iex' -ForegroundColor Yellow
    $false
}
