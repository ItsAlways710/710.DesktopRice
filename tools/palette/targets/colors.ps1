# config\wallust\generated\colors.json -- the four colours the pipeline used to read back for
# komorebi (today it resolves them itself). Kept, the same four colours it always held (the
# Background, Accent, Subtext and Text roles), for anything of yours that still reads it; not
# shown in the editor.
@{
    Id     = 'colors'
    Label  = 'colors.json (legacy)'
    Order  = 30
    Hidden = $true
    About  = 'config\wallust\generated\colors.json'
    Properties = [ordered]@{
        color1 = @{ Label = 'color1'; Default = 'base' }
        color3 = @{ Label = 'color3'; Default = 'accent' }
        color5 = @{ Label = 'color5'; Default = 'subtext' }
        color6 = @{ Label = 'color6'; Default = 'text' }
    }
    Template = 'colors.json.tpl'
    Validate = 'json'
    Output   = { Join-Path (Get-PaletteRoot) 'config\wallust\generated\colors.json' }
}
