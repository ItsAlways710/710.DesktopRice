#Requires -Version 7.0
<#
.SYNOPSIS
  710sRice -- one command for this repo's scripts.

.DESCRIPTION
  `710sRice <command> [options]` from any PS7 window. install.ps1 puts bin\ on the user PATH,
  and bin\710sRice.cmd (one line) runs this file with pwsh. Before that exists (a fresh
  clone): .\710sRice.ps1 <command>. The shim also makes it work from cmd, Windows PowerShell
  and the Run dialog -- supported, just not what the README tells anyone to do.

  A thin dispatcher: each command runs one of the existing scripts unchanged, so the scripts
  themselves, the scheduled tasks and the hotkeys keep working on their own. Every command is
  a row in $Commands; the help text is generated from that table, so it can't drift.

  Deliberately a PLAIN script -- no param() block, no [CmdletBinding()]. A plain script's
  $args keeps "-Activate" marked as a switch when it's splatted on to install.ps1. An
  advanced script's ValueFromRemainingArguments collects the same text but loses the mark on
  the way out (tested: `install -Activate -Keep X` bound "-Activate" as -Keep's value).
  Corollary: never pass the arguments through a [string[]] parameter or cast -- that strips
  the marks too. Slices and copies of $args keep them.

  Admin: a command tagged (admin) that's run from a normal window reopens itself in a new
  admin window -- one UAC prompt -- and waits for it: `pwsh -File 710sRice.ps1 --elevated
  <command as typed>`. The admin window holds the output and always ends with "Press Enter to
  close"; this window reports its exit code and passes it on. Already admin: it just runs.
  Nothing that STARTS the stack needs that: start, reload and reload bar only ever start
  things through the components' own scheduled tasks, which carry their own run level, so
  they're safe from any window (see claude/cli-plan.md).

  Exit codes: help 0; unknown command, an error or a declined UAC prompt 1; otherwise the
  called script's own (relayed from the admin window when it ran there) -- for reload, read
  from reload-stack.log, since 710.ahk is the one that runs it; for doctor, the number of
  problems it found; for doctor -repair, the number still left; for update, 1 when it refused
  (nothing changed) or its repair didn't run, else doctor's count (nothing to pull) or
  repair's (pulled).

  Never run this hidden (AHK, scheduled tasks). When its window was opened just for it (the
  Run dialog, an Explorer double-click, the elevated relaunch) it ends with "Press Enter to
  close" -- in a hidden window that waits forever. Hidden callers use the scripts directly.

.EXAMPLE
  710sRice                            # the command list
  710sRice install -?                 # one command's usage
  .\710sRice.ps1 install -Activate    # the very first install, from the repo folder
  710sRice install -Only tasks        # just re-register the scheduled tasks
  710sRice uninstall -DryRun -Keep AutoHotkey.AutoHotkey,ShareX.ShareX
  710sRice activate                   # full-time: it starts at every sign-in
  710sRice deactivate -DryRun         # what going back to on demand would do (changes nothing)
  710sRice doctor                     # what's wrong, and the command that fixes each thing
  710sRice doctor -repair             # ...and fix it (never the wallpaper or theme)
  710sRice update                     # the newest version from GitHub, then doctor -repair
  710sRice reload bar                 # just the bar, e.g. after a config.yaml change
  710sRice tiling normal              # komorebi stops running as admin (next start)
#>
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
# install's steps, in their order (install -? lists them; doctor's repair plan orders by them).
# Only functions and the fixed list here -- the components are read when something asks for the
# full order, so help stays fast.
. (Join-Path $Root 'tools\lib\steps.ps1')

# --- The commands -----------------------------------------------------------------------------
# One row per command, shown in help in this order. The name is one word or two ('reload bar'
# beats 'reload': the dispatcher tries the first two words before the first one). Usage is the
# help line's left side; Admin is 'Required' (the command asks for UAC itself) or 'Any'; Run gets
# the arguments that follow the name, with their switch marks intact. Hidden rows work but
# stay out of the help list (bare `tiling` = `tiling status`). AsksAdmin tags a row that runs as
# you but asks for UAC part-way (update's repair) with (admin) in help, like a Required row.
$Commands = [ordered]@{
    'help'      = @{ Usage = 'help'; Help = 'Show this list'; Admin = 'Any'
                     Run = { Show-RiceHelp } }
    # More: shown by `install -?` only -- the steps from tools\lib\steps.ps1 (a scriptblock, so the
    # component files are only read when someone asks).
    'install'   = @{ Usage = 'install [-Activate] [-SkipPackages] [-ElevatedTiling | -NoElevatedTiling] | -Only <step>,...'
                     Help = 'Install (safe to run again); -Activate = full-time from the start; -Only = just those steps'; Admin = 'Required'
                     More = { "Steps: $((Get-InstallStepOrder) -join ', ')" }
                     Run = { Invoke-RiceScript 'install.ps1' @args } }
    'uninstall' = @{ Usage = 'uninstall [-DryRun] [-Force] [-Keep <id>,<id>...]'
                     Help = 'Undo everything install did; -DryRun shows the plan first'; Admin = 'Required'
                     Run = { Invoke-RiceScript 'uninstall.ps1' @args } }
    # activate / deactivate: the switch between full time and on demand, both ways, on an
    # installed machine -- the tasks, full time's Windows settings and the stack, nothing else (no
    # winget pass, no theme reset). Admin: komorebi's task is elevated by default, and only an
    # admin window can register it. Invoke-RiceSwitch, below.
    'activate'   = @{ Usage = 'activate [-DryRun]'; Help = 'Full-time: it starts at every sign-in, hides the taskbar, turns off Windows'' tips and ads'; Admin = 'Required'
                      Run = { Invoke-RiceSwitch 'activate' @args } }
    'deactivate' = @{ Usage = 'deactivate [-DryRun]'; Help = 'On demand: nothing at sign-in; your taskbar and Windows settings back as they were'; Admin = 'Required'
                      Run = { Invoke-RiceSwitch 'deactivate' @args } }
    # doctor: read-only, any window. Its checks live in tools\lib\doctor.ps1, loaded only here;
    # the exit code is the number of problems ([XX]) it found.
    'doctor'    = @{ Usage = 'doctor'; Help = 'Health check -- each problem names the command that fixes it (changes nothing)'; Admin = 'Any'
                     Run = {
                         if ($args.Count) {
                             Write-RiceError "Unknown option '$($args[0])' for doctor"
                             Show-RiceCommandHelp 'doctor'
                             $script:RiceExit = 1
                             return
                         }
                         . (Join-Path $Root 'tools\lib\activation.ps1')
                         . (Join-Path $Root 'tools\lib\packages.ps1')
                         . (Join-Path $Root 'tools\lib\doctor.ps1')
                         $script:RiceExit = Invoke-RiceDoctor
                     } }
    # doctor -repair: doctor's checks, then the fix behind every [XX] that doesn't need you
    # (tools\lib\repair.ps1, loaded only here), then the checks again. Admin: one UAC prompt,
    # the work happens in the admin window. Exit code = the problems left.
    # ALSO update's hand-off (tools\lib\update.ps1): every update's first half, however old,
    # starts `710sRice.ps1 --elevated doctor -repair` or `710sRice.ps1 doctor -repair` from the
    # files it just pulled -- keep this row's name and the --elevated marker working, always.
    'doctor -repair' = @{ Usage = 'doctor -repair'; Help = 'Fix what doctor finds -- never your wallpaper, theme or choices'; Admin = 'Required'
                     Run = {
                         if ($args.Count) {
                             Write-RiceError "Unknown option '$($args[0])' for doctor -repair"
                             Show-RiceCommandHelp 'doctor -repair'
                             $script:RiceExit = 1
                             return
                         }
                         . (Join-Path $Root 'tools\lib\activation.ps1')
                         . (Join-Path $Root 'tools\lib\packages.ps1')
                         . (Join-Path $Root 'tools\lib\doctor.ps1')
                         . (Join-Path $Root 'tools\lib\repair.ps1')
                         $script:RiceExit = Invoke-RiceRepair
                     } }
    # update: pull as you (tools\lib\update.ps1 -- loaded here, BEFORE the pull; nothing is loaded
    # after it), then doctor -repair in a new process started from the pulled files. The row runs
    # in any window; the repair asks for UAC itself (AsksAdmin: help says (admin)).
    'update'    = @{ Usage = 'update'; Help = 'Get the newest version from GitHub, then repair -- keeps your wallpaper, theme and choices'; Admin = 'Any'; AsksAdmin = $true
                     Run = {
                         if ($args.Count) {
                             Write-RiceError "Unknown option '$($args[0])' for update"
                             Show-RiceCommandHelp 'update'
                             $script:RiceExit = 1
                             return
                         }
                         . (Join-Path $Root 'tools\lib\activation.ps1')
                         . (Join-Path $Root 'tools\lib\packages.ps1')
                         . (Join-Path $Root 'tools\lib\doctor.ps1')
                         . (Join-Path $Root 'tools\lib\update.ps1')
                         $r = Invoke-RiceUpdate
                         # A statement of its own, not an assignment: the repair's output goes
                         # straight to the console (see Invoke-RiceUpdateHandOff).
                         if ($r.HandOff) { Invoke-RiceUpdateHandOff } else { $script:RiceExit = $r.Exit }
                     } }
    'start'     = @{ Usage = 'start'; Help = 'Start the stack'; Admin = 'Any'
                     Run = { Invoke-RiceScript 'scripts\Start-All.ps1' @args } }
    'stop'      = @{ Usage = 'stop'; Help = 'Stop the stack'; Admin = 'Any'
                     Run = { Invoke-RiceScript 'scripts\Stop-All.ps1' @args } }
    # restart: stop + start, with a wait in between (Invoke-RiceRestart). activation.ps1 for
    # Find-AhkWindow, loaded here for the same reason as reload's.
    'restart'   = @{ Usage = 'restart'; Help = 'Stop the stack, then start it again (= SUPER+Ctrl+R; SUPER+Shift+R only reloads)'; Admin = 'Any'
                     Run = { . (Join-Path $Root 'tools\lib\activation.ps1'); Invoke-RiceRestart } }
    # activation.ps1 (Send-AhkMessage) is loaded here, not at the top, so the other commands
    # -- help above all -- don't pay for parsing it. Dot-sourced into this block's scope,
    # which Invoke-RiceReload runs inside of.
    'reload'    = @{ Usage = 'reload'; Help = 'Reload the whole stack (same as SUPER+Shift+R)'; Admin = 'Any'
                     Run = { . (Join-Path $Root 'tools\lib\activation.ps1'); Invoke-RiceReload } }
    'reload bar' = @{ Usage = 'reload bar'; Help = 'Restart just the bar (YASB)'; Admin = 'Any'
                     Run = { Invoke-RiceReloadBar } }
    'logs'      = @{ Usage = 'logs'; Help = 'Open the logs folder (and list what''s in it)'; Admin = 'Any'
                     Run = { Show-RiceLogs } }
    # palette: the palette profiles (tools\lib\palette.ps1, loaded only here). Any window: a
    # switch goes through the wallpaper pipeline (apply-wallust-outputs.ps1 -ProfileId), which
    # keeps the old choice when the new profile's palette can't be made.
    'palette'     = @{ Usage = 'palette'; Help = 'List the palette profiles (SUPER+Alt+Space > Palette profiles)'; Admin = 'Any'
                       Run = {
                           if ($args.Count) {
                               Write-RiceError "Unknown option '$($args[0])' for palette"
                               Show-RiceCommandHelp 'palette'
                               $script:RiceExit = 1
                               return
                           }
                           . (Join-Path $Root 'tools\lib\palette.ps1'); Show-RicePalettes
                       } }
    'palette use' = @{ Usage = 'palette use <profile>'; Help = 'Theme everything with that profile now (default, 0-9 or its name)'; Admin = 'Any'
                       Run = { Invoke-RicePaletteUse @args } }
    # The editor is a window of its own (tools\palette-editor.ps1, hidden pwsh -STA): these start
    # it and come back as soon as it's up, so the prompt is free again.
    'palette edit' = @{ Usage = 'palette edit [<profile>]'; Help = 'Open the palette profile editor on the one in use (or that profile)'; Admin = 'Any'
                        Run = { Invoke-RicePaletteEditor 'edit' @args } }
    'palette new'  = @{ Usage = 'palette new [<from>]'; Help = 'Create a palette profile in the editor, starting from the one in use (or <from>)'; Admin = 'Any'
                        Run = { Invoke-RicePaletteEditor 'new' @args } }
    # tiling: the saved mode (tiling-mode.txt) and komorebi's task only -- never install's
    # theme reset. Changing it needs admin: an elevated task can only be registered, or a
    # task an admin window made replaced, from an admin window.
    'tiling'    = @{ Usage = 'tiling [status | elevated | normal]'; Help = 'Same as tiling status'; Admin = 'Any'; Hidden = $true
                     Run = {
                         if ($args.Count) {
                             Write-RiceError "Unknown command 'tiling $($args -join ' ')'"
                             Show-RiceHelp
                             $script:RiceExit = 1
                         } else { . (Join-Path $Root 'tools\lib\activation.ps1'); Show-RiceTilingStatus }
                     } }
    'tiling status'   = @{ Usage = 'tiling status'; Help = 'Show the tiling mode, komorebi''s task and the running komorebi'; Admin = 'Any'
                           Run = { . (Join-Path $Root 'tools\lib\activation.ps1'); Show-RiceTilingStatus } }
    'tiling elevated' = @{ Usage = 'tiling elevated'; Help = 'komorebi runs as admin, so admin windows tile too (the default)'; Admin = 'Required'
                           Run = { . (Join-Path $Root 'tools\lib\activation.ps1'); Set-RiceTilingMode 'elevated' } }
    'tiling normal'   = @{ Usage = 'tiling normal'; Help = 'komorebi runs as you; admin windows float'; Admin = 'Required'
                           Run = { . (Join-Path $Root 'tools\lib\activation.ps1'); Set-RiceTilingMode 'normal' } }
}

# Anywhere after a command these mean "tell me about it" -- never run it, never elevate.
$HelpFlags = @('-h', '-?', '/?', '--help')

function Write-RiceError { param([string]$Message) Write-Host "  [XX] $Message" -ForegroundColor Red }
# The same three the scripts print with -- and tools\lib\activation.ps1 expects its caller to
# have them before it's dot-sourced (see its header).
function Step-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Step-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Step-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

function Invoke-RiceScript {
    # $args[0] is the script (relative to the repo), the rest the arguments as typed, switch
    # marks intact. The exit code to pass on goes in $script:RiceExit. $? decides, not
    # $LASTEXITCODE alone: a script that finishes without an `exit` still holds whatever its
    # last native command returned (a failed schtasks, say) while $? stays True -- tested.
    $path = Join-Path $Root $args[0]
    $rest = @($args | Select-Object -Skip 1)
    $global:LASTEXITCODE = 0
    & $path @rest
    $script:RiceExit = if ($?) { 0 } elseif ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
}

# --- reload / reload bar -------------------------------------------------------------------------
$RiceReloadLog = Join-Path $env:LOCALAPPDATA '710.DesktopRice\reload-stack.log'

function Read-RiceLogFrom {
    # Everything written to the log since byte $Offset. A log that's now SHORTER than that got
    # rotated to .old -- which reload-stack.ps1 only does at the very start of a run, before its
    # first line -- so then all of it is new. Opened share-everything: a run may be appending.
    param([string]$Path, [long]$Offset)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                 [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $sr = [System.IO.StreamReader]::new($fs)   # disposing the reader closes the file too
    try {
        if ($fs.Length -lt $Offset) { $Offset = 0 }
        $null = $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $sr.ReadToEnd()
    } finally { $sr.Dispose() }
}

function Get-RiceReloadOutcome {
    # The first full reload that ENDS in $Text: its exit code, as reload-stack.ps1 gives it,
    # and its log lines (from its header, when that's in $Text too). $null while none has. A
    # `reload bar` run (-BarOnly) that happens to finish in between is skipped -- its 'done.'
    # isn't ours.
    param([string]$Text)
    $lines = @("$Text" -split "`r?`n" | Where-Object { $_ })
    $inBar = $false
    $start = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = $lines[$i] -replace '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  ', ''
        if ($m -like '--- reload-stack -BarOnly*') { $inBar = $true; continue }
        if ($m -like '--- reload-stack*')          { $inBar = $false; $start = $i; continue }
        $code = if ($m -eq 'done.') { 0 } elseif ($m -like 'done, with failures*') { 2 } elseif ($m -like '1. rule compile FAILED*') { 1 } else { $null }
        if ($null -eq $code) { continue }
        if ($inBar) { $inBar = $false; continue }
        return [pscustomobject]@{ Code = $code; Lines = @($lines[$start..$i]) }
    }
    $null
}

function Write-RiceReloadResult {
    # Same words as 710.ahk's toasts. When it didn't go cleanly, the run's own log lines too.
    param([int]$Code, [string[]]$Lines)
    $script:RiceExit = $Code
    switch ($Code) {
        0       { Step-Ok 'Stack reloaded' }
        1       { Write-RiceError 'Rules failed to compile -- nothing reloaded (see reload-stack.log)' }
        default { Step-Warn 'Reloaded, with errors (see reload-stack.log)' }
    }
    if ($Code -ne 0) { $Lines | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray } }
}

function Wait-RiceAhkReloaded {
    # 710.ahk's ReloadStack() writes reload-stack.log's done. line, shows its toast, waits 1.5 s
    # and only then Reload()s itself -- into a new process. Waits (up to 10 s) for 710.ahk's
    # window to belong to a process other than $OldPid, so whatever runs next meets the reloaded
    # 710.ahk: `doctor -repair`'s re-check caught the old one once and called a `710.ahk changed
    # since it started` it had just fixed "still broken" (2026-09-27, the update test).
    # $true once it has, or when there was nothing to wait for.
    param([Parameter(Mandatory)][string]$ScriptPath, $OldPid)
    if (-not $OldPid) { return $true }
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $now = try { Get-AhkWindowProcessId -ScriptPath $ScriptPath } catch { $null }
        if ($now -and $now -ne $OldPid) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    $false
}

function Invoke-RiceReload {
    # `reload` = SUPER+Shift+R: 710.ahk runs its own ReloadStack() (toasts, double-press guard,
    # its Reload() at the end), we read the result from reload-stack.log -- only what's written
    # after the post, so an older run can't pass for this one. A reload already running when we
    # post: AHK ignores ours and we report that one, which is the one that counts anyway. Then
    # we wait for that Reload() too (Wait-RiceAhkReloaded): "Stack reloaded" means all of it.
    $ahk    = Join-Path $Root 'config\ahk\710.ahk'
    $offset = if (Test-Path -LiteralPath $RiceReloadLog) { (Get-Item -LiteralPath $RiceReloadLog).Length } else { 0 }
    $ahkPid = try { Get-AhkWindowProcessId -ScriptPath $ahk } catch { $null }
    if (Send-AhkMessage -ScriptPath $ahk -Name '710sRice.ReloadStack') {
        Step-Info 'Reloading (same as SUPER+Shift+R)...'
        $deadline = (Get-Date).AddMinutes(2)
        $outcome  = $null
        while (-not $outcome -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
            $outcome = Get-RiceReloadOutcome (Read-RiceLogFrom $RiceReloadLog $offset)
        }
        # A failed rule compile (1) ends ReloadStack() before its Reload(): nothing to wait for.
        $reloaded = if ($outcome -and $outcome.Code -ne 1) { Wait-RiceAhkReloaded $ahk $ahkPid } else { $true }
        if ($outcome) { Write-RiceReloadResult $outcome.Code $outcome.Lines }
        else {
            Step-Warn 'No result in reload-stack.log after 2 minutes -- check its toasts and the log.'
            $script:RiceExit = 2
        }
        if (-not $reloaded) { Step-Warn "710.ahk hasn't reloaded itself 10 s after the stack did -- give it a moment (SUPER+Shift+R if its hotkeys act up)." }
        return
    }
    # No 710.ahk: run the script ourselves. Safe from any window (it starts things only through
    # their tasks), but nothing brings AHK back afterwards -- so say what does.
    Step-Info "Reloading without 710.ahk (it isn't running)..."
    Invoke-RiceScript 'tools\reload-stack.ps1'
    Write-RiceReloadResult $script:RiceExit (Get-RiceReloadOutcome (Read-RiceLogFrom $RiceReloadLog $offset)).Lines
    Step-Warn "710.ahk isn't running -- reloaded without it; ``710sRice start`` brings it back."
}

function Invoke-RiceReloadBar {
    # `reload bar`: reload-stack.ps1 -BarOnly, right here -- no AHK, no Reload(). YASB only ever
    # starts through its task, so any window will do. "Restarted" only once yasb.exe is back:
    # the script is done when the task has fired, and YASB takes a few seconds after that.
    $offset = if (Test-Path -LiteralPath $RiceReloadLog) { (Get-Item -LiteralPath $RiceReloadLog).Length } else { 0 }
    Step-Info 'Restarting the bar...'
    Invoke-RiceScript 'tools\reload-stack.ps1' -BarOnly
    switch ($script:RiceExit) {
        0 {
            $deadline = (Get-Date).AddSeconds(15)
            while (-not (Get-Process yasb -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
            if (Get-Process yasb -ErrorAction SilentlyContinue) { Step-Ok 'Bar restarted' }
            else { Step-Warn "Bar's task fired, but YASB isn't up after 15s -- it may still be starting (see yasb-autostart.log)." }
            Step-Info 'Chrome, the Claude app and other Chromium apps can pick up an extra title bar when the bar restarts -- focus the app and press SUPER+Ctrl+C to redraw it.'
        }
        3 { Step-Warn 'komorebi is paused -- unpause it first (SUPER+P). A bar started during a pause never connects to komorebi.' }
        default {
            Step-Warn 'Bar restart had errors (see reload-stack.log)'
            ((Read-RiceLogFrom $RiceReloadLog $offset) -split "`r?`n" | Where-Object { $_ }) |
                ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        }
    }
}

# --- restart --------------------------------------------------------------------------------------
function Invoke-RiceRestart {
    # `restart` = stop, then start: the whole stack, every time. SUPER+Shift+R (`reload`) no
    # longer is that -- it restarts komorebi only when a rule was removed, and YASB only when
    # it has to (Chromium apps' extra title bar per bar restart, plan doc #40). In between, it
    # waits until everything has really exited: each launcher leaves alone a component it still
    # sees running, and Stop-All only gives each stop a few hundred ms. Something still up after
    # 10 s (Stop-All has already said why) keeps running as it was; the rest start anyway.
    Invoke-RiceScript 'scripts\Stop-All.ps1'
    $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
    $stillUp = {
        @(
            if (Get-Process komorebi -ErrorAction SilentlyContinue) { 'komorebi' }
            if (Get-Process yasb -ErrorAction SilentlyContinue) { 'YASB' }
            if (Get-Process ShareX -ErrorAction SilentlyContinue) { 'ShareX' }
            if ((Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero) { '710.ahk' }
        )
    }
    $deadline = (Get-Date).AddSeconds(10)
    while (@(& $stillUp).Count -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    $left = @(& $stillUp)
    if ($left.Count) {
        Step-Warn "Still running after 10 s: $($left -join ', ') -- starting the rest; $(if ($left.Count -eq 1) { 'it keeps' } else { 'those keep' }) running as before (not restarted)."
    }
    Invoke-RiceScript 'scripts\Start-All.ps1'
    if ($script:RiceExit -eq 0) {
        Step-Info 'Chrome, the Claude app and other Chromium apps can pick up an extra title bar when the bar restarts -- focus the app and press SUPER+Ctrl+C to redraw it.'
    }
}

# --- palette ---------------------------------------------------------------------------------------
function Show-RicePalettes {
    # Default and the profiles that exist, the one in use marked; a broken one says why.
    $active = Resolve-ActivePaletteProfile
    $chosen = Get-ActivePaletteProfileId
    $all = @(Get-PaletteProfiles)
    Write-Host ''
    Write-Host '  Palette profiles -- SUPER+Alt+Space > Palette profiles, or 710sRice palette use / edit / new'
    foreach ($p in $all | Where-Object Exists) {
        $mark = if ($p.Id -eq $active.Id) { '>' } else { ' ' }
        $what = if ($p.Error) { "can't be used: $($p.Error -replace '^[^:]+: ', '')" } else { $p.Summary }
        $line = '  {0} {1,-26} {2}' -f $mark, $p.Label, $what
        if ($p.Id -eq $active.Id) { Write-Host $line -ForegroundColor Green }
        elseif ($p.Error) { Write-Host $line -ForegroundColor Yellow }
        else { Write-Host $line }
    }
    if ($chosen -ne $active.Id) { Write-Host "  [!!] $($active.Warning)" -ForegroundColor Yellow }
    $free = @($all | Where-Object { $_.Id -ne 'default' -and -not $_.Exists }).Count
    Write-Host ''
    Write-Host "  $free of 10 slots free. palette use <profile> switches now (every wallpaper change uses it too); palette edit <profile> opens the editor."
    Write-Host ''
}

function Invoke-RicePaletteUse {
    if ($args.Count -ne 1 -or -not "$($args[0])".Trim()) {
        Write-RiceError 'palette use takes one profile: default, 0-9, or its name'
        Show-RiceCommandHelp 'palette use'
        $script:RiceExit = 1
        return
    }
    # In-process, like install's palette step; the pipeline prints what it themed.
    & (Join-Path $Root 'tools\apply-wallust-outputs.ps1') -ProfileId "$($args[0])"
    $script:RiceExit = $LASTEXITCODE
}

function Invoke-RicePaletteEditor {
    # Starts the editor hidden (only its own window shows) and waits until that window is up --
    # or the process ends: already open (it brought that one to the front) or it failed (the
    # last line of its log says why).
    param([string]$Mode, [Parameter(ValueFromRemainingArguments)]$Rest)
    $rest = @($Rest | Where-Object { "$_".Trim() })
    $usage = if ($Mode -eq 'new') { 'palette new' } else { 'palette edit' }
    if ($rest.Count -gt 1) {
        Write-RiceError "$usage takes at most one profile: default, 0-9, or its name (quote a name with spaces)"
        Show-RiceCommandHelp $usage
        $script:RiceExit = 1
        return
    }
    . (Join-Path $Root 'tools\lib\palette.ps1')
    $argLine = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$(Join-Path $Root 'tools\palette-editor.ps1')`""
    if ($rest.Count) {
        $want = "$($rest[0])".Trim()
        $id = ConvertTo-PaletteProfileId $want
        if (-not $id) {
            Write-RiceError "No palette profile '$want' -- default, 0-9, or a profile's name (710sRice palette lists them)"
            $script:RiceExit = 1
            return
        }
        if ($Mode -eq 'new') {
            if (-not (Test-Path -LiteralPath (Get-PaletteProfilePath -Id $id))) {
                Write-RiceError "$(Get-PaletteProfileLabel -Id $id) doesn't exist yet -- nothing to start from"
                $script:RiceExit = 1
                return
            }
            $argLine += " -New -From $id"
        } else { $argLine += " -ProfileId $id" }
    } elseif ($Mode -eq 'new') { $argLine += ' -New' }
    if ($Mode -eq 'new' -and -not (Get-FreePaletteProfileId)) {
        Write-RiceError 'All 10 profile slots are in use -- delete one first (710sRice palette edit <profile>, then Delete)'
        $script:RiceExit = 1
        return
    }
    $log = Join-Path $env:LOCALAPPDATA '710.DesktopRice\palette-editor.log'
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $until = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $until) {
        Start-Sleep -Milliseconds 200
        if ($p.HasExited) { break }
        $p.Refresh()
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
            Step-Ok 'The palette editor is open.'
            return
        }
    }
    if (-not $p.HasExited) { Step-Ok 'The palette editor is starting.'; return }
    if ($p.ExitCode -eq 0) { Step-Ok 'The palette editor was already open -- it''s in front now.'; return }
    $last = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log -Tail 1)[0] -replace '^\S+ \S+\s+', '' } else { '' }
    Write-RiceError "The palette editor didn't start$(if ($last) { ": $last" }) (log: %LOCALAPPDATA%\710.DesktopRice\palette-editor.log)"
    $script:RiceExit = 1
}

# --- logs / tiling ---------------------------------------------------------------------------------
function Show-RiceLogs {
    # The folder every 710.DesktopRice log lives in: its path and logs here, newest first (which
    # one just moved), and the folder in Explorer. From an admin window Explorer hands the
    # folder to your running (normal) shell, so that window isn't elevated. The path is shown
    # as %LOCALAPPDATA%\..., never expanded: that carries the Windows user name.
    $dir   = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
    $shown = '%LOCALAPPDATA%\710.DesktopRice'
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-RiceError "Nothing logged yet -- $shown doesn't exist"
        $script:RiceExit = 1
        return
    }
    Write-Host ''
    Write-Host "  $shown"
    $logs = @(Get-ChildItem -LiteralPath $dir -File |
              Where-Object { $_.Name -like '*.log' -or $_.Name -like '*.log.old' } |
              Sort-Object LastWriteTime -Descending)
    foreach ($f in $logs) {
        $size = if ($f.Length -ge 1MB) { '{0:N1} MB' -f ($f.Length / 1MB) }
                elseif ($f.Length -ge 1KB) { '{0:N0} KB' -f ($f.Length / 1KB) }
                else { "$($f.Length) B" }
        Write-Host ('    {0,-28}{1,9}   {2:yyyy-MM-dd HH:mm:ss}' -f $f.Name, $size, $f.LastWriteTime)
    }
    if (-not $logs.Count) { Write-Host '    (no .log files yet)' }
    Write-Host ''
    Invoke-Item -LiteralPath $dir
}

function Get-RiceLevelText { param($Level) if ($Level -eq 'HighestAvailable' -or $Level -eq 'elevated') { 'elevated' } else { 'not elevated' } }

function Show-RiceTilingStatus {
    # Three answers that can disagree: what's saved, what komorebi's task will start it as,
    # and what's running now. The saved mode only reaches the task through install or
    # `tiling elevated|normal`, and the task only reaches komorebi at its next start.
    $saved   = Get-TilingMode
    $isSaved = Test-Path -LiteralPath (Get-TilingModePath)
    $task    = Get-ComponentTaskInfo -TaskName 'komorebi'
    $running = Get-ProcessElevation -Name 'komorebi'
    $taskText = if (-not $task) { 'none -- run `710sRice install` first' }
                else { "$(Get-RiceLevelText $task.RunLevel), $(if ($task.AtLogOn) { 'starts at sign-in' } else { 'on demand (no sign-in start)' })" }
    $runText  = switch ($running) {
        'elevated'    { 'elevated' }
        'normal'      { 'not elevated' }
        'not running' { 'not running' }
        default       { "couldn't tell" }
    }
    Write-Host ''
    Write-Host ('    {0,-20}{1}' -f 'Tiling mode:', "$saved$(if (-not $isSaved) { ' (the default)' })")
    Write-Host ('    {0,-20}{1}' -f "komorebi's task:", $taskText)
    Write-Host ('    {0,-20}{1}' -f 'Running komorebi:', $runText)
    Write-Host ''
    if ($task -and (Get-RiceLevelText $task.RunLevel) -ne (Get-RiceLevelText $saved)) {
        Step-Warn "komorebi's task doesn't match the saved mode -- ``710sRice tiling $saved`` re-registers it."
    } elseif ($task -and $running -in 'elevated', 'normal' -and (Get-RiceLevelText $running) -ne (Get-RiceLevelText $task.RunLevel)) {
        Step-Info 'Takes effect at komorebi''s next start: `710sRice restart` (or sign out and in).'
    }
}

function Set-RiceTilingMode {
    # `tiling elevated|normal` (already admin by now): save the mode, then re-register ONLY
    # komorebi's task, in the kind it already is -- sign-in (an -Activate'd machine) or on
    # demand. Same mode as before: say so and re-register anyway, which also repairs a task
    # that drifted from the saved mode. A running komorebi is left alone.
    param([ValidateSet('elevated', 'normal')][string]$Mode)
    $task = Get-ComponentTaskInfo -TaskName 'komorebi'
    if (-not $task) { throw 'komorebi has no scheduled task yet -- run `710sRice install` first. Nothing was changed.' }
    $before = Get-TilingMode
    $null = Resolve-TilingMode -Elevated:($Mode -eq 'elevated') -Normal:($Mode -eq 'normal')
    if ($before -eq $Mode) { Step-Info "Tiling mode is already $Mode -- re-registering komorebi's task to match anyway." }
    else { Step-Ok "Tiling mode: $before -> $Mode" }
    if ($task.AtLogOn) { Register-Autostart -Key 'komorebi' } else { Register-OnDemandTasks -Key 'komorebi' }
    $after = Get-ComponentTaskInfo -TaskName 'komorebi'
    if (-not $after -or (Get-RiceLevelText $after.RunLevel) -ne (Get-RiceLevelText $Mode)) {
        Write-RiceError "komorebi's task still isn't $Mode (see above). The saved mode is $Mode now, so ``710sRice tiling $Mode`` again retries just the task."
        $script:RiceExit = 1
        return
    }
    $running = Get-ProcessElevation -Name 'komorebi'
    if ($running -in 'elevated', 'normal' -and (Get-RiceLevelText $running) -ne (Get-RiceLevelText $Mode)) {
        Step-Info "komorebi is still running $(if ($running -eq 'elevated') { 'elevated' } else { 'non-elevated' }) -- the new mode takes effect at its next start: ``710sRice restart`` (or sign out and in)."
    }
}

# --- activate / deactivate: full time and on demand ---------------------------------------------
# The switch, both ways, on an installed machine (the user's decisions, 2026-10-03). The mode is
# never stored: Test-FullTimeMachine reads it from the tasks (any sign-in task, or a Startup-
# shortcut fallback). Rules:
#   - The tasks change LAST either way, so a switch cut off part-way still reads as the old mode,
#     and running it again finishes it -- from the same saved copy of your Windows settings, which
#     goes only once the way back is done.
#   - No Windows setting changes under a running stack: deactivate stops it first and leaves it
#     stopped; activate stops it, switches, and starts everything through the tasks.
#   - activate saves your Windows settings before changing them (Save-FullTimeSettings), only
#     when the machine isn't full-time yet; deactivate puts them back
#     (Restore-FullTimeWindowsSettings: the saved copy, else Windows' defaults -- uninstall's
#     own way back).
#   - Run in the mode it's already in, each says so and re-registers that mode's tasks (which
#     mends a mixed set) and changes nothing else -- except that deactivate still puts back a
#     copy left by an activate that didn't finish.
# install -Activate on a machine that isn't full-time yet makes the same switch (its tasks and
# windows steps), with its whole install run around it.

function Invoke-RiceSwitch {
    # `activate` / `deactivate` (admin by now): -DryRun, or nothing at all.
    $name = "$($args[0])"
    $dry = $false
    foreach ($a in @($args | Select-Object -Skip 1)) {
        if ("$a" -ieq '-DryRun') { $dry = $true; continue }
        Write-RiceError "Unknown option '$a' for $name"
        Show-RiceCommandHelp $name
        $script:RiceExit = 1
        return
    }
    . (Join-Path $Root 'tools\lib\activation.ps1')
    if ($name -eq 'activate') { Invoke-RiceActivate -DryRun:$dry } else { Invoke-RiceDeactivate -DryRun:$dry }
}

function Get-RiceSwitchTaskNames {
    # The components whose tasks the switch re-registers, as the dry run lists them.
    param([object[]]$Components)
    @($Components | ForEach-Object {
        if ($_.Key -eq 'komorebi') { "komorebi ($(if ((Get-KomorebiRunLevel) -eq 'HighestAvailable') { 'elevated' } else { 'non-elevated' }))" } else { $_.Key }
    }) -join ', '
}

function Stop-RiceStackForSwitch {
    # The stack goes down before any Windows setting changes (Stop-RunningComponents, uninstall's
    # and `710sRice stop`'s own). -Then finishes the line. $true when something was running.
    param([switch]$DryRun, [string]$Then = '')
    $running = @(Get-RunningStackNames)
    if (-not $running.Count) { Step-Info "The stack isn't running -- nothing to stop"; return $false }
    if ($DryRun) {
        Write-Host "  [ ] Stop the stack: $($running -join ', ') (Flow Launcher and Everything keep running)$Then"
        return $true
    }
    Stop-RunningComponents
    $left = @(Get-RunningStackNames)
    $stopped = @($running | Where-Object { $left -notcontains $_ })
    if ($stopped.Count) { Step-Ok "Stopped: $($stopped -join ', ') (Flow Launcher and Everything keep running)$Then" }
    $true
}

function Test-RiceSwitchInstalled {
    # Something of the stack's is installed: the switch has tasks to change. $false (and the run's
    # error line, exit 1) when nothing is.
    param([object[]]$Components)
    if ($Components.Count) { return $true }
    Write-RiceError "Nothing of 710sRice's is installed here (no komorebi, YASB, AutoHotkey, ShareX or Flow Launcher) -- run 710sRice install first. Nothing was changed."
    $script:RiceExit = 1
    $false
}

function Set-RiceSwitchLockScreen {
    # deactivate's last Windows setting: your lock-screen picture (the wallpaper) set again. The
    # put-back can hand Windows' lock screen back to Spotlight -- the hardening held its Picture
    # choice -- and Spotlight hides the picture (Win+L and the boot screen showed Windows' default
    # image on the Dell, 2026-10-03). The setter chooses Picture again (scripts\Set-LockScreen.ps1).
    param([switch]$DryRun)
    if ($DryRun) { Write-Host "  [ ] Set your lock-screen picture again (the wallpaper, with Windows' lock screen on Picture)"; return }
    Set-LockScreenToWallpaper
}

function Invoke-RiceActivate {
    # `activate`: on demand -> full-time. Save your Windows settings (once), stop the stack, apply
    # full time's settings, every task with its sign-in trigger, then start everything.
    param([switch]$DryRun)
    Write-Host "`n== 710sRice activate ==" -ForegroundColor Cyan
    if ($DryRun) { Step-Info 'DRY RUN: nothing will be changed.' }
    $components = @(Get-AutostartComponents -NoWrite)
    if (-not (Test-RiceSwitchInstalled $components)) { return }

    if (Test-FullTimeMachine) {
        Step-Info 'Already full-time: it starts at every sign-in.'
        Write-Host "`n-- Tasks --" -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "  [ ] Re-register the sign-in tasks as they are (puts back a trigger one has lost): $(Get-RiceSwitchTaskNames $components)"
            Write-Host ''
            Step-Info 'DRY RUN complete: nothing was changed.'
            return
        }
        Register-Autostart
        Write-RiceModeLines
        return
    }

    # 1. Your Windows settings as they are, saved before anything changes -- or a copy that's
    #    already here kept: an activate that didn't finish left it, and it's the real "before".
    Write-Host "`n-- Save your Windows settings --" -ForegroundColor Cyan
    $saved = Get-SavedFullTimeSettings
    if ($saved) {
        Step-Info "Keeping the copy saved $(Get-SavedFullTimeSettingsWhen $saved) -- it's how they were before (by a 710sRice activate that didn't finish)"
    } elseif ($DryRun) {
        Write-Host '  [ ] Save them as they are now (taskbar auto-hide, the hardening values, the Startup delay) -- 710sRice deactivate and uninstall put them back'
    } else {
        try {
            $null = Save-FullTimeSettings
            Step-Ok 'Saved as they are now (taskbar auto-hide, the hardening values, the Startup delay) -- 710sRice deactivate and uninstall put them back'
        } catch {
            Write-RiceError "Couldn't save your Windows settings ($($_.Exception.Message)) -- nothing was changed."
            $script:RiceExit = 1
            return
        }
    }

    # 2. The stack down. 3. Full time's Windows settings.
    Write-Host "`n-- Stack --" -ForegroundColor Cyan
    $null = Stop-RiceStackForSwitch -DryRun:$DryRun -Then ' -- it starts again at the end'
    Write-Host "`n-- Windows settings --" -ForegroundColor Cyan
    Set-FullTimeWindowsSettings -DryRun:$DryRun

    # 4. The tasks, last: they make it full-time.
    Write-Host "`n-- Tasks --" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "  [ ] Every task gets its sign-in trigger: $(Get-RiceSwitchTaskNames $components)"
        Write-Host '  [ ] Start the stack through its tasks'
        Write-Host ''
        Step-Info 'DRY RUN complete: nothing was changed. 710sRice activate does it.'
        return
    }
    Register-Autostart
    if (-not (Test-FullTimeMachine)) {
        Write-RiceError "Not full-time: no task starts at sign-in (see above). Full time's Windows settings are on and your own are saved; 710sRice activate again retries the tasks, and 710sRice start starts the stack meanwhile."
        $script:RiceExit = 1
        return
    }

    # 5. Everything started, through the tasks.
    Write-Host "`n-- Start --" -ForegroundColor Cyan
    Start-StackFromTasks
    Step-Info 'Chrome, the Claude app and other Chromium apps can pick up an extra title bar when the bar restarts -- focus the app and press SUPER+Ctrl+C to redraw it.'
    Write-RiceModeLines
}

function Invoke-RiceDeactivate {
    # `deactivate`: full-time -> on demand. Stop the stack, put your Windows settings back (the
    # saved copy, else Windows' defaults), every task without its sign-in trigger and the Startup
    # fallbacks gone -- then, once the machine reads on demand, the saved copy goes.
    param([switch]$DryRun)
    Write-Host "`n== 710sRice deactivate ==" -ForegroundColor Cyan
    if ($DryRun) { Step-Info 'DRY RUN: nothing will be changed.' }
    $components = @(Get-AutostartComponents -NoWrite)
    if (-not (Test-RiceSwitchInstalled $components)) { return }

    if (-not (Test-FullTimeMachine)) {
        Step-Info 'Already on demand: nothing starts at sign-in.'
        # A copy on an on-demand machine: an activate that didn't finish saved it (and may have
        # changed your settings). Finish the way back.
        $saved = Get-SavedFullTimeSettings
        if ($saved) {
            Write-Host "`n-- Windows settings --" -ForegroundColor Cyan
            Step-Info "A copy of your Windows settings saved $(Get-SavedFullTimeSettingsWhen $saved) is still here (by a 710sRice activate that didn't finish) -- putting them back."
            Restore-FullTimeWindowsSettings -DryRun:$DryRun
            Set-RiceSwitchLockScreen -DryRun:$DryRun
            if (-not $DryRun) { Remove-OriginalState -Label 'full-time-settings' }
        }
        Write-Host "`n-- Tasks --" -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "  [ ] Re-register the tasks with no sign-in trigger, as they are: $(Get-RiceSwitchTaskNames $components)"
            Write-Host ''
            Step-Info 'DRY RUN complete: nothing was changed.'
            return
        }
        Register-OnDemandTasks
        Write-RiceModeLines
        return
    }

    # 1. The stack down, and it stays down: on demand starts when you say.
    Write-Host "`n-- Stack --" -ForegroundColor Cyan
    $null = Stop-RiceStackForSwitch -DryRun:$DryRun -Then ' -- 710sRice start brings it back'

    # 2. Your Windows settings back, and your lock-screen picture with them.
    Write-Host "`n-- Windows settings --" -ForegroundColor Cyan
    Restore-FullTimeWindowsSettings -DryRun:$DryRun
    Set-RiceSwitchLockScreen -DryRun:$DryRun

    # 3. The tasks, last: without their sign-in trigger the machine is on demand.
    Write-Host "`n-- Tasks --" -ForegroundColor Cyan
    $startup = [Environment]::GetFolderPath('Startup')
    $lnks = @(if ($startup) { Get-ChildItem -LiteralPath $startup -Filter '710.DesktopRice *.lnk' -File -ErrorAction SilentlyContinue })
    if ($DryRun) {
        Write-Host "  [ ] Every task loses its sign-in trigger (710sRice start still starts them all): $(Get-RiceSwitchTaskNames $components)"
        if ($lnks.Count) { Write-Host "  [ ] Remove 710.DesktopRice's Startup-folder shortcut$(if ($lnks.Count -gt 1) { 's' }) ($($lnks.Count))" }
        Write-Host ''
        Step-Info 'DRY RUN complete: nothing was changed. 710sRice deactivate does it.'
        return
    }
    Register-OnDemandTasks
    if ($lnks.Count) {
        Remove-StartupShortcuts
        Step-Ok "Startup-folder shortcut$(if ($lnks.Count -gt 1) { 's' }) removed ($($lnks.Count))"
    }
    $still = @((Get-AutostartStatus).GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })
    if ($still.Count) {
        Write-RiceError "Still full-time: $($still -join ', ') still start$(if ($still.Count -eq 1) { 's' }) at sign-in (see above). Your Windows settings are back; 710sRice deactivate again retries the rest."
        $script:RiceExit = 1
        return
    }
    Remove-OriginalState -Label 'full-time-settings'
    Write-RiceModeLines
}

# --- Admin: reopen in an admin window ------------------------------------------------------------
function Test-RiceAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-RiceArgument {
    # One argument back into command-line text for the admin relaunch. An array (-Keep A,B typed
    # at a PS7 prompt, running in place) goes over as A,B -- uninstall.ps1 splits it again.
    # Quoted only when it has to be, with the usual backslash-before-quote rules.
    $v = $args[0]
    $s = if ($v -is [array]) { ($v | ForEach-Object { "$_" }) -join ',' } else { "$v" }
    if ($s -ne '' -and $s -notmatch '[\s"]') { return $s }
    '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-RiceElevated {
    # $args = the command line as typed, command name first. Opens a new admin window running
    # this same file with it (one UAC prompt), waits, and passes its exit code on. `pwsh` by
    # name, not this process's own path: the Store build lives in WindowsApps, whose exes
    # can't always be started directly -- the alias on PATH can.
    $typed    = @($args | ForEach-Object { ConvertTo-RiceArgument $_ })
    $display  = $typed -join ' '
    $argLine  = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Root '710sRice.ps1')`" --elevated $display"
    Write-Host "  [..] Needs admin -- running '$display' in a new admin window (UAC)..." -ForegroundColor Cyan
    try {
        $p = Start-Process -FilePath 'pwsh' -ArgumentList $argLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        # A declined UAC prompt is ERROR_CANCELLED (1223) somewhere in the exception chain.
        $cancelled = $false
        for ($e = $_.Exception; $e; $e = $e.InnerException) {
            if ($e -is [System.ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1223) { $cancelled = $true }
        }
        if ($cancelled -or $_.Exception.Message -match 'canceled by the user') {
            throw 'Needs admin rights and UAC was declined -- nothing was changed.'
        }
        throw "Couldn't open an admin window: $($_.Exception.Message)"
    }
    $script:RiceExit    = $p.ExitCode
    $script:RiceRelayed = $true   # the output is over there, so this window doesn't wait for Enter
    $color = if ($p.ExitCode -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host "  [$(if ($p.ExitCode -eq 0) { 'OK' } else { '!!' })] Admin window finished (exit $($p.ExitCode))" -ForegroundColor $color
}

function Get-RiceAdminTag { param($Command) if ($Command.Admin -eq 'Required' -or $Command.AsksAdmin) { '   (admin)' } else { '' } }

function Show-RiceHelp {
    $col = 26
    Write-Host ''
    Write-Host '  710sRice -- komorebi + YASB + AutoHotkey + Flow Launcher, from one command'
    Write-Host ''
    Write-Host '  USAGE: 710sRice <command> [options]      <command> -?  shows its options'
    Write-Host ''
    foreach ($name in $Commands.Keys) {
        $c = $Commands[$name]
        if ($c.Hidden) { continue }
        $tag = Get-RiceAdminTag $c
        if ($c.Usage.Length -lt $col) {
            Write-Host ('    {0}{1}{2}' -f $c.Usage.PadRight($col), $c.Help, $tag)
        } else {
            # Long usage (install's switches): usage on its own line, help under it.
            Write-Host "    $($c.Usage)$tag"
            Write-Host ('    {0}{1}' -f ''.PadRight($col), $c.Help)
        }
    }
    Write-Host ''
}

function Show-RiceCommandHelp {
    param([string]$Name)
    $c = $Commands[$Name]
    Write-Host ''
    Write-Host "  710sRice $($c.Usage)$(Get-RiceAdminTag $c)"
    Write-Host "    $($c.Help)"
    if ($c.More) { Write-Host "    $(if ($c.More -is [scriptblock]) { & $c.More } else { $c.More })" }
    Write-Host ''
}

# --- "Press Enter to close" ---------------------------------------------------------------------
# Only when this console window was opened just for this command, so it would vanish the moment
# we exit: the Run dialog / an Explorer double-click (cmd /c -> us). Nowhere else -- an open
# terminal stays as it is. Cheapest checks first, because the full check (Add-Type ~0.3-0.6 s,
# plus a CIM query) would otherwise tax every command typed in PS7, the one documented path.
#
#   PS7 window               your pwsh -> cmd /c -> us     3 on the console   no prompt
#   Windows PowerShell 5.1   powershell -> cmd /c -> us    3                  no prompt
#   an open cmd window       interactive cmd -> us         2                  no prompt
#   Run dialog / Explorer    cmd /c -> us                  2                  PROMPT
#   .\710sRice.ps1 in PS7    runs inside your pwsh         1                  no prompt
#
# A count alone can't do it: 2 is the Run dialog OR an open cmd window (only that cmd's /c tells
# them apart), and 1 is a window made for us OR .\710sRice.ps1 running inside your own shell.

function Get-ConsoleProcessIds {
    if (-not ('TenSeven.Native.ConsoleList' -as [type])) {
        Add-Type -Namespace TenSeven.Native -Name ConsoleList -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint GetConsoleProcessList(uint[] processList, uint processCount);
'@
    }
    $buf = [uint32[]]::new(16)
    $n = [TenSeven.Native.ConsoleList]::GetConsoleProcessList($buf, $buf.Length)
    if ($n -gt $buf.Length) {
        $buf = [uint32[]]::new($n)
        $n = [TenSeven.Native.ConsoleList]::GetConsoleProcessList($buf, $buf.Length)
    }
    if ($n -eq 0) { throw 'no console attached' }
    @($buf[0..($n - 1)])
}

function Test-LaunchedForUs {
    # Our own process was started to run this file (the shim's `pwsh -File ...\710sRice.ps1`),
    # rather than this file running inside someone's interactive shell. Free: no query at all.
    $argv = [Environment]::GetCommandLineArgs()
    for ($i = 1; $i -lt $argv.Count - 1; $i++) {
        if ($argv[$i] -in '-File', '-f' -and $argv[$i + 1] -like '*710sRice.ps1') { return $true }
    }
    $false
}

function Test-RiceOwnConsole {
    try {
        if ([Console]::IsInputRedirected) { return $false }
        # 0. The admin relaunch: always a window of its own, and the output lives only there.
        if ($script:RiceElevatedRun) { return $true }
        # 1. Running inside someone's shell: that window is theirs.
        if (-not (Test-LaunchedForUs)) { return $false }
        # 2. Typed in a PS7 / Windows PowerShell window: parent cmd /c, grandparent the shell.
        #    PS7's Process.Parent is a cheap native lookup (~20 ms), no CIM.
        $parent = (Get-Process -Id $PID).Parent
        if ($parent -and $parent.ProcessName -eq 'cmd') {
            $grand = $parent.Parent
            if ($grand -and $grand.ProcessName -in 'pwsh', 'powershell') { return $false }
        }
        # 3. Everything else (Run dialog, an open cmd window, anything odd): who else is here?
        $others = @(Get-ConsoleProcessIds | Where-Object { $_ -ne $PID })
        if ($others.Count -eq 0) { return $true }     # a window made for us alone
        if ($others.Count -ge 2) { return $false }    # a shell, and more
        # Exactly one other: a cmd that is either our /c runner (Run dialog) or an interactive
        # cmd someone typed the command into. Its first /c or /k switch decides.
        $cl = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($others[0])").CommandLine
        $m = [regex]::Match("$cl", '(?i)(?:^|\s)/([ck])')
        return ($m.Success -and $m.Groups[1].Value -eq 'c')
    } catch {
        return $false   # can't tell: never trap someone in a prompt
    }
}

function Wait-RiceClose {
    Write-Host ''
    Write-Host '  Press Enter to close' -NoNewline -ForegroundColor DarkGray
    $null = [Console]::ReadLine()
}

# --- Dispatch -------------------------------------------------------------------------------------
$script:RiceExit        = 0
$script:RiceRelayed     = $false
$script:RiceElevatedRun = $false
try {
    $argv = $args   # no cast: the switch marks must survive (see the header)
    # The admin relaunch marks itself with a leading --elevated (never typed by a person).
    if ($argv.Count -ge 1 -and "$($argv[0])" -eq '--elevated') {
        $script:RiceElevatedRun = $true
        $argv = @($argv | Select-Object -Skip 1)
    }
    $first = if ($argv.Count -ge 1) { "$($argv[0])".ToLowerInvariant() } else { '' }

    if ($first -eq '' -or $first -in $HelpFlags) {
        Show-RiceHelp
    } else {
        $name = $null
        $skip = 0
        if ($argv.Count -ge 2) {
            $two = "$first $("$($argv[1])".ToLowerInvariant())"
            if ($Commands.Contains($two)) { $name = $two; $skip = 2 }
        }
        if (-not $name -and $Commands.Contains($first)) { $name = $first; $skip = 1 }

        if (-not $name) {
            Write-RiceError "Unknown command '$($argv[0])'"
            Show-RiceHelp
            $script:RiceExit = 1
        } else {
            $rest = @($argv | Select-Object -Skip $skip)
            if (@($rest | Where-Object { "$_" -in $HelpFlags }).Count) {
                Show-RiceCommandHelp $name
            } elseif ($Commands[$name].Admin -eq 'Required' -and -not (Test-RiceAdmin)) {
                # Never relaunch from a relaunch: if the admin window somehow isn't admin, stop
                # here rather than asking for UAC again and again.
                if ($script:RiceElevatedRun) { throw 'The admin window did not get admin rights -- nothing was changed.' }
                Invoke-RiceElevated @argv
                # The very first install is `.\710sRice.ps1 install` typed in a normal window, so
                # this file is running inside that window: put bin\ on its PATH too, and
                # `710sRice` works there straight away (install did the same in the admin one).
                if ($name -eq 'install' -and $script:RiceExit -eq 0 -and -not (Test-LaunchedForUs)) {
                    $bin = Join-Path $Root 'bin'
                    if (-not @(("$env:Path" -split ';') | Where-Object { $_.TrimEnd('\') -eq $bin })) {
                        $env:Path = "$("$env:Path".TrimEnd(';'));$bin"
                        Write-Host '  [OK] 710sRice works in this window now too.' -ForegroundColor Green
                    }
                }
            } else {
                & $Commands[$name].Run @rest
            }
        }
    }
} catch {
    Write-RiceError $_.Exception.Message
    $script:RiceExit = 1
}

# After an admin relaunch the output is in the admin window, which waits for Enter itself.
if (-not $script:RiceRelayed -and (Test-RiceOwnConsole)) { Wait-RiceClose }
exit $script:RiceExit
