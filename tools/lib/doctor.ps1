<#
.SYNOPSIS
  `710sRice doctor` -- a read-only health report of this clone and its install. Dot-sourced
  by 710sRice.ps1 after tools\lib\activation.ps1 and tools\lib\packages.ps1 (it uses both;
  the dispatcher has already loaded tools\lib\steps.ps1) -- never run directly.

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

# The palette library: the theme checks read the chosen profile and its targets the way the
# wallpaper pipeline does (one definition of "current theme").
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
    param($Check, $Context)
    try { @(& $Check.Run $Context | Where-Object { $_ }) }
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

# --- a. Repo and command ------------------------------------------------------------------------
# Registry reads sit behind these small functions (the Linux sandbox has no HKCU:, and they
# are what a test stubs). Get-UserPathRaw and Test-SamePathEntry come from activation.ps1 --
# install's own PATH helpers, so "on your PATH" means exactly what install means by it.

function Get-DoctorMachinePathRaw {
    (Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
}

function Get-DoctorUserEnv {
    # A variable as registered for the user (what a new window gets) -- not doctor's own
    # process, which only knows what was set when its window opened.
    param([Parameter(Mandatory)][string]$Name)
    [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Get-DoctorScriptCommand {
    # This clone's 710sRice.ps1 as a command that works typed into any PS7 window -- for when
    # the bare `710sRice` isn't on PATH, or runs some other copy. A plain path needs no
    # quoting; anything else (a space, a quote, a $...) gets the call operator. A clone under
    # the user's own folders (the README's `git clone` from a fresh window lands in the home
    # folder) is written with $env:USERPROFILE & co., never the user name -- still typeable.
    param([Parameter(Mandatory)][string]$CommandLine)
    $ps1  = Join-Path $Root '710sRice.ps1'
    $safe = ConvertTo-SafePath $ps1
    if ($safe -match '^%(\w+)%(.*)$') {
        $rest = $Matches[2] -replace '([`$"])', '`$1'   # escaped for a double-quoted string
        return "& `"`$env:$($Matches[1])$rest`" $CommandLine"
    }
    if ($ps1 -match '^[A-Za-z]:\\[\w.\\-]+$') { return "$ps1 $CommandLine" }
    "& '$($ps1 -replace "'", "''")' $CommandLine"
}

function Test-DoctorPath {
    # This clone's bin\ (bin\710sRice.cmd, the `710sRice` command) on the user PATH -- what any
    # new window gets. Missing: say whether a new window would find some other copy instead.
    $bin = Join-Path $Root 'bin'
    if (@("$(Get-UserPathRaw)" -split ';' | Where-Object { Test-SamePathEntry $_ $bin }).Count) {
        return New-DoctorResult -Id 'path' -Status 'OK' -Text "710sRice command: $(ConvertTo-SafePath $bin) is on your PATH"
    }
    # A new window's PATH is the machine's entries, then the user's. [IO.Path]::Combine, not
    # Join-Path: Join-Path throws on a drive that isn't there (an unplugged USB or network
    # drive still on PATH), and one stale entry mustn't sink the check.
    $other = $null
    foreach ($entry in @("$(Get-DoctorMachinePathRaw)" -split ';') + @("$(Get-UserPathRaw)" -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
        try { $found = Test-Path -LiteralPath ([IO.Path]::Combine($dir, '710sRice.cmd')) } catch { $found = $false }
        if ($found) { $other = $dir; break }
    }
    New-DoctorResult -Id 'path' -Status 'XX' -Text "710sRice command: $(ConvertTo-SafePath $bin) isn't on your PATH" `
        -Detail $(if ($other) { "710sRice on your PATH runs another copy: $(ConvertTo-SafePath $other)" }) `
        -Fix (Get-DoctorScriptCommand 'install -Only path') -Step 'path'
}

function Test-DoctorEnvVars {
    # The three config variables install registers, each pointing into this clone. One line
    # when all three are right; otherwise one detail line per wrong one.
    $want = [ordered]@{
        KOMOREBI_CONFIG_HOME = Join-Path $Root 'config\komorebi'
        YASB_CONFIG_HOME     = Join-Path $Root 'config\yasb'
        DESKTOPRICE_HOME     = $Root
    }
    $wrong = foreach ($name in $want.Keys) {
        $v = Get-DoctorUserEnv $name
        if (-not $v) { "$name isn't set" }
        elseif (-not (Test-SamePathEntry $v $want[$name])) { "$name = $(ConvertTo-SafePath $v)" }
    }
    if (-not @($wrong).Count) {
        return New-DoctorResult -Id 'envvars' -Status 'OK' -Text "Config env vars point at this clone ($($want.Keys -join ', '))"
    }
    New-DoctorResult -Id 'envvars' -Status 'XX' -Text "Config env vars don't all point at this clone" `
        -Detail @($wrong) -Fix '710sRice install -Only envvars' -Step 'envvars'
}

function Test-DoctorWeather {
    # Set or not set -- NEVER the values: the key is a secret, the location is where someone
    # lives, and doctor output gets pasted into issues. Optional, so never a problem.
    $key = [bool](Get-DoctorUserEnv 'YASB_WEATHER_API_KEY')
    $loc = [bool](Get-DoctorUserEnv 'YASB_WEATHER_LOCATION')
    $text = "Weather widget: API key $(if ($key) { 'set' } else { 'not set' }), location $(if ($loc) { 'set' } else { 'not set' })"
    if ($key -and $loc) { return New-DoctorResult -Id 'weather' -Status 'OK' -Text $text }
    New-DoctorResult -Id 'weather' -Status '..' -Text "$text -- 710sRice install -Only weather asks for $(if ($key -or $loc) { 'it' } else { 'them' })" `
        -Step 'weather' -NeedsYou
}

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
    # `winget pin list`, in the background (3.2 s on the Dell). Reason says why there's no job.
    $winget = (Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $winget) { return [pscustomobject]@{ Reason = "winget isn't installed"; Job = $null } }
    [pscustomobject]@{ Reason = $null; Job = (Start-DoctorProcess -Exe $winget -Arguments @('pin', 'list')) }
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

function Test-DoctorWallust {
    # wallust at versions.md's pin, by the very test install's wallust step makes (its
    # --version output contains the pin) -- so this check and its fix can't disagree.
    $row = Get-DoctorVersionRows | Where-Object { $_.InstallId -like '*wallust*' } | Select-Object -First 1
    if (-not $row) { return }   # no wallust row: nothing to hold it to
    $pin = $row.Version
    $exe = Join-Path $Root 'tools\bin\wallust\wallust.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return New-DoctorResult -Id 'wallust' -Status 'XX' -Text "wallust isn't installed" -Fix '710sRice install -Only wallust' -Step 'wallust'
    }
    $out = "$(& $exe --version 2>$null)"
    $ver = if ($out -match '^\s*wallust\s+(\S+)') { $Matches[1] } else { '' }
    if ($out -match [regex]::Escape($pin)) {
        return New-DoctorResult -Id 'wallust' -Status 'OK' -Text "wallust $(if ($ver) { $ver } else { $pin }) -- at its pin"
    }
    $text = if ($ver) { "wallust $ver -- its pin is $pin" } else { "wallust -- its version couldn't be read (its pin is $pin)" }
    New-DoctorResult -Id 'wallust' -Status 'XX' -Text $text -Fix '710sRice install -Only wallust' -Step 'wallust'
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

# --- c. Is the stack running --------------------------------------------------------------------
# The four components the stack starts (Flow isn't one: SUPER+Space cold-starts it). One line
# each, carrying the worst thing found. Nothing running at all is a plain fact -- an on-demand
# machine between sessions, or a full-time one after `710sRice stop` -- but some running and
# some not means something died. Only komorebi may run as admin (the tiling mode's choice);
# anything else elevated makes everything it launches elevated too. Log paths are given by
# name only: the full path carries the Windows user name, and a report may get pasted into an
# issue.

function Get-DoctorLogDir { Join-Path $env:LOCALAPPDATA '710.DesktopRice' }

function Get-DoctorYasbWatchdogNote {
    # Why YASB is down, when 710.ahk's watchdog says so and nothing has happened since: its
    # give-up line (or its "watchdog off" line), with no relaunch -- a '--- startup' line from
    # Start-Yasb.ps1 -- after it. The watchdog writes into yasb-autostart.log; the tail is plenty.
    $log = Join-Path (Get-DoctorLogDir) 'yasb-autostart.log'
    if (-not (Test-Path -LiteralPath $log)) { return $null }
    $note = $null
    foreach ($line in @(Get-Content -LiteralPath $log -Tail 300 -ErrorAction SilentlyContinue)) {
        if ($line -match '  --- startup') { $note = $null; continue }
        if ($line -notmatch '^(\d{4}-\d\d-\d\d) (\d\d:\d\d):\d\d  watchdog: (.*)$') { continue }
        $when = if ($Matches[1] -eq (Get-Date -Format 'yyyy-MM-dd')) { $Matches[2] } else { "$($Matches[1]) $($Matches[2])" }
        $what = $Matches[3]
        if ($what -match 'stopped relaunching') {
            $note = "the watchdog gave up at $when after 3 relaunches -- the crash is in config\yasb\yasb.log"
        } elseif ($what -match 'Watchdog off') {
            $note = "the watchdog couldn't relaunch it at $when (its task didn't run) -- watchdog off"
        }
    }
    $note
}

function Get-DoctorStaleText {
    # A running YASB / 710.ahk that loaded older files than the repo has now: Text (+ Detail), or
    # $null. YASB: config.yaml against the fingerprint Start-Yasb.ps1 recorded when the bar started
    # -- reload-stack.ps1's own test for "restart the bar", byte for byte, so the two can't
    # disagree (no fingerprint = the same answer). 710.ahk: 710.ahk or user.ahk written after its
    # process started (AHK's Reload() starts a new process); a start time Windows won't hand
    # over = not checked, never guessed.
    param([string]$Key, $Process)
    if ($Key -eq 'yasb') {
        $fp  = Join-Path (Get-DoctorLogDir) 'yasb-config.sha256'
        $cfg = Join-Path $Root 'config\yasb\config.yaml'
        if (-not (Test-Path -LiteralPath $cfg)) { return $null }   # group e / the bar itself say so
        if (-not (Test-Path -LiteralPath $fp)) {
            return [pscustomobject]@{ Text = 'YASB is running an older config.yaml'; Detail = 'no record of the config.yaml it started with (yasb-config.sha256)' }
        }
        if ((Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash -ne (Get-Content -LiteralPath $fp -Raw).Trim()) {
            return [pscustomobject]@{ Text = 'YASB is running an older config.yaml'; Detail = $null }
        }
        return $null
    }
    if ($Key -eq 'ahk') {
        $started = try { $Process.StartTime } catch { $null }
        if (-not $started) { return $null }
        foreach ($f in 'config\ahk\710.ahk', 'config\ahk\user.ahk') {
            $item = Get-Item -LiteralPath (Join-Path $Root $f) -ErrorAction SilentlyContinue
            if ($item -and $item.LastWriteTime -gt $started) {
                $leaf = Split-Path -Leaf $f
                $text = if ($leaf -eq '710.ahk') { '710.ahk changed since it started' } else { 'user.ahk changed since 710.ahk started' }
                return [pscustomobject]@{ Text = $text; Detail = $null }
            }
        }
    }
    $null
}

function Test-DoctorStack {
    # One line per component (or one line for "nothing running").
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    $ahkExe    = Get-AhkExe
    $parts = @(
        [pscustomobject]@{ Key = 'komorebi'; Name = 'komorebi'; Log = 'komorebi-autostart.log'; Installed = [bool](Get-KomorebiExe) }
        [pscustomobject]@{ Key = 'yasb';     Name = 'YASB';     Log = 'yasb-autostart.log';     Installed = [bool](Get-Command yasbc.exe -CommandType Application -ErrorAction SilentlyContinue) }
        [pscustomobject]@{ Key = 'ahk';      Name = '710.ahk';  Log = 'ahk-autostart.log';      Installed = [bool]$ahkExe }
        [pscustomobject]@{ Key = 'sharex';   Name = 'ShareX';   Log = $null;                    Installed = [bool](Get-ShareXExe) }
    )
    # What's running. 710.ahk by its window (Get-AhkWindowProcessId), the rest by name.
    $ahkPid = Get-AhkWindowProcessId -ScriptPath $ahkScript
    $procs = @{
        komorebi = @(Get-Process komorebi -ErrorAction SilentlyContinue)
        yasb     = @(Get-Process yasb -ErrorAction SilentlyContinue)
        ahk      = @(if ($ahkPid) { Get-Process -Id $ahkPid -ErrorAction SilentlyContinue })
        sharex   = @(Get-Process ShareX -ErrorAction SilentlyContinue)
    }
    # Not installed: group b already says so, and nothing here could start it.
    $parts = @($parts | Where-Object Installed)
    if (-not @($parts | Where-Object { $procs[$_.Key].Count }).Count) {
        # Nothing running: normal on an on-demand machine between sessions. A full-time
        # (-Activate'd) machine is meant to run from sign-in, so there it's a problem, and
        # repair starts the lot (user, 2026-09-27: "repair just make it all on if possible").
        if (Test-FullTimeMachine) {
            return New-DoctorResult -Id 'stack' -Status 'XX' -Text "Stack not running -- this is a full-time machine (it starts at sign-in)" `
                -Fix '710sRice start' -Repair "start:$(@($parts | ForEach-Object Key) -join ',')"
        }
        return New-DoctorResult -Id 'stack' -Status '..' -Text 'Stack not running -- 710sRice start starts it'
    }
    foreach ($c in $parts) {
        $id = "stack:$($c.Key)"
        $running = $procs[$c.Key]
        if (-not $running.Count) {
            $text   = "$($c.Name) isn't running$(if ($c.Key -eq 'sharex') { ' -- capture hotkeys do nothing without it' })"
            $detail = if ($c.Key -eq 'yasb') { Get-DoctorYasbWatchdogNote } else { $null }
            if (-not $detail -and $c.Log) { $detail = "its log: $($c.Log) (710sRice logs opens the folder)" }
            New-DoctorResult -Id $id -Status 'XX' -Text $text -Detail $detail -Fix '710sRice start' -Repair "start:$($c.Key)"
            continue
        }
        if ($c.Key -eq 'yasb' -and $running.Count -gt 1) {
            New-DoctorResult -Id $id -Status 'XX' -Text "$($running.Count) YASB processes -- two bars fight over komorebi's events" -Fix '710sRice reload bar' -Repair 'reload-bar'
            continue
        }
        if ($c.Key -ne 'komorebi' -and (Get-ProcessElevation -Id $running[0].Id) -eq 'elevated') {
            New-DoctorResult -Id $id -Status 'XX' -Text "$($c.Name) is running as admin -- nothing but komorebi should" -Fix '710sRice restart' -Repair 'restart'
            continue
        }
        # Running files older than the ones on disk (a pull or an edit since they started):
        # `710sRice reload` restarts the bar for a changed config.yaml and reloads 710.ahk at its
        # end. The last finding each line can have -- the ones above cover these anyway.
        $stale = Get-DoctorStaleText $c.Key $running[0]
        if ($stale) {
            New-DoctorResult -Id $id -Status 'XX' -Text $stale.Text -Detail $stale.Detail -Fix '710sRice reload' -Repair 'reload'
            continue
        }
        if ($c.Key -eq 'ahk') {
            # The UI Access build is what lets 710.ahk's hotkeys reach admin windows; the
            # installer only makes it in a Program Files install (Get-AhkExe prefers it).
            if ($running[0].ProcessName -eq 'AutoHotkey64_UIA') {
                New-DoctorResult -Id $id -Status 'OK' -Text '710.ahk running (UI Access)'
            } elseif ("$ahkExe" -like '*AutoHotkey64_UIA.exe') {
                New-DoctorResult -Id $id -Status '!!' -Text "710.ahk is running without UI Access -- its hotkeys don't reach admin windows" -Fix '710sRice restart'
            } else {
                New-DoctorResult -Id $id -Status 'OK' -Text '710.ahk running'
            }
            continue
        }
        New-DoctorResult -Id $id -Status 'OK' -Text "$($c.Name) running"
    }
}

function Test-DoctorPaused {
    # komorebi paused (SUPER+P) -- a plain fact, but it explains a lot: nothing tiles, and a bar
    # (re)started now never connects. Its own check, so a komorebic hiccup can't hide the lines above.
    if (-not (Get-Process komorebi -ErrorAction SilentlyContinue)) { return }
    $kc = Get-DoctorKomorebic
    if (-not $kc) { return }
    $text = @(& $kc state 2>$null) -join "`n"
    if (-not $text.Trim()) { return }   # no answer: nothing to say about a pause
    $state = $text | ConvertFrom-Json
    if ($state.is_paused) { New-DoctorResult -Id 'paused' -Status '..' -Text 'komorebi is paused -- SUPER+P resumes' }
}

# --- d. Tasks and tiling mode --------------------------------------------------------------------
# Every component starts through its scheduled task -- with a sign-in trigger on a full-time
# (-Activate'd) machine, without one on an on-demand machine -- and install's tasks step
# (`710sRice install -Only tasks`) re-registers them all in the machine's mode, which fixes
# nearly everything here. The mode itself is install's own rule (Test-FullTimeMachine). The
# task's command is compared with what install would register now (Get-AutostartComponents
# -NoWrite: the same answer, nothing written); a difference is reported by part, never with
# the paths -- the launch files live under %LOCALAPPDATA%, whose path carries the user name.

function Get-DoctorComponentName {
    param([string]$Key)
    switch ($Key) { 'komorebi' { 'komorebi' } 'yasb' { 'YASB' } 'sharex' { 'ShareX' } 'ahk' { '710.ahk' } default { $Key } }
}

function Test-DoctorSameText { param([string]$A, [string]$B) [string]::Equals("$A".Trim(), "$B".Trim(), [StringComparison]::OrdinalIgnoreCase) }

function Get-DoctorTaskDrift {
    # What differs between a component's task as registered and what install would register
    # now: the task's command, and (for the three launched through run-hidden.vbs) its
    # launch-<key>.txt. Nothing = they match.
    param($Component, $Task)
    if (-not (Test-DoctorSameText $Task.Command $Component.Exe) -or -not (Test-DoctorSameText $Task.Arguments $Component.Arguments)) {
        "its task's command differs"
    }
    if ($Component.Spec) {
        $leaf = Split-Path -Leaf $Component.Spec
        if (-not (Test-Path -LiteralPath $Component.Spec)) { "$leaf is missing" }
        else {
            $lines = @(Get-Content -LiteralPath $Component.Spec -ErrorAction Stop)
            if ($lines.Count -ne 2 -or -not (Test-DoctorSameText $lines[0] $Component.SpecLines[0]) -or -not (Test-DoctorSameText $lines[1] $Component.SpecLines[1])) {
                "$leaf differs"
            }
        }
    }
}

function Test-DoctorTasks {
    # The mode line and one line per component's task (the worst thing found). (The lock-screen
    # sync task was checked here until it was retired, 2026-09-28: plan doc item 48.)
    $components = @(Get-AutostartComponents -NoWrite)
    if (-not $components.Count) { return }   # nothing installed: group b says so
    $tasksFix = @{ Fix = '710sRice install -Only tasks'; Step = 'tasks' }
    $fullTime = Test-FullTimeMachine
    $infos = @{}
    foreach ($c in $components) { $infos[$c.Key] = Get-ComponentTaskInfo -TaskName $c.TaskName }
    $names = { param($list) ($list | ForEach-Object { Get-DoctorComponentName $_.Key }) -join ', ' }

    # Mode. Full-time with a task that has no sign-in trigger = mixed (install's rule makes the
    # whole machine full-time, so the tasks step gives every task its trigger back).
    $signIn   = @($components | Where-Object { $infos[$_.Key] -and $infos[$_.Key].AtLogOn })
    $noSignIn = @($components | Where-Object { $infos[$_.Key] -and -not $infos[$_.Key].AtLogOn })
    if ($fullTime -and $noSignIn.Count) {
        $text = if ($signIn.Count) { "Mode: mixed -- $(& $names $signIn) start at sign-in; $(& $names $noSignIn) $(if ($noSignIn.Count -eq 1) { "doesn't" } else { "don't" })" }
                else { "Mode: mixed -- a Startup shortcut says full-time, but no task starts at sign-in" }
        New-DoctorResult -Id 'mode' -Status 'XX' -Text $text @tasksFix
    } elseif ($fullTime) {
        New-DoctorResult -Id 'mode' -Status 'OK' -Text 'Mode: full-time (starts at sign-in)'
    } else {
        New-DoctorResult -Id 'mode' -Status 'OK' -Text 'Mode: on demand (710sRice start)'
    }

    $startup = [Environment]::GetFolderPath('Startup')
    foreach ($c in $components) {
        $name = Get-DoctorComponentName $c.Key
        $id   = "task:$($c.Key)"
        $t    = $infos[$c.Key]
        if (-not $t) { New-DoctorResult -Id $id -Status 'XX' -Text "$name has no task" @tasksFix; continue }
        if ($c.Key -ne 'komorebi' -and $t.RunLevel -eq 'HighestAvailable') {
            New-DoctorResult -Id $id -Status 'XX' -Text "$name's task runs elevated -- only komorebi's may" @tasksFix; continue
        }
        $drift = @(Get-DoctorTaskDrift $c $t)
        if ($drift.Count) {
            New-DoctorResult -Id $id -Status 'XX' -Text "$name's task doesn't match what install would register now (a moved clone or a moved exe?)" -Detail $drift @tasksFix
            continue
        }
        # A Startup shortcut from before the tasks (or Register-Autostart's fallback) next to a
        # working task. The tasks step removes them (Register-Autostart; a shortcut makes the
        # machine full-time by install's rule, so that's the path it takes).
        if (Test-Path -LiteralPath ([IO.Path]::Combine($startup, $c.LnkName))) {
            $why = if ($t.AtLogOn) { "$name starts twice at sign-in" } else { "it starts $name at sign-in on its own" }
            New-DoctorResult -Id $id -Status 'XX' -Text "Startup folder still has `"$($c.LnkName)`" next to $name's task -- $why" @tasksFix
            continue
        }
        if (-not $t.Enabled) {
            New-DoctorResult -Id $id -Status '!!' -Text "$name's task is disabled in Task Scheduler" `
                -Fix "re-enable it in Task Scheduler (Task Scheduler Library > 710.DesktopRice > $($c.TaskName))"
            continue
        }
        $kind = @(if ($t.AtLogOn) { 'sign-in' } else { 'on demand' }; if ($t.RunLevel -eq 'HighestAvailable') { 'elevated' }) -join ', '
        New-DoctorResult -Id $id -Status 'OK' -Text "$name's task ($kind)"
    }
}

function Test-DoctorTilingMode {
    # Three answers that should agree: the saved mode, komorebi's task, the running komorebi.
    # The saved mode reaches the task through `710sRice tiling <mode>` (or install), and the
    # task reaches komorebi at its next start -- `710sRice restart`.
    $saved = Get-TilingMode
    $mode  = if (Test-Path -LiteralPath (Get-TilingModePath)) { $saved } else { "$saved (the default)" }
    $t = Get-ComponentTaskInfo -TaskName 'komorebi'
    if (-not $t) { return New-DoctorResult -Id 'tiling' -Status '..' -Text "Tiling mode: $mode -- komorebi has no task yet" }
    $taskMode = if ($t.RunLevel -eq 'HighestAvailable') { 'elevated' } else { 'normal' }
    if ($taskMode -ne $saved) {
        return New-DoctorResult -Id 'tiling' -Status 'XX' -Text "Tiling mode: $saved is saved, but komorebi's task runs $(if ($taskMode -eq 'elevated') { 'elevated' } else { 'non-elevated' })" `
            -Fix "710sRice tiling $saved" -Repair "tiling:$saved"
    }
    $running = Get-ProcessElevation -Name 'komorebi'
    if ($running -notin 'elevated', 'normal') {
        return New-DoctorResult -Id 'tiling' -Status 'OK' -Text "Tiling mode: $mode -- komorebi's task agrees ($(if ($running -eq 'not running') { "komorebi isn't running" } else { "couldn't read the running komorebi" }))"
    }
    if ($running -ne $taskMode) {
        return New-DoctorResult -Id 'tiling' -Status '!!' -Text "Tiling mode: $saved -- but the running komorebi $(if ($running -eq 'elevated') { 'is elevated' } else { "isn't" }) (it started before the change)" `
            -Fix '710sRice restart'
    }
    New-DoctorResult -Id 'tiling' -Status 'OK' -Text "Tiling mode: $mode -- komorebi's task and the running komorebi agree"
}

# --- e. Generated configs ------------------------------------------------------------------------
# The files install and the stack generate. komorebi.json and wallust.toml are asked of their
# own writers in read-only mode (-Check), so doctor never carries a second copy of how
# they're made. Monitor serials are never printed -- counts only (a serial is a hardware
# identifier; one was scrubbed from this repo's history).

function Get-DoctorKomorebic {
    # komorebic.exe on PATH, else where winget installs it; $null when neither.
    $kc = (Get-Command komorebic.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $kc -and $env:ProgramFiles) {
        $p = [IO.Path]::Combine($env:ProgramFiles, 'komorebi', 'bin', 'komorebic.exe')
        if (Test-Path -LiteralPath $p) { $kc = $p }
    }
    $kc
}

function Test-DoctorKomorebiJson {
    # compile-komorebi-rules.ps1 -Check: a real compile, in memory, against the file on disk.
    # Its warnings are rules the compile skips -- a rule that silently never applies.
    $out  = Join-Path $Root 'config\komorebi\komorebi.json'
    $global:LASTEXITCODE = 0
    try {
        $stream = @(& (Join-Path $Root 'tools\compile-komorebi-rules.ps1') -Check 3>&1 6>$null)
    } catch {
        return New-DoctorResult -Id 'komorebi-json' -Status 'XX' -Text "komorebi.json won't compile" `
            -Detail $_.Exception.Message -Fix 'fix the file named above, then 710sRice reload' -NeedsYou
    }
    $code = $LASTEXITCODE
    switch ($code) {
        0 { New-DoctorResult -Id 'komorebi-json' -Status 'OK' -Text 'komorebi.json is current with its sources' }
        3 {
            $text = if (Test-Path -LiteralPath $out) { 'komorebi.json is out of date with its sources' } else { 'komorebi.json is missing' }
            # A running komorebi: reload -- the hot reload plus its layouts put back. Not
            # running: just the compile step -- reload-stack.ps1 STARTS komorebi (and the bar)
            # when it's down, and a stopped stack has no layouts to keep; komorebi reads the
            # new file at its next start.
            if (Get-Process komorebi -ErrorAction SilentlyContinue) {
                New-DoctorResult -Id 'komorebi-json' -Status 'XX' -Text $text -Fix '710sRice reload' -Repair 'reload'
            } else {
                New-DoctorResult -Id 'komorebi-json' -Status 'XX' -Text $text -Fix '710sRice install -Only compile' -Step 'compile'
            }
        }
        default { New-DoctorResult -Id 'komorebi-json' -Status '!!' -Text "komorebi.json -- couldn't check (the compiler exited $code)" }
    }
    $warnings = @($stream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    if ($warnings.Count) {
        # Your rules (Quick add's file) have their own menu item; anything else is named in the warning.
        $fix = if (-not @($warnings | Where-Object { $_ -notlike 'rules.local.toml:*' }).Count) {
            'fix the line shown (Tiling > Edit my rules... opens rules.local.toml), then 710sRice reload'
        } else { 'fix what the lines above name, then 710sRice reload' }
        New-DoctorResult -Id 'komorebi-json-warnings' -Status '!!' -Text 'komorebi.json compiles, with warnings' -Detail $warnings -Fix $fix
    }
}

function Get-DoctorLfSha256 {
    # sha256 of a text file's bytes with CRLF turned into LF -- the file as the repo stores it.
    # Git for Windows' default (core.autocrlf) checks text files out with CRLF, so a raw hash
    # would never match a pin taken from the LF file; line endings don't change what it says.
    # Decode/encode round-trips a valid UTF-8 file byte for byte, a BOM included.
    param([Parameter(Mandatory)][string]$Path)
    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)) -replace "`r`n", "`n"
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
}

function Test-DoctorAscPin {
    # vendor\asc\applications.json -- the community rules, pinned to one upstream commit -- as
    # pinned: pin.toml's sha256. Changed = someone edited a vendored file; re-pinning is a
    # deliberate maintainer step, so this is worth knowing, not a problem repair touches.
    $file = Join-Path $Root 'vendor\asc\applications.json'
    $pin  = Join-Path $Root 'vendor\asc\pin.toml'
    $fix  = 'git checkout -- vendor\asc\applications.json'
    $want = if ((Test-Path -LiteralPath $pin) -and (Get-Content -LiteralPath $pin -Raw) -match '(?m)^\s*sha256\s*=\s*"([0-9a-fA-F]{64})"') { $Matches[1].ToLowerInvariant() }
    if (-not $want) { return New-DoctorResult -Id 'asc' -Status '!!' -Text "ASC rules file -- couldn't check (vendor\asc\pin.toml has no sha256)" }
    if (-not (Test-Path -LiteralPath $file)) { return New-DoctorResult -Id 'asc' -Status '!!' -Text 'ASC rules file is missing (vendor\asc\applications.json)' -Fix $fix }
    if ((Get-DoctorLfSha256 $file) -eq $want) { return New-DoctorResult -Id 'asc' -Status 'OK' -Text 'ASC rules file matches its pin' }
    New-DoctorResult -Id 'asc' -Status '!!' -Text "ASC rules file doesn't match its pin (vendor\asc\pin.toml)" -Fix $fix
}

function Test-DoctorDisplayIndex {
    # display-index.local.json: which physical monitor is komorebi's 0, 1, ... It's written
    # from a live `komorebic monitor-information` -- by install, or by komorebi's launcher on
    # the first start without one -- so the connected monitors can only be compared while
    # komorebi runs. A monitor in the file but not connected is normal (a laptop off its dock).
    $file = Join-Path $Root 'config\komorebi\display-index.local.json'
    $fix  = @{ Fix = '710sRice install -Only monitors, then 710sRice reload'; Step = 'monitors' }
    $running = [bool](Get-Process komorebi -ErrorAction SilentlyContinue)
    # A broken file (unreadable / empty): the monitors step can only rewrite it while komorebi
    # runs, and komorebi's launcher only writes one that's MISSING -- so with komorebi down,
    # nothing can fix it until the stack is started.
    $broken = if ($running) { $fix + @{ Repair = 'reload' } }
              else { @{ Fix = '710sRice start, then 710sRice doctor -repair'; NeedsYou = $true } }
    if (-not (Test-Path -LiteralPath $file)) {
        if ($running) { return New-DoctorResult -Id 'display-index' -Status 'XX' -Text 'display-index.local.json is missing' @fix -Repair 'reload' }
        return New-DoctorResult -Id 'display-index' -Status '..' -Text 'display-index.local.json not written yet -- komorebi writes it when it next starts'
    }
    try { $map = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable }
    catch { return New-DoctorResult -Id 'display-index' -Status 'XX' -Text "display-index.local.json isn't valid JSON" @broken }
    if (-not $map -or -not $map.Count) { return New-DoctorResult -Id 'display-index' -Status 'XX' -Text 'display-index.local.json is empty' @broken }
    $mapped = @($map.Values | ForEach-Object { "$_" })
    if (-not $running) {
        return New-DoctorResult -Id 'display-index' -Status 'OK' -Text "display-index.local.json: $(Get-DoctorPlural $map.Count 'monitor' 'monitors') mapped (komorebi isn't running -- not compared)"
    }
    $kc = Get-DoctorKomorebic
    if (-not $kc) { return New-DoctorResult -Id 'display-index' -Status '!!' -Text "display-index.local.json -- couldn't check (komorebic.exe not found)" }
    $raw = @(& $kc monitor-information 2>$null) -join "`n"
    if (-not $raw.Trim()) { return New-DoctorResult -Id 'display-index' -Status '!!' -Text "display-index.local.json -- couldn't check (komorebic monitor-information said nothing)" }
    # Monitors without a serial can't be mapped at all (write-display-index.ps1 leaves them out).
    $connected = @(@($raw | ConvertFrom-Json) | ForEach-Object { "$($_.serial_number_id)" } | Where-Object { $_.Trim() })
    $missing   = @($connected | Where-Object { $mapped -notcontains $_ })
    if ($missing.Count) {
        return New-DoctorResult -Id 'display-index' -Status '!!' -Text "display-index.local.json doesn't list $($missing.Count) of the $($connected.Count) connected monitors" @fix
    }
    $which = switch ($connected.Count) { 1 { 'the connected monitor' } 2 { 'both connected monitors' } default { "all $($connected.Count) connected monitors" } }
    New-DoctorResult -Id 'display-index' -Status 'OK' -Text "display-index.local.json: $which mapped"
}

function Test-DoctorWallustToml {
    # write-wallust-config.ps1 -Check: wallust.toml is generated with this clone's own path in
    # it (wallust's template targets are absolute), so a moved clone needs it written again.
    $global:LASTEXITCODE = 0
    $stream = @(& (Join-Path $Root 'tools\write-wallust-config.ps1') -Check 3>&1 6>$null)
    $code = $LASTEXITCODE
    switch ($code) {
        0 { return New-DoctorResult -Id 'wallust-toml' -Status 'OK' -Text 'wallust.toml generated for this clone' }
        3 { return New-DoctorResult -Id 'wallust-toml' -Status 'XX' -Text "wallust.toml isn't generated for this clone (missing, or from a moved clone)" -Fix '710sRice install -Only wallust' -Step 'wallust' }
    }
    # 1: it can't be generated here at all (no template, or a path wallust.toml can't hold).
    $why = @($stream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    New-DoctorResult -Id 'wallust-toml' -Status 'XX' -Text "wallust.toml can't be generated for this clone" -Detail $why `
        -Fix 'deal with what the line above says, then 710sRice install -Only wallust' -NeedsYou
}

function Get-DoctorShownPath {
    # A file as the report names it: repo-relative inside the clone, else ConvertTo-SafePath.
    param([string]$Path)
    if ($Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($Root.Length).TrimStart('\', '/') }
    ConvertTo-SafePath $Path
}

function Test-DoctorPaletteProfile {
    # The chosen palette profile (SUPER+Alt+Space > Palette profiles, 710sRice palette use),
    # usable or not. A chosen profile that's gone or broken is still themed -- with Default,
    # the pipeline's fallback -- so it's [!!]: the choice is yours to fix, repair never
    # changes it. Broken profiles nobody chose are just noted.
    $chosen = Get-ActivePaletteProfileId
    $active = Resolve-ActivePaletteProfile
    $all = @(Get-PaletteProfiles)
    if ($chosen -ne $active.Id) {
        $chosenLabel = ($all | Where-Object Id -eq $chosen | Select-Object -First 1).Label
        New-DoctorResult -Id 'palette-profile' -Status '!!' -Text "Palette profile: $chosenLabel is chosen but can't be used -- Default is used instead" `
            -Detail @("$($active.Warning -replace ' -- using Default$', '')") -Fix "710sRice palette use default (or fix it in SUPER+Alt+Space > Palette profiles > Edit)"
    } else {
        $p = $all | Where-Object Id -eq $active.Id | Select-Object -First 1
        New-DoctorResult -Id 'palette-profile' -Status 'OK' -Text "Palette profile: $($p.Label) ($(Get-PaletteSourceSummary -Source $active.Profile.source))"
    }
    foreach ($b in $all | Where-Object { $_.Exists -and $_.Error -and $_.Id -ne $chosen }) {
        New-DoctorResult -Id "palette-profile:$($b.Id)" -Status '..' -Text "$($b.Label) can't be used: $($b.Error -replace '^[^:]+: ', '')"
    }
}

function Test-DoctorThemeFiles {
    # What the wallpaper pipeline (tools\apply-wallust-outputs.ps1) leaves behind: the palette it
    # made last (config\wallust\generated\palette.json -- the one kept when wallust fails) and
    # every file the chosen palette profile's file targets write (the bar's and menus' colours,
    # colors.json, the prompt, Flow's theme). Made again from the current wallpaper by the palette
    # step, which never changes the wallpaper itself.
    $active = Resolve-ActivePaletteProfile
    $problems = @(); $names = @()
    if (-not (Read-PaletteLastGood)) { $problems += 'no palette made yet (config\wallust\generated\palette.json)' }
    foreach ($t in Get-PaletteTargets) {
        if (-not $t.Template -or -not $t.Output -or $t.Id -in $active.Profile.off) { continue }
        $path = & $t.Output
        if (-not $path) { continue }
        $names += $t.Label
        if (-not (Test-Path -LiteralPath $path)) { $problems += "$($t.Label): $(Get-DoctorShownPath $path) is missing" }
    }
    if ($problems.Count) {
        return New-DoctorResult -Id 'theme-files' -Status 'XX' -Text "Theme files: $($problems -join '; ')" -Fix '710sRice install -Only palette' -Step 'palette'
    }
    New-DoctorResult -Id 'theme-files' -Status 'OK' -Text "Theme files: the palette, $($names -join ', ')"
}

function Test-DoctorThemeInputs {
    # The theme on screen made from what's in the repo now, with the profile chosen now. The
    # pipeline stamps what it was made from after every run that applied everything
    # (theme-inputs.sha256: tools\apply-wallust-outputs.ps1, tools\lib\palette.ps1, every file in
    # tools\palette\targets, and "profile:<id>" = the chosen profile file's hash) -- the list comes
    # from Get-PaletteThemeInputs (tools\lib\palette.ps1), the one the pipeline writes with. A pull
    # that brings a new target or template, a profile changed by hand, a choice made behind the
    # pipeline's back, a run that stopped part-way: each leaves the old look until the next
    # wallpaper change. No stamp at all = an install from before the stamp.
    $stamp = Join-Path (Get-DoctorLogDir) 'theme-inputs.sha256'
    $fix = @{ Fix = '710sRice install -Only palette'; Step = 'palette' }
    $made = [ordered]@{}
    if (Test-Path -LiteralPath $stamp) {
        foreach ($line in @(Get-Content -LiteralPath $stamp)) {
            if ($line -match '^([0-9a-f]{64})\s+(\S.*)$') { $made[$Matches[2].Trim()] = $Matches[1] }
        }
    }
    if (-not $made.Count) {   # no stamp, or nothing readable in it
        return New-DoctorResult -Id 'theme-inputs' -Status 'XX' -Text 'No record of what made the theme' @fix
    }
    $active = Resolve-ActivePaletteProfile
    $label = Get-PaletteProfileLabel -Id $active.Id -Name $active.Profile.name
    $now = Get-PaletteThemeInputs -ProfileId $active.Id
    $what = @(
        $madeProfile = @($made.Keys | Where-Object { $_ -like 'profile:*' }) | Select-Object -First 1
        $nowProfile = "profile:$($active.Id)"
        if (-not $madeProfile) { 'made before palette profiles' }
        elseif ($madeProfile -ne $nowProfile) {
            $was = $madeProfile.Substring(8)
            $wasLabel = if ($was -in $script:PaletteProfileIds) { Get-PaletteProfileLabel -Id $was } else { $was }
            "made with $wasLabel -- $label is chosen now"
        } elseif ($made[$madeProfile] -ne $now[$nowProfile]) { "$label has changed since" }
        foreach ($rel in $now.Keys) {
            if ($rel -like 'profile:*') { continue }
            $leaf = Split-Path -Leaf $rel
            if (-not $made.Contains($rel)) { "new: $leaf" }
            elseif ($made[$rel] -ne $now[$rel]) { "$leaf changed" }
        }
        foreach ($rel in $made.Keys) { if ($rel -notlike 'profile:*' -and -not $now.Contains($rel)) { "gone: $(Split-Path -Leaf $rel)" } }
    )
    if ($what.Count) {
        return New-DoctorResult -Id 'theme-inputs' -Status 'XX' -Text "Theme isn't what the repo and $label make now" -Detail $what @fix
    }
    New-DoctorResult -Id 'theme-inputs' -Status 'OK' -Text "Theme made from the current files, with $label"
}

function Test-DoctorPaletteLastRun {
    # How the last theme run went (palette-status.json, written by the pipeline). A wallust
    # failure leaves the old theme on screen by design -- this is where it says so, next to the
    # toast 710.ahk showed at the time. Nothing to fix by command for a wallpaper wallust can't
    # read, so it's [!!]; a target that failed is also why the stamp above says [XX].
    $s = Get-PaletteStatus
    if (-not $s) { return }
    $when = try { $t = [datetime]::Parse("$($s.time)"); if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') } else { $t.ToString('yyyy-MM-dd HH:mm') } } catch { "$($s.time)" }
    $who = ''
    if ("$($s.profile)" -in $script:PaletteProfileIds) {
        $name = try { (Read-PaletteProfile -Id "$($s.profile)").name } catch { '' }
        $who = Get-PaletteProfileLabel -Id "$($s.profile)" -Name $name
    }
    if ($s.ok) { return New-DoctorResult -Id 'palette-last' -Status 'OK' -Text "Last theme run: $when$(if ($who) { ", $who" })" }
    $detail = @("$(ConvertTo-SafeText "$($s.reason)")")
    if ($s.image) { $detail = @("wallpaper: $($s.image)") + $detail }
    if ("$($s.stage)" -eq 'targets') {
        return New-DoctorResult -Id 'palette-last' -Status '!!' -Text "The last theme run ($when) didn't apply everything" -Detail $detail -Fix '710sRice install -Only palette'
    }
    New-DoctorResult -Id 'palette-last' -Status '!!' -Text "The last theme run ($when) couldn't make a palette -- the theme on screen is from before it" `
        -Detail $detail -Fix 'pick another wallpaper (SUPER+W), or another palette source (SUPER+Alt+Space > Palette profiles)'
}

# --- f. Integrations -----------------------------------------------------------------------------
# The apps the stack leans on, set up the way install sets them up: Flow and Everything (file
# search), Windows Terminal (theme, default shell), the $PROFILE hook, Defender's exclusions,
# and -- on a full-time machine -- the Windows settings -Activate applies.

function Test-DoctorFlowTheme {
    # Flow on the palette's theme (tools\palette\targets\flow.ps1): selected in its settings and
    # the file there. Skipped when the chosen profile switches Flow off, or Flow has never run
    # (the line above says so). Picking another theme in Flow's own settings reads as [XX] here:
    # the palette re-selects its own on every wallpaper change -- switch Flow off in the profile
    # to keep one of yours.
    $active = Resolve-ActivePaletteProfile
    if ('flow' -in $active.Profile.off) {
        return New-DoctorResult -Id 'flow-theme' -Status '..' -Text "Flow Launcher's colours: off in $(Get-PaletteProfileLabel -Id $active.Id -Name $active.Profile.name)"
    }
    $settingsPath = Join-Path $env:APPDATA 'FlowLauncher\Settings\Settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return }
    $theme = "$(([IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -AsHashtable)['Theme'])"
    $file = Test-Path -LiteralPath (Join-Path $env:APPDATA 'FlowLauncher\Themes\710sRice.xaml')
    if ($theme -eq '710sRice' -and $file) { return New-DoctorResult -Id 'flow-theme' -Status 'OK' -Text 'Flow Launcher themed (710sRice)' }
    $why = if ($theme -ne '710sRice') { "it's on '$(if ($theme) { $theme } else { "Flow's default" })'" } else { '710sRice.xaml is missing' }
    New-DoctorResult -Id 'flow-theme' -Status 'XX' -Text "Flow Launcher isn't on the palette's theme ($why)" -Fix '710sRice install -Only palette' -Step 'palette'
}

function Test-DoctorFlow {
    # setup-flow-launcher.ps1 -Check: install's own flow step, asked what it would change.
    # Functional items (the search keywords, the Everything engine, the old plugin, Flow
    # updating itself) are [XX]; preferences (the query box, the tray icon, the update prompt)
    # are [!!].
    if (-not (Test-Path -LiteralPath "$env:LOCALAPPDATA\FlowLauncher\Flow.Launcher.exe")) { return }   # group b says so
    $global:LASTEXITCODE = 0
    $found = @(& (Join-Path $Root 'tools\setup-flow-launcher.ps1') -Check 3>$null 6>$null)
    $code = $LASTEXITCODE
    if ($code -eq 2) { return New-DoctorResult -Id 'flow' -Status '..' -Text "Flow Launcher hasn't run yet -- SUPER+Space starts it" }
    if ($code -notin 0, 3) { return New-DoctorResult -Id 'flow' -Status '!!' -Text "Flow Launcher -- couldn't check (its setup script exited $code)" }
    $functional = @($found | Where-Object { $_.Kind -eq 'functional' } | ForEach-Object Item)
    $preference = @($found | Where-Object { $_.Kind -eq 'preference' } | ForEach-Object Item)
    $fix = @{ Fix = '710sRice install -Only flow'; Step = 'flow' }
    if ($functional.Count) { New-DoctorResult -Id 'flow' -Status 'XX' -Text "Flow Launcher setup: $($functional -join '; ')" @fix }
    else { New-DoctorResult -Id 'flow' -Status 'OK' -Text 'Flow Launcher set up (file search on Everything with f, apps with app, old plugin gone, auto-updates off)' }
    if ($preference.Count) { New-DoctorResult -Id 'flow-prefs' -Status '!!' -Text "Flow Launcher preferences: $($preference -join '; ')" @fix }
    else { New-DoctorResult -Id 'flow-prefs' -Status 'OK' -Text 'Flow Launcher preferences (opens empty, tray icon hidden, no update prompt)' }
}

function Test-DoctorEverything {
    # Flow's file search (SUPER+S) asks Everything's own app -- the tray process in this
    # session. Its Windows service indexes, but doesn't answer searches.
    $exe = @("$env:ProgramFiles\Everything\Everything.exe", "${env:ProgramFiles(x86)}\Everything\Everything.exe") |
           Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $exe) { return }   # group b says so
    $session = (Get-Process -Id $PID).SessionId
    if (@(Get-Process Everything -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }).Count) {
        return New-DoctorResult -Id 'everything' -Status 'OK' -Text 'Everything running'
    }
    New-DoctorResult -Id 'everything' -Status '!!' -Text "Everything isn't running -- SUPER+S (Flow's file search) needs it" -Fix 'start Everything from the Start menu'
}

function Get-DoctorTerminalSettings {
    # Windows Terminal's settings.json, from the same two places install and the palette look.
    $path = @("$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
              "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json") |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
}

function Test-DoctorTerminal {
    # Themed: the palette step sets profiles.defaults.colorScheme to wallust's own scheme.
    # Default shell: the terminal step points defaultProfile at the PowerShell 7 profile.
    $wt = Get-DoctorTerminalSettings
    if (-not $wt) {
        if (Test-Path -LiteralPath "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe") {
            return New-DoctorResult -Id 'terminal' -Status '..' -Text "Windows Terminal hasn't been opened yet -- no settings to check"
        }
        return   # not installed: group b says so
    }
    $active = Resolve-ActivePaletteProfile
    if ('terminal' -in $active.Profile.off) {
        New-DoctorResult -Id 'terminal' -Status '..' -Text "Windows Terminal's colours: off in $(Get-PaletteProfileLabel -Id $active.Id -Name $active.Profile.name)"
    }
    $scheme  = if ($wt['profiles'] -is [hashtable] -and $wt['profiles']['defaults'] -is [hashtable]) { $wt['profiles']['defaults']['colorScheme'] }
    $hasOurs = [bool](@($wt['schemes']) | Where-Object { $_ -is [hashtable] -and $_['name'] -eq 'wallust' })
    if ('terminal' -in $active.Profile.off) { }
    elseif ($scheme -eq 'wallust' -and $hasOurs) { New-DoctorResult -Id 'terminal' -Status 'OK' -Text 'Windows Terminal themed (wallust)' }
    else {
        $why = if ($scheme -ne 'wallust') { "colorScheme isn't wallust" } else { 'no wallust scheme' }
        New-DoctorResult -Id 'terminal' -Status 'XX' -Text "Windows Terminal isn't themed ($why)" -Fix '710sRice install -Only palette' -Step 'palette'
    }
    $pwsh = @(if ($wt['profiles'] -is [hashtable]) { $wt['profiles']['list'] }) | Where-Object { $_ -is [hashtable] -and $_['source'] -eq 'Windows.Terminal.PowershellCore' } | Select-Object -First 1
    if (-not $pwsh -or -not $pwsh['guid']) {
        New-DoctorResult -Id 'terminal-default' -Status '!!' -Text 'Windows Terminal has no PowerShell 7 profile yet' -Fix 'open Terminal once, then 710sRice install -Only terminal'
    } elseif ($wt['defaultProfile'] -eq $pwsh['guid']) {
        New-DoctorResult -Id 'terminal-default' -Status 'OK' -Text 'Windows Terminal opens PowerShell 7'
    } else {
        New-DoctorResult -Id 'terminal-default' -Status '!!' -Text 'Windows Terminal opens something other than PowerShell 7' -Fix '710sRice install -Only terminal' -Step 'terminal'
    }
}

function Test-DoctorProfileHook {
    # $PROFILE's 710.DesktopRice block, compared with exactly what install writes for this clone.
    $fix = @{ Fix = '710sRice install -Only profile'; Step = 'profile' }
    switch (Get-ShellProfileHookState) {
        'installed' { New-DoctorResult -Id 'profile' -Status 'OK' -Text 'Shell profile hook -> this clone' }
        'other'     { New-DoctorResult -Id 'profile' -Status 'XX' -Text 'Shell profile hook points at another copy' @fix }
        default     { New-DoctorResult -Id 'profile' -Status 'XX' -Text "Shell profile hook isn't installed" @fix }
    }
}

function Test-DoctorDefender {
    # Every path install excludes, and no earlier pwsh.exe of ours left behind -- the same two
    # lists install's defender step works from. Windows only shows the exclusions to an admin.
    if (-not (Test-IsAdmin)) { return New-DoctorResult -Id 'defender' -Status '..' -Text 'Defender exclusions: Windows only shows them to an admin -- 710sRice doctor -repair checks them' }
    try { $pref = Get-MpPreference -ErrorAction Stop }
    catch { return New-DoctorResult -Id 'defender' -Status '..' -Text "Defender isn't in use here (another antivirus?) -- nothing to check" }
    $current = @($pref.ExclusionPath)
    $want    = @(Get-DefenderExclusionPaths)
    $missing = @($want | Where-Object { $current -notcontains $_ })
    $stale   = @(Get-StalePwshExclusions -Current $current)
    if (-not $missing.Count -and -not $stale.Count) {
        return New-DoctorResult -Id 'defender' -Status 'OK' -Text "Defender exclusions: all $($want.Count) in place"
    }
    $parts  = @(if ($missing.Count) { "$($missing.Count) missing" }; if ($stale.Count) { "$(Get-DoctorPlural $stale.Count 'old pwsh.exe' 'old pwsh.exes') left" })
    $detail = @($missing | ForEach-Object { "missing: $(ConvertTo-SafePath $_)" }) + @($stale | ForEach-Object { "old: $(ConvertTo-SafePath $_)" })
    New-DoctorResult -Id 'defender' -Status 'XX' -Text "Defender exclusions: $($parts -join ', ')" -Detail $detail -Fix '710sRice install -Only defender' -Step 'defender'
}

function Test-DoctorWindowsSettings {
    # What -Activate applies on a full-time machine: taskbar auto-hide, the hardening values
    # (Get-HardeningSettings), no Startup delay. Worth knowing when it drifts, but the fix
    # restarts Explorer and a change may be deliberate -- so [!!]. TaskbarDa (the Widgets
    # button) is left out: Windows refuses a script's write to it, so no fix could clear it
    # (install already points at Settings for that one).
    if (-not (Test-FullTimeMachine)) { return }
    $drift = @()
    try { if (-not (Test-TaskbarAutoHide)) { $drift += "taskbar doesn't auto-hide" } } catch { }
    $hard = @(foreach ($s in Get-HardeningSettings) {
        $path, $name, $value = $s
        if ($name -eq 'TaskbarDa') { continue }
        $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Ignore
        if ($null -eq $item -or $item.$name -ne $value) { $name }
    })
    if ($hard.Count) {
        $shown = @($hard | Select-Object -First 4) -join ', '
        $drift += "hardening: $shown$(if ($hard.Count -gt 4) { " and $($hard.Count - 4) more" })"
    }
    $delay = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' -Name StartupDelayInMSec -ErrorAction Ignore
    if ($null -eq $delay -or $delay.StartupDelayInMSec -ne 0) { $drift += 'the Startup delay is back' }
    if ($drift.Count) {
        return New-DoctorResult -Id 'windows' -Status '!!' -Text "Windows settings drifted: $($drift -join '; ')" -Fix '710sRice install -Only windows' -Step 'windows'
    }
    New-DoctorResult -Id 'windows' -Status 'OK' -Text 'Windows settings (-Activate): taskbar auto-hides, hardening applied, no Startup delay'
}

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
    @(
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
        ) }
        [pscustomobject]@{ Title = 'Integrations'; Checks = @(
            @{ Id = 'flow';       Name = 'Flow Launcher';        Run = { Test-DoctorFlow } }
            @{ Id = 'flow-theme'; Name = 'Flow Launcher theme';  Run = { Test-DoctorFlowTheme } }
            @{ Id = 'everything'; Name = 'Everything';           Run = { Test-DoctorEverything } }
            @{ Id = 'terminal';   Name = 'Windows Terminal';     Run = { Test-DoctorTerminal } }
            @{ Id = 'profile';    Name = 'Shell profile hook';   Run = { Test-DoctorProfileHook } }
            @{ Id = 'defender';   Name = 'Defender exclusions';  Run = { Test-DoctorDefender } }
            @{ Id = 'windows';    Name = 'Windows settings';     Run = { Test-DoctorWindowsSettings } }
        ) }
        [pscustomobject]@{ Title = 'Conflicts and leftovers'; Checks = @(
            @{ Id = 'conflicts';        Name = 'Other window / hotkey managers'; Run = { Test-DoctorConflicts } }
            @{ Id = 'komorebi-scripts'; Name = 'komorebi.ps1 / komorebi.ahk';    Run = { Test-DoctorKomorebiScripts } }
        ) }
    )
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
        # theme is the default-wallpaper reset and weather needs someone at the keyboard: never
        # repair's, whatever a check says.
        if ($r.Step -and $r.Step -notin 'theme', 'weather') { [void]$steps.Add($r.Step); $covered = $true }
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
    # install's order (tools\lib\steps.ps1 -- the dispatcher loads it; loaded here if not).
    if (-not $InstallStepOrder) { . (Join-Path $Root 'tools\lib\steps.ps1') }
    $plan.Steps = @($InstallStepOrder | Where-Object { $steps.Contains($_) })
    # The stack's own order (komorebi first: the rest look for it), whatever order they came in.
    $order = @('komorebi', 'yasb', 'ahk', 'sharex')
    $plan.Start = @($starts | Sort-Object { $i = $order.IndexOf($_); if ($i -lt 0) { 99 } else { $i } })
    $plan.Lines = @(
        if ($plan.Steps.Count) { "710sRice install -Only $($plan.Steps -join ',')" }
        if ($plan.Tiling)      { "710sRice tiling $($plan.Tiling)" }
        if ($plan.Restart)     { '710sRice restart' }
        if ($plan.Start.Count) {
            "start $(@($plan.Start | ForEach-Object { Get-DoctorComponentName $_ }) -join ', ') ($(if ($plan.Start.Count -eq 1) { 'its task' } else { 'their tasks' }))"
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
    $ctx = [pscustomobject]@{ Git = Start-DoctorGitJobs; Winget = Start-DoctorWingetJob; Head = $null }
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
