# The menus -- SUPER+Alt+Space, SUPER+Esc, SUPER+K and Quick add's pick list are all 710.ahk's
# palette, which reads config\ahk\menu-colors.css on every open (the bar's file until this one
# exists). The palette editor dresses itself from it too.
@{
    Id    = 'menus'
    Label = 'Menus'
    Order = 20
    About = 'SUPER+Alt+Space, SUPER+Esc, SUPER+K and the palette editor (config\ahk\menu-colors.css)'
    Properties = [ordered]@{
        background   = @{ Label = 'Background';         Default = 'base' }
        text         = @{ Label = 'Text';               Default = 'text' }
        accent       = @{ Label = 'Selected row';       Default = 'accent' }
        selectedText = @{ Label = 'Selected row text';  Default = 'base' }
        subtext      = @{ Label = 'Hints and headings'; Default = 'subtext' }
    }
    Readable = @(
        @{ Fg = 'text';         Bg = 'background'; Min = 4.5 }
        @{ Fg = 'subtext';      Bg = 'background'; Min = 3.0 }
        @{ Fg = 'selectedText'; Bg = 'accent';     Min = 3.0 }
    )
    Template = 'menus.css.tpl'
    Output   = { Join-Path (Get-PaletteRoot) 'config\ahk\menu-colors.css' }
}
