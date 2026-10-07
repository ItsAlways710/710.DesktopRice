<#
.SYNOPSIS
  710sRice's scheduled tasks, through schtasks.exe: their folder and names, whether one exists, its
  XML, what one is registered to run, the hidden launch every task program goes through
  (run-hidden.vbs), and Start-AsUser (an app started as you, not elevated, through a one-shot
  task). Loaded by tools\lib\activation.ps1. Functions, and the task folder's name.
#>

# schtasks.exe (native), not the ScheduledTasks module: that module's CIM/MI subsystem is
# broken on some machines ("type initializer for 'Microsoft.Management.Infrastructure.
# Native...'"). schtasks.exe never touches that layer. Ported from winarchy's Autostart.ps1
# @ 4574fc7.
$script:TaskFolder = '710.DesktopRice'

function Get-TaskFullName {
    param([Parameter(Mandatory)][string]$TaskName)
    "\$script:TaskFolder\$TaskName"
}

function Test-Task {
    <# -AtLogOn: only a task that actually starts at sign-in counts. That's what "this
       machine is -Activate'd" means -- an on-demand install has a task for every
       component too (Register-OnDemandTasks, no trigger), and without this check a later
       plain install.ps1 would read them as "autostart is active" and quietly register
       everything to start at sign-in (plan doc Open item 37). #>
    param([Parameter(Mandatory)][string]$TaskName, [switch]$AtLogOn)
    # $null = ... 2>&1 (capture-and-discard), not *> $null (redirect-and-discard): the
    # latter doesn't fully suppress schtasks.exe's own "ERROR: ..." text for a genuinely
    # missing task -- found live tonight when toolspply-wallust-outputs.ps1's own copy
    # of this exact check (same *> $null) leaked that text to the console the first time
    # all night it ever queried a task that truly didn't exist yet. Every earlier call to
    # this function happened to query a task that already existed, so the leak was never
    # actually exercised here until now.
    $full = Get-TaskFullName -TaskName $TaskName
    if ($AtLogOn) {
        $xml = & schtasks.exe /Query /TN $full /XML 2>&1
        return ($LASTEXITCODE -eq 0) -and (($xml -join "`n") -match '<LogonTrigger>')
    }
    $null = & schtasks.exe /Query /TN $full 2>&1
    $LASTEXITCODE -eq 0
}

function New-TaskXml {
    <# At-LogOn trigger (per-component Delay), InteractiveToken + LeastPrivilege principal
       (no elevation, interactive session only), IgnoreNew multiple-instances policy, no
       execution time limit, Normal priority. Ported from New-WinarchyTaskXml.
       <Priority>4</Priority> ported from winarchy 2d8c910 (v1.5.0): Task Scheduler's
       default is 7, which starts the task's process at BelowNormal -- and Windows hands
       BelowNormal down to child processes that don't ask for a class, so through our
       wscript -> powershell -> launcher chain komorebi/YASB/AHK all came up BelowNormal
       (winarchy saw delayed retiles under load from exactly this). 4 = Normal. #>
    # -RunLevel HighestAvailable: komorebi in elevated tiling mode (Get-KomorebiRunLevel).
    # -NoTrigger: an on-demand task that never fires on its own -- Start-All.ps1 and
    # reload-stack.ps1 fire it (Register-OnDemandTasks), Start-AsUser runs its one-shot.
    # Labelled "on demand" rather than "autostart" in Task Scheduler, so the list doesn't lie.
    param([Parameter(Mandatory)][object]$Component, [Parameter(Mandatory)][string]$User,
          [ValidateSet('LeastPrivilege', 'HighestAvailable')][string]$RunLevel = 'LeastPrivilege',
          [switch]$NoTrigger)
    $u = [System.Security.SecurityElement]::Escape($User)
    $cmd = [System.Security.SecurityElement]::Escape($Component.Exe)
    # No arguments = no <Arguments> element (a GUI exe may take none -- Start-AsUser's Flow).
    $argLine = if ("$($Component.Arguments)") { "`n      <Arguments>$([System.Security.SecurityElement]::Escape($Component.Arguments))</Arguments>" } else { '' }
    $delay = if ($Component.Delay) { $Component.Delay } else { 'PT0S' }
    $label = if ($NoTrigger) { 'on demand' } else { 'autostart' }
    $triggers = if ($NoTrigger) { '  <Triggers />' } else { @"
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$u</UserId>
      <Delay>$delay</Delay>
    </LogonTrigger>
  </Triggers>
"@ }
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>710.DesktopRice ${label}: $($Component.Key)</Description>
  </RegistrationInfo>
$triggers
  <Principals>
    <Principal id="Author">
      <UserId>$u</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>$RunLevel</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>4</Priority>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmd</Command>$argLine
    </Exec>
  </Actions>
</Task>
"@
}

function ConvertTo-HiddenLaunch {
    <# Rewraps an Exe/Arguments pair so the Scheduled Task launches it via
       tools\lib\run-hidden.vbs (WScript.Shell.Run, windowStyle 0) instead of directly. Used
       by the component tasks (Get-AutostartComponents). (The elevated lock-screen-sync task
       started this way too, 2026-09-27 until it was retired on 09-28: Remove-RetiredLockScreenSync.)

       Why: Task Scheduler launching a console-subsystem host (powershell.exe) directly
       with -WindowStyle Hidden still briefly flashes a console at every logon -- confirmed
       live on Dell, 3-4 flashes at boot (one per powershell-hosted autostart component
       below). Windows allocates the console as part of process creation, before
       PowerShell's own startup code has run far enough to read -WindowStyle and hide
       itself -- a well-documented Task Scheduler + PowerShell race, not specific to this
       repo. wscript.exe (unlike cscript.exe) never allocates a console at all, so there's
       nothing to flash; its WScript.Shell.Run requests the hidden window style up front,
       as part of creating the process, not as a hide-after-the-fact race. See
       run-hidden.vbs's own header for the full writeup, including why this is NOT the same
       technique winarchy tried and reverted for komorebi (`conhost --headless`, git log
       d52e515/f088211 -- that killed the child process outright when its detached host
       exited; this script doesn't host/attach the child's console at all).

       Real bug found and fixed 2026-09-23: the original version tried to carry Exe/
       Arguments on run-hidden.vbs's own command line, backslash-escaping embedded double
       quotes ("same convention Win32 command-line parsing already uses"). That assumption
       was never actually verified against WSH's real parser and was wrong -- confirmed
       live via a real run-hidden.log entry plus a byte-exact `od -c` dump: WSH's
       command-line parser does NOT support backslash-escaped quotes; `\"` comes through as
       a literal backslash plus an ORDINARY (unescaped) quote-toggle, not a literal `"`. A
       quoted -File path arrived at powershell.exe mangled
       (`\C:\710.DesktopRice\...\Start-Komorebi.ps1\` -- stray leading/trailing backslashes,
       no quotes at all), which powershell.exe can't resolve as a path -- it failed
       silently, every time this ran for real, including the very scheduled runs this
       feature was supposedly validated against. Task Scheduler still reported Last Result
       0 (that's wscript.exe's own exit code, unaffected -- see run-hidden.vbs's header) and
       the launched script never got far enough to write even its first log line, so this
       had no visible symptom other than "komorebi just isn't running" after logon.

       Fixed by not putting Exe/Arguments on run-hidden.vbs's command line at all: they're
       written to a small two-line plain-text spec file instead (line 1 = Exe, line 2 =
       Arguments, exactly as originally composed, no escaping needed), and only that file's
       own path -- a plain, quote-free, backslash-free-at-the-end Windows path -- is passed
       as run-hidden.vbs's one argument. This sidesteps WSH's command-line parsing for the
       payload entirely; nothing about it needs to be "quoted correctly" for WSH anymore.
       Written once here, at registration/-Activate time; read fresh by run-hidden.vbs on
       every actual fire, including ones long after this PowerShell process has exited (a
       reboot days later, etc.), so it has to be static/persistent, not a live variable --
       same %LOCALAPPDATA%\710.DesktopRice\ folder every other autostart log/state file
       already lives in. #>
    # -NoWrite: work out the same answer without writing the spec file -- `710sRice doctor`
    # compares it with the registered task and the file on disk, and writes nothing.
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Arguments,
        [switch]$NoWrite
    )
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $vbs = Join-Path $Root 'tools\lib\run-hidden.vbs'
    $specDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
    $spec = Join-Path $specDir "launch-$Key.txt"
    if (-not $NoWrite) {
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
        # ASCII, no BOM -- every value written here is a plain Windows path or powershell.exe
        # flag, so there's nothing here that needs Unicode; a BOM would otherwise land as a
        # stray leading character on run-hidden.vbs's own ForReading (ASCII/ANSI) ReadLine.
        Set-Content -LiteralPath $spec -Value @($Exe, $Arguments) -Encoding ASCII
    }
    [pscustomobject]@{
        Exe       = $wscript
        Arguments = "//B `"$vbs`" `"$spec`""
        Spec      = $spec
        SpecLines = @($Exe, $Arguments)
    }
}

function Get-ComponentTaskInfo {
    <# A component's task as registered: $null when there is none, else AtLogOn (it has a
       sign-in trigger -- an -Activate'd machine; an on-demand install's tasks have none),
       RunLevel ('HighestAvailable' = runs elevated, 'LeastPrivilege'), Enabled (not switched
       off in Task Scheduler), and the Command / Arguments it runs (`710sRice doctor` compares
       them with what install would register now). Read from `schtasks /Query /XML`, like
       Test-Task -AtLogOn, so it works from a normal window too. #>
    param([Parameter(Mandatory)][string]$TaskName)
    $xml = & schtasks.exe /Query /TN (Get-TaskFullName -TaskName $TaskName) /XML 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = $xml -join "`n"
    $runLevel = if ($text -match '<RunLevel>(\w+)</RunLevel>') { $Matches[1] } else { 'LeastPrivilege' }
    # The XML's own UTF-16 declaration means nothing to an already-decoded string -- dropped
    # before parsing. Element access by name ignores the task namespace.
    $doc = $null
    try { $doc = [xml]($text -replace '^\s*<\?xml[^>]*\?>', '') } catch { }
    $exec = if ($doc) { @($doc.Task.Actions.Exec)[0] } else { $null }
    [pscustomobject]@{
        AtLogOn   = ($text -match '<LogonTrigger>')
        RunLevel  = $runLevel
        Enabled   = -not ($doc -and "$($doc.Task.Settings.Enabled)".Trim() -eq 'false')
        Command   = if ($exec) { "$($exec.Command)" } else { $null }
        Arguments = if ($exec) { "$($exec.Arguments)" } else { $null }
    }
}

function Start-AsUser {
    <# Starts an app as the signed-in user, NOT elevated, from an elevated install / uninstall /
       repair (Group 1 #12's rule: a component never starts an app from there itself -- it
       would run as admin, like the "ShareX running as admin" doctor already flags). The same
       trick as Restart-Explorer and Invoke-WingetAsUser: a one-shot task, here written with
       New-TaskXml (LeastPrivilege, interactive, Normal priority -- a plain `schtasks /SC ONCE`
       task starts its process BelowNormal, and the app would keep that), fired, then deleted
       once the app has started (deleting a task leaves the process it started running).
       -Process: the process name to wait for -- a NEW one (a copy already running doesn't
       count); without it, it waits for Task Scheduler to report the task started.
       Returns $true once the app has started, $false if it didn't within -TimeoutSeconds
       (or the task couldn't be made). Never throws for a start that didn't happen. #>
    param([Parameter(Mandatory)][string]$Exe, [string]$Arguments = '', [string]$Process,
          [string]$Name, [int]$TimeoutSeconds = 15)
    if (-not $Name) { $Name = if ($Process) { $Process } else { [System.IO.Path]::GetFileNameWithoutExtension($Exe) } }
    $taskName = 'as-user-' + (($Name.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-'))
    $task = Get-TaskFullName -TaskName $taskName
    $before = if ($Process) { @(Get-Process -Name $Process -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) } else { @() }
    $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) "710-task-$taskName.xml"
    try {
        $spec = [pscustomobject]@{ Key = $taskName; Exe = $Exe; Arguments = $Arguments; Delay = 'PT0S' }
        Set-Content -Path $xmlPath -Value (New-TaskXml -Component $spec -User "$env:USERDOMAIN\$env:USERNAME" -NoTrigger) -Encoding Unicode
        $null = & schtasks.exe /Create /TN $task /XML $xmlPath /F 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        $null = & schtasks.exe /Run /TN $task 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ($true) {
            if ($Process) {
                if (@(Get-Process -Name $Process -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id }).Count) { return $true }
            } else {
                # LastTaskResult reads 0x41303 ("has not yet run") until Task Scheduler starts it
                # (see Invoke-WingetAsUser). Where the ScheduledTasks module can't be read, a
                # short wait stands in.
                $result = $null
                try { $result = (Get-ScheduledTaskInfo -TaskPath "\$script:TaskFolder\" -TaskName $taskName -ErrorAction Stop).LastTaskResult } catch { }
                if ($null -eq $result) { Start-Sleep -Seconds 2; return $true }
                if ($result -ne 0x41303) { return $true }
            }
            if ((Get-Date) -ge $deadline) { return $false }
            Start-Sleep -Milliseconds 250
        }
    } finally {
        $null = & schtasks.exe /Delete /TN $task /F 2>&1
        Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
    }
}
