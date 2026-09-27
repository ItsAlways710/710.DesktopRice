# komorebi's window borders and stack tabs. Runtime-only state: komorebi starts on its own
# defaults (blue borders, grey tabs) every time, so scripts\Start-Komorebi.ps1 and
# tools\reload-stack.ps1 ask for these again (apply-wallust-outputs.ps1 -BordersOnly).
@{
    Id    = 'komorebi'
    Label = 'Borders and stack tabs'
    Order = 60
    About = 'komorebi (live, over its socket)'
    Properties = [ordered]@{
        focused        = @{ Label = 'Focused border';          Default = 'accent' }
        monocle        = @{ Label = 'Monocle border';          Default = 'lighten(accent, 25)' }
        stack          = @{ Label = 'Stack border';            Default = 'darken(accent, 20)' }
        unfocused      = @{ Label = 'Unfocused border';        Default = 'base' }
        tabBackground  = @{ Label = 'Stack tabs';              Default = 'base' }
        tabFocusedText = @{ Label = 'Focused stack tab text';  Default = 'text' }
        tabText        = @{ Label = 'Stack tab text';          Default = 'subtext' }
    }
    Readable = @(
        @{ Fg = 'tabFocusedText'; Bg = 'tabBackground'; Min = 4.5 }
        @{ Fg = 'tabText';        Bg = 'tabBackground'; Min = 3.0 }
    )
    Apply = {
        param($Values, $Theme, $Context)
        # komorebic talks to a running komorebi over its socket; with komorebi down the
        # connection is refused -- nothing to colour, so say so and move on.
        if (-not (Get-Process -Name 'komorebi' -ErrorAction SilentlyContinue)) {
            return @{ Status = 'skipped'; Message = "komorebi isn't running -- borders skipped" }
        }
        $kinds = [ordered]@{ single = 'focused'; monocle = 'monocle'; stack = 'stack'; unfocused = 'unfocused' }
        foreach ($kind in $kinds.Keys) {
            $rgb = ConvertTo-PaletteRgb -Hex $Values[$kinds[$kind]]
            & komorebic.exe border-colour --window-kind $kind $rgb.R $rgb.G $rgb.B 2>$null | Out-Null
        }
        # Stack tabs: komorebic has no command for their colours, komorebi 0.1.41 takes them as
        # Stackbar*Colour socket messages and repaints straight after. Best-effort -- a tab
        # colour that doesn't land is cosmetic.
        $tabs = [ordered]@{
            StackbarBackgroundColour    = 'tabBackground'
            StackbarFocusedTextColour   = 'tabFocusedText'
            StackbarUnfocusedTextColour = 'tabText'
        }
        $note = ''
        try {
            $messages = @(foreach ($name in $tabs.Keys) {
                $rgb = ConvertTo-PaletteRgb -Hex $Values[$tabs[$name]]
                [ordered]@{ type = $name; content = @($rgb.R, $rgb.G, $rgb.B) }
            })
            Send-PaletteKomorebiMessage -Messages $messages
        } catch { $note = " (stack tabs not set: $($_.Exception.Message))" }
        @{ Status = 'ok'; Message = "komorebi borders + stack tabs$note" }
    }
}
