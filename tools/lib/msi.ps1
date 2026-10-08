<#
.SYNOPSIS
  Removing an MSI package quietly without Windows Installer closing anything -- uninstall's way
  for the JetBrainsMono Nerd Font (why: below). Loaded by tools\lib\activation.ps1. Only
  functions.
#>

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
