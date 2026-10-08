<#
.SYNOPSIS
  710sRice's "Press Enter to close": whether this console window was opened just for the command
  (Test-RiceOwnConsole), so the window waits for Enter before it goes (Wait-RiceClose);
  Test-LaunchedForUs also tells the dispatcher's first install whether it runs inside your own
  shell. Dot-sourced by 710sRice.ps1 at its start, and only there: it reads the dispatcher's
  $script:RiceElevatedRun. Only functions.
#>

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
