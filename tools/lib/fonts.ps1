<#
.SYNOPSIS
  The JetBrainsMono Nerd Font's face name, as the fonts Windows has registered call it -- what
  Windows Terminal and Flow Launcher are set to. Loaded by tools\lib\activation.ps1. Only
  functions.
#>

function Get-NerdFontFace {
    <# The face name Windows Terminal should use for the JetBrainsMono Nerd Font the packages step
       installs (DEVCOM.JetBrainsMonoNerdFont, Nerd Fonts v3: "JetBrainsMono NF"; v2 called it
       "JetBrainsMono Nerd Font"), from the fonts Windows has registered -- $null when it isn't
       installed. Install's terminal step and doctor's check both ask here. #>
    $names = @(Get-InstalledFontNames)
    if (@($names | Where-Object { $_ -match '^JetBrainsMono NF[ (]' }).Count) { return 'JetBrainsMono NF' }
    if (@($names | Where-Object { $_ -match '^JetBrainsMono Nerd Font[ (]' }).Count) { return 'JetBrainsMono Nerd Font' }
    $null
}
