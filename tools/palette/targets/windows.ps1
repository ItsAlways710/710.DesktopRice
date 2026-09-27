# Windows' own accent colour (title bars, Start, the taskbar's highlights) and its dark / light
# app mode. Ported from winarchy's Set-WinarchyWindowsAppearance / Send-WinarchyColorSetChange.
@{
    Id    = 'windows'
    Label = 'Windows accent'
    Order = 70
    About = 'Windows accent colour and app mode (registry, applied live)'
    Properties = [ordered]@{
        accent = @{ Label = 'Accent'; Default = 'accent' }
    }
    Apply = {
        param($Values, $Theme, $Context)
        $personalize = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $dwm = 'HKCU:\SOFTWARE\Microsoft\Windows\DWM'
        # What these were before we ever touched them -- uninstall's Restore-WindowsAccent
        # (tools\lib\activation.ps1) puts it back. Written once in the life of the install.
        Save-PaletteOriginalStateOnce -Label 'windows-accent' -Data @{
            Personalize_AppsUseLightTheme    = Get-PaletteRegValueSnapshot -Path $personalize -Name 'AppsUseLightTheme'
            Personalize_SystemUsesLightTheme = Get-PaletteRegValueSnapshot -Path $personalize -Name 'SystemUsesLightTheme'
            Personalize_ColorPrevalence      = Get-PaletteRegValueSnapshot -Path $personalize -Name 'ColorPrevalence'
            Dwm_ColorPrevalence              = Get-PaletteRegValueSnapshot -Path $dwm -Name 'ColorPrevalence'
            Dwm_AccentColor                  = Get-PaletteRegValueSnapshot -Path $dwm -Name 'AccentColor'
            Dwm_ColorizationColor            = Get-PaletteRegValueSnapshot -Path $dwm -Name 'ColorizationColor'
        }
        $light = if ($Theme.AppDark) { 0 } else { 1 }
        Set-ItemProperty -Path $personalize -Name 'AppsUseLightTheme' -Value $light -Type DWord
        Set-ItemProperty -Path $personalize -Name 'SystemUsesLightTheme' -Value $light -Type DWord
        Set-ItemProperty -Path $personalize -Name 'ColorPrevalence' -Value 1 -Type DWord
        Set-ItemProperty -Path $dwm -Name 'ColorPrevalence' -Value 1 -Type DWord
        $rgb = ConvertTo-PaletteRgb -Hex $Values.accent
        $abgr = (0xFF -shl 24) -bor ($rgb.B -shl 16) -bor ($rgb.G -shl 8) -bor $rgb.R
        Set-ItemProperty -Path $dwm -Name 'AccentColor' -Value $abgr -Type DWord
        Set-ItemProperty -Path $dwm -Name 'ColorizationColor' -Value $abgr -Type DWord
        Send-PaletteSettingChange
        @{ Status = 'ok'; Message = "Windows accent ($($Values.accent))$(if (-not $Theme.AppDark) { ', light mode' })" }
    }
}
