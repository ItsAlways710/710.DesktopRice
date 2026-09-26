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

  Exit codes: help 0; unknown command or an error 1; otherwise the called script's own.

  Never run this hidden (AHK, scheduled tasks). When its window was opened just for it (the
  Run dialog, an Explorer double-click, the elevated relaunch) it ends with "Press Enter to
  close" -- in a hidden window that waits forever. Hidden callers use the scripts directly.

.EXAMPLE
  710sRice                 # the command list
  710sRice help -?         # one command's usage
#>
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# --- The commands -----------------------------------------------------------------------------
# One row per command, shown in help in this order. The name is one word or two ('reload bar'
# beats 'reload': the dispatcher tries the first two words before the first one). Usage is the
# help line's left side; Admin is 'Required' (the command asks for UAC itself) or 'Any'; Run gets
# the arguments that follow the name, with their switch marks intact.
$Commands = [ordered]@{
    'help' = @{ Usage = 'help'; Help = 'Show this list'; Admin = 'Any'; Run = { Show-RiceHelp } }
}

# Anywhere after a command these mean "tell me about it" -- never run it, never elevate.
$HelpFlags = @('-h', '-?', '/?', '--help')

function Write-RiceError { param([string]$Message) Write-Host "  [XX] $Message" -ForegroundColor Red }

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
$script:RiceExit = 0
try {
    $argv  = $args   # no cast: the switch marks must survive (see the header)
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
            } else {
                & $Commands[$name].Run @rest
            }
        }
    }
} catch {
    Write-RiceError $_.Exception.Message
    $script:RiceExit = 1
}

if (Test-RiceOwnConsole) { Wait-RiceClose }
exit $script:RiceExit
