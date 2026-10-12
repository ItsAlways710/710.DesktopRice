<#
.SYNOPSIS
  `710sRice doctor` -- a read-only health report of this clone and its install. Dot-sourced
  by 710sRice.ps1 after tools\lib\activation.ps1 (it uses the libraries that loads;
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
# This clone and GitHub (tools\lib\clone.ps1): git, and doctor's header, update and local-changes
# lines -- update.ps1 uses them too.
. (Join-Path $PSScriptRoot 'clone.ps1')

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

# --- a. Repo and command: tools\steps\path.ps1 (Test-DoctorPath), tools\steps\envvars.ps1 ----------
# (Test-DoctorEnvVars, Test-DoctorWeather).

# --- b. Packages and pins: tools\steps\packages.ps1 (Test-DoctorPinnedPackages, Test-DoctorPins,
# Test-DoctorOtherPackages; Start-DoctorWingetJob, the background job the run starts first).

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
# never touched: they're facts repair can't or mustn't change. (claude/cli-plan.md, Stage 4,
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
