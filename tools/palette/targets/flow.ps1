# Flow Launcher -- the worked example of adding a target (claude/palette-profiles-plan.md, "How
# to add a target"): a template next to this file, where it goes (Output), and what else the app
# needs (Apply). Everything else -- the editor, the "keep text readable" guard, the theme stamp,
# doctor's "theme files" check -- picks the target up by itself.
#
# Flow 2.1.3 reads its theme once, at start (no file watcher -- Theme.cs in its source), and a
# running Flow saves its in-memory settings over Settings.json, so: our theme is selected with
# Flow stopped, and Flow is restarted when it was running -- unless this run is elevated (a Flow
# started from here would run as admin; the next SUPER+Space starts it as you) or Flow is set to
# show itself at start (HideOnStartup off -- a restart would pop it up on every wallpaper change).
@{
    Id    = 'flow'
    Label = 'Flow Launcher'
    Order = 50
    About = 'Flow Launcher''s theme (%APPDATA%\FlowLauncher\Themes\710sRice.xaml, selected in its settings)'
    Properties = [ordered]@{
        window        = @{ Label = 'Window';                    Default = 'base' }
        border        = @{ Label = 'Border';                    Default = 'accent' }
        query         = @{ Label = 'Search text';               Default = 'text' }
        caret         = @{ Label = 'Text cursor';               Default = 'accent' }
        selection     = @{ Label = 'Selected text';             Default = 'panel' }
        suggestion    = @{ Label = 'Autocomplete';              Default = 'subtext' }
        title         = @{ Label = 'Results';                   Default = 'text' }
        subtitle      = @{ Label = 'Result details and hints';  Default = 'subtext' }
        selected      = @{ Label = 'Selected result';           Default = 'accent' }
        selectedTitle = @{ Label = 'Selected result text';      Default = 'base' }
        highlight     = @{ Label = 'Matched letters';           Default = 'bright' }
        separator     = @{ Label = 'Separators';                Default = 'panel' }
    }
    # Like the menus: the selected row is the accent with the background colour as its text.
    Readable = @(
        @{ Fg = 'query';         Bg = 'window';   Min = 4.5 }
        @{ Fg = 'title';         Bg = 'window';   Min = 4.5 }
        @{ Fg = 'subtitle';      Bg = 'window';   Min = 3.0 }
        @{ Fg = 'highlight';     Bg = 'window';   Min = 3.0 }
        @{ Fg = 'selectedTitle'; Bg = 'selected'; Min = 3.0 }
    )
    Template = 'flow.xaml.tpl'
    Validate = 'xml'
    # Flow keeps its data in %APPDATA%\FlowLauncher once it has run; before that there's nowhere
    # to put a theme (no file written, Apply says so).
    Output = {
        $data = Join-Path $env:APPDATA 'FlowLauncher'
        if (Test-Path -LiteralPath $data) { Join-Path $data 'Themes\710sRice.xaml' }
    }
    Apply = {
        param($Values, $Theme, $Context)
        $data = Join-Path $env:APPDATA 'FlowLauncher'
        $settingsPath = Join-Path $data 'Settings\Settings.json'
        if (-not (Test-Path -LiteralPath $settingsPath)) {
            return @{ Status = 'skipped'; Message = "Flow Launcher hasn't run yet -- themed once it has (SUPER+Space, then change the wallpaper)" }
        }
        $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -AsHashtable
        $select = "$($settings['Theme'])" -ne '710sRice'
        if (-not $select -and -not $Context.Changed) { return @{ Status = 'ok'; Message = 'Flow Launcher unchanged' } }

        $flow = @(Get-Process -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)
        if ($flow.Count) {
            $flow | Stop-Process -Force
            $flow | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
        }
        if ($select) {
            # What it was before we ever picked ours -- uninstall's Restore-FlowTheme puts it back.
            Save-PaletteOriginalStateOnce -Label 'flow-theme' -Data @{ ThemeExisted = $settings.Contains('Theme'); Theme = $settings['Theme'] }
            $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -AsHashtable   # as the stopped Flow left it
            $settings['Theme'] = '710sRice'
            # The same writer tools\setup-flow-launcher.ps1 uses for this file.
            $settings | ConvertTo-Json -Depth 50 | Set-Content -Path $settingsPath -Encoding UTF8
        }
        $how = if ($select) { 'selected' } else { 'updated' }
        if (-not $flow.Count) { return @{ Status = 'ok'; Message = "Flow Launcher theme $how (Flow picks it up when it starts)" } }
        $exe = Join-Path $env:LOCALAPPDATA 'FlowLauncher\Flow.Launcher.exe'
        if ($Context.IsAdmin -or $settings['HideOnStartup'] -eq $false -or -not (Test-Path -LiteralPath $exe)) {
            return @{ Status = 'ok'; Message = "Flow Launcher theme $how -- Flow was stopped; SUPER+Space starts it with the new colours" }
        }
        # ShellExecute, never a plain CreateProcess: whatever runs this pipeline may be reading
        # its output through a pipe (YASB's run_after does, and waits for it to close) -- a Flow
        # that inherited that pipe would keep it open for as long as Flow runs.
        $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
        $psi.UseShellExecute = $true
        $psi.WorkingDirectory = Split-Path -Parent $exe
        $null = [System.Diagnostics.Process]::Start($psi)
        @{ Status = 'ok'; Message = "Flow Launcher theme $how (Flow restarted)" }
    }
}
