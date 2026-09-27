# The bar. YASB reads config\yasb\wallust_colors.css (styles.css pulls it in, and
# watch_stylesheet repaints the bar a moment after every write).
@{
    Id    = 'yasb'
    Label = 'Bar'
    Order = 10
    About = 'YASB (config\yasb\wallust_colors.css)'
    Properties = [ordered]@{
        background  = @{ Label = 'Background';       Default = 'base' }
        background2 = @{ Label = 'Panels';           Default = 'panel' }
        accent      = @{ Label = 'Accent';           Default = 'accent' }
        text        = @{ Label = 'Text';             Default = 'text' }
        accentText  = @{ Label = 'Text on accent';   Default = 'bright' }
        hover       = @{ Label = 'Hover';            Default = 'hover' }
        mutedBG     = @{ Label = 'Muted background'; Default = 'panel' }
        border      = @{ Label = 'Borders';          Default = 'panel' }
        subtext     = @{ Label = 'Subtext';          Default = 'subtext' }
    }
    # The "keep text readable" guard (a profile's readable.ui): Fg moves until it reads on Bg.
    Readable = @(
        @{ Fg = 'text';       Bg = 'background'; Min = 4.5 }
        @{ Fg = 'subtext';    Bg = 'background'; Min = 3.0 }
        @{ Fg = 'accentText'; Bg = 'accent';     Min = 3.0 }
    )
    Template = 'yasb.css.tpl'
    Output   = { Join-Path (Get-PaletteRoot) 'config\yasb\wallust_colors.css' }
}
