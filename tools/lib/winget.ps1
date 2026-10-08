<#
.SYNOPSIS
  Talking to winget: the source every call names, the exit codes the scripts act on and what they
  mean, the version `winget list` shows, and running winget as the user from an admin window
  (Invoke-WingetAsUser -- it uses the task plumbing, tools\lib\tasks.ps1). Loaded by
  tools\lib\activation.ps1. Functions, and the exit codes and per-user packages as variables.
#>

function Get-WingetSourceArgs {
    # The source a row's winget calls go through, always named: `--source winget` for winget
    # rows, `--source msstore` for msstore rows (PowerShell 7). Every winget argument list in
    # the repo is built with this -- install's list / install / pin add, the upgrade's pin remove /
    # upgrade / pin add, uninstall's pin remove / uninstall, and so Invoke-WingetAsUser's too.
    # Without a source winget also opens the Store source, and when that one is broken (no
    # Store, a broken Store) every call fails with 0x8A15003B -- install / upgrade / pin /
    # uninstall alike (winarchy 093cd71 + 39ee198, Group 1 W1).
    param($Row)
    if ($Row.Source -eq 'msstore') { @('--source', 'msstore') } else { @('--source', 'winget') }
}

# winget exit codes the scripts act on (winget-cli's doc/.../winget/returnCodes.md).
# PowerShell reads a 0x8... hex literal as a negative Int32 -- the same thing
# $LASTEXITCODE holds for these -- so a plain -eq compares them correctly.
$WingetNotInstalled    = 0x8A150014   # NO_APPLICATIONS_FOUND -- nothing by that ID is installed
$WingetAdminProhibited = 0x8A15007D   # ADMIN_CONTEXT_ACTION_PROHIBITED -- see Invoke-WingetAsUser
# Packages installed for the current user only (into %LOCALAPPDATA%): install's packages step
# installs them un-elevated, through Invoke-WingetAsUser, when it runs elevated (final test T7,
# 2026-10-01 -- see install.ps1). Uninstall and the upgrade step reach the same task through
# winget's own refusal ($WingetAdminProhibited) instead.
$PerUserPackages = @('Flow-Launcher.Flow-Launcher')
$WingetNoPin           = 0x8A150063   # PIN_DOES_NOT_EXIST
# Three that mean the package IS there (winarchy c5053b9 + 093cd71, Group 1 W2):
$WingetRebootRequired  = 0x8A150109   # INSTALL_REBOOT_REQUIRED_TO_FINISH -- installed; a restart finishes its setup
$WingetAlreadyInstalled = 0x8A150061  # PACKAGE_ALREADY_INSTALLED
$WingetNotApplicable   = 0x8A15002B   # UPDATE_NOT_APPLICABLE -- nothing newer to move to (already at that version)

function Get-WingetOutcome {
    <# What a winget install / upgrade exit code means for this repo: 'ok' (0, or already there:
       PACKAGE_ALREADY_INSTALLED / UPDATE_NOT_APPLICABLE), 'restart' (installed, Windows has to
       restart to finish its setup -- counted as installed), 'failed' (anything else), or
       'timeout' ($null: Invoke-WingetAsUser's run was still going). #>
    param($Code)
    if ($null -eq $Code) { return 'timeout' }
    if ($Code -eq 0 -or $Code -eq $WingetAlreadyInstalled -or $Code -eq $WingetNotApplicable) { return 'ok' }
    if ($Code -eq $WingetRebootRequired) { return 'restart' }
    'failed'
}

function Get-WingetListedVersion {
    <# The version `winget list --id <id> --exact` shows for $Id, from its output lines -- the
       token right after the ID (winarchy ce49d5c's parse). The table is Name / Id / Version
       (and an Available column when an upgrade exists); the Name holds spaces, so it's never
       split into columns. $null when the ID isn't in the output (not installed) or no version
       follows it. #>
    param([string[]]$Lines, [Parameter(Mandatory)][string]$Id)
    foreach ($line in $Lines) {
        # winget's progress spinner rides on the same line as the table's first row when output
        # is captured (\r-separated); only the last \r-piece is what the console would show.
        $shown = @("$line" -split "`r")[-1]
        if ($shown -match "(?:^|\s)$([regex]::Escape($Id))\s+(\S+)") {
            $v = $Matches[1]
            if ($v -match '^\d') { return $v }
            return $null
        }
    }
    $null
}

function Format-WingetCode {
    # 0x8A15007D reads better than -1978335107 in a warning, and matches winget's own docs.
    param([int]$Code)
    '0x{0:X8}' -f $Code
}

function Invoke-WingetAsUser {
    <# Runs winget with $Arguments NON-elevated, through a one-shot LeastPrivilege
       scheduled task (same trick as Restart-Explorer), waits for it to finish, and returns
       winget's exit code -- or $null if it's still running after $TimeoutSeconds.

       Why: winget refuses to touch a package installed for this user only (per-user
       scope -- Flow Launcher is one, living under %LOCALAPPDATA%) when it's run from an
       elevated shell: exit 0x8A15007D, ADMIN_CONTEXT_ACTION_PROHIBITED. uninstall.ps1 has
       to run elevated (Defender exclusions, among others), so found live on the
       2026-09-24 reinstall test: Flow's uninstall failed on every run, while the line
       below it still printed "uninstalled". The task runs as the same user, un-elevated,
       so winget allows it. Its console window shows briefly while winget works.
       Moved here from uninstall.ps1 unchanged (2026-09-26) -- install's upgrade step needs
       it for Flow too. #>
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 180)
    $winget   = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    $taskName = 'winget-as-user'
    $task     = Get-TaskFullName -TaskName $taskName
    $null = & schtasks.exe /Create /TN $task /TR "`"$winget`" $($Arguments -join ' ')" /SC ONCE /ST 23:59 /RL LIMITED /F 2>&1
    if ($LASTEXITCODE -ne 0) { throw "couldn't create the one-shot task to run winget un-elevated (schtasks exit $LASTEXITCODE)" }
    try {
        $null = & schtasks.exe /Run /TN $task 2>&1
        if ($LASTEXITCODE -ne 0) { throw "couldn't start the one-shot task to run winget un-elevated (schtasks exit $LASTEXITCODE)" }
        # LastTaskResult reads 0x41303 ("has not yet run") until Task Scheduler actually
        # starts it, then 0x41301 ("currently running"), then winget's own exit code.
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 500
            $result = (Get-ScheduledTaskInfo -TaskPath "\$script:TaskFolder\" -TaskName $taskName).LastTaskResult
        } while ($result -in 0x41301, 0x41303 -and (Get-Date) -lt $deadline)
        if ($result -in 0x41301, 0x41303) { return $null }
        # LastTaskResult is a UInt32; reinterpret the same bits as winget's signed code.
        return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$result), 0)
    }
    finally {
        $null = & schtasks.exe /Delete /TN $task /F 2>&1
    }
}
