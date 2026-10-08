<#
.SYNOPSIS
  `710sRice doctor` -- a read-only health report of this clone and its install. Dot-sourced
  by 710sRice.ps1 after tools\lib\activation.ps1 and tools\lib\packages.ps1 (it uses both;
  the dispatcher has already loaded tools\lib\steps.ps1, and with it tools\lib\components.ps1:
  each component file's Check joins its group) -- never run directly.

.DESCRIPTION
  Read-only, and it has to stay that way: doctor changes nothing, starts or stops nothing and
  writes no files -- not even git's index (every git call is --no-optional-locks or a command
  that never writes; `git ls-remote` fetches no refs). It runs from any window, never elevates.

  Every check returns one or more results (New-DoctorResult): a stable Id, a Status, the
  line's Text, Detail lines, a Fix -- a command to type -- and, when that fix is an install
  step, its name in Step; Repair names what `710sRice doctor -repair` does that isn't an
  install step (reload, reload-bar, restart, start:<key>, tiling:<mode>); NeedsYou marks a
  problem no command can fix for you. Each check is written together with its fix, so a new
  check extends repair by itself: Get-RepairPlan turns the [XX] results into what repair
  runs, and doctor's closing lines preview the same plan.

    [XX]  broken -- counted: doctor's exit code is the number of them
    [!!]  worth knowing, with a fix; not counted (repair leaves these alone)
    [..]  a plain fact
    [OK]  fine -- every one is shown, so a report also says what WAS checked

  A check that throws becomes "[!!] <name> -- couldn't check (<why>)" and the run goes on.
  Nothing is printed until every check is in, so the report comes out in one piece. The slow
  outside calls -- `git ls-remote` (the network), `git status` and `winget pin list` -- start
  first, in the background, and the checks that need them run last (Late).

  claude/cli-plan.md, Stage 3, has the full check list, what each severity means, and why.
#>

# The palette library: the theme checks (tools\steps\theme.ps1) read the chosen profile and its
# targets the way the wallpaper pipeline does (one definition of "current theme").
. (Join-Path $PSScriptRoot 'palette.ps1')

# --- Results ------------------------------------------------------------------------------------
function New-DoctorResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('OK', 'XX', '!!', '..')][string]$Status,
        [Parameter(Mandatory)][string]$Text,
        [string[]]$Detail = @(),
        [string]$Fix = '',
        [string]$Step = '',
        [string]$Repair = '',
        [switch]$NeedsYou
    )
    [pscustomobject]@{
        Id = $Id; Status = $Status; Text = $Text; Detail = @($Detail | Where-Object { $_ })
        Fix = $Fix; Step = $Step; Repair = $Repair; NeedsYou = [bool]$NeedsYou
    }
}

function Write-DoctorResult {
    param($Result)
    $color = switch ($Result.Status) { 'OK' { 'Green' } 'XX' { 'Red' } '!!' { 'Yellow' } default { 'Cyan' } }
    # Control characters out: a parser's message can quote the byte it choked on (a NUL, say).
    $clean = { param($s) "$s" -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '' }
    Write-Host "  [$($Result.Status)] $(& $clean $Result.Text)" -ForegroundColor $color
    foreach ($d in $Result.Detail) { Write-Host "         $(& $clean $d)" -ForegroundColor DarkGray }
    if ($Result.Fix -and $Result.Status -in 'XX', '!!') { Write-Host "       fix: $($Result.Fix)" -ForegroundColor Yellow }
}

function Invoke-DoctorCheck {
    # One check's results; a check that throws is reported, never fatal. $Context carries the
    # background jobs (see Invoke-RiceDoctor) for the checks that collect one.
    # The check itself is handed over too: a component's check (Get-DoctorGroups) finds its
    # component on it.
    param($Check, $Context)
    try { @(& $Check.Run $Context $Check | Where-Object { $_ }) }
    catch { New-DoctorResult -Id $Check.Id -Status '!!' -Text "$($Check.Name) -- couldn't check ($($_.Exception.Message))" }
}

function Get-DoctorPlural { param([int]$Count, [string]$One, [string]$Many) if ($Count -eq 1) { "1 $One" } else { "$Count $Many" } }

# --- Background processes -------------------------------------------------------------------
# Started at the top of the run, collected at the end. No window (CreateNoWindow), nothing to
# type into (stdin closed): nothing can pop up or wait for an answer -- a credential prompt
# included (GIT_TERMINAL_PROMPT=0, GCM_INTERACTIVE=never). Output is read asynchronously so a
# chatty process can't stall on a full pipe; one still running at its deadline is killed with
# everything it started (git.exe hands https to git-remote-https.exe).

function Start-DoctorProcess {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @(), [hashtable]$Environment = @{})
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
    foreach ($k in $Environment.Keys) { $psi.Environment[$k] = "$($Environment[$k])" }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    [pscustomobject]@{
        Process = $p; Started = [DateTime]::UtcNow
        Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync()
    }
}

function Wait-DoctorProcess {
    # TimedOut, ExitCode, Out, Err. The timeout counts from the start, not from this call --
    # the checks in between already used some of it.
    param([Parameter(Mandatory)]$Job, [int]$TimeoutSeconds = 10)
    $left = [int][Math]::Max(0, ($Job.Started.AddSeconds($TimeoutSeconds) - [DateTime]::UtcNow).TotalMilliseconds)
    if (-not $Job.Process.WaitForExit($left)) {
        try { $Job.Process.Kill($true) } catch { }
        return [pscustomobject]@{ TimedOut = $true; ExitCode = $null; Out = ''; Err = '' }
    }
    $Job.Process.WaitForExit()   # the no-argument wait also lets the output readers finish
    [pscustomobject]@{ TimedOut = $false; ExitCode = $Job.Process.ExitCode; Out = "$($Job.Out.Result)"; Err = "$($Job.Err.Result)" }
}

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

# --- a. Repo and command: tools\steps\path.ps1 (Test-DoctorPath), tools\steps\envvars.ps1 ----------
# (Test-DoctorEnvVars, Test-DoctorWeather).

# --- b. Packages and pins -----------------------------------------------------------------------
# versions.md's rows against the machine: the local probes in tools\lib\packages.ps1 (the ones
# install's upgrade step goes by, so a check and its fix can't disagree) and ONE `winget pin
# list`, started in the background at the top of the run -- a `winget list` per package would
# be 20-30 s. Pinned rows get their version against the pin; the rest just need to be there.

function Get-DoctorShellToolIds { @('Starship.Starship', 'junegunn.fzf', 'ajeetdsouza.zoxide', 'eza-community.eza', 'sharkdp.bat') }

function Get-DoctorVersionRows {
    $rows = @(Get-VersionsTable -Path (Join-Path $Root 'versions.md'))
    if (-not $rows.Count) { throw "versions.md has no package table" }
    $rows
}

function Test-DoctorPinnedWingetRow { param($Row) (Test-WingetRow $Row) -and (Test-PinnedRow $Row) }

function Get-DoctorPackageName {
    # "PowerShell 7" at 7.6.6 reads "PowerShell 7.6.6", not "PowerShell 7 7.6.6".
    param([string]$Component, [string]$Version)
    if (-not $Version) { return $Component }
    if ($Component -match '^(.*\S)\s+(\d+)$' -and $Version.StartsWith("$($Matches[2]).")) { return "$($Matches[1]) $Version" }
    "$Component $Version"
}

function Get-DoctorPackageResult {
    # One versions.md row: installed at all, and -- when it's pinned -- at its pin.
    param($Row)
    $id   = "pkg:$($Row.InstallId)"
    $name = $Row.Component
    $v    = Get-PackageVersion $Row
    if (-not $v.Probe)     { return New-DoctorResult -Id $id -Status '!!' -Text "$name -- doctor doesn't know how to check it" }
    if (-not $v.Installed) { return New-DoctorResult -Id $id -Status 'XX' -Text "$name isn't installed" -Fix '710sRice install -Only packages' -Step 'packages' }
    $shown = Get-DoctorPackageName $name $v.Version
    if (-not (Test-PinnedRow $Row)) { return New-DoctorResult -Id $id -Status 'OK' -Text $shown }
    $pin = $Row.Version
    switch (Compare-PinVersion $v.Version $pin) {
        0  { return New-DoctorResult -Id $id -Status 'OK' -Text "$shown -- at its pin" }
        -1 { return New-DoctorResult -Id $id -Status 'XX' -Text "$shown -- older than its pin $pin" -Fix '710sRice install -Only upgrade' -Step 'upgrade' }
        1  {
            # The user's call, not a problem: a hand upgrade being tried out before the pin moves.
            return New-DoctorResult -Id $id -Status '!!' -Text "$shown -- newer than its pin $pin" `
                -Detail "left alone -- your call: bump versions.md once it's tested, or go back to $pin by hand"
        }
    }
    $what = if ($v.Version) { "its version '$($v.Version)' can't be compared with its pin $pin" } else { "installed, but its version couldn't be read" }
    New-DoctorResult -Id $id -Status '!!' -Text "$name -- $what"
}

function Test-DoctorPinnedPackages {
    # The pinned winget rows, in versions.md's order, one line each.
    foreach ($row in @(Get-DoctorVersionRows | Where-Object { Test-DoctorPinnedWingetRow $_ })) { Get-DoctorPackageResult $row }
}

function Start-DoctorWingetJob {
    # `winget pin list --source winget`, in the background (3.2 s on the Dell). Reason says why
    # there's no job. The source named, like every winget call here (Get-WingetSourceArgs): with
    # none, winget also opens the Store source, and a broken one fails the call (Group 1 W1) --
    # every pinned row is a winget row.
    $winget = (Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $winget) { return [pscustomobject]@{ Reason = "winget isn't installed"; Job = $null } }
    [pscustomobject]@{ Reason = $null; Job = (Start-DoctorProcess -Exe $winget -Arguments @('pin', 'list', '--source', 'winget')) }
}

function Test-DoctorPins {
    # Every installed pinned package still winget-pinned -- without the pin, a general `winget
    # upgrade --all` moves it off the version this repo was tested with. One line for all of
    # them. Each Id is matched as a whole word in `winget pin list`'s output (its Name column
    # has spaces, so it isn't split into columns). A package that isn't installed is already
    # its own [XX] above, and the packages step pins what it installs.
    param($Context)
    $rows = @(Get-DoctorVersionRows | Where-Object { (Test-DoctorPinnedWingetRow $_) -and (Get-PackageVersion $_).Installed })
    if (-not $rows.Count) { return }
    $w = $Context.Winget
    if ($w.Reason) { return New-DoctorResult -Id 'pins' -Status '!!' -Text "winget pins -- couldn't check ($($w.Reason))" }
    $r = Wait-DoctorProcess -Job $w.Job -TimeoutSeconds 20
    if ($r.TimedOut)       { return New-DoctorResult -Id 'pins' -Status '!!' -Text "winget pins -- couldn't check (winget didn't answer in 20 s)" }
    if ($r.ExitCode -ne 0) { return New-DoctorResult -Id 'pins' -Status '!!' -Text "winget pins -- couldn't check (winget exited $(Format-WingetCode $r.ExitCode))" }
    $missing = @($rows | Where-Object { $r.Out -notmatch "(?<![\w.-])$([regex]::Escape($_.InstallId))(?![\w.-])" } | ForEach-Object Component)
    if ($missing.Count) {
        return New-DoctorResult -Id 'pins' -Status 'XX' -Text "winget pins missing: $($missing -join ', ')" -Fix '710sRice install -Only packages' -Step 'packages'
    }
    if ($rows.Count -eq 1) { return New-DoctorResult -Id 'pins' -Status 'OK' -Text "winget pin in place ($($rows[0].Component))" }
    New-DoctorResult -Id 'pins' -Status 'OK' -Text "winget pins: all $($rows.Count) in place"
}

function Get-DoctorShellToolsResult {
    # The five shell tools on one line: what's there (starship with its version), and what isn't.
    param([object[]]$Rows)
    $have = @(); $missing = @()
    foreach ($row in $Rows) {
        $v = Get-PackageVersion $row
        if (-not $v.Probe) { Get-DoctorPackageResult $row; continue }   # its own "doesn't know" line
        if ($v.Installed) { $have += Get-DoctorPackageName $row.Component $v.Version } else { $missing += $row.Component }
    }
    if (-not $missing.Count) { return New-DoctorResult -Id 'pkg:shell-tools' -Status 'OK' -Text "Shell tools: $($have -join ', ')" }
    $verb = if ($missing.Count -eq 1) { "isn't" } else { "aren't" }
    $text = if ($have.Count) { "Shell tools: $($have -join ', ') -- $($missing -join ', ') $verb installed" }
            else { "Shell tools: $($missing -join ', ') $verb installed" }
    New-DoctorResult -Id 'pkg:shell-tools' -Status 'XX' -Text $text -Fix '710sRice install -Only packages' -Step 'packages'
}

function Test-DoctorOtherPackages {
    # Everything that isn't a pinned winget row or wallust, in versions.md's order -- the shell
    # tools folded into one line where the first of them sits.
    $rows  = @(Get-DoctorVersionRows | Where-Object { -not (Test-DoctorPinnedWingetRow $_) -and $_.InstallId -notlike '*wallust*' })
    $tools = @(Get-DoctorShellToolIds)
    $toolsShown = $false
    foreach ($row in $rows) {
        if ($tools -contains $row.InstallId) {
            if (-not $toolsShown) {
                $toolsShown = $true
                Get-DoctorShellToolsResult @($rows | Where-Object { $tools -contains $_.InstallId })
            }
            continue
        }
        Get-DoctorPackageResult $row
    }
}

# --- c. Is the stack running: tools\lib\stack.ps1 (Test-DoctorStack, Test-DoctorPaused) ----------
# Where 710sRice keeps its logs and state: the Stack checks and the theme stamp read files there.
function Get-DoctorLogDir { Join-Path $env:LOCALAPPDATA '710.DesktopRice' }

# --- d. Tasks and tiling mode: tools\steps\tasks.ps1 (Test-DoctorTasks), tools\lib\tiling.ps1 -------
# (Test-DoctorTilingMode). Get-DoctorComponentName is shared: the task lines, the Stack group and
# the repair plan name things with it.

function Get-DoctorComponentName {
    # A stack component's name as the report says it; a component file's own Label for the rest.
    param([string]$Key)
    switch ($Key) {
        'komorebi' { 'komorebi' } 'yasb' { 'YASB' } 'sharex' { 'ShareX' } 'ahk' { '710.ahk' }
        default {
            $c = try { Get-RiceComponent -Id $Key } catch { $null }
            if ($c) { $c.Label } else { $Key }
        }
    }
}

# --- e. Generated configs ------------------------------------------------------------------------
# The files install and the stack generate, checked by their steps' modules: komorebi.json and the
# ASC file, tools\steps\compile.ps1; display-index.local.json, tools\steps\monitors.ps1; wallust.toml,
# tools\steps\wallust.ps1; the theme, tools\steps\theme.ps1; the lock screen, tools\lib\lockscreen.ps1.
# Get-DoctorKomorebic is shared: the display-index check and the Stack group use it.

function Get-DoctorKomorebic {
    # komorebic.exe on PATH, else where winget installs it; $null when neither.
    $kc = (Get-Command komorebic.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $kc -and $env:ProgramFiles) {
        $p = [IO.Path]::Combine($env:ProgramFiles, 'komorebi', 'bin', 'komorebic.exe')
        if (Test-Path -LiteralPath $p) { $kc = $p }
    }
    $kc
}

# --- f. Integrations -----------------------------------------------------------------------------
# The apps the stack leans on, set up the way install sets them up: Flow and Everything (file
# search), the $PROFILE hook, and -- on a full-time machine -- the Windows settings -Activate
# applies. (Windows Terminal and Defender's exclusions: their components. The $PROFILE hook:
# tools\steps\profile.ps1. Flow's theme: tools\steps\theme.ps1.)

# --- g. Conflicts and leftovers --------------------------------------------------------------------

function Test-DoctorConflicts {
    # Another window manager or hotkey owner running alongside: they fight over the same
    # windows / keys. (winarchy's doctor checked whkd and seelen-ui by these names.)
    $others = [ordered]@{ whkd = @('whkd', 'hotkey managers', 'keys'); 'seelen-ui' = @('Seelen UI', 'window managers', 'windows'); glazewm = @('GlazeWM', 'window managers', 'windows') }
    $running = @($others.Keys | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
    foreach ($k in $running) {
        $n, $what, $over = $others[$k]
        New-DoctorResult -Id "conflict:$k" -Status '!!' -Text "$n is running -- two $what fight over the same $over" -Fix 'stop it and remove its autostart'
    }
    if (-not $running.Count) { New-DoctorResult -Id 'conflicts' -Status 'OK' -Text 'No other window or hotkey manager running (whkd, Seelen UI, GlazeWM)' }
}

function Test-DoctorKomorebiScripts {
    # komorebi runs a komorebi.ps1 / komorebi.ahk it finds in its config folder at every start
    # (and on reload-configuration) -- as admin in elevated tiling mode. Nothing of ours puts
    # one there (plan doc item 37's accepted risk), so one showing up is worth a look.
    $found = @('komorebi.ps1', 'komorebi.ahk' | Where-Object { Test-Path -LiteralPath (Join-Path $Root "config\komorebi\$_") })
    foreach ($f in $found) {
        New-DoctorResult -Id "leftover:$f" -Status '!!' -Text "config\komorebi\$f exists -- komorebi runs it at every start (as admin in elevated tiling mode)" -Fix 'delete it unless you put it there on purpose'
    }
    if (-not $found.Count) { New-DoctorResult -Id 'komorebi-scripts' -Status 'OK' -Text 'No komorebi.ps1 / komorebi.ahk in config\komorebi' }
}

# --- The checks, in report order ------------------------------------------------------------
# Each check: Id, Name (for "couldn't check"), Run (gets the run's context), and Late = waits
# on a background job -- run after every other check, so the jobs have the longest head start.
# The report keeps this order whatever order they ran in. The first group has no title: it
# prints right under the header.
function Get-DoctorGroups {
    $groups = @(
        [pscustomobject]@{ Title = $null; Checks = @(
            @{ Id = 'update';        Name = 'Update check';  Late = $true; Run = { param($c) Get-DoctorUpdateResult $c.Git $c.Head } }
            @{ Id = 'local-changes'; Name = 'Local changes'; Late = $true; Run = { param($c) Get-DoctorLocalChangesResult $c.Git } }
        ) }
        [pscustomobject]@{ Title = 'Repo and command'; Checks = @(
            @{ Id = 'path';    Name = '710sRice command'; Run = { Test-DoctorPath } }
            @{ Id = 'envvars'; Name = 'Config env vars';  Run = { Test-DoctorEnvVars } }
            @{ Id = 'weather'; Name = 'Weather widget';   Run = { Test-DoctorWeather } }
        ) }
        [pscustomobject]@{ Title = 'Packages and pins'; Checks = @(
            @{ Id = 'pkg:pinned'; Name = 'Pinned packages'; Run = { Test-DoctorPinnedPackages } }
            @{ Id = 'pins';       Name = 'winget pins';     Late = $true; Run = { param($c) Test-DoctorPins $c } }
            @{ Id = 'wallust';    Name = 'wallust';         Run = { Test-DoctorWallust } }
            @{ Id = 'pkg:other';  Name = 'Packages';        Run = { Test-DoctorOtherPackages } }
        ) }
        [pscustomobject]@{ Title = 'Stack'; Checks = @(
            @{ Id = 'stack';  Name = 'Stack';                 Run = { Test-DoctorStack } }
            @{ Id = 'paused'; Name = "komorebi's pause state"; Run = { Test-DoctorPaused } }
        ) }
        [pscustomobject]@{ Title = 'Tasks and tiling mode'; Checks = @(
            @{ Id = 'tasks';  Name = 'Tasks';       Run = { Test-DoctorTasks } }
            @{ Id = 'tiling'; Name = 'Tiling mode'; Run = { Test-DoctorTilingMode } }
        ) }
        [pscustomobject]@{ Title = 'Generated configs'; Checks = @(
            @{ Id = 'komorebi-json'; Name = 'komorebi.json';            Run = { Test-DoctorKomorebiJson } }
            @{ Id = 'asc';           Name = 'ASC rules file';           Run = { Test-DoctorAscPin } }
            @{ Id = 'display-index'; Name = 'display-index.local.json'; Run = { Test-DoctorDisplayIndex } }
            @{ Id = 'wallust-toml';  Name = 'wallust.toml';             Run = { Test-DoctorWallustToml } }
            @{ Id = 'palette-profile'; Name = 'Palette profile';        Run = { Test-DoctorPaletteProfile } }
            @{ Id = 'theme-files';   Name = 'Theme files';              Run = { Test-DoctorThemeFiles } }
            @{ Id = 'theme-inputs';  Name = 'Theme stamp';              Run = { Test-DoctorThemeInputs } }
            @{ Id = 'palette-last';  Name = 'Last theme run';           Run = { Test-DoctorPaletteLastRun } }
            @{ Id = 'lock-screen';   Name = 'Lock screen';              Run = { Test-DoctorLockScreen } }
        ) }
        [pscustomobject]@{ Title = 'Integrations'; Checks = @(
            @{ Id = 'flow-theme'; Name = 'Flow Launcher theme';  Run = { Test-DoctorFlowTheme } }
            @{ Id = 'profile';    Name = 'Shell profile hook';   Run = { Test-DoctorProfileHook } }
            @{ Id = 'windows';    Name = 'Windows settings';     Run = { Test-DoctorWindowsSettings } }
        ) }
        [pscustomobject]@{ Title = 'Conflicts and leftovers'; Checks = @(
            @{ Id = 'conflicts';        Name = 'Other window / hotkey managers'; Run = { Test-DoctorConflicts } }
            @{ Id = 'komorebi-scripts'; Name = 'komorebi.ps1 / komorebi.ahk';    Run = { Test-DoctorKomorebiScripts } }
        ) }
    )
    # Each component's own checks (tools\components\<id>.ps1, Group 1 #12), at the end of its Group,
    # in install's order. Its [XX] carry Step = its Id, so repair runs its install step. A broken
    # component file is its own [XX] -- the rest of the report still runs (install and uninstall
    # refuse to start until it's fixed).
    try { $comps = @(Get-RiceComponents); $order = @(Get-InstallStepOrder) }
    catch {
        $broken = $_.Exception.Message
        $repo = $groups | Where-Object { $_.Title -eq 'Repo and command' } | Select-Object -First 1
        $repo.Checks = @($repo.Checks) + @(@{ Id = 'components'; Name = 'Component files'; Broken = $broken
            Run = { param($ctx, $check) New-DoctorResult -Id 'components' -Status 'XX' -Text "A component file is broken: $($check.Broken) -- install and uninstall won't start until it's fixed" -Fix 'put the file back as it was (git shows what changed), or fix what the line says' -NeedsYou } })
        $comps = @(); $order = @()
    }
    foreach ($id in $order) {
        $c = $comps | Where-Object { $_.Id -eq $id -and $_.Check } | Select-Object -First 1
        if (-not $c) { continue }
        $g = $groups | Where-Object { $_.Title -eq $c.Group } | Select-Object -First 1
        $g.Checks = @($g.Checks) + @(@{ Id = "component:$($c.Id)"; Name = $c.Label; Component = $c
                                          Run = { param($ctx, $check) Invoke-RiceComponentPart -Component $check.Component -Part Check -Ctx (Get-DoctorComponentContext $ctx) } })
    }
    $groups
}

function Get-DoctorComponentContext {
    # A component check's $Ctx (New-RiceComponentContext), made once per report.
    param($DoctorContext)
    if (-not $DoctorContext.Component) { $DoctorContext.Component = New-RiceComponentContext }
    $DoctorContext.Component
}

# --- The repair plan -----------------------------------------------------------------------
# What `710sRice doctor -repair` does about a report's [XX] lines -- asked by doctor's closing
# lines (the preview) and by repair itself, so the two can't disagree. [!!] and [..] are
# never touched: they're either the user's call or plain facts. (claude/cli-plan.md, Stage 4,
# Topics 1-2.)

function Get-RepairPlan {
    <# The plan for a set of results. Steps (install's, in install's own order -- one
       `install.ps1 -Only` run), Tiling, Restart / Start (component keys) / ReloadBar, Reload,
       and Lines -- the plan as text, in the order repair runs it. Problems = every [XX];
       Fixable = the ones the plan covers; NeedsYou / Unknown = the ones it leaves (Unknown: an
       [XX] with no step and no repair action -- none today, a guard for future checks -- or a
       step repair never runs). #>
    param([object[]]$Results)
    $problems = @($Results | Where-Object { $_.Status -eq 'XX' })
    $plan = [pscustomobject]@{
        Steps = @(); Tiling = $null; Restart = $false; Start = @(); ReloadBar = $false; Reload = $false; Lines = @()
        Problems = $problems; Fixable = @(); NeedsYou = @(); Unknown = @()
    }
    $steps  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $starts = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $problems) {
        if ($r.NeedsYou) { $plan.NeedsYou += $r; continue }
        $covered = $false
        # theme is the default-wallpaper reset: never repair's, whatever a check says. (weather,
        # which needed someone at the keyboard, was a step until Group 1 #1.)
        if ($r.Step -and $r.Step -ne 'theme') { [void]$steps.Add($r.Step); $covered = $true }
        switch -Regex ($r.Repair) {
            '^reload$'                 { $plan.Reload = $true; $covered = $true }
            '^reload-bar$'             { $plan.ReloadBar = $true; $covered = $true }
            '^restart$'                { $plan.Restart = $true; $covered = $true }
            '^start:([\w,]+)$'         {   # one component, or several (start:komorebi,yasb,...)
                foreach ($k in $Matches[1] -split ',') { if ($k -and -not $starts.Contains($k)) { $starts.Add($k) } }
                $covered = $true
            }
            '^tiling:(elevated|normal)$' { $plan.Tiling = $Matches[1]; $covered = $true }
        }
        if ($covered) { $plan.Fixable += $r } else { $plan.Unknown += $r }
    }
    # A restart stops and starts everything: it covers the starts and the bar, and a komorebi
    # that restarts reads komorebi.json from disk -- so the compile step instead of a reload.
    if ($plan.Restart) {
        $starts.Clear(); $plan.ReloadBar = $false
        if ($plan.Reload) { $plan.Reload = $false; [void]$steps.Add('compile') }
    }
    # The tasks step registers komorebi's task at the saved mode anyway.
    if ($plan.Tiling -and $steps.Contains('tasks')) { $plan.Tiling = $null }
    # install's order, components included (tools\lib\steps.ps1 -- the dispatcher loads it;
    # loaded here if not).
    if (-not (Get-Command Get-InstallStepOrder -ErrorAction SilentlyContinue)) { . (Join-Path $Root 'tools\lib\steps.ps1') }
    $installOrder = try { @(Get-InstallStepOrder) } catch { @($InstallFixedStepOrder) }
    $plan.Steps = @($installOrder | Where-Object { $steps.Contains($_) })
    # The stack's own order (komorebi first: the rest look for it; 710.ahk next: it starts the bar,
    # Flow and ShareX), then anything else in install's order, whatever order they came in.
    $first = @('komorebi', 'ahk', 'yasb', 'flow', 'sharex')
    $order = $first + @($installOrder | Where-Object { $_ -notin $first })
    $plan.Start = @($starts | Sort-Object { $i = $order.IndexOf($_); if ($i -lt 0) { 99 } else { $i } })
    $byAhk  = @(Get-AhkStartedApps | ForEach-Object Key)
    $names  = { param($keys) @($keys | ForEach-Object { Get-DoctorComponentName $_ }) -join ', ' }
    $viaTask = @($plan.Start | Where-Object { $byAhk -notcontains $_ })
    $viaAhk  = @($plan.Start | Where-Object { $byAhk -contains $_ })
    $plan.Lines = @(
        if ($plan.Steps.Count) { "710sRice install -Only $($plan.Steps -join ',')" }
        if ($plan.Tiling)      { "710sRice tiling $($plan.Tiling)" }
        if ($plan.Restart)     { '710sRice restart' }
        if ($plan.Start.Count) {
            "start " + (@(
                if ($viaTask.Count) { "$(& $names $viaTask) ($(if ($viaTask.Count -eq 1) { 'its task' } else { 'their tasks' }))" }
                if ($viaAhk.Count)  { "$(& $names $viaAhk) (710.ahk starts $(if ($viaAhk.Count -eq 1) { 'it' } else { 'them' }))" }
            ) -join '; ')
        }
        if ($plan.ReloadBar)   { '710sRice reload bar' }
        if ($plan.Reload)      { '710sRice reload' }
    )
    $plan
}

# --- The run ----------------------------------------------------------------------------------
function Get-DoctorReport {
    <# Runs every check; prints nothing. Header (Title, Head), Groups, and Results -- one list
       per group, in report order -- plus All, every result in that order. #>
    # The slow outside calls start first, in the background; the Late checks collect them.
    $ctx = [pscustomobject]@{ Git = Start-DoctorGitJobs; Winget = Start-DoctorWingetJob; Head = $null; Component = $null }
    $header   = Get-DoctorHeader $ctx.Git
    $ctx.Head = $header.Head
    $groups   = @(Get-DoctorGroups)
    $results  = @{}
    foreach ($late in $false, $true) {
        for ($g = 0; $g -lt $groups.Count; $g++) {
            for ($i = 0; $i -lt $groups[$g].Checks.Count; $i++) {
                $check = $groups[$g].Checks[$i]
                if ([bool]$check.Late -ne $late) { continue }
                $results["$g/$i"] = @(Invoke-DoctorCheck $check $ctx)
            }
        }
    }
    $byGroup = @(for ($g = 0; $g -lt $groups.Count; $g++) {
        , @(for ($i = 0; $i -lt $groups[$g].Checks.Count; $i++) { $results["$g/$i"] })
    })
    [pscustomobject]@{ Header = $header; Groups = $groups; Results = $byGroup; All = @($byGroup | ForEach-Object { $_ }) }
}

function Write-DoctorReport {
    <# Prints a report and its closing lines -- with, when there are problems repair can fix,
       what `710sRice doctor -repair` would run (Get-RepairPlan: the same list repair prints
       before it acts). Returns the number of [XX]. -Title replaces the header's; -NoClosing
       stops after the last group (repair prints its own closing lines). #>
    param([Parameter(Mandatory)]$Report, [string]$Title, [switch]$NoClosing)
    Write-Host ''
    Write-Host "== $(if ($Title) { $Title } else { $Report.Header.Title }) ==" -ForegroundColor Cyan
    for ($g = 0; $g -lt $Report.Groups.Count; $g++) {
        if ($Report.Groups[$g].Title) { Write-Host "`n-- $($Report.Groups[$g].Title) --" -ForegroundColor Cyan }
        foreach ($r in $Report.Results[$g]) { Write-DoctorResult $r }
    }

    $problems = @($Report.All | Where-Object { $_.Status -eq 'XX' }).Count
    if ($NoClosing) { return $problems }
    $warnings = @($Report.All | Where-Object { $_.Status -eq '!!' }).Count
    $look     = "$(Get-DoctorPlural $warnings 'thing' 'things') worth a look (!!)."
    Write-Host ''
    if ($problems) {
        $line = if ($problems -eq 1) { '1 problem -- its fix is above.' } else { "$problems problems -- each has its fix above." }
        if ($warnings) { $line += " $look" }
        Write-Host "  $line" -ForegroundColor Red
        $plan = Get-RepairPlan $Report.All
        if ($plan.Lines.Count) {
            $left = $plan.NeedsYou.Count + $plan.Unknown.Count
            $others = if ($left -eq 1) { 'the other one' } else { "the other $left" }
            $what = if (-not $left) { if ($problems -eq 1) { 'it' } else { 'them' } }
                    elseif (-not $plan.Unknown.Count) { "$($plan.Fixable.Count) of them ($(if ($left -eq 1) { 'the other needs you' } else { "the other $left need you" }))" }
                    else { "$($plan.Fixable.Count) of them (it can't fix $others)" }
            Write-Host "  710sRice doctor -repair would fix $($what):" -ForegroundColor Yellow
            foreach ($l in $plan.Lines) { Write-Host "    $l" -ForegroundColor Yellow }
        }
    } elseif ($warnings) {
        Write-Host "  No problems. $look" -ForegroundColor Yellow
    } else {
        Write-Host '  All good.' -ForegroundColor Green
    }
    Write-Host ''
    $problems
}

function Invoke-RiceDoctor {
    <# `710sRice doctor`: runs every check and prints the report. Returns the number of [XX]
       -- 710sRice's exit code. Everything else goes to the screen with Write-Host. #>
    Write-Host ''
    Write-Host '  Checking...' -ForegroundColor DarkGray
    Write-DoctorReport (Get-DoctorReport)
}
