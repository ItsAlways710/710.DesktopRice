<#
.SYNOPSIS
  What's installed, and at which version, for each versions.md row -- read locally, no winget
  call -- and how a version compares with its pin (Compare-PinVersion). Doctor reads them all;
  install's upgrade step and the move to a pin (tools\lib\topin.ps1) read the pinned rows'.
  Loaded by tools\lib\activation.ps1. Functions, and the probe table.
#>

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
    # By its name in Windows' fonts, either face (tools\lib\fonts.ps1) -- what install's packages step
    # asks before winget, so the two agree.
    'DEVCOM.JetBrainsMonoNerdFont' = { if (Get-NerdFontFace) { '' } }
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
