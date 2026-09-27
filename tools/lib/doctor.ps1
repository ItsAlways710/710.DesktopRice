<#
.SYNOPSIS
  `710sRice doctor` -- a read-only health report of this clone and its install. Dot-sourced
  by 710sRice.ps1 after tools\lib\activation.ps1 and tools\lib\packages.ps1 (it uses both)
  -- never run directly.

.DESCRIPTION
  Read-only, and it has to stay that way: doctor changes nothing, starts or stops nothing and
  writes no files -- not even git's index (every git call is --no-optional-locks or a command
  that never writes; `git ls-remote` fetches no refs). It runs from any window, never elevates.

  Every check returns one or more results (New-DoctorResult): a stable Id, a Status, the
  line's Text, Detail lines, a Fix -- a command to type -- and, when that fix is an install
  step, its name in Step; NeedsYou marks a problem no command can fix for you. That's the
  shape `710sRice doctor -repair` (Stage 4) plugs into: it runs the Step behind every [XX]
  that doesn't need you.

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

# --- Results ------------------------------------------------------------------------------------
function New-DoctorResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('OK', 'XX', '!!', '..')][string]$Status,
        [Parameter(Mandatory)][string]$Text,
        [string[]]$Detail = @(),
        [string]$Fix = '',
        [string]$Step = '',
        [switch]$NeedsYou
    )
    [pscustomobject]@{
        Id = $Id; Status = $Status; Text = $Text; Detail = @($Detail | Where-Object { $_ })
        Fix = $Fix; Step = $Step; NeedsYou = [bool]$NeedsYou
    }
}

function Write-DoctorResult {
    param($Result)
    $color = switch ($Result.Status) { 'OK' { 'Green' } 'XX' { 'Red' } '!!' { 'Yellow' } default { 'Cyan' } }
    Write-Host "  [$($Result.Status)] $($Result.Text)" -ForegroundColor $color
    foreach ($d in $Result.Detail) { Write-Host "         $d" -ForegroundColor DarkGray }
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

function Get-DoctorFirstLine {
    # The first non-empty line of $Text, git's "fatal: " / "error: " prefix dropped.
    param([string]$Text)
    $line = @("$Text" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
    "$line" -replace '^(fatal|error): ', ''
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

    $newer = @{ Id = 'update'; Status = '!!'; Text = 'Newer version on GitHub'; Fix = 'git pull, then 710sRice install' }
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
        -Fix 'git pull --rebase'
}

function Get-DoctorLocalChangesResult {
    # Tracked files edited in place. A pull that touches one of them refuses to run, so the
    # user's own tweaks belong in the files git ignores (user.ahk, rules.local.toml, user.ps1).
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
        -Text "$(Get-DoctorPlural $files.Count 'tracked file' 'tracked files') changed locally -- git pull can refuse to update" `
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
    # quoting; anything else (a space, a quote, a $...) gets the call operator.
    param([Parameter(Mandatory)][string]$CommandLine)
    $ps1 = Join-Path $Root '710sRice.ps1'
    if ($ps1 -match '^[A-Za-z]:\\[\w.\\-]+$') { return "$ps1 $CommandLine" }
    "& '$($ps1 -replace "'", "''")' $CommandLine"
}

function Test-DoctorPath {
    # This clone's bin\ (bin\710sRice.cmd, the `710sRice` command) on the user PATH -- what any
    # new window gets. Missing: say whether a new window would find some other copy instead.
    $bin = Join-Path $Root 'bin'
    if (@("$(Get-UserPathRaw)" -split ';' | Where-Object { Test-SamePathEntry $_ $bin }).Count) {
        return New-DoctorResult -Id 'path' -Status 'OK' -Text "710sRice command: $bin is on your PATH"
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
    New-DoctorResult -Id 'path' -Status 'XX' -Text "710sRice command: $bin isn't on your PATH" `
        -Detail $(if ($other) { "710sRice on your PATH runs another copy: $other" }) `
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
        elseif (-not (Test-SamePathEntry $v $want[$name])) { "$name = $v" }
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
        return New-DoctorResult -Id 'stack' -Status '..' -Text 'Stack not running -- 710sRice start starts it'
    }
    foreach ($c in $parts) {
        $id = "stack:$($c.Key)"
        $running = $procs[$c.Key]
        if (-not $running.Count) {
            $text   = "$($c.Name) isn't running$(if ($c.Key -eq 'sharex') { ' -- capture hotkeys do nothing without it' })"
            $detail = if ($c.Key -eq 'yasb') { Get-DoctorYasbWatchdogNote } else { $null }
            if (-not $detail -and $c.Log) { $detail = "its log: $($c.Log) (710sRice logs opens the folder)" }
            New-DoctorResult -Id $id -Status 'XX' -Text $text -Detail $detail -Fix '710sRice start'
            continue
        }
        if ($c.Key -eq 'yasb' -and $running.Count -gt 1) {
            New-DoctorResult -Id $id -Status 'XX' -Text "$($running.Count) YASB processes -- two bars fight over komorebi's events" -Fix '710sRice reload bar'
            continue
        }
        if ($c.Key -ne 'komorebi' -and (Get-ProcessElevation -Id $running[0].Id) -eq 'elevated') {
            New-DoctorResult -Id $id -Status 'XX' -Text "$($c.Name) is running as admin -- nothing but komorebi should" -Fix '710sRice restart'
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
    $kc = (Get-Command komorebic.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
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
    # The mode line, one line per component's task (the worst thing found), and the lock-screen
    # sync task on a full-time machine.
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
                else { "Mode: mixed -- the lock-screen sync task (or a Startup shortcut) says full-time, but no task starts at sign-in" }
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

    if ($fullTime) {
        if (Test-Task -TaskName 'lock-screen-sync') { New-DoctorResult -Id 'task:lock-screen-sync' -Status 'OK' -Text 'Lock-screen sync task' }
        else { New-DoctorResult -Id 'task:lock-screen-sync' -Status 'XX' -Text 'Lock-screen sync task is missing (full-time machine)' @tasksFix }
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
            -Fix "710sRice tiling $saved"
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
    )
}

# --- The run ----------------------------------------------------------------------------------
function Invoke-RiceDoctor {
    <# Runs every check and prints the report. Returns the number of [XX] -- 710sRice's exit
       code. Everything else goes to the screen with Write-Host. #>
    Write-Host ''
    Write-Host '  Checking...' -ForegroundColor DarkGray

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

    Write-Host ''
    Write-Host "== $($header.Title) ==" -ForegroundColor Cyan
    $all = [System.Collections.Generic.List[object]]::new()
    for ($g = 0; $g -lt $groups.Count; $g++) {
        if ($groups[$g].Title) { Write-Host "`n-- $($groups[$g].Title) --" -ForegroundColor Cyan }
        for ($i = 0; $i -lt $groups[$g].Checks.Count; $i++) {
            foreach ($r in $results["$g/$i"]) { Write-DoctorResult $r; $all.Add($r) }
        }
    }

    $problems = @($all | Where-Object { $_.Status -eq 'XX' }).Count
    $warnings = @($all | Where-Object { $_.Status -eq '!!' }).Count
    $look     = "$(Get-DoctorPlural $warnings 'thing' 'things') worth a look (!!)."
    Write-Host ''
    if ($problems) {
        $line = if ($problems -eq 1) { '1 problem -- its fix is above.' } else { "$problems problems -- each has its fix above." }
        if ($warnings) { $line += " $look" }
        Write-Host "  $line" -ForegroundColor Red
    } elseif ($warnings) {
        Write-Host "  No problems. $look" -ForegroundColor Yellow
    } else {
        Write-Host '  All good.' -ForegroundColor Green
    }
    Write-Host ''
    $problems
}
