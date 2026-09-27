<#
.SYNOPSIS
  Package helpers shared by install.ps1, uninstall.ps1, tools\install-wallust.ps1 and
  `710sRice doctor`. Dot-sourced -- never run directly.

.DESCRIPTION
  versions.md is the one list of what this repo installs and at which version
  (claude/cli-plan.md, Stage 2 -- "pins in one place"). Everything here reads that table;
  nothing keeps a second copy of a pin. A pin bump is one line in versions.md.

  Dot-source AFTER tools\lib\activation.ps1: Invoke-WingetAsUser uses its Get-TaskFullName
  and $script:TaskFolder, Stop-PinnedApp its Find-AhkWindow / Send-AhkQuit and the caller's
  $Root, the ShareX probe its Get-ShareXExe. (install-wallust.ps1 only needs
  Get-VersionsTable, which stands alone.)
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

# --- Installed versions (the probes) ------------------------------------------------------
# What's actually installed, read locally -- no winget call (a `winget list` per package is
# 1-2 s each). Strings as the Dell reports them (2026-09-26 reading): komorebi's exes carry
# no version resource at all, so komorebic --version is asked; the rest are exe
# ProductVersions. A probe returns the version, '' for "installed, no version to read", or
# nothing for "not installed". The five pinned rows' probes are the upgrade step's (it reads
# no others); `710sRice doctor` reads them all. wallust (github-release) isn't here: doctor
# checks it the way install's wallust step does.

function Get-ExeProductVersion {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $v = (Get-Item -LiteralPath $Path).VersionInfo
    $s = "$($v.ProductVersion)".Trim()
    if (-not $s) { $s = "$($v.FileVersion)".Trim() }
    $s
}

function Find-ExeOnPath {
    # The first $Name in a folder on this process's PATH, or $null. A plain scan: Get-Command
    # took 614 ms for the five shell tools on the Dell (it looks through modules as well).
    param([Parameter(Mandatory)][string]$Name)
    foreach ($dir in "$env:Path" -split [IO.Path]::PathSeparator) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        try { $p = [IO.Path]::Combine([Environment]::ExpandEnvironmentVariables($dir.Trim().Trim('"')), $Name) } catch { continue }
        if ([IO.File]::Exists($p)) { return $p }
    }
    $null
}

function Get-InstalledFontNames {
    # Every font Windows has registered, machine-wide and for this user -- the value names
    # ("JetBrainsMono NF Bold (TrueType)", ...).
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
        $k = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
        if ($k) { $k.GetValueNames() }
    }
}

$script:PackageProbes = @{
    # `komorebic 0.1.41` (then tag / commit / build lines).
    'LGUG2Z.komorebi' = {
        $c = Get-Command komorebic.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $c) { $c = @(Get-Item "$env:ProgramFiles\komorebi\bin\komorebic.exe" -ErrorAction SilentlyContinue) | Select-Object -First 1 }
        if (-not $c) { return $null }
        $exe = if ($c.Source) { $c.Source } else { $c.FullName }
        $line = @(& $exe --version 2>$null) | Select-Object -First 1
        if ("$line" -match '(\d+(?:\.\d+)+)') { $Matches[1] } else { '' }
    }
    'AmN.yasb' = {
        $exe = (Get-Command yasb.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $exe) { $exe = "$env:ProgramFiles\YASB\yasb.exe" }
        Get-ExeProductVersion $exe
    }
    # The plain exe -- the UI Access one next to it is the same build.
    'AutoHotkey.AutoHotkey' = {
        $exe = @("$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
                 "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe") |
               Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        Get-ExeProductVersion $exe
    }
    # Flow's root Flow.Launcher.exe is its updater stub, but it carries the version too.
    'Flow-Launcher.Flow-Launcher' = { Get-ExeProductVersion "$env:LOCALAPPDATA\FlowLauncher\Flow.Launcher.exe" }
    'voidtools.Everything' = {
        $exe = @("$env:ProgramFiles\Everything\Everything.exe", "${env:ProgramFiles(x86)}\Everything\Everything.exe") |
               Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        Get-ExeProductVersion $exe
    }
    # --- Unpinned rows (installed is what counts; a version only where it's cheap) ---------
    'ShareX.ShareX' = { Get-ExeProductVersion (Get-ShareXExe) }
    # The wt.exe alias Windows keeps for it. Its version sits behind Get-AppxPackage (1.2 s
    # on the Dell) -- not worth it for an unpinned row.
    'Microsoft.WindowsTerminal' = { if (Test-Path -LiteralPath "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe") { '' } }
    # PowerShell 7 is what's running this.
    '9MZ1SNWT0N5D' = { if ($PSVersionTable.PSVersion.Major -ge 7) { "$($PSVersionTable.PSVersion)" } }
    'DEVCOM.JetBrainsMonoNerdFont' = { if (@(Get-InstalledFontNames | Where-Object { $_ -like 'JetBrainsMono NF*' }).Count) { '' } }
    # Only starship's exe carries a version; the other four are there or not.
    'Starship.Starship'  = { Get-ExeProductVersion (Find-ExeOnPath 'starship.exe') }
    'junegunn.fzf'       = { if (Find-ExeOnPath 'fzf.exe') { '' } }
    'ajeetdsouza.zoxide' = { if (Find-ExeOnPath 'zoxide.exe') { '' } }
    'eza-community.eza'  = { if (Find-ExeOnPath 'eza.exe') { '' } }
    'sharkdp.bat'        = { if (Find-ExeOnPath 'bat.exe') { '' } }
    'PSFzf' = {
        $m = Get-Module -ListAvailable -Name PSFzf -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        if ($m) { "$($m.Version)" }
    }
}

function Get-PackageVersion {
    <# What's installed for a versions.md row: Probe ($false = no probe for this row yet),
       Installed, and Version ('' when it's there but its version can't be read). #>
    param($Row)
    $probe = $script:PackageProbes[$Row.InstallId]
    if (-not $probe) { return [pscustomobject]@{ Probe = $false; Installed = $false; Version = $null } }
    $v = & $probe
    [pscustomobject]@{ Probe = $true; Installed = ($null -ne $v); Version = $v }
}

function Compare-PinVersion {
    <# -1 installed older than the pin, 0 at the pin, 1 newer; $null when they can't be
       compared. Segment by segment as numbers, missing segments = 0, so 2.1.3 matches
       2.1.3.0 (winget and exe versions often have a fourth part) -- and 2.0.2 is NOT 2.0.28,
       which a plain "starts with" would say. A pin that isn't all numbers (wallust's
       4.1.0-alpha) only ever matches exactly. #>
    param([string]$Installed, [string]$Pin)
    if (-not $Installed -or -not $Pin) { return $null }
    if ($Pin -notmatch '^\d+(\.\d+)*$' -or $Installed -notmatch '^\d+(\.\d+)*$') {
        if ($Installed -eq $Pin) { return 0 }
        return $null
    }
    $a = @($Installed.Split('.') | ForEach-Object { [long]$_ })
    $b = @($Pin.Split('.') | ForEach-Object { [long]$_ })
    for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $y = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    0
}

# --- Upgrading a pinned package to its pin (install's upgrade step) ---------------------
# Each pinned app is stopped before winget touches it (a running app locks its files) and
# started again afterwards through its own task -- only if it was running before, and never
# directly from install's admin window (the task runs at its own level). Flow isn't
# restarted: SUPER+Space cold-starts it. Everything is left to its own installer, which
# stops and restarts its service itself.

function Get-PinnedAppTask {
    # The autostart task that starts this row's app, or $null (Flow, Everything).
    param($Row)
    switch ($Row.InstallId) {
        'LGUG2Z.komorebi'       { 'komorebi' }
        'AmN.yasb'              { 'yasb' }
        'AutoHotkey.AutoHotkey' { 'ahk' }
        default                 { $null }
    }
}

function Stop-PinnedApp {
    <# Stops this row's app if it's running; $true when it was. komorebi through its own
       `komorebic stop` first (a clean stop saves its layouts), YASB and Flow killed (the YASB
       watchdog in 710.ahk already holds off while winget.exe runs), 710.ahk asked to quit --
       the same message tray Quit uses -- then killed if it's still there (install's admin
       window can end the UI Access process; see Stop-RunningComponents). #>
    param($Row)
    switch ($Row.InstallId) {
        'LGUG2Z.komorebi' {
            if (-not (Get-Process komorebi -ErrorAction SilentlyContinue)) { return $false }
            $komorebic = (Get-Command komorebic -ErrorAction SilentlyContinue)?.Source
            if ($komorebic) { try { & $komorebic stop 2>$null | Out-Null } catch { } }
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Process komorebi -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            Stop-Process -Name komorebi -Force -ErrorAction SilentlyContinue
            return $true
        }
        'AmN.yasb' {
            if (-not (Get-Process yasb -ErrorAction SilentlyContinue)) { return $false }
            Stop-Process -Name yasb -Force -ErrorAction SilentlyContinue
            return $true
        }
        'AutoHotkey.AutoHotkey' {
            $ahkScript = Join-Path $Root 'config\ahk\710.ahk'
            if ((Find-AhkWindow -ScriptPath $ahkScript) -eq [IntPtr]::Zero) { return $false }
            [void](Send-AhkQuit -ScriptPath $ahkScript)
            $deadline = (Get-Date).AddSeconds(3)
            while ((Find-AhkWindow -ScriptPath $ahkScript) -ne [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            try {
                Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe' OR Name = 'AutoHotkey64_UIA.exe'" -ErrorAction Stop |
                    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ahkScript) } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            } catch { }
            return $true
        }
        'Flow-Launcher.Flow-Launcher' {
            if (-not (Get-Process Flow.Launcher -ErrorAction SilentlyContinue)) { return $false }
            Stop-Process -Name Flow.Launcher -Force -ErrorAction SilentlyContinue
            return $true
        }
        default { return $false }
    }
}

function Invoke-PinnedUpgrade {
    <# One pinned package, older than its pin, to exactly its pin: pin remove -> winget
       upgrade --version <pin> -> pin add -- the route the AutoHotkey 2.0.28 bump took by hand
       (2026-09-23). A per-user package (Flow) that winget refuses from an admin window runs
       again as the user (Invoke-WingetAsUser). The pin always goes back on, even when the
       upgrade fails -- a pinned package is never left unpinned. Returns winget's exit code
       ($null = the un-elevated run was still going after 3 minutes). #>
    param($Row)
    $id  = $Row.InstallId
    $src = @(Get-WingetSourceArgs $Row)
    $pinRemove = @('pin', 'remove', '--id', $id) + $src
    $pinAdd    = @('pin', 'add', '--id', $id) + $src
    winget @pinRemove 2>$null | Out-Null
    try {
        $upgradeArgs = @('upgrade', '--id', $id, '--exact', '--version', $Row.Version, '--silent',
                         '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + $src
        # To the screen, not the output stream: this function returns winget's exit code and
        # nothing else. (Its first Dell run returned winget's progress lines along with the
        # code -- the upgrade itself went through, the report after it crashed; 2026-09-26.)
        winget @upgradeArgs | Out-Host
        $code = $LASTEXITCODE
        if ($code -eq $WingetAdminProhibited) {
            Step-Info "$id is installed for this user only -- upgrading it un-elevated ..."
            $code = Invoke-WingetAsUser -Arguments $upgradeArgs
        }
        return $code
    } finally {
        winget @pinAdd 2>$null | Out-Null
    }
}
