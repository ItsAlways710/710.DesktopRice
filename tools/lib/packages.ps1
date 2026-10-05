<#
.SYNOPSIS
  Package helpers shared by install.ps1, uninstall.ps1, tools\install-wallust.ps1 and
  `710sRice doctor`. Dot-sourced -- never run directly.

.DESCRIPTION
  versions.md is the one list of what this repo installs and at which version
  (claude/cli-plan.md, Stage 2 -- "pins in one place"). Everything here reads that table;
  nothing keeps a second copy of a pin. A pin bump is one line in versions.md.

  Dot-source AFTER tools\lib\activation.ps1: Invoke-WingetAsUser uses its Get-TaskFullName
  and $script:TaskFolder, Stop-PinnedApp its Find-AhkWindow / Send-AhkQuit / Get-KomorebicExe
  and the caller's $Root, the ShareX probe its Get-ShareXExe. (install-wallust.ps1 only needs
  Get-VersionsTable, which stands alone.)
#>

function Get-VersionsTable {
    # Hand-rolled parser for versions.md's one real table -- not a general Markdown
    # parser, scoped to exactly that file's fixed column layout (see versions.md's own
    # "table format is load-bearing" note: Component | Version | Source | Install ID |
    # Pre-existing? | Last touched). Returns an array of @{ Component; Version; Source;
    # InstallId; Keep; PreExisting; System; LastTouched }. Moved here from uninstall.ps1
    # (2026-09-26).
    #
    # Pre-existing? is read explicitly (Group 1, W9 -- 2026-09-30): Keep is exactly one of
    #   no      removed by a plain uninstall (unless -Keep <id>)
    #   yes     kept by a plain uninstall, removed by -Force
    #   system  installed if missing, NEVER removed by uninstall, -Force included (PowerShell 7,
    #           which uninstall itself runs on, and Windows Terminal, part of Windows 11)
    # and anything else THROWS, naming the row: a typo must never read as "no" -- which is what
    # the old `-match '^\s*yes'` made of it, i.e. "remove it". PreExisting ($true for yes and
    # system) and System are there for the callers that only ask "protected?" / "never?".
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
        $keep = $cells[4].ToLowerInvariant()
        if ($keep -notin 'no', 'yes', 'system') {
            throw "versions.md: $($cells[0])'s Pre-existing? is '$($cells[4])' -- it has to be yes, no or system (nothing was changed)"
        }
        $rows.Add([pscustomobject]@{
            Component   = $cells[0]
            Version     = $cells[1]
            Source      = $cells[2]
            InstallId   = $cells[3]
            Keep        = $keep
            PreExisting = ($keep -ne 'no')
            System      = ($keep -eq 'system')
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

# --- Removing an MSI package without closing anything (uninstall -Force, the Nerd Font) ----------
# The JetBrainsMono Nerd Font package is an MSI. A silent MSI uninstall (what winget runs) has
# Windows Installer's Restart Manager shut down whatever has one of its files open -- and Windows
# Terminal keeps a font it has drawn with open until it exits, even after you switch fonts. On
# the Dell (2026-10-01, B2 at 06:46 and T5 at 16:12) the Application log reads, both times:
# RestartManager 10005 "Machine restart is required", then 10002 "Shutting down application or
# service 'Windows Terminal Host'" -- the window running the uninstall, gone mid-run (T5 never got
# past the font: 9 things left). MSIRESTARTMANAGERCONTROL=Disable: Windows Installer closes
# nothing; a file still in use is deleted at the next restart (exit 3010 instead of 0).

function Get-MsiProductCode {
    <# The ProductCode of the installed MSI whose name matches $DisplayName (a regex), or $null:
       the Uninstall entry Windows Installer writes is keyed by it (WindowsInstaller = 1).
       Machine-wide entries (64- and 32-bit) first, then this user's. #>
    param([Parameter(Mandatory)][string]$DisplayName)
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                      'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            if ($k.PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { continue }
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and "$($p.DisplayName)" -match $DisplayName -and "$($p.WindowsInstaller)" -eq '1') { return $k.PSChildName }
        }
    }
    $null
}

function Invoke-MsiUninstall {
    <# Removes MSI product $ProductCode quietly, with Restart Manager off (see above) and no
       restart; returns msiexec's exit code: 0 removed, 3010 removed (files still in use go at the
       next restart), 1605 not installed, anything else a failure. msiexec is a GUI program --
       Start-Process -Wait is what waits for it; /qn shows no window of its own. #>
    param([Parameter(Mandatory)][string]$ProductCode)
    $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -Wait -PassThru `
        -ArgumentList @('/x', $ProductCode, '/qn', '/norestart', 'MSIRESTARTMANAGERCONTROL=Disable')
    $p.ExitCode
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
    # The first $Name in a folder on this process's PATH -- or else on the PATH Windows gives
    # every new window (the machine's and the user's, from the registry) -- or $null. A window
    # opened before an install doesn't have what the install added: right after Godzilla's
    # first install (2026-10-03) doctor, run in that same window, called fzf, zoxide, eza and
    # bat "not installed", because winget had added its Links folder to the user PATH partway
    # through. A plain scan: Get-Command took 614 ms for the five shell tools on the Dell (it
    # looks through modules as well).
    param([Parameter(Mandatory)][string]$Name)
    $dirs = @("$env:Path" -split [IO.Path]::PathSeparator) +
        @("$([Environment]::GetEnvironmentVariable('Path', 'Machine'))" -split ';') +
        @("$([Environment]::GetEnvironmentVariable('Path', 'User'))" -split ';')
    foreach ($dir in $dirs) {
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
    # The plain exe -- the UI Access one next to it is the same build. No v2 at all: AutoHotkey
    # v1 (1.1.x) in the install folder's root, so a v1 machine reads "1.1.37 -- older than its
    # pin" (fix: the upgrade step) rather than "not installed" -- which the packages step, where
    # winget DOES list v1, answered "already installed" and pinned 1.1, round after round
    # (Group 1 W7).
    'AutoHotkey.AutoHotkey' = {
        $exe = @("$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
                 "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
                 "$env:ProgramFiles\AutoHotkey\AutoHotkeyU64.exe",
                 "$env:ProgramFiles\AutoHotkey\AutoHotkey.exe",
                 "$env:LOCALAPPDATA\Programs\AutoHotkey\AutoHotkeyU64.exe",
                 "$env:LOCALAPPDATA\Programs\AutoHotkey\AutoHotkey.exe") |
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
    # The Screens menu's (tools\screens.ps1).
    'DisplayConfig' = {
        $m = Get-Module -ListAvailable -Name DisplayConfig -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
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
# directly from install's admin window (the task runs at its own level). Flow has its own
# task since Group 1 #4 (its root Flow.Launcher.exe survives an upgrade; the versioned app
# folder doesn't). Everything is left to its own installer, which stops and restarts its
# service itself.

function Get-PinnedAppTask {
    # The autostart task that starts this row's app, or $null (Everything).
    param($Row)
    switch ($Row.InstallId) {
        'LGUG2Z.komorebi'             { 'komorebi' }
        'AmN.yasb'                    { 'yasb' }
        'AutoHotkey.AutoHotkey'       { 'ahk' }
        'Flow-Launcher.Flow-Launcher' { 'flow' }
        default                       { $null }
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
            $komorebic = Get-KomorebicExe   # next to komorebi.exe first, then PATH (W6)
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
    $pinRemove = @('pin', 'remove', '--id', $id, '--exact') + $src
    $pinAdd    = @('pin', 'add', '--id', $id, '--exact') + $src
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

function Invoke-MoveToPin {
    <# One pinned package that's BELOW its pin, moved up to exactly its pin -- the one routine
       install's packages step (what `winget list` shows is older than the pin: Group 1 W7) and
       the upgrade step (what the probe reads is older) both run, so they can't differ. Stops
       the app if it's running (Stop-PinnedApp), pin remove -> winget upgrade --version <pin> ->
       pin add (Invoke-PinnedUpgrade -- as the user for a per-user package, Flow), reads the
       version again, then starts the app through its own task if it was running before. Never
       down: callers only come here for a package below its pin, never for one newer than it
       (the user's call -- doctor's [!!]). Prints its own lines. $true when the package ended at
       its pin (a restart-to-finish counts); $false when it didn't -- the caller counts that as
       not installed (W2). #>
    param([Parameter(Mandatory)]$Row, [string]$From)
    $name = $Row.Component
    Step-Info "$name $From -> $($Row.Version) (its pin) ..."
    $ok = $false
    # One package going wrong is that package's [XX], never the end of the step: whatever was
    # stopped still gets started again below.
    $wasRunning = $false
    try {
        $wasRunning = Stop-PinnedApp $Row
        $code    = Invoke-PinnedUpgrade $Row
        $outcome = Get-WingetOutcome $code
        $after   = Get-PackageVersion $Row
        $atPin   = $after.Probe -and (Compare-PinVersion $after.Version $Row.Version) -eq 0
        if ($outcome -eq 'failed') {
            Write-Host "  [XX] $($name): winget exited $(Format-WingetCode $code) -- still $(if ($after.Version) { $after.Version } else { $From }) (pin put back)" -ForegroundColor Red
        } elseif ($outcome -eq 'restart') {
            Step-Warn "$name $From -> $($Row.Version) -- restart Windows to finish its setup"
            $ok = $true
        } elseif ($atPin) {
            Step-Ok "$name $From -> $($after.Version)"
            $ok = $true
        } elseif (-not $after.Probe -and $outcome -eq 'ok') {
            # No local probe for this row: winget's own word is all there is.
            Step-Ok "$name $From -> $($Row.Version)"
            $ok = $true
        } elseif ($outcome -eq 'timeout' -and $after.Installed) {
            Step-Warn "$($name): the un-elevated upgrade was still running after 3 minutes -- it reports $($after.Version) so far; check again once it's done."
        } else {
            Write-Host "  [XX] $($name): winget finished, but it reports '$($after.Version)', not $($Row.Version)" -ForegroundColor Red
        }
    } catch {
        # Invoke-PinnedUpgrade puts the pin back itself (finally), whatever went wrong.
        Write-Host "  [XX] $($name): $($_.Exception.Message)" -ForegroundColor Red
    }
    $task = Get-PinnedAppTask $Row
    if ($wasRunning -and $task) {
        if (Test-Task -TaskName $task) {
            $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName $task) 2>&1
            if ($LASTEXITCODE -eq 0) { Step-Ok "$($name): started again through its task" }
            else { Step-Warn "$($name): its task didn't start (schtasks exit $LASTEXITCODE) -- 710sRice start brings it back." }
        } else {
            Step-Warn "$($name) was running but has no task -- 710sRice start brings it back."
        }
    } elseif ($wasRunning) {
        Step-Info "$name was closed for the upgrade -- it starts again the next time you open it."
    }
    $ok
}
