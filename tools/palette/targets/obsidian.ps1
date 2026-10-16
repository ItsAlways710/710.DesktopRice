# Obsidian -- every vault Obsidian lists on this machine gets the palette as a CSS snippet,
# <vault>\.obsidian\snippets\710rice.css, switched on in that vault's own appearance.json. One
# template, many vaults, so no Output: Apply writes each vault's copy (tools\lib\obsidian.ps1 has
# the vaults, the snapshot, the switch-on, uninstall's put-back and doctor's line).
#
# Obsidian repaints a snippet that's on the moment its file changes; which ones are on, it reads
# when it starts. So the first theme run that switches ours on while Obsidian is open shows after
# a restart of Obsidian, and says so; every wallpaper change after that repaints it live.
#
# The accent goes in Obsidian's own slot for it (--accent-h/s/l, as numbers: the template's
# {{accentH}}, {{accentS}} and {{accentL}}, Get-ObsidianSnippetText's), so it's only the default:
# an accent picked in Obsidian's settings goes over it, and Obsidian makes links, tags, buttons and
# the rest from whichever is showing (his call, 10-16). Links being the accent, the accent gets the
# links' readable pair.
@{
    Id    = 'obsidian'
    Label = 'Obsidian'
    Order = 50
    About = 'Obsidian, every vault it lists (<vault>\.obsidian\snippets\710rice.css, switched on in its appearance settings)'
    Properties = [ordered]@{
        background = @{ Label = 'Notes';                           Default = 'base' }
        panel      = @{ Label = 'Sidebars, tabs and title bar';    Default = 'panel' }
        hover      = @{ Label = 'Hover';                           Default = 'hover' }
        accent     = @{ Label = 'Accent: links, tags, buttons';    Default = 'accent' }
        text       = @{ Label = 'Text';                            Default = 'text' }
        muted      = @{ Label = 'Muted text: file list, details';  Default = 'subtext' }
        error      = @{ Label = 'Errors';                          Default = 'alert' }
    }
    # The file list is muted text on the sidebar's colour, so that pair counts as much as the notes'.
    Readable = @(
        @{ Fg = 'text';       Bg = 'background'; Min = 4.5 }
        @{ Fg = 'text';       Bg = 'panel';      Min = 4.5 }
        @{ Fg = 'muted';      Bg = 'background'; Min = 3.0 }
        @{ Fg = 'muted';      Bg = 'panel';      Min = 3.0 }
        @{ Fg = 'accent';     Bg = 'background'; Min = 3.0 }
        @{ Fg = 'error';      Bg = 'background'; Min = 3.0 }
    )
    Template = 'obsidian.css.tpl'
    Apply = {
        param($Values, $Theme, $Context)
        . (Join-Path (Get-PaletteRoot) 'tools\lib\obsidian.ps1')
        $found = Get-ObsidianVaults
        if (-not $found.Listed) { return @{ Status = 'skipped'; Message = "Obsidian hasn't run here -- themed once it has opened a vault (then change the wallpaper)" } }
        if (-not $found.Vaults.Count) { return @{ Status = 'skipped'; Message = 'Obsidian lists no vault that is on this machine' } }
        $css = Get-ObsidianSnippetText -Theme $Theme
        $written = 0; $enabled = 0; $failed = @()
        foreach ($v in $found.Vaults) {
            try {
                $r = Set-ObsidianVaultTheme -Vault $v -Css $css
                $written += [int]$r.Written; $enabled += [int]$r.Enabled
            } catch { $failed += "$(Split-Path -Leaf $v): $($_.Exception.Message)" }
        }
        if ($failed.Count) { throw "$($failed -join '; ')" }
        $n = $found.Vaults.Count; $vaults = "$n vault$(if ($n -ne 1) { 's' })"
        if (-not $written -and -not $enabled) { return @{ Status = 'ok'; Message = "Obsidian unchanged ($vaults)" } }
        $msg = "Obsidian themed ($vaults)"
        if ($enabled -and @(Get-Process -Name 'Obsidian' -ErrorAction SilentlyContinue).Count) {
            $msg += " -- restart Obsidian once to see it: it reads which snippets are on only when it starts"
        }
        @{ Status = 'ok'; Message = $msg }
    }
}
