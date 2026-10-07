<#
.SYNOPSIS
  Shortcuts (.lnk) through WScript.Shell, and where your Start menu's programs are. Loaded by
  tools\lib\activation.ps1. Only functions.
#>

function Get-StartMenuProgramsDir {
    # Your Start menu's Programs folder (what Flow Launcher's Program plugin indexes). The
    # shell's answer, or its usual place when it has none.
    $sm = [Environment]::GetFolderPath('StartMenu')
    if (-not $sm) { $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu' }
    Join-Path $sm 'Programs'
}

function Save-RiceShortcut {
    <# Writes a .lnk (WScript.Shell): target, arguments, working folder, icon, description. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target, [string]$Arguments = '',
          [string]$WorkingDirectory = '', [string]$Icon = '', [string]$Description = '')
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.WorkingDirectory = $WorkingDirectory
    if ($Icon) { $lnk.IconLocation = $Icon }
    $lnk.Description = $Description
    $lnk.Save()
}

function Read-RiceShortcut {
    <# A .lnk's target, arguments, working folder, icon and description; $null if it isn't there
       or can't be read. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        [pscustomobject]@{ Target = $lnk.TargetPath; Arguments = $lnk.Arguments; WorkingDirectory = $lnk.WorkingDirectory; Icon = $lnk.IconLocation; Description = $lnk.Description }
    } catch { $null }
}
