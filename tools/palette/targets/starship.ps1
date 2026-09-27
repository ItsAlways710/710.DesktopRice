# The PowerShell prompt -- starship reads config\pwsh\starship.toml (config\pwsh\profile.ps1
# points STARSHIP_CONFIG at it), so a new prompt line picks the colours up.
@{
    Id    = 'starship'
    Label = 'Prompt'
    Order = 40
    About = 'starship (config\pwsh\starship.toml)'
    Properties = [ordered]@{
        prompt    = @{ Label = 'Prompt and folder';        Default = 'accent' }
        branch    = @{ Label = 'Git branch';               Default = 'bright' }
        status    = @{ Label = 'Git status, run time';     Default = 'subtext' }
        languages = @{ Label = 'Python / Node / Rust';     Default = 'text' }
        error     = @{ Label = 'Errors';                   Default = 'alert' }
    }
    # The prompt sits on Windows Terminal's background.
    Readable = @(
        @{ Fg = 'prompt';    Bg = 'terminal.background'; Min = 4.5 }
        @{ Fg = 'branch';    Bg = 'terminal.background'; Min = 4.5 }
        @{ Fg = 'languages'; Bg = 'terminal.background'; Min = 4.5 }
        @{ Fg = 'error';     Bg = 'terminal.background'; Min = 4.5 }
        @{ Fg = 'status';    Bg = 'terminal.background'; Min = 3.0 }
    )
    Template = 'starship.toml.tpl'
    Output   = { Join-Path (Get-PaletteRoot) 'config\pwsh\starship.toml' }
}
