<#
.SYNOPSIS
  The desktop wallpaper: set it, read the one that's up, and the snapshot of the one that was there
  before 710sRice's default (install's theme step saves it, uninstall puts it back). Loaded by
  tools\lib\activation.ps1. Only functions.
#>

function Set-DesktopWallpaper {
    <# SPI_SETDESKWALLPAPER=0x0014, SPIF_UPDATEINIFILE|SPIF_SENDCHANGE=0x03 -- writes
       HKCU\Control Panel\Desktop\WallPaper and applies live, no logoff/restart needed.
       Shared by install.ps1 Section 4 (sets the first-run default) and
       Restore-OriginalWallpaper below (sets it back to whatever was there before). #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('TenSeven.Native.Wallpaper' -as [type])) {
        Add-Type -Namespace TenSeven.Native -Name Wallpaper -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
'@
    }
    $ok = [TenSeven.Native.Wallpaper]::SystemParametersInfo(0x0014, 0, $Path, 0x03)
    if (-not $ok) { throw "SystemParametersInfo returned false (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
}

function Get-CurrentWallpaper {
    <# The desktop wallpaper that's up now: HKCU\Control Panel\Desktop\WallPaper -- the value
       both SystemParametersInfo (Set-DesktopWallpaper) and the IDesktopWallpaper COM API
       that YASB's wallpaper widget uses keep current. scripts\Set-LockScreen.ps1 reads the
       same value when it isn't handed a picture. $null when none is set. Used by install's
       palette and tasks steps. #>
    (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper' -ErrorAction SilentlyContinue).WallPaper
}

function Save-OriginalWallpaper {
    <# One-time snapshot of the wallpaper as it stood before install.ps1 Section 4 ever
       set the repo's default -- called from there, right before the first Set-
       DesktopWallpaper call. #>
    Save-OriginalState -Label 'wallpaper' -Data (Get-RegValueSnapshot -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper')
}

function Restore-OriginalWallpaper {
    <# Reverts Save-OriginalWallpaper -- called from uninstall.ps1. $null from Get-
       OriginalState means install.ps1 never actually reached Section 4's wallpaper-setting
       branch on this machine (already using one of the repo's own wallpapers, or the
       default image was missing) -- safe no-op, not a warning. #>
    $snap = Get-OriginalState -Label 'wallpaper'
    if (-not $snap) { return $false }
    if ($snap.Existed -and $snap.Value) {
        Set-DesktopWallpaper -Path $snap.Value
    }
    Remove-OriginalState -Label 'wallpaper'
    return $true
}
