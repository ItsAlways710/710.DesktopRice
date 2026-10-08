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
  things through komorebi's and 710.ahk's own scheduled tasks, which carry their own run
  level, or by asking the running 710.ahk (the bar, Flow Launcher and ShareX -- only it starts
  those), so they're safe from any window (see claude/cli-plan.md).

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
# "Press Enter to close" (tools\lib\console.ps1): every run ends with its check. Only functions.
. (Join-Path $Root 'tools\lib\console.ps1')

# --- The commands -----------------------------------------------------------------------------
# One row per command, shown in help in this order. The name is one word or two ('reload bar'
# beats 'reload': the dispatcher tries the first two words before the first one). Usage is the
# help line's left side; Admin is 'Required' (the command asks for UAC itself) or 'Any'; Run gets
# the arguments that follow the name, with their switch marks intact. Hidden rows work but
# stay out of the help list (bare `tiling` = `tiling status`). AsksAdmin tags a row that runs as
# you but asks for UAC part-way (update's repair) with (admin) in help, like a Required row.
# NoOptions: the command takes none -- the main block refuses anything after it (before any UAC).
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
    # admin window can register it. Invoke-RiceSwitch: tools\lib\switch.ps1, loaded only here.
    'activate'   = @{ Usage = 'activate [-DryRun]'; Help = 'Full-time: it starts at every sign-in, hides the taskbar, turns off Windows'' tips and ads'; Admin = 'Required'
                      Run = { . (Join-Path $Root 'tools\lib\switch.ps1'); Invoke-RiceSwitch 'activate' @args } }
    'deactivate' = @{ Usage = 'deactivate [-DryRun]'; Help = 'On demand: nothing at sign-in; your taskbar and Windows settings back as they were'; Admin = 'Required'
                      Run = { . (Join-Path $Root 'tools\lib\switch.ps1'); Invoke-RiceSwitch 'deactivate' @args } }
    # doctor: read-only, any window. Its checks live in tools\lib\doctor.ps1, loaded only here;
    # the exit code is the number of problems ([XX]) it found.
    'doctor'    = @{ Usage = 'doctor'; Help = 'Health check -- each problem names the command that fixes it (changes nothing)'; Admin = 'Any'; NoOptions = $true
                     Run = {
                         . (Join-Path $Root 'tools\lib\activation.ps1')
                         . (Join-Path $Root 'tools\lib\doctor.ps1')
                         $script:RiceExit = Invoke-RiceDoctor
                     } }
    # doctor -repair: doctor's checks, then the fix behind every [XX] that doesn't need you
    # (tools\lib\repair.ps1, loaded only here; it runs restart, reload and reload bar, so their
    # stack-commands.ps1 too), then the checks again. Admin: one UAC prompt, the work happens in
    # the admin window. Exit code = the problems left.
    # ALSO update's hand-off (tools\lib\update.ps1): every update's first half, however old,
    # starts `710sRice.ps1 --elevated doctor -repair` or `710sRice.ps1 doctor -repair` from the
    # files it just pulled -- keep this row's name and the --elevated marker working, always.
    'doctor -repair' = @{ Usage = 'doctor -repair'; Help = 'Fix what doctor finds -- never your wallpaper, theme or choices'; Admin = 'Required'; NoOptions = $true
                     Run = {
                         . (Join-Path $Root 'tools\lib\activation.ps1')
                         . (Join-Path $Root 'tools\lib\doctor.ps1')
                         . (Join-Path $Root 'tools\lib\stack-commands.ps1')
                         . (Join-Path $Root 'tools\lib\repair.ps1')
                         $script:RiceExit = Invoke-RiceRepair
                     } }
    # update: pull as you (tools\lib\update.ps1 -- loaded here, BEFORE the pull; nothing is loaded
    # after it), then doctor -repair in a new process started from the pulled files. The row runs
    # in any window; the repair asks for UAC itself (AsksAdmin: help says (admin)).
    'update'    = @{ Usage = 'update'; Help = 'Get the newest version from GitHub, then repair -- keeps your wallpaper, theme and choices'; Admin = 'Any'; AsksAdmin = $true; NoOptions = $true
                     Run = {
                         . (Join-Path $Root 'tools\lib\activation.ps1')
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
    # restart (stop + start, with a wait in between), reload and reload bar:
    # tools\lib\stack-commands.ps1. It and activation.ps1 (Send-AhkMessage, Find-AhkWindow) are
    # loaded here, not at the top, so the other commands -- help above all -- don't pay for
    # parsing them. Dot-sourced into this block's scope, which the command runs inside of.
    'restart'   = @{ Usage = 'restart'; Help = 'Stop the stack, then start it again (= SUPER+Ctrl+R; SUPER+Shift+R only reloads)'; Admin = 'Any'
                     Run = { . (Join-Path $Root 'tools\lib\activation.ps1'); . (Join-Path $Root 'tools\lib\stack-commands.ps1'); Invoke-RiceRestart } }
    'reload'    = @{ Usage = 'reload'; Help = 'Reload the whole stack (same as SUPER+Shift+R)'; Admin = 'Any'
                     Run = { . (Join-Path $Root 'tools\lib\activation.ps1'); . (Join-Path $Root 'tools\lib\stack-commands.ps1'); Invoke-RiceReload } }
    'reload bar' = @{ Usage = 'reload bar'; Help = 'Restart just the bar (YASB)'; Admin = 'Any'
                     Run = { . (Join-Path $Root 'tools\lib\activation.ps1'); . (Join-Path $Root 'tools\lib\stack-commands.ps1'); Invoke-RiceReloadBar } }
    'logs'      = @{ Usage = 'logs'; Help = 'Open the logs folder (and list what''s in it)'; Admin = 'Any'
                     Run = { . (Join-Path $Root 'tools\lib\logs.ps1'); Show-RiceLogs } }
    # palette: the palette profiles (tools\lib\palette.ps1) and the four commands
    # (tools\lib\palette-commands.ps1), both loaded only here. Any window: a switch goes through
    # the wallpaper pipeline (apply-wallust-outputs.ps1 -ProfileId), which keeps the old choice
    # when the new profile's palette can't be made.
    'palette'     = @{ Usage = 'palette'; Help = 'List the palette profiles (SUPER+Alt+Space > Palette profiles)'; Admin = 'Any'; NoOptions = $true
                       Run = { . (Join-Path $Root 'tools\lib\palette.ps1'); . (Join-Path $Root 'tools\lib\palette-commands.ps1'); Show-RicePalettes } }
    'palette use' = @{ Usage = 'palette use <profile>'; Help = 'Theme everything with that profile now (default, 0-9 or its name)'; Admin = 'Any'
                       Run = { . (Join-Path $Root 'tools\lib\palette-commands.ps1'); Invoke-RicePaletteUse @args } }
    # The editor is a window of its own (tools\palette-editor.ps1, hidden pwsh -STA): these start
    # it and come back as soon as it's up, so the prompt is free again.
    'palette edit' = @{ Usage = 'palette edit [<profile>]'; Help = 'Open the palette profile editor on the one in use (or that profile)'; Admin = 'Any'
                        Run = { . (Join-Path $Root 'tools\lib\palette-commands.ps1'); Invoke-RicePaletteEditor 'edit' @args } }
    'palette new'  = @{ Usage = 'palette new [<from>]'; Help = 'Create a palette profile in the editor, starting from the one in use (or <from>)'; Admin = 'Any'
                        Run = { . (Join-Path $Root 'tools\lib\palette-commands.ps1'); Invoke-RicePaletteEditor 'new' @args } }
    # tiling (tools\lib\tiling.ps1, which activation.ps1 loads): the saved mode (tiling-mode.txt)
    # and komorebi's task only -- never install's theme reset. Changing it needs admin: an
    # elevated task can only be registered, or a task an admin window made replaced, from an
    # admin window.
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
            } elseif ($Commands[$name].NoOptions -and $rest.Count) {
                Write-RiceError "Unknown option '$($rest[0])' for $name"
                Show-RiceCommandHelp $name
                $script:RiceExit = 1
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
