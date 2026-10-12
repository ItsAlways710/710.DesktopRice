#Requires -Version 7.0
<#
.SYNOPSIS
    The palette editor's start, window first: its frame on screen as soon as the window is built
    and wired, then everything in it at once.

.DESCRIPTION
    tools\palette-editor.ps1 dot-sources this just before it shows the window, so it runs in the
    editor's own scope. Filling the window -- the profiles read, the one opened, the rows built,
    the palette and the theme -- took most of the second before anything showed. Now the frame
    is drawn first, its content collapsed so nothing half-built shows, and Start-EditorFill runs
    straight after that first render, showing the content when it's done. A key pressed before
    the profile is read does nothing (the editor's key handler waits for it), and a click on the
    empty frame lands nowhere.
#>

function Initialize-EditorWindow {
    <# Fits the window to the screen, collapses its content, and has Start-EditorFill run once
       the frame is drawn: at Loaded priority, after that render and before any input. #>
    # Fit the screen (a 1080p laptop at 125 % has about 830 px of height to give).
    $wa = [System.Windows.SystemParameters]::WorkArea
    $script:Window.Width = [Math]::Min($script:Window.Width, [Math]::Floor($wa.Width * 0.95))
    $script:Window.Height = [Math]::Min($script:Window.Height, [Math]::Floor($wa.Height * 0.95))
    $script:Window.MinWidth = [Math]::Min($script:Window.MinWidth, $script:Window.Width)
    $script:Window.MinHeight = [Math]::Min($script:Window.MinHeight, $script:Window.Height)
    $script:Window.FindName('Main').Visibility = 'Collapsed'
    $script:Window.Add_ContentRendered({
        $null = $script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [Action]{ Start-EditorFill })
    })
}

function Start-EditorFill {
    <# Everything in the window, then the content shown, all at once. Shown even when something
       here failed: the status line says what (the dispatcher's handler logs it). #>
    try {
        $script:Image = Get-PaletteCurrentWallpaper
        if ($script:Image -and -not (Test-Path -LiteralPath $script:Image)) { $script:Image = $null }
        Update-Known
        Set-Backdrop -Image $script:Image
        Open-EditorProfile
        Build-PaletteStrip
        Build-RoleRows
        Build-TargetToggles
        Build-AnsiGrid
        Register-PreviewTags
        if ($script:Mode -eq 'new') { $script:Ui.FromRow.Visibility = 'Visible'; Build-FromPanel }
        Sync-SourceControls
        Sync-OptionControls
        Sync-Header
        Request-EditorPalette
        $script:Timer.Start()
        Write-EditorLog "opened: $(Get-EditorLabel) ($script:Mode)"
    } finally {
        # Shown, but deaf to clicks until the input that waited behind this has been handled
        # (Background comes after Input): a click on the empty frame doesn't land on whatever
        # is under it now.
        $main = $script:Window.FindName('Main')
        $main.IsHitTestVisible = $false
        $main.Visibility = 'Visible'
        $null = $script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ $script:Window.FindName('Main').IsHitTestVisible = $true })
    }
}
