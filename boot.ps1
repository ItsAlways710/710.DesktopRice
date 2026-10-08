# 710sRice's one-line install, from a normal PowerShell window (Windows PowerShell 5.1 will do):
#
#   irm https://raw.githubusercontent.com/ItsAlways710/710.DesktopRice/master/boot.ps1 | iex
#
# It installs git and PowerShell 7 if they're missing, clones this repo to C:\710.DesktopRice
# ($env:DESKTOPRICE_HOME, when set, picks another folder -- install sets that variable, so a
# machine that had 710sRice finds its folder again), then runs the installer: on demand, one UAC
# prompt. `710sRice activate` afterwards makes it start at every sign-in. A 710sRice clone already
# in that folder is used as it is (`710sRice update` brings it up to date). A port of winarchy's
# boot.ps1, reshaped. Runs on Windows PowerShell 5.1 -- nothing PowerShell 7-only here -- inside
# one script block, so nothing it defines stays behind in your window, and it never closes it.
& {
    $repo = 'https://github.com/ItsAlways710/710.DesktopRice.git'

    function Write-BootLine([string]$Status, [string]$Text) {
        $color = switch ($Status) { 'OK' { 'Green' } 'XX' { 'Red' } '!!' { 'Yellow' } default { 'Cyan' } }
        Write-Host "  [$Status] $Text" -ForegroundColor $color
    }

    function Get-BootShownPath([string]$Path) {
        # Your profile folder as %USERPROFILE%: never the Windows user name on screen.
        if ($env:USERPROFILE -and $Path.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
            return '%USERPROFILE%' + $Path.Substring($env:USERPROFILE.Length)
        }
        $Path
    }

    function Test-BootCommand([string]$Name) {
        [bool](Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
    }

    function Update-BootPath {
        # A package winget just installed put itself on the machine or user PATH: this window's
        # copy is from before.
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }

    function Invoke-RiceBoot {
        Write-Host ''
        Write-Host '== 710sRice: one-line install ==' -ForegroundColor Cyan
        if ([Environment]::OSVersion.Version.Build -lt 22000) {
            Write-BootLine 'XX' '710sRice needs Windows 11 (build 22000 or later). Nothing was changed.'
            return
        }
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-BootLine 'XX' 'Run this from a normal PowerShell window, not as administrator: a clone made as administrator belongs to Administrators, and git then refuses to work in it as you (710sRice update needs it). The installer asks for admin itself, with one UAC prompt. Nothing was changed.'
            return
        }
        $wingetOk = $false
        try { $null = & winget --version; $wingetOk = $LASTEXITCODE -eq 0 } catch { }
        if (-not $wingetOk) {
            Write-BootLine 'XX' "winget isn't available. Install or update App Installer from the Microsoft Store, then run this again. Nothing was changed."
            return
        }

        # Where it goes -- checked before anything is installed.
        $dir = 'C:\710.DesktopRice'
        if ($env:DESKTOPRICE_HOME) { $dir = $env:DESKTOPRICE_HOME }
        $shown = Get-BootShownPath $dir
        $isClone = (Test-Path -LiteralPath (Join-Path $dir '.git')) -and (Test-Path -LiteralPath (Join-Path $dir '710sRice.ps1'))
        if (-not $isClone -and (Test-Path -LiteralPath $dir) -and (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) {
            Write-BootLine 'XX' "$shown already exists and isn't a 710sRice clone. Move it, or set DESKTOPRICE_HOME to another folder first, then run this again. Nothing was changed."
            return
        }

        # git and PowerShell 7, when they're missing. Each winget run a statement of its own, so its
        # output goes straight to this window; the exit codes winget calls fine: installed, a
        # restart finishes it, already installed, nothing newer.
        $fine = 0, -1978334967, -1978335135, -1978335189
        $agree = '--accept-package-agreements', '--accept-source-agreements'
        if (-not (Test-BootCommand 'git')) {
            Write-BootLine '..' 'Installing git with winget...'
            & winget install --id Git.Git --exact --source winget --silent @agree
            if ($LASTEXITCODE -notin $fine) { Write-BootLine 'XX' "winget couldn't install git (exit $LASTEXITCODE)."; return }
            Update-BootPath
            if (-not (Test-BootCommand 'git')) { Write-BootLine '!!' "git is installed, but this window can't see it yet. Open a new PowerShell window and run this again."; return }
        }
        Write-BootLine 'OK' 'git is there'
        if (-not (Test-BootCommand 'pwsh')) {
            # The Microsoft Store build first (versions.md's row: it keeps itself updated), winget's
            # own when the Store is blocked -- the README's two ways.
            Write-BootLine '..' 'Installing PowerShell 7 with winget (the Microsoft Store build)...'
            & winget install --id 9MZ1SNWT0N5D --source msstore @agree
            if ($LASTEXITCODE -notin $fine) {
                Write-BootLine '..' "The Store's didn't install (exit $LASTEXITCODE) -- winget's own build instead..."
                & winget install --id Microsoft.PowerShell --exact --source winget --silent @agree
                if ($LASTEXITCODE -notin $fine) { Write-BootLine 'XX' "winget couldn't install PowerShell 7 (exit $LASTEXITCODE)."; return }
            }
            Update-BootPath
            if (-not (Test-BootCommand 'pwsh')) { Write-BootLine '!!' "PowerShell 7 is installed, but this window can't see it yet. Open a new PowerShell window and run this again."; return }
        }
        Write-BootLine 'OK' 'PowerShell 7 is there'

        # The clone -- or the one that's there, as it is.
        if ($isClone) {
            Write-BootLine 'OK' "710sRice is already in $shown -- using it as it is (710sRice update brings it up to date)"
        } else {
            Write-BootLine '..' "Cloning 710sRice into $shown..."
            & git clone $repo $dir
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $dir '710sRice.ps1'))) {
                Write-BootLine 'XX' "git clone failed (exit $LASTEXITCODE)."
                return
            }
        }

        # The installer, through the 710sRice command: it opens its own admin window (one UAC
        # prompt) and waits for it.
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir '710sRice.ps1') install
        $code = $LASTEXITCODE
        Write-Host ''
        if ($code -eq 0) {
            Write-BootLine 'OK' "710sRice is installed, on demand. Open a new PowerShell 7 window: 710sRice start starts it, 710sRice doctor checks it, and 710sRice activate makes it start at every sign-in."
        } else {
            Write-BootLine '!!' "The install ended with exit $code -- the lines above, or its admin window, say why. Run the one-liner again to try again: it uses the clone that's there now."
        }
    }

    Invoke-RiceBoot
}
