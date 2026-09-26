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
  Nothing that STARTS the stack needs that: start goes through the sign-in tasks, which carry
  their own run level, so it's safe from any window (see claude/cli-plan.md).

  Exit codes: help 0; unknown command, an error or a declined UAC prompt 1; otherwise the
  called script's own (relayed from the admin window when it ran there).

  Never run this hidden (AHK, scheduled tasks). When its window was opened just for it (the
  Run dialog, an Explorer double-click, the elevated relaunch) it ends with "Press Enter to
  close" -- in a hidden window that waits forever. Hidden callers use the scripts directly.

.EXAMPLE
  710sRice                            # the command list
  710sRice install -?                 # one command's usage
  .\710sRice.ps1 install -Activate    # the very first install, from the repo folder
  710sRice uninstall -DryRun -Keep AutoHotkey.AutoHotkey,ShareX.ShareX
#>
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# --- The commands -----------------------------------------------------------------------------
# One row per command, shown in help in this order. The name is one word or two ('reload bar'
# beats 'reload': the dispatcher tries the first two words before the first one). Usage is the
# help line's left side; Admin is 'Required' (the command asks for UAC itself) or 'Any'; Run gets
# the arguments that follow the name, with their switch marks intact.
$Commands = [ordered]@{
    'help'      = @{ Usage = 'help'; Help = 'Show this list'; Admin = 'Any'
                     Run = { Show-RiceHelp } }
    'install'   = @{ Usage = 'install [-Activate] [-SkipPackages] [-ElevatedTiling | -NoElevatedTiling]'
                     Help = 'Install or update (safe to re-run); -Activate = start it at every sign-in'; Admin = 'Required'
                     Run = { Invoke-RiceScript 'install.ps1' @args } }
    'uninstall' = @{ Usage = 'uninstall [-DryRun] [-Force] [-Keep <id>,<id>...]'
                     Help = 'Undo everything install did; -DryRun shows the plan first'; Admin = 'Required'
                     Run = { Invoke-RiceScript 'uninstall.ps1' @args } }
    'start'     = @{ Usage = 'start'; Help = 'Start the stack'; Admin = 'Any'
                     Run = { Invoke-RiceScript 'scripts\Start-All.ps1' @args } }
    'stop'      = @{ Usage = 'stop'; Help = 'Stop the stack'; Admin = 'Any'
                     Run = { Invoke-RiceScript 'scripts\Stop-All.ps1' @args } }
}

# Anywhere after a command these mean "tell me about it" -- never run it, never elevate.
$HelpFlags = @('-h', '-?', '/?', '--help')

function Write-RiceError { param([string]$Message) Write-Host "  [XX] $Message" -ForegroundColor Red }

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

function Get-RiceAdminTag { param($Command) if ($Command.Admin -eq 'Required') { '   (admin)' } else { '' } }

function Show-RiceHelp {
    $col = 26
    Write-Host ''
    Write-Host '  710sRice -- komorebi + YASB + AutoHotkey + Flow Launcher, from one command'
    Write-Host ''
    Write-Host '  USAGE: 710sRice <command> [options]      <command> -?  shows its options'
    Write-Host ''
    foreach ($name in $Commands.Keys) {
        $c = $Commands[$name]
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
