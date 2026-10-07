# Windows Terminal: the "wallust" colour scheme every profile uses, and the tab row. wallust
# itself never writes settings.json any more (it runs with -s); this does, in one pass.
#
# Slot defaults are the standard ANSI order (red = color1 ...), right for palettes that come in
# terminal order (ansi, the built-in themes, scheme files). The Default profile overrides every
# slot: fixed hues (red, green, yellow, blue, purple, cyan, a normal and a bright shade each) mixed
# 15% with the wallpaper's Text colour, and near-neutral whites and greys -- a kmeans palette is
# often one hue (710Default001-004 are all purple), so the terminal can't take its colours
# straight from it and stay readable. The archived Classic Default
# (config\palettes\archive\classic-default.json) keeps wallust 4.1's own Windows Terminal order
# (red = color3, green = color1 ...), measured on the Dell across all 21 shipped wallpapers.
$slots = [ordered]@{
    background = 'background'; foreground = 'foreground'; cursorColor = 'cursor'; selectionBackground = 'color8'
    black = 'color0'; red = 'color1'; green = 'color2'; yellow = 'color3'; blue = 'color4'; purple = 'color5'; cyan = 'color6'; white = 'color7'
    brightBlack = 'color8'; brightRed = 'color9'; brightGreen = 'color10'; brightYellow = 'color11'
    brightBlue = 'color12'; brightPurple = 'color13'; brightCyan = 'color14'; brightWhite = 'color15'
}
$labels = @{ cursorColor = 'Cursor'; selectionBackground = 'Selection'; brightBlack = 'Bright black (dim text)' }
$props = [ordered]@{}
foreach ($k in $slots.Keys) {
    $label = if ($labels.Contains($k)) { $labels[$k] } else { (($k -creplace '([A-Z])', ' $1').Trim()).Substring(0, 1).ToUpper() + (($k -creplace '([A-Z])', ' $1').Trim()).Substring(1).ToLower() }
    $props[$k] = @{ Label = $label; Default = $slots[$k]; Group = 'terminal' }
}
$props['tabRow'] = @{ Label = 'Tab row'; Default = 'base' }

# The readability lift (a profile's readable.terminal) -- a69fc6c's rule: every colour slot
# against the background, 4.5:1; bright black and the cursor 3:1 (meant to stay dimmer);
# background, black, foreground and selection left as they are.
$readable = @(foreach ($k in 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
                             'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite') {
    @{ Fg = $k; Bg = 'background'; Min = 4.5; Guard = 'terminal' }
})
$readable += @{ Fg = 'brightBlack'; Bg = 'background'; Min = 3.0; Guard = 'terminal' }
$readable += @{ Fg = 'cursorColor'; Bg = 'background'; Min = 3.0; Guard = 'terminal' }

@{
    Id    = 'terminal'
    Label = 'Windows Terminal'
    Order = 80
    About = 'Windows Terminal''s "wallust" scheme and tab row (settings.json)'
    Properties = $props
    Readable = $readable
    Apply = {
        param($Values, $Theme, $Context)
        $path = Get-PaletteTerminalSettingsPath
        if (-not $path) { return @{ Status = 'skipped'; Message = "Windows Terminal settings.json not found -- skipped" } }
        $wt = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        # What these were before we ever touched them -- uninstall's Restore-WindowsTerminalSettings
        # puts them back (same label and shape the old pipeline wrote, so existing snapshots still work).
        $colorSchemeExisted = $wt['profiles'] -is [System.Collections.IDictionary] -and $wt['profiles']['defaults'] -is [System.Collections.IDictionary] -and $wt['profiles']['defaults'].Contains('colorScheme')
        $existingTheme = if ($wt['themes'] -is [array]) { @($wt['themes']) | Where-Object { $_['name'] -eq 'wallust' } | Select-Object -First 1 } else { $null }
        # A "wallust" scheme of someone else's that ours is about to replace: saved whole (since
        # 2026-10-07), so uninstall puts it back rather than leaving ours in its place.
        $existingScheme = @($wt['schemes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -eq 'wallust' } | Select-Object -First 1
        Save-PaletteOriginalStateOnce -Label 'terminal-colorscheme' -Data @{
            ColorSchemeExisted       = $colorSchemeExisted
            ColorScheme              = if ($colorSchemeExisted) { $wt['profiles']['defaults']['colorScheme'] } else { $null }
            ThemeKeyExisted          = $wt.Contains('theme')
            Theme                    = $wt['theme']
            WallustThemeEntryExisted = $null -ne $existingTheme
            WallustSchemeExisted     = $null -ne $existingScheme
            WallustScheme            = $existingScheme
        }
        if (-not $wt.Contains('profiles') -or $wt['profiles'] -isnot [System.Collections.IDictionary]) { $wt['profiles'] = [ordered]@{} }
        if (-not $wt['profiles'].Contains('defaults') -or $wt['profiles']['defaults'] -isnot [System.Collections.IDictionary]) { $wt['profiles']['defaults'] = [ordered]@{} }
        $wt['profiles']['defaults']['colorScheme'] = 'wallust'

        $scheme = [ordered]@{ name = 'wallust' }
        foreach ($k in $Values.Keys) { if ($k -ne 'tabRow') { $scheme[$k] = $Values[$k] } }
        $wt['schemes'] = @(@($wt['schemes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -ne 'wallust' }) + @($scheme)

        $wtTheme = [ordered]@{
            name   = 'wallust'
            tabRow = [ordered]@{ background = $Values.tabRow; unfocusedBackground = $Values.tabRow }
            window = [ordered]@{ applicationTheme = $(if ($Theme.AppDark) { 'dark' } else { 'light' }) }
        }
        $wt['themes'] = @(@($wt['themes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -ne 'wallust' }) + @($wtTheme)
        $wt['theme'] = 'wallust'

        $text = ($wt | ConvertTo-Json -Depth 50) + [Environment]::NewLine
        $changed = Write-PaletteFile -Path $path -Text $text
        $raised = @($Theme.Raised | Where-Object { $_ -like 'terminal.*' })
        $msg = 'Windows Terminal'
        if ($raised.Count) { $msg += " (raised contrast on $($raised.Count) colour$(if ($raised.Count -ne 1) { 's' }))" }
        if (-not $changed) { $msg += ' unchanged' }
        @{ Status = 'ok'; Message = $msg }
    }
}
