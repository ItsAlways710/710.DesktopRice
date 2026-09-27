<#
.SYNOPSIS
  Package helpers shared by install.ps1, uninstall.ps1, tools\install-wallust.ps1 and (Stage 3)
  `710sRice doctor`. Dot-sourced -- never run directly.

.DESCRIPTION
  versions.md is the one list of what this repo installs and at which version
  (claude/cli-plan.md, Stage 2 -- "pins in one place"). Everything here reads that table;
  nothing keeps a second copy of a pin. A pin bump is one line in versions.md.

  Dot-source AFTER tools\lib\activation.ps1: Invoke-WingetAsUser uses its Get-TaskFullName
  and $script:TaskFolder. (install-wallust.ps1 only needs Get-VersionsTable, which stands
  alone.)
#>

function Get-VersionsTable {
    # Hand-rolled parser for versions.md's one real table -- not a general Markdown
    # parser, scoped to exactly that file's fixed column layout (see versions.md's own
    # "table format is load-bearing" note: Component | Version | Source | Install ID |
    # Pre-existing? | Last touched). Returns an array of @{ Component; Version; Source;
    # InstallId; PreExisting; LastTouched }; PreExisting is $true for "yes" or "yes ?".
    # Moved here from uninstall.ps1 unchanged (2026-09-26).
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    $inTable = $false
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('|')) { $inTable = $false; continue }
        $cells = @($trimmed.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells[0] -eq 'Component') { $inTable = $true; continue }   # header row
        if ($cells[0] -match '^-+$') { continue }                       # separator row
        if (-not $inTable) { continue }
        if ($cells.Count -lt 6) { continue }
        $rows.Add([pscustomobject]@{
            Component   = $cells[0]
            Version     = $cells[1]
            Source      = $cells[2]
            InstallId   = $cells[3]
            PreExisting = ($cells[4] -match '^\s*yes')
            LastTouched = $cells[5]
        })
    }
    return @($rows)
}

function Test-WingetRow {
    # A row winget installs: Source `winget`, or `msstore` (winget, from the Microsoft Store
    # source -- PowerShell 7, whose Store/MSIX build isn't in winget's default source).
    param($Row)
    $Row.Source -in 'winget', 'msstore'
}

function Test-PinnedRow {
    # A pin: any Version but `latest`. Installed at exactly that version and winget-pinned,
    # so a general `winget upgrade --all` elsewhere can't move it off what was tested here.
    param($Row)
    [bool]$Row.Version -and $Row.Version -ne 'latest'
}

function Get-WingetSourceArgs {
    # The extra winget arguments a row's Source needs: `--source msstore` for msstore rows,
    # nothing for winget's default source.
    param($Row)
    if ($Row.Source -eq 'msstore') { @('--source', 'msstore') } else { @() }
}

# winget exit codes the scripts act on (winget-cli's doc/.../winget/returnCodes.md).
# PowerShell reads a 0x8... hex literal as a negative Int32 -- the same thing
# $LASTEXITCODE holds for these -- so a plain -eq compares them correctly.
$WingetNotInstalled    = 0x8A150014   # NO_APPLICATIONS_FOUND -- nothing by that ID is installed
$WingetAdminProhibited = 0x8A15007D   # ADMIN_CONTEXT_ACTION_PROHIBITED -- see Invoke-WingetAsUser
$WingetNoPin           = 0x8A150063   # PIN_DOES_NOT_EXIST

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
       to run elevated (Defender exclusions, lock screen), so found live on the
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
