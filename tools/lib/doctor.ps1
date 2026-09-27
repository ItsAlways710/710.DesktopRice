<#
.SYNOPSIS
  `710sRice doctor` -- a read-only health report of this clone and its install. Dot-sourced
  by 710sRice.ps1 (after tools\lib\activation.ps1) -- never run directly.

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
  Nothing is printed until every check is in, so the report comes out in one piece. The two
  slow outside calls -- `git ls-remote` (the network) and `git status` -- start first, in the
  background, and are collected last.

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
    # One check's results; a check that throws is reported, never fatal.
    param($Check)
    try { @(& $Check.Run) }
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

# --- The checks, in report order ------------------------------------------------------------
function Get-DoctorGroups {
    @(
        [pscustomobject]@{ Title = 'Repo and command'; Checks = @(
            @{ Id = 'path';    Name = '710sRice command'; Run = { Test-DoctorPath } }
            @{ Id = 'envvars'; Name = 'Config env vars';  Run = { Test-DoctorEnvVars } }
            @{ Id = 'weather'; Name = 'Weather widget';   Run = { Test-DoctorWeather } }
        ) }
    )
}

# --- The run ----------------------------------------------------------------------------------
function Invoke-RiceDoctor {
    <# Runs every check and prints the report. Returns the number of [XX] -- 710sRice's exit
       code. Everything else goes to the screen with Write-Host. #>
    Write-Host ''
    Write-Host '  Checking...' -ForegroundColor DarkGray

    $gitState = Start-DoctorGitJobs
    $header   = Get-DoctorHeader $gitState
    $groups   = foreach ($g in Get-DoctorGroups) {
        [pscustomobject]@{ Title = $g.Title; Results = @(foreach ($c in $g.Checks) { Invoke-DoctorCheck $c }) }
    }
    $top = @(
        Get-DoctorUpdateResult $gitState $header.Head
        Get-DoctorLocalChangesResult $gitState
    ) | Where-Object { $_ }

    Write-Host ''
    Write-Host "== $($header.Title) ==" -ForegroundColor Cyan
    $top | ForEach-Object { Write-DoctorResult $_ }
    foreach ($g in $groups) {
        Write-Host "`n-- $($g.Title) --" -ForegroundColor Cyan
        $g.Results | ForEach-Object { Write-DoctorResult $_ }
    }

    $all      = @($top) + @($groups | ForEach-Object { $_.Results })
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
