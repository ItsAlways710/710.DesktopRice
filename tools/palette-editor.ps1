#Requires -Version 7.0
<#
.SYNOPSIS
    The palette profile editor: create, edit and delete palette profiles, with a live preview.

.DESCRIPTION
    SUPER+Alt+Space > Palette profiles > Create / Edit, or `710sRice palette new | edit`, start
    this in its own hidden pwsh (-STA); it shows a WPF window (tools\palette-editor.xaml) and
    nothing else. One editor at a time: a second start brings the open one to the front.

    What's on it (claude/palette-profiles-plan.md, "Stage 5"):
      - the color source and its settings, and the palette it makes from the wallpaper that's
        up now (wallust runs in the background, into a config of the editor's own -- never the
        pipeline's files);
      - the eight roles, each with every app color that follows it underneath; any color
        opens the color selector (a palette slot, a role, a fixed color, lighter / darker /
        mixed), and an app color picked there becomes that app's own (an override);
      - readable text, light / dark, and which apps the profile themes;
      - a preview of the bar, menus, Flow, Terminal and the prompt, borders and stack tabs
        and the Windows accent, repainted on every change -- click any of it to change it.
    Save writes config\palettes\profileN.json (Default can't be changed: Save as new);
    "Save and use" also themes everything with it (tools\apply-wallust-outputs.ps1
    -ProfileId, in a process of its own); saving the profile in use re-themes too, so what's on
    screen never lags behind the file.

.PARAMETER ProfileId
    The profile to open (default, 0-9, profileN or its name). Left out: the one in use. A slot
    with no profile yet opens as a new profile for that slot.
.PARAMETER New
    A new profile, saved in the first free slot (or -ProfileId's, when it's free).
.PARAMETER From
    With -New: where to start from (left out: the profile in use).
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProfileId,
    [switch]$New,
    [string]$From
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'tools\lib\palette.ps1')
. (Join-Path $Root 'tools\lib\palette-edit.ps1')

$script:Dot = [char]0x00B7
$script:Chev = [char]0x203A
$script:LogPath = Join-Path (Get-PaletteStateDir) 'palette-editor.log'

function Write-EditorLog {
    # Everything the editor did or tripped over; one rule for every log of ours: 1 MB, one .old.
    param([Parameter(Mandatory)][string]$Message)
    try {
        $null = New-Item -ItemType Directory -Force -Path (Get-PaletteStateDir)
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $script:LogPath -Destination "$script:LogPath.old" -Force
        }
        Add-Content -LiteralPath $script:LogPath -Encoding utf8 -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (ConvertTo-PaletteSafeText $Message))
    } catch { }
}

# --- one editor at a time ------------------------------------------------------------------
$script:Mutex = [System.Threading.Mutex]::new($false, 'Local\710sRice.PaletteEditor')
$owned = $false
try { $owned = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    # The open one comes to the front (its unsaved changes are its own business).
    try { Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.Interaction]::AppActivate('710sRice palette profiles') } catch { }
    exit 0
}
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-EditorLog 'not started -STA (WPF needs it) -- start it through 710sRice palette edit / the menu'
    exit 1
}
Write-EditorLog "--- start: -ProfileId '$ProfileId' -New:$New -From '$From'"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ------------------------------------------------------------------------------------------
# Colors and brushes
# ------------------------------------------------------------------------------------------
$script:BrushCache = @{}
function Get-Brush {
    param([Parameter(Mandatory)][string]$Hex)
    $b = $script:BrushCache[$Hex]
    if (-not $b) {
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
        $b.Freeze()
        $script:BrushCache[$Hex] = $b
    }
    $b
}

function Get-EditorColors {
    <# The editor wears the menus' colors (config\ahk\menu-colors.css; the bar's file until the
       menus have their own) -- 710.ahk's fallbacks before either exists. #>
    $c = [ordered]@{ Bg = '#2B2B2B'; Text = '#E0E0E0'; Accent = '#5C41A5'; OnAccent = $null; Sub = '#9A9A9A' }
    foreach ($f in @((Join-Path $Root 'config\ahk\menu-colors.css'), (Join-Path $Root 'config\yasb\wallust_colors.css'))) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $css = [IO.File]::ReadAllText($f)
        foreach ($pair in @(@('Bg', 'background'), @('Text', 'text'), @('Accent', 'accent'), @('Sub', 'subtext'), @('OnAccent', 'selectedText'))) {
            if ($css -match "--wallust-$($pair[1])\s*:\s*(#[0-9A-Fa-f]{6})") { $c[$pair[0]] = $Matches[1] }
        }
        break
    }
    if (-not $c.OnAccent) { $c.OnAccent = $c.Bg }   # 710.ahk: the background color on the accent bar
    $c
}

function Set-EditorBrushes {
    $c = Get-EditorColors
    $res = $script:Window.Resources
    $res['B.Bg'] = Get-Brush $c.Bg
    $res['B.Text'] = Get-Brush $c.Text
    $res['B.Sub'] = Get-Brush $c.Sub
    $res['B.Accent'] = Get-Brush $c.Accent
    $res['B.OnAccent'] = Get-Brush $c.OnAccent
    $res['B.Panel'] = Get-Brush (Get-PaletteMixedHex -A $c.Bg -B $c.Text -Weight 0.07)
    $res['B.Line'] = Get-Brush (Get-PaletteMixedHex -A $c.Bg -B $c.Sub -Weight 0.4)
    $res['B.Hover'] = Get-Brush (Get-PaletteMixedHex -A $c.Bg -B $c.Accent -Weight 0.22)
    $res['B.Scrim'] = Get-Brush ('#D0' + $c.Bg.TrimStart('#'))
    $script:EditorColors = $c
}

function Get-TextOn {
    # Black or white, whichever reads on $Hex.
    param([string]$Hex)
    if (Test-PaletteIsLight $Hex) { '#000000' } else { '#FFFFFF' }
}

# ------------------------------------------------------------------------------------------
# The window
# ------------------------------------------------------------------------------------------
try {
    $script:Window = [System.Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'palette-editor.xaml')))
} catch {
    Write-EditorLog "the window didn't load: $($_.Exception.GetBaseException().Message)"
    throw
}
$script:Ui = @{}
foreach ($n in @('Header', 'Crumb', 'InUse', 'Blurb', 'CloseX', 'LeftScroll', 'NameBox', 'NameHint', 'FromRow', 'FromPanel',
                 'KindPanel', 'KindWallpaper', 'KindMatch', 'KindTheme', 'KindRandom', 'KindScheme', 'KindHint',
                 'WallpaperOpts', 'MethodKmeans', 'MethodSalience', 'MethodAnsi', 'MethodHint', 'StyleDark', 'StyleLight', 'StyleHint',
                 'SatOn', 'SatSlider', 'SatValue', 'Cols16', 'MatchOpts', 'MatchNote', 'MatchPanel', 'ThemeOpts', 'CloseNote', 'ClosePanel',
                 'ThemeSearch', 'ThemeList', 'RandomOpts', 'Shuffle', 'SchemeOpts', 'SchemePanel', 'SchemeNote', 'SchemeFolder',
                 'PaletteNote', 'PaletteStrip', 'RolesPanel', 'PresetDefault', 'PresetTerminal', 'PresetHint', 'TermLighten', 'TermAuto', 'TermOff', 'TermReadHint', 'ReadUi',
                 'ModeDark', 'ModeLight', 'ModeAuto', 'TargetsPanel',
                 'PickerLayer', 'PkTitle', 'PkAbout', 'PkSwatch', 'PkHex', 'PkWhat', 'PkSlotRow', 'PkSlotBase', 'PkSlotOther',
                 'PkPalette', 'PkRoles', 'PkSV', 'PkHueFill', 'PkSVThumb', 'PkHue', 'PkHueThumb', 'PkHexBox',
                 'PkAdjNone', 'PkAdjLighten', 'PkAdjDarken', 'PkAdjMix', 'PkAmountRow', 'PkAmount', 'PkAmountText',
                 'PkExpr', 'PkError', 'PkReset', 'PkUse', 'PkCancel',
                 'Preview', 'PreviewHint', 'MockBar', 'MockMenu', 'MockFlow', 'MockTerm', 'MockWin', 'MockAccent', 'MockAccentText', 'AnsiGrid',
                 'CapBar', 'CapMenu', 'CapFlow', 'CapTerm', 'CapWin',
                 'Status', 'BtnDelete', 'BtnCancel', 'BtnSave', 'BtnSaveUse', 'AskLayer', 'AskTitle', 'AskText', 'AskNo', 'AskYes')) {
    $el = $script:Window.FindName($n)
    if ($null -eq $el) { throw "palette-editor.xaml has no element named $n" }
    $script:Ui[$n] = $el
}
$script:SegStyle = $script:Window.FindResource('Seg')
Set-EditorBrushes

function Set-Backdrop {
    # The preview's backdrop: the wallpaper that's up, decoded small (a 4K picture would cost
    # 100+ ms and a lot of memory for a 470-px panel).
    param([string]$Image)
    if (-not $Image) { return }
    try {
        $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
        $bmp.BeginInit()
        $bmp.UriSource = [Uri]::new($Image)
        $bmp.DecodePixelWidth = 720
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $bmp.Freeze()
        $brush = [System.Windows.Media.ImageBrush]::new($bmp)
        $brush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        $brush.Freeze()
        $script:Window.FindName('BackdropImage').Background = $brush
    } catch { Write-EditorLog "backdrop: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------
$script:Targets = @(Get-PaletteTargets)
$script:Shown = @($script:Targets | Where-Object { -not $_.Hidden })
$script:Layout = Get-PaletteEditorLayout -Targets $script:Targets
$script:Mode = 'edit'          # edit | default | new
$script:Id = $null             # the slot being edited ('default', 'profileN'); new: the slot it'll go in, if asked for
$script:Work = $null           # the profile as edited (ConvertTo-PaletteProfile's shape)
$script:Baseline = ''          # its saved form when opened / last saved (dirty = different)
$script:Palette = $null        # the 19 colors the source makes from the wallpaper that's up
$script:PaletteKey = ''
$script:Theme = $null          # Resolve-PaletteTheme of Work + Palette
$script:ThemeError = $null
$script:Image = $null
$script:Updating = $false      # true while code sets controls (their events must not echo back)
$script:PaletteCache = @{}
$script:ThemeNames = $null
$script:ThemeMatches = @{}     # image -> closest themes (not $Matches: -match owns that name)
$script:RandomRound = 0
$script:Busy = $null           # a running theme run (Start-EditorApply)
$script:Pk = $null             # the open color selector
$script:Ask = $null            # the open question
$script:RoleUi = [ordered]@{}
$script:PropUi = @{}
$script:Tagged = [System.Collections.Generic.List[object]]::new()

function Get-WorkJson { ConvertTo-PaletteProfileJson -Profile $script:Work }
function Test-Dirty { (Get-WorkJson) -ne $script:Baseline }
function Test-SettingsChanged {
    # Changed anything but the name? (starting over from another profile keeps the name)
    $keep = $script:Work.name
    try { $script:Work.name = ''; (Get-WorkJson) -ne $script:BaselineNoName } finally { $script:Work.name = $keep }
}
function Update-Known {
    # What the other slots hold (names, the one in use) -- read once, again after a save / delete /
    # theme run, never per keystroke (reading a profile validates it: ~20 ms each).
    $script:Known = @(Get-PaletteProfiles)
    $script:ChosenId = (Resolve-ActivePaletteProfile).Id
}
function Get-ChosenId { $script:ChosenId }

function Set-Status {
    param([string]$Text, [switch]$Warn, [string]$Details)
    $script:Ui.Status.Text = ConvertTo-PaletteSafeText $Text
    $script:Ui.Status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($Warn) { 'B.Warn' } else { 'B.Sub' }))
    $script:Ui.Status.ToolTip = if ($Details) { ConvertTo-PaletteSafeText $Details } else { $null }
}

# ------------------------------------------------------------------------------------------
# Background work: wallust runs in a runspace of its own, one at a time; a timer collects
# ------------------------------------------------------------------------------------------
$script:Rs = [runspacefactory]::CreateRunspace()
$script:Rs.Open()
$script:Jobs = [System.Collections.Generic.List[object]]::new()
$script:Job = $null
$script:Scratch = Initialize-PaletteScratchConfig
$script:JobScript = {
    param($Lib, $EditLib, $Kind, $Arg)
    if (-not (Get-Command Get-PaletteFromSource -ErrorAction SilentlyContinue)) { . $Lib; . $EditLib }
    try {
        switch ($Kind) {
            'palette' { @{ Ok = $true; Value = (Get-PaletteFromSource -Source $Arg.Source -Image $Arg.Image -ConfigDir $Arg.ConfigDir -DumpPath $Arg.DumpPath) } }
            'themes'  { @{ Ok = $true; Value = @(Get-PaletteThemeNames) } }
            'matches' { @{ Ok = $true; Value = @(Get-PaletteThemeMatches -Image $Arg.Image -Top 8) } }
        }
    } catch { @{ Ok = $false; Value = $_.Exception.Message } }
}

function Add-EditorJob {
    <# Queues wallust work; a newer job of the same kind replaces a queued (not yet running) one. #>
    param([Parameter(Mandatory)][string]$Kind, [string]$Key, $Arg)
    for ($i = $script:Jobs.Count - 1; $i -ge 0; $i--) { if ($script:Jobs[$i].Kind -eq $Kind) { $script:Jobs.RemoveAt($i) } }
    $script:Jobs.Add([pscustomobject]@{ Kind = $Kind; Key = $Key; Arg = $Arg })
    Step-EditorJobs
}

function Step-EditorJobs {
    if ($script:Job) {
        if (-not $script:Job.Handle.IsCompleted) { return }
        $j = $script:Job
        $script:Job = $null
        $res = $null
        try { $res = @($j.PS.EndInvoke($j.Handle)) | Select-Object -Last 1 } catch { $res = @{ Ok = $false; Value = $_.Exception.GetBaseException().Message } }
        $j.PS.Dispose()
        if (-not $res) { $res = @{ Ok = $false; Value = 'no answer from wallust' } }
        try { Complete-EditorJob -Job $j.Job -Result $res } catch { Write-EditorLog "after $($j.Job.Kind): $($_.Exception.Message)" }
    }
    if ($script:Jobs.Count -eq 0) { return }
    $next = $script:Jobs[0]
    $script:Jobs.RemoveAt(0)
    $ps = [powershell]::Create()
    $ps.Runspace = $script:Rs
    $null = $ps.AddScript($script:JobScript).AddArgument((Join-Path $Root 'tools\lib\palette.ps1')).AddArgument((Join-Path $Root 'tools\lib\palette-edit.ps1')).AddArgument($next.Kind).AddArgument($next.Arg)
    $script:Job = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Job = $next }
}

function Complete-EditorJob {
    param($Job, $Result)
    switch ($Job.Kind) {
        'palette' {
            if ($Result.Ok) {
                $pal = [ordered]@{}
                foreach ($k in $Result.Value.Keys) { $pal[$k] = $Result.Value[$k] }
                $script:PaletteCache[$Job.Key] = $pal
                Write-EditorLog "palette made: $($Job.Arg.What)"
            } else {
                $script:PaletteCache[$Job.Key] = [pscustomobject]@{ Error = "$($Result.Value)" }
                Write-EditorLog "palette FAILED ($($Job.Arg.What)): $($Result.Value)"
            }
            if ($Job.Key -eq $script:PaletteKey) { Use-EditorPalette }
        }
        'themes' {
            if ($Result.Ok) { $script:ThemeNames = @($Result.Value); Update-ThemeList }
            else { $script:ThemeNames = @(); $script:Ui.CloseNote.Text = "wallust couldn't list its themes: $($Result.Value)" }
        }
        'matches' {
            $script:ThemeMatches[$Job.Key] = if ($Result.Ok) { , @($Result.Value) } else { [pscustomobject]@{ Error = "$($Result.Value)" } }
            Update-MatchLists
        }
    }
}

$script:Timer = [System.Windows.Threading.DispatcherTimer]::new()
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(70)
$script:Timer.Add_Tick({
    try { Step-EditorJobs; Step-EditorApply; Step-EditorDeferred } catch { Write-EditorLog "timer: $($_.Exception.Message)" }
})

# Work that should wait for a pause (slider drags, typing): the last request wins.
$script:Deferred = @{}
function Request-Deferred {
    param([Parameter(Mandatory)][string]$Name, [int]$Ms = 160)
    $script:Deferred[$Name] = (Get-Date).AddMilliseconds($Ms)
}
function Step-EditorDeferred {
    if (-not $script:Deferred.Count) { return }
    $now = Get-Date
    foreach ($n in @($script:Deferred.Keys)) {
        if ($script:Deferred[$n] -le $now) {
            $script:Deferred.Remove($n)
            switch ($n) {
                'theme'       { Update-Theme }
                'themeSearch' { Update-ThemeList }
                'pickerLive'  { Update-PickerLive }
                'pickerExpr'  { Read-PickerExpression }
                'sat'         { Request-EditorPalette }
                'answer'      { Invoke-AskAnswer }
            }
        }
    }
}

# ------------------------------------------------------------------------------------------
# The palette for the profile's source, on the wallpaper that's up now
# ------------------------------------------------------------------------------------------
function Get-EditorPaletteKey {
    $src = $script:Work.source
    $key = Get-PaletteSourceKey -Source $src
    if (Test-PaletteSourceUsesImage -Source $src) { $key += "|$script:Image|$(Get-PaletteImageStamp $script:Image)" }
    if ($src.kind -eq 'random') { $key += "|$script:RandomRound" }
    $key
}

function Request-EditorPalette {
    $src = $script:Work.source
    $key = Get-EditorPaletteKey
    $script:PaletteKey = $key
    if ($script:PaletteCache.ContainsKey($key)) { Use-EditorPalette; return }
    if ((Test-PaletteSourceUsesImage -Source $src) -and -not $script:Image) {
        $script:PaletteCache[$key] = [pscustomobject]@{ Error = 'no wallpaper file to read (change the wallpaper once)' }
        Use-EditorPalette
        return
    }
    if ($src.kind -eq 'scheme' -and -not (Test-Path -LiteralPath (Join-Path (Get-PaletteSchemesDir) "$($src.file)") -PathType Leaf)) {
        # Nothing picked yet (or the file's gone): no wallust run for a name that isn't there.
        $script:PaletteCache[$key] = [pscustomobject]@{ Error = 'no scheme file'; Note = 'Pick a scheme file -- showing the last palette meanwhile' }
        Use-EditorPalette
        return
    }
    # The pipeline's last palette is this one when the source and wallpaper match -- no wallust run.
    $last = Read-PaletteLastGood
    if ($last -and $src.kind -ne 'random' -and $last.SourceKey -eq (Get-PaletteSourceKey -Source $src) -and
        (-not (Test-PaletteSourceUsesImage -Source $src) -or ($last.Image -eq "$script:Image" -and $last.ImageStamp -eq (Get-PaletteImageStamp $script:Image)))) {
        $script:PaletteCache[$key] = $last.Palette
        Use-EditorPalette
        return
    }
    $script:Ui.PaletteNote.Text = 'making the palette' + [char]0x2026
    $copy = [ordered]@{}; foreach ($k in $src.Keys) { $copy[$k] = $src[$k] }
    $what = Get-PaletteSourceSummary -Source $src
    if ((Test-PaletteSourceUsesImage -Source $src) -and $script:Image) { $what += " from $(Split-Path -Leaf $script:Image)" }
    Add-EditorJob -Kind 'palette' -Key $key -Arg @{ Source = $copy; Image = $script:Image; ConfigDir = $script:Scratch.ConfigDir; DumpPath = $script:Scratch.DumpPath; What = $what }
}

function Use-EditorPalette {
    $got = $script:PaletteCache[$script:PaletteKey]
    $src = $script:Work.source
    $where = if ((Test-PaletteSourceUsesImage -Source $src) -and $script:Image) { "from $(Split-Path -Leaf $script:Image)" } else { '' }
    if ($got -is [System.Collections.IDictionary]) {
        $script:Palette = $got
        $script:Ui.PaletteNote.Text = "$(Get-PaletteSourceSummary -Source $src) $where".Trim()
        $script:Ui.PaletteNote.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'B.Sub')
    } else {
        # Keep showing the last palette we had (or the pipeline's) so the rest stays usable.
        if (-not $script:Palette) { $l = Read-PaletteLastGood; if ($l) { $script:Palette = $l.Palette } }
        $script:Ui.PaletteNote.Text = if ($got.PSObject.Properties['Note']) { $got.Note } else { ConvertTo-PaletteSafeText "wallust couldn't: $($got.Error) -- showing the last palette" }
        $script:Ui.PaletteNote.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'B.Warn')
    }
    Update-PaletteStrip
    Update-Theme
}

# ------------------------------------------------------------------------------------------
# Small builders
# ------------------------------------------------------------------------------------------
function New-Swatch {
    param([double]$Width = 26, [double]$Height = 26, [double]$Radius = 5)
    $b = [System.Windows.Controls.Border]::new()
    $b.Width = $Width; $b.Height = $Height
    $b.CornerRadius = [System.Windows.CornerRadius]::new($Radius)
    $b.BorderThickness = [System.Windows.Thickness]::new(1)
    $b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'B.Line')
    $b
}

function New-Text {
    param([string]$Text, [string]$Brush = 'B.Text', [double]$Size = 0, [switch]$Bold)
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Text
    $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Brush)
    if ($Size) { $t.FontSize = $Size }
    if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::Bold }
    $t.VerticalAlignment = 'Center'
    $t
}

function New-Seg {
    param([string]$Text, [string]$Tag, [string]$Tip)
    $r = [System.Windows.Controls.RadioButton]::new()
    $r.Style = $script:SegStyle
    $r.Content = $Text
    $r.Tag = $Tag
    if ($Tip) { $r.ToolTip = $Tip }
    $r
}

function Get-TargetLabel { param([string]$Id) (@($script:Targets | Where-Object Id -eq $Id) | Select-Object -First 1).Label }
function Get-PropLabel {
    param([string]$Target, [string]$Prop)
    $t = @($script:Targets | Where-Object Id -eq $Target) | Select-Object -First 1
    "$($t.Label) $script:Chev $($t.Properties[$Prop].Label)"
}

function Get-ExpressionWords {
    <# An expression the way the editor says it: "Accent", "color3", "Accent, 25% lighter",
       "#d35f5f", "color1 mixed 30% with Text". #>
    param([string]$Text)
    $name = {
        param($n)
        if ($script:PaletteRoles.Contains($n)) { $script:PaletteRoles[$n].Label } else { $n }
    }
    try { $s = Split-PaletteExpression -Text $Text } catch { return $Text }
    if (-not $s.Simple) { return $Text }
    $b = & $name $s.Base
    switch ($s.Adjust) {
        'lighten' { "$b, $($s.Amount)% lighter" }
        'darken'  { "$b, $($s.Amount)% darker" }
        'mix'     { "$b mixed $($s.Amount)% with $(& $name $s.Other)" }
        default   { $b }
    }
}

# ------------------------------------------------------------------------------------------
# Building the dynamic parts (once)
# ------------------------------------------------------------------------------------------
function Build-PaletteStrip {
    $script:Ui.PaletteStrip.Children.Clear()
    $script:StripSwatches = @{}
    foreach ($slot in $script:PaletteSlots) {
        $sp = [System.Windows.Controls.StackPanel]::new()
        $sp.Margin = [System.Windows.Thickness]::new(0, 0, 5, 6)
        $sw = New-Swatch -Width 30 -Height 30 -Radius 5
        $sp.Children.Add($sw) | Out-Null
        $short = switch ($slot) { 'background' { 'bg' } 'foreground' { 'fg' } 'cursor' { 'cur' } default { $slot.Substring(5) } }
        $lbl = New-Text -Text $short -Brush 'B.Sub' -Size 10
        $lbl.HorizontalAlignment = 'Center'
        $sp.Children.Add($lbl) | Out-Null
        $script:Ui.PaletteStrip.Children.Add($sp) | Out-Null
        $script:StripSwatches[$slot] = $sw
    }
}

function Update-PaletteStrip {
    foreach ($slot in $script:PaletteSlots) {
        $sw = $script:StripSwatches[$slot]
        if ($script:Palette) {
            $sw.Background = Get-Brush $script:Palette[$slot]
            $sw.ToolTip = "$slot  $($script:Palette[$slot])"
        }
    }
}

function Build-RoleRows {
    $script:Ui.RolesPanel.Children.Clear()
    $groups = @($script:PaletteRoles.Keys) + @('palette')
    foreach ($role in $groups) {
        $isRole = $role -ne 'palette'
        $items = $script:Layout[$role]
        $wrap = [System.Windows.Controls.StackPanel]::new()

        $row = [System.Windows.Controls.Border]::new()
        $row.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $row.Padding = [System.Windows.Thickness]::new(4, 4, 8, 4)
        $row.Background = [System.Windows.Media.Brushes]::Transparent
        $row.Tag = $role
        $grid = [System.Windows.Controls.Grid]::new()
        foreach ($w in @(28, 38, 170, -1, 160)) {
            $cd = [System.Windows.Controls.ColumnDefinition]::new()
            $cd.Width = if ($w -lt 0) { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::new($w) }
            $grid.ColumnDefinitions.Add($cd)
        }
        $chev = [System.Windows.Controls.Button]::new()
        $chev.Style = $script:Window.FindResource('Ghost')
        $chev.Content = [string]$script:Chev
        $chev.FontSize = 15
        $chev.Focusable = $false
        $chev.Tag = $role
        $chev.ToolTip = 'Show the app colors that follow this'
        $chev.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
        $chev.Add_Click({ param($s, $e) Switch-RoleOpen -Role $s.Tag; $e.Handled = $true })
        [System.Windows.Controls.Grid]::SetColumn($chev, 0)
        $grid.Children.Add($chev) | Out-Null

        $sw = New-Swatch -Width 28 -Height 22 -Radius 5
        [System.Windows.Controls.Grid]::SetColumn($sw, 1)
        $grid.Children.Add($sw) | Out-Null
        $label = if ($isRole) { $script:PaletteRoles[$role].Label } else { 'Terminal' }
        $lt = New-Text -Text $label -Bold:$isRole
        [System.Windows.Controls.Grid]::SetColumn($lt, 2)
        $grid.Children.Add($lt) | Out-Null
        $expr = New-Text -Text '' -Brush 'B.Sub'
        $expr.TextTrimming = 'CharacterEllipsis'
        [System.Windows.Controls.Grid]::SetColumn($expr, 3)
        $grid.Children.Add($expr) | Out-Null
        $count = New-Text -Text "$($items.Count) place$(if ($items.Count -ne 1) { 's' })" -Brush 'B.Sub' -Size 11
        $count.HorizontalAlignment = 'Right'
        [System.Windows.Controls.Grid]::SetColumn($count, 4)
        $grid.Children.Add($count) | Out-Null
        $row.Child = $grid
        if ($isRole) {
            $row.Cursor = [System.Windows.Input.Cursors]::Hand
            $row.ToolTip = $script:PaletteRoles[$role].About
            $row.Add_MouseEnter({ param($s, $e) $s.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'B.Hover') })
            $row.Add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })
            $row.Add_MouseLeftButtonUp({ param($s, $e) Open-Picker -Kind 'role' -Role $s.Tag })
        } else {
            $sw.Visibility = 'Hidden'
            $expr.Text = 'its colors, straight from the palette'
            $row.ToolTip = 'Windows Terminal''s sixteen colors, background, text, cursor and selection: palette slots, not roles'
            $row.Cursor = [System.Windows.Input.Cursors]::Hand
            $row.Add_MouseLeftButtonUp({ param($s, $e) Switch-RoleOpen -Role $s.Tag })
        }
        $wrap.Children.Add($row) | Out-Null

        $props = [System.Windows.Controls.StackPanel]::new()
        $props.Margin = [System.Windows.Thickness]::new(66, 0, 0, 6)
        $props.Visibility = 'Collapsed'
        foreach ($it in $items) {
            $key = "$($it.Target).$($it.Prop)"
            $pr = [System.Windows.Controls.Border]::new()
            $pr.CornerRadius = [System.Windows.CornerRadius]::new(5)
            $pr.Padding = [System.Windows.Thickness]::new(4, 2, 6, 2)
            $pr.Background = [System.Windows.Media.Brushes]::Transparent
            $pr.Cursor = [System.Windows.Input.Cursors]::Hand
            $pr.Tag = $key
            $pg = [System.Windows.Controls.Grid]::new()
            foreach ($w in @(30, 290, -1, 34)) {
                $cd = [System.Windows.Controls.ColumnDefinition]::new()
                $cd.Width = if ($w -lt 0) { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::new($w) }
                $pg.ColumnDefinitions.Add($cd)
            }
            $psw = New-Swatch -Width 20 -Height 16 -Radius 4
            $psw.HorizontalAlignment = 'Left'
            [System.Windows.Controls.Grid]::SetColumn($psw, 0)
            $pg.Children.Add($psw) | Out-Null
            $pl = New-Text -Text "$($it.TargetLabel) $script:Chev $($it.Label)" -Size 12
            $pl.TextTrimming = 'CharacterEllipsis'
            [System.Windows.Controls.Grid]::SetColumn($pl, 1)
            $pg.Children.Add($pl) | Out-Null
            $pe = New-Text -Text '' -Brush 'B.Sub' -Size 12
            $pe.TextTrimming = 'CharacterEllipsis'
            [System.Windows.Controls.Grid]::SetColumn($pe, 2)
            $pg.Children.Add($pe) | Out-Null
            $reset = [System.Windows.Controls.Button]::new()
            $reset.Style = $script:Window.FindResource('Ghost')
            $reset.Content = [string][char]0x21BA
            $reset.Tag = $key
            $reset.ToolTip = 'Follow the role again'
            $reset.Visibility = 'Hidden'
            $reset.Add_Click({ param($s, $e) Reset-Override -Key $s.Tag; $e.Handled = $true })
            [System.Windows.Controls.Grid]::SetColumn($reset, 3)
            $pg.Children.Add($reset) | Out-Null
            $pr.Child = $pg
            $pr.Add_MouseEnter({ param($s, $e) $s.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'B.Hover') })
            $pr.Add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })
            $pr.Add_MouseLeftButtonUp({ param($s, $e) $t, $p = "$($s.Tag)".Split('.', 2); Open-Picker -Kind 'prop' -Target $t -Prop $p })
            $props.Children.Add($pr) | Out-Null
            $script:PropUi[$key] = @{ Row = $pr; Swatch = $psw; Label = $pl; Expr = $pe; Reset = $reset; Target = $it.Target; Prop = $it.Prop; Role = $role }
        }
        $wrap.Children.Add($props) | Out-Null
        $script:Ui.RolesPanel.Children.Add($wrap) | Out-Null
        $script:RoleUi[$role] = @{ Row = $row; Swatch = $sw; Expr = $expr; Count = $count; Props = $props; Chev = $chev }
    }
}

function Switch-RoleOpen {
    param([string]$Role)
    $r = $script:RoleUi[$Role]
    $open = $r.Props.Visibility -ne 'Visible'
    $r.Props.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
    $r.Chev.RenderTransform = if ($open) { [System.Windows.Media.RotateTransform]::new(90) } else { $null }
}

function Build-TargetToggles {
    $script:Ui.TargetsPanel.Children.Clear()
    $script:TargetBoxes = @{}
    foreach ($t in $script:Shown) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        $cb.Content = $t.Label
        $cb.Tag = $t.Id
        if ($t.About) { $cb.ToolTip = $t.About }
        $cb.Add_Click({ param($s, $e) Set-TargetOn -Id $s.Tag -On ($s.IsChecked -eq $true) })
        $script:Ui.TargetsPanel.Children.Add($cb) | Out-Null
        $script:TargetBoxes[$t.Id] = $cb
    }
}

function Build-AnsiGrid {
    $script:Ui.AnsiGrid.Children.Clear()
    foreach ($row in @(@('black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white'),
                       @('brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite'))) {
        foreach ($k in $row) {
            $sp = [System.Windows.Controls.StackPanel]::new()
            $sp.Margin = [System.Windows.Thickness]::new(0, 0, 4, 4)
            $t = [System.Windows.Controls.TextBlock]::new()
            $t.Text = 'Aa'
            $t.HorizontalAlignment = 'Center'
            $t.Tag = "Foreground=terminal.$k"
            $bar = [System.Windows.Controls.Border]::new()
            $bar.Height = 5
            $bar.CornerRadius = [System.Windows.CornerRadius]::new(2)
            $bar.Tag = "Background=terminal.$k"
            $sp.Children.Add($t) | Out-Null
            $sp.Children.Add($bar) | Out-Null
            $script:Ui.AnsiGrid.Children.Add($sp) | Out-Null
        }
    }
}

function Register-PreviewTags {
    # Every preview element with Tag="Property=target.prop;..." -> painted by Update-Preview.
    $script:Tagged.Clear()
    $walk = $null
    $walk = {
        param($node)
        if ($node -is [System.Windows.FrameworkElement] -or $node -is [System.Windows.FrameworkContentElement]) {
            $tag = "$($node.Tag)"
            if ($tag -match '=') {
                $maps = foreach ($m in $tag.Split(';')) {
                    # "Background=terminal.selectionBackground@45": @ = opacity in % (Terminal's see-through selection)
                    if ($m -match '^\s*(\w+)\s*=\s*(\w+)\.(\w+)(?:@(\d+))?\s*$') { [pscustomobject]@{ Prop = $Matches[1]; Target = $Matches[2]; Key = $Matches[3]; Alpha = $Matches[4] } }
                }
                $script:Tagged.Add([pscustomobject]@{ El = $node; Maps = @($maps) })
            }
        }
        if ($node -is [System.Windows.DependencyObject]) {
            foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($node)) { if ($c -is [System.Windows.DependencyObject]) { & $walk $c } }
        }
    }
    & $walk $script:Ui.Preview
}

# ------------------------------------------------------------------------------------------
# Profile <-> controls
# ------------------------------------------------------------------------------------------
function Get-KindHint {
    param([string]$Kind)
    switch ($Kind) {
        'wallpaper' { 'wallust reads the colors out of each wallpaper.' }
        'match'     { 'Each wallpaper gets the built-in theme whose colors are closest to it.' }
        'theme'     { 'The same built-in theme, whatever the wallpaper.' }
        'random'    { 'A different built-in theme every time the wallpaper changes (the preview shows one).' }
        'scheme'    { 'A pywal or terminal.sexy color scheme file, whatever the wallpaper.' }
    }
}

function Sync-SourceControls {
    $script:Updating = $true
    try {
        $src = $script:Work.source
        foreach ($rb in @($script:Ui.KindWallpaper, $script:Ui.KindMatch, $script:Ui.KindTheme, $script:Ui.KindRandom, $script:Ui.KindScheme)) {
            $rb.IsChecked = ($rb.Tag -eq $src.kind)
        }
        $script:Ui.KindHint.Text = Get-KindHint $src.kind
        foreach ($pair in @(@('wallpaper', 'WallpaperOpts'), @('match', 'MatchOpts'), @('theme', 'ThemeOpts'), @('random', 'RandomOpts'), @('scheme', 'SchemeOpts'))) {
            $script:Ui[$pair[1]].Visibility = if ($src.kind -eq $pair[0]) { 'Visible' } else { 'Collapsed' }
        }
        if ($src.kind -eq 'wallpaper') {
            foreach ($rb in @($script:Ui.MethodKmeans, $script:Ui.MethodSalience, $script:Ui.MethodAnsi)) { $rb.IsChecked = ($rb.Tag -eq $src.method) }
            $script:Ui.MethodHint.Text = switch ($src.method) {
                'kmeans'   { 'Groups the picture''s pixels into its main colors -- Default''s method.' }
                'salience' { 'Picks the colors that stand out, even small ones.' }
                'ansi'     { 'Sorts the picture''s colors into terminal order: red in the red slot, and so on.' }
            }
            $kmeans = $src.method -eq 'kmeans'
            $script:Ui.StyleDark.IsEnabled = -not $kmeans
            $script:Ui.StyleLight.IsEnabled = -not $kmeans
            $script:Ui.StyleDark.IsChecked = (-not $kmeans) -and $src.style -eq 'dark'
            $script:Ui.StyleLight.IsChecked = (-not $kmeans) -and $src.style -eq 'light'
            $script:Ui.StyleHint.Text = if ($kmeans) { 'kmeans makes one palette; dark or light is for salience and ansi.' } else { 'A dark background with light text, or the other way round.' }
            $on = [int]$src.saturation -gt 0
            $script:Ui.SatOn.IsChecked = $on
            $script:Ui.SatSlider.IsEnabled = $on
            if ($on) { $script:Ui.SatSlider.Value = [int]$src.saturation }
            $script:Ui.SatValue.Text = if ($on) { "$([int]$src.saturation)" } else { 'off' }
            $script:Ui.Cols16.IsChecked = [bool]$src.colors16
        }
        if ($src.kind -eq 'theme') { Update-ThemeList }
        if ($src.kind -eq 'scheme') { Update-SchemeList }
        if ($src.kind -in 'match', 'theme') { Request-Matches }
        if ($src.kind -eq 'theme' -and $null -eq $script:ThemeNames) { Add-EditorJob -Kind 'themes' -Key 'themes' }
    } finally { $script:Updating = $false }
}

function Sync-OptionControls {
    $script:Updating = $true
    try {
        foreach ($rb in @($script:Ui.TermLighten, $script:Ui.TermAuto, $script:Ui.TermOff)) { $rb.IsChecked = ($rb.Tag -eq $script:Work.readable.terminal) }
        $script:Ui.TermReadHint.Text = switch ($script:Work.readable.terminal) {
            'lighten' { 'Colors too dim to read on the background are lifted until they read (Default).' }
            'auto'    { 'Lifted on a dark background, deepened on a light one.' }
            'off'     { 'The palette''s colors exactly, readable or not.' }
        }
        $script:Ui.ReadUi.IsChecked = [bool]$script:Work.readable.ui
        foreach ($rb in @($script:Ui.ModeDark, $script:Ui.ModeLight, $script:Ui.ModeAuto)) { $rb.IsChecked = ($rb.Tag -eq $script:Work.appMode) }
        foreach ($id in $script:TargetBoxes.Keys) { $script:TargetBoxes[$id].IsChecked = ($id -notin @($script:Work.off)) }
        if ($script:Ui.NameBox.Text -ne "$($script:Work.name)") { $script:Ui.NameBox.Text = "$($script:Work.name)" }
    } finally { $script:Updating = $false }
}

function Get-EditorLabel {
    # What this editor holds, as the header says it.
    $name = "$($script:Work.name)".Trim()
    switch ($script:Mode) {
        'default' { 'Default' }
        'new' {
            $slot = Get-EditorSaveSlot
            if ($slot) { Get-PaletteProfileLabel -Id $slot -Name $name } else { 'New profile' }
        }
        default { Get-PaletteProfileLabel -Id $script:Id -Name $name }
    }
}

function Get-EditorSaveSlot {
    # Where Save puts it: the slot being edited; for a new one, the slot asked for or the first free.
    switch ($script:Mode) {
        'edit' { return $script:Id }
        'new' {
            if ($script:Id -and -not (Test-Path -LiteralPath (Get-PaletteProfilePath -Id $script:Id))) { return $script:Id }
            return Get-FreePaletteProfileId
        }
        default { return Get-FreePaletteProfileId }
    }
}

function Sync-Header {
    $chosen = Get-ChosenId
    $label = Get-EditorLabel
    $script:Ui.Crumb.Text = "PALETTE PROFILES $script:Chev $($label.ToUpperInvariant())"
    $inUse = ($script:Mode -ne 'new') -and ($script:Id -eq $chosen)
    $script:Ui.InUse.Visibility = if ($inUse) { 'Visible' } else { 'Collapsed' }
    $slot = Get-EditorSaveSlot
    $script:Ui.Blurb.Text = switch ($script:Mode) {
        'default' {
            if ($slot) { "Default ships with 710sRice and can't be changed. Try anything here -- Save as new keeps it as $(Get-PaletteProfileLabel -Id $slot)." }
            else { "Default ships with 710sRice and can't be changed. All 10 profile slots are in use -- delete one to save a new profile." }
        }
        'new' {
            if ($slot) { "A new profile -- it's saved as $(Get-PaletteProfileLabel -Id $slot)." }
            else { 'All 10 profile slots are in use -- delete one to make room.' }
        }
        default {
            if ($inUse) { 'The profile in use: saving re-themes everything with it.' }
            else { 'Save keeps your changes; Save and use also themes everything with this profile now.' }
        }
    }
    $script:Ui.NameHint.Text = if ($script:Mode -eq 'default') { 'the new profile''s name (optional)' } else { "optional -- shows as $(Get-EditorLabel)" }
    Update-Buttons
}

function Update-Buttons {
    $busy = [bool]$script:Busy
    $dirty = Test-Dirty
    $chosen = Get-ChosenId
    $slot = Get-EditorSaveSlot
    $nameError = Test-PaletteProfileName -Name $script:Ui.NameBox.Text -Id $(if ($slot) { $slot } else { 'profile0' }) -Profiles $script:Known
    $srcProblem = $null
    if ($script:Work.source.kind -eq 'scheme' -and -not (Test-Path -LiteralPath (Join-Path (Get-PaletteSchemesDir) "$($script:Work.source.file)") -PathType Leaf)) {
        $srcProblem = 'pick a scheme file first'
    }
    $ok = -not $script:ThemeError -and -not $nameError -and -not $busy -and -not $srcProblem -and -not $script:Pk
    $u = $script:Ui
    $u.BtnDelete.Visibility = if ($script:Mode -eq 'edit' -and (Test-Path -LiteralPath (Get-PaletteProfilePath -Id $script:Id))) { 'Visible' } else { 'Collapsed' }
    $u.BtnDelete.IsEnabled = -not $busy
    $u.BtnCancel.Content = if ($dirty) { 'Cancel' } else { 'Close' }
    $u.BtnCancel.IsEnabled = -not $busy
    switch ($script:Mode) {
        'default' {
            $u.BtnSave.Content = 'Save as new'
            $u.BtnSave.Visibility = 'Visible'
            $u.BtnSave.IsEnabled = $ok -and [bool]$slot
            if ($dirty -or $chosen -eq 'default') {
                $u.BtnSaveUse.Content = 'Save as new and use'
                $u.BtnSaveUse.IsEnabled = $ok -and [bool]$slot
            } else {
                $u.BtnSaveUse.Content = 'Use Default'
                $u.BtnSaveUse.IsEnabled = -not $busy
            }
            $u.BtnSaveUse.Visibility = 'Visible'
        }
        'new' {
            $u.BtnSave.Content = 'Save'
            $u.BtnSave.Visibility = 'Visible'
            $u.BtnSave.IsEnabled = $ok -and [bool]$slot
            $u.BtnSaveUse.Content = 'Save and use'
            $u.BtnSaveUse.Visibility = 'Visible'
            $u.BtnSaveUse.IsEnabled = $ok -and [bool]$slot
        }
        default {
            if ($script:Id -eq $chosen) {
                $u.BtnSave.Visibility = 'Collapsed'
                $u.BtnSaveUse.Content = 'Save and apply'
                $u.BtnSaveUse.IsEnabled = $ok -and $dirty
            } else {
                $u.BtnSave.Content = 'Save'
                $u.BtnSave.Visibility = 'Visible'
                $u.BtnSave.IsEnabled = $ok -and $dirty
                $u.BtnSaveUse.Content = if ($dirty) { 'Save and use' } else { 'Use this profile' }
                $u.BtnSaveUse.IsEnabled = $ok
            }
            $u.BtnSaveUse.Visibility = 'Visible'
        }
    }
    if ($nameError) {
        $u.NameHint.Text = $nameError
        $u.NameHint.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'B.Warn')
    } else {
        $u.NameHint.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'B.Sub')
    }
}

# ------------------------------------------------------------------------------------------
# Resolve and repaint
# ------------------------------------------------------------------------------------------
function Update-Theme {
    if (-not $script:Palette) { Update-Buttons; return }
    try {
        $script:Theme = Resolve-PaletteTheme -Profile $script:Work -Palette $script:Palette -Targets $script:Targets
        $script:ThemeError = $null
    } catch {
        $script:ThemeError = $_.Exception.Message
        Set-Status -Warn -Text "This profile can't be used as it is: $script:ThemeError"
    }
    if ($script:Theme) {
        Update-RoleRows
        Update-Preview
    }
    Update-PresetHint
    Update-Buttons
}

function Update-RoleRows {
    $th = $script:Theme
    foreach ($role in $script:PaletteRoles.Keys) {
        $r = $script:RoleUi[$role]
        $r.Swatch.Background = Get-Brush $th.Roles[$role]
        $words = Get-ExpressionWords $script:Work.roles[$role]
        $hexUp = $th.Roles[$role].ToUpperInvariant()
        $r.Expr.Text = if ($words -eq $hexUp -or $words -eq $th.Roles[$role]) { "fixed    $hexUp" } else { "$words    $hexUp" }
        $moved = 0
        foreach ($it in $script:Layout[$role]) { if ($script:Work.overrides.Contains($it.Target) -and $script:Work.overrides[$it.Target].Contains($it.Prop)) { $moved++ } }
        $n = $script:Layout[$role].Count
        $r.Count.Text = "$n place$(if ($n -ne 1) { 's' })$(if ($moved) { " $script:Dot $moved own" })"
    }
    $pm = 0
    foreach ($it in $script:Layout['palette']) { if ($script:Work.overrides.Contains($it.Target) -and $script:Work.overrides[$it.Target].Contains($it.Prop)) { $pm++ } }
    $script:RoleUi['palette'].Count.Text = "$($script:Layout['palette'].Count) places$(if ($pm) { " $script:Dot $pm remapped" })"
    $raised = @{}
    foreach ($x in $th.Raised) { if ($x -match '^(\w+\.\w+) (#\w+)->(#\w+)$') { $raised[$Matches[1]] = $Matches[2] } }
    foreach ($key in $script:PropUi.Keys) {
        $p = $script:PropUi[$key]
        $hex = $th.Targets[$p.Target][$p.Prop]
        $p.Swatch.Background = Get-Brush $hex
        $own = $script:Work.overrides.Contains($p.Target) -and $script:Work.overrides[$p.Target].Contains($p.Prop)
        $def = (Get-PaletteTarget -Id $p.Target).Properties[$p.Prop].Default
        $words = if ($own) { Get-ExpressionWords $script:Work.overrides[$p.Target][$p.Prop] } else { Get-ExpressionWords $def }
        $txt = if ($own) { "$words (its own)" } else { $words }
        if ($raised.ContainsKey($key)) { $txt += " $script:Dot made readable" }
        if ($p.Target -in @($script:Work.off)) { $txt += " $script:Dot app off" }
        $p.Expr.Text = $txt
        if ($own) { $p.Expr.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'B.Accent') }
        else { $p.Expr.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'B.Sub') }
        $p.Reset.Visibility = if ($own) { 'Visible' } else { 'Hidden' }
        $tip = "$(Get-PropLabel -Target $p.Target -Prop $p.Prop): $($hex.ToUpperInvariant())"
        if ($raised.ContainsKey($key)) { $tip += " (the palette gives $($raised[$key]); moved to stay readable)" }
        $p.Row.ToolTip = $tip
    }
}

function Update-Preview {
    $th = $script:Theme
    foreach ($t in $script:Tagged) {
        foreach ($m in $t.Maps) {
            $hex = $th.Targets[$m.Target][$m.Key]
            if (-not $hex) { continue }
            if ($m.Alpha) { $hex = '#{0:X2}{1}' -f [int]([int]$m.Alpha * 255 / 100), $hex.TrimStart('#') }
            $t.El.($m.Prop) = Get-Brush $hex
        }
        $first = $t.Maps[0]
        if ($first) { $t.El.ToolTip = "$(Get-PropLabel -Target $first.Target -Prop $first.Key)  $($th.Targets[$first.Target][$first.Key])" }
    }
    $acc = $th.Targets['windows']['accent']
    if ($acc) { $script:Ui.MockAccentText.Foreground = Get-Brush (Get-TextOn $acc) }
    # An app that's off keeps its own colors: its mock is dimmed and says so.
    $off = @($script:Work.off)
    foreach ($pair in @(@('yasb', 'MockBar', 'CapBar', 'BAR'), @('menus', 'MockMenu', 'CapMenu', 'MENUS'), @('flow', 'MockFlow', 'CapFlow', 'FLOW LAUNCHER'),
                        @('terminal', 'MockTerm', 'CapTerm', 'WINDOWS TERMINAL AND THE PROMPT'), @('komorebi', 'MockWin', 'CapWin', 'WINDOWS: BORDERS, STACK TABS, ACCENT'))) {
        $isOff = $pair[0] -in $off
        $script:Ui[$pair[1]].Opacity = if ($isOff) { 0.35 } else { 1.0 }
        $script:Ui[$pair[2]].Text = if ($isOff) { "$($pair[3]) (OFF IN THIS PROFILE)" } else { $pair[3] }
    }
    $script:Ui.MockAccent.Opacity = if ('windows' -in $off) { 0.35 } else { 1.0 }
}

# ------------------------------------------------------------------------------------------
# Changes from the controls
# ------------------------------------------------------------------------------------------
function Set-SourceField {
    param([Parameter(Mandatory)][string]$Field, $Value)
    $src = $script:Work.source
    if ($Field -eq 'kind') {
        if ($src.kind -eq $Value) { return }
        # Each kind keeps only its own fields (ConvertTo-PaletteProfile's shape).
        $new = [ordered]@{ kind = $Value }
        switch ($Value) {
            'wallpaper' { $new.method = 'kmeans'; $new.style = 'dark'; $new.saturation = 0; $new.colors16 = $false }
            'theme' {
                $name = $null
                $m = $script:ThemeMatches["$script:Image"]
                if ($m -is [array] -and $m.Count) { $name = $m[0].Name }
                if (-not $name -and $script:ThemeNames) { $name = $script:ThemeNames[0] }
                if (-not $name) { $name = 'Catppuccin-Mocha' }
                $new.name = $name
            }
            'scheme' {
                $files = @(Get-PaletteSchemeFiles)
                # No file yet: a name that isn't there -- Save waits until one is picked.
                $new.file = if ($files.Count) { $files[0] } else { 'none.json' }
            }
        }
        $script:Work.source = $new
    } else {
        $src[$Field] = $Value
    }
    Sync-SourceControls
    Request-EditorPalette
}

# Two starting points for the roles. Wallpaper palettes (kmeans, salience) come darkest-first,
# built-in themes, scheme files and ansi in terminal order (color1 red, color4 blue ...) -- the
# same map can't suit both.
function Get-RolePreset {
    param([ValidateSet('default', 'terminal')][string]$Name)
    $def = Get-PaletteDefaultProfile
    if ($Name -eq 'default') {
        $roles = [ordered]@{}; foreach ($k in $def.roles.Keys) { $roles[$k] = $def.roles[$k] }
        $term = [ordered]@{}; foreach ($k in $def.overrides['terminal'].Keys) { $term[$k] = $def.overrides['terminal'][$k] }
        return [pscustomobject]@{ Roles = $roles; Terminal = $term }
    }
    [pscustomobject]@{
        Roles = [ordered]@{
            base = 'background'; panel = 'mix(background, foreground, 12)'; accent = 'color4'; hover = 'mix(background, color4, 35)'
            subtext = 'mix(foreground, background, 35)'; text = 'foreground'; bright = 'color15'; alert = 'color1'
        }
        Terminal = $null   # standard ANSI order: the target's own defaults
    }
}

function Set-RolePreset {
    param([string]$Name)
    $p = Get-RolePreset -Name $Name
    $script:Work.roles = $p.Roles
    if ($p.Terminal) { $script:Work.overrides['terminal'] = $p.Terminal }
    elseif ($script:Work.overrides.Contains('terminal')) { $script:Work.overrides.Remove('terminal') }
    Update-Theme
}

function Test-TerminalOrdered {
    # Is the source's palette in terminal order?
    $src = $script:Work.source
    ($src.kind -in 'match', 'theme', 'random', 'scheme') -or ($src.kind -eq 'wallpaper' -and $src.method -eq 'ansi')
}

function Update-PresetHint {
    $same = $true
    $def = (Get-RolePreset -Name 'default').Roles
    foreach ($k in $def.Keys) { if ($script:Work.roles[$k] -ne $def[$k]) { $same = $false } }
    $show = $same -and (Test-TerminalOrdered)
    $script:Ui.PresetHint.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
    $script:Ui.PresetHint.Text = 'This palette is in terminal order (color1 is red, color4 blue ...), so Default''s map puts odd colors in odd places -- Terminal order suits it.'
}

function Set-TargetOn {
    param([string]$Id, [bool]$On)
    $off = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @($script:Work.off)) { if ($x -ne $Id) { $off.Add($x) } }
    if (-not $On) { $off.Add($Id) }
    # Keep the targets' own order, so the saved file doesn't change with the clicking order.
    $script:Work.off = @($script:Targets | ForEach-Object Id | Where-Object { $off.Contains($_) })
    Sync-OptionControls
    Update-Theme
}

function Reset-Override {
    param([string]$Key)
    $t, $p = $Key.Split('.', 2)
    if ($script:Work.overrides.Contains($t) -and $script:Work.overrides[$t].Contains($p)) {
        $script:Work.overrides[$t].Remove($p)
        if (-not $script:Work.overrides[$t].Count) { $script:Work.overrides.Remove($t) }
    }
    Update-Theme
}

function Update-ThemeList {
    $list = $script:Ui.ThemeList
    if ($null -eq $script:ThemeNames) { return }
    $q = "$($script:Ui.ThemeSearch.Text)".Trim()
    $names = if ($q) { @($script:ThemeNames | Where-Object { $_ -like "*$q*" }) } else { $script:ThemeNames }
    $script:Updating = $true
    try {
        $list.ItemsSource = $names
        $cur = $script:Work.source.name
        if ($script:Work.source.kind -eq 'theme' -and $cur -and $names -contains $cur) {
            $list.SelectedItem = $cur
            $list.ScrollIntoView($cur)
        } else { $list.SelectedItem = $null }
    } finally { $script:Updating = $false }
    $script:Ui.ThemeSearch.ToolTip = "Search the $($script:ThemeNames.Count) built-in themes"
}

function Update-SchemeList {
    $files = @(Get-PaletteSchemeFiles)
    $panel = $script:Ui.SchemePanel
    $panel.Children.Clear()
    foreach ($f in $files) {
        $rb = New-Seg -Text $f -Tag $f
        $rb.IsChecked = ($f -eq $script:Work.source.file)
        $rb.Add_Checked({ param($s, $e) if (-not $script:Updating) { Set-SourceField -Field 'file' -Value "$($s.Tag)" } })
        $panel.Children.Add($rb) | Out-Null
    }
    $script:Ui.SchemeNote.Text = if ($files.Count) {
        if ($script:Work.source.file -notin $files) { "$($script:Work.source.file) isn't in config\palettes\schemes -- pick one." } else { 'Files in config\palettes\schemes (they stay on this PC).' }
    } else { 'No scheme files yet: put a pywal (.json) or terminal.sexy scheme file in config\palettes\schemes -- this list updates when you come back to the editor.' }
}

function Request-Matches {
    $img = "$script:Image"
    if (-not $img) {
        $script:Ui.MatchNote.Text = 'No wallpaper file to match against.'
        return
    }
    if ($script:ThemeMatches.ContainsKey($img)) { Update-MatchLists; return }
    $script:Ui.MatchNote.Text = 'Matching the built-in themes to this wallpaper' + [char]0x2026
    Add-EditorJob -Kind 'matches' -Key $img -Arg @{ Image = $img }
}

function Update-MatchLists {
    $m = $script:ThemeMatches["$script:Image"]
    foreach ($panel in @($script:Ui.MatchPanel, $script:Ui.ClosePanel)) { $panel.Children.Clear() }
    if ($null -eq $m) { return }
    if ($m -isnot [array]) {
        $script:Ui.MatchNote.Text = "wallust couldn't match themes: $($m.Error)"
        $script:Ui.CloseNote.Text = ''
        return
    }
    $script:Ui.MatchNote.Text = if ($m.Count) { "For this wallpaper that's $($m[0].Name). The closest few -- click one to keep it for every wallpaper:" } else { 'wallust found no match.' }
    $script:Ui.CloseNote.Text = 'Closest to this wallpaper:'
    foreach ($x in $m) {
        foreach ($panel in @($script:Ui.MatchPanel, $script:Ui.ClosePanel)) {
            $b = [System.Windows.Controls.Button]::new()
            $b.Content = $x.Name
            $b.Tag = $x.Name
            $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
            $b.Padding = [System.Windows.Thickness]::new(10, 3, 10, 3)
            $b.ToolTip = "Use $($x.Name) whatever the wallpaper (distance $($x.Score))"
            $b.Add_Click({ param($s, $e) Set-FixedTheme -Name "$($s.Tag)" })
            $panel.Children.Add($b) | Out-Null
        }
    }
}

function Set-FixedTheme {
    param([string]$Name)
    $script:Work.source = [ordered]@{ kind = 'theme'; name = $Name }
    Sync-SourceControls
    Request-EditorPalette
}

# ------------------------------------------------------------------------------------------
# The color selector
# ------------------------------------------------------------------------------------------
function Open-Picker {
    param([ValidateSet('role', 'prop')][string]$Kind, [string]$Role, [string]$Target, [string]$Prop)
    if ($script:Busy -or $script:Ask) { return }
    if ($script:Pk) { Close-Picker -Keep:(-not $script:Ui.PkError.Text) }
    $pk = [pscustomobject]@{ Kind = $Kind; Role = $Role; Target = $Target; Prop = $Prop; Original = $null; Current = ''; Default = ''; Slot = 'base'; Hsv = $null }
    if ($Kind -eq 'role') {
        $pk.Original = $script:Work.roles[$Role]
        $pk.Current = $pk.Original
        $pk.Default = (Get-PaletteDefaultProfile).roles[$Role]
        $script:Ui.PkTitle.Text = $script:PaletteRoles[$Role].Label.ToUpperInvariant()
        $script:Ui.PkAbout.Text = "$($script:PaletteRoles[$Role].About). Every app color under it follows."
        $script:Ui.PkReset.Content = "Default's color ($(Get-ExpressionWords $pk.Default))"
    } else {
        $t = Get-PaletteTarget -Id $Target
        $def = $t.Properties[$Prop].Default
        $own = $script:Work.overrides.Contains($Target) -and $script:Work.overrides[$Target].Contains($Prop)
        $pk.Original = if ($own) { $script:Work.overrides[$Target][$Prop] } else { $null }
        $pk.Current = if ($own) { $pk.Original } else { $def }
        $pk.Default = $def
        $script:Ui.PkTitle.Text = (Get-PropLabel -Target $Target -Prop $Prop).ToUpperInvariant()
        $script:Ui.PkAbout.Text = "Follows $(Get-ExpressionWords $def) unless you give it a color of its own here."
        $script:Ui.PkReset.Content = "Follow $(Get-ExpressionWords $def)"
    }
    $script:Pk = $pk
    Build-PickerSwatches
    $script:Ui.PkError.Text = ''
    Sync-Picker
    $script:Ui.PickerLayer.Visibility = 'Visible'
    Update-Buttons
    $null = $script:Ui.PkUse.Focus()
}

function Build-PickerSwatches {
    $pk = $script:Pk
    foreach ($panel in @($script:Ui.PkPalette, $script:Ui.PkRoles)) { $panel.Children.Clear() }
    $add = {
        param($panel, $name, $label, $hex)
        $sp = [System.Windows.Controls.StackPanel]::new()
        $sp.Margin = [System.Windows.Thickness]::new(0, 0, 3, 6)
        $sp.Cursor = [System.Windows.Input.Cursors]::Hand
        $sp.Background = [System.Windows.Media.Brushes]::Transparent
        $sp.Tag = $name
        $sw = New-Swatch -Width 30 -Height 26 -Radius 5
        if ($hex) { $sw.Background = Get-Brush $hex }
        $sp.Children.Add($sw) | Out-Null
        $t = New-Text -Text $label -Brush 'B.Sub' -Size 10
        $t.HorizontalAlignment = 'Center'
        $sp.Children.Add($t) | Out-Null
        $sp.ToolTip = "$name  $hex"
        $sp.Add_MouseLeftButtonUp({ param($s, $e) Set-PickerName -Name "$($s.Tag)" })
        $panel.Children.Add($sp) | Out-Null
    }
    foreach ($slot in $script:PaletteSlots) {
        $short = switch ($slot) { 'background' { 'bg' } 'foreground' { 'fg' } 'cursor' { 'cur' } default { $slot.Substring(5) } }
        & $add $script:Ui.PkPalette $slot $short $(if ($script:Palette) { $script:Palette[$slot] })
    }
    foreach ($r in $script:PaletteRoles.Keys) {
        if ($pk.Kind -eq 'role' -and $r -eq $pk.Role) { continue }
        $hex = if ($script:Theme) { $script:Theme.Roles[$r] } else { $null }
        $lbl = $script:PaletteRoles[$r].Label
        if ($lbl.Length -gt 10) { $lbl = $lbl.Substring(0, 9) + [char]0x2026 }
        & $add $script:Ui.PkRoles $r $lbl $hex
    }
}

function Resolve-PickerHex {
    <# The color an expression gives in the profile as edited. For a role's own color the role
       is taken as $Text first, so a loop back to itself (Accent -> Text -> Accent) throws. #>
    param([string]$Text, [switch]$AsRole)
    $defs = [ordered]@{}
    foreach ($k in $script:Work.roles.Keys) { $defs[$k] = $script:Work.roles[$k] }
    if ($AsRole -and $script:Pk -and $script:Pk.Kind -eq 'role') {
        $defs[$script:Pk.Role] = $Text
        return Resolve-PaletteExpression -Text $script:Pk.Role -Palette $script:Palette -Roles ([ordered]@{}) -RoleDefs $defs
    }
    Resolve-PaletteExpression -Text $Text -Palette $script:Palette -Roles ([ordered]@{}) -RoleDefs $defs
}

function Sync-Picker {
    <# Every selector control from $script:Pk.Current. #>
    $pk = $script:Pk
    $script:Updating = $true
    try {
        $split = $null
        try { $split = Split-PaletteExpression -Text $pk.Current } catch { }
        $simple = $split -and $split.Simple
        $adj = if ($simple) { $split.Adjust } else { 'none' }
        foreach ($rb in @($script:Ui.PkAdjNone, $script:Ui.PkAdjLighten, $script:Ui.PkAdjDarken, $script:Ui.PkAdjMix)) { $rb.IsChecked = ($rb.Tag -eq $adj) }
        $script:Ui.PkAmountRow.Visibility = if ($adj -ne 'none') { 'Visible' } else { 'Collapsed' }
        if ($simple -and $adj -ne 'none') { $script:Ui.PkAmount.Value = $split.Amount; $script:Ui.PkAmountText.Text = "$([int]$split.Amount)%" }
        $script:Ui.PkSlotRow.Visibility = if ($adj -eq 'mix') { 'Visible' } else { 'Collapsed' }
        if ($adj -ne 'mix') { $pk.Slot = 'base' }
        $script:Ui.PkSlotBase.IsChecked = $pk.Slot -eq 'base'
        $script:Ui.PkSlotOther.IsChecked = $pk.Slot -eq 'other'
        if ($script:Ui.PkExpr.Text -ne $pk.Current) { $script:Ui.PkExpr.Text = $pk.Current }
        # Which swatch is picked: outlined in the accent.
        $picked = if ($simple) { if ($pk.Slot -eq 'other') { $split.Other } else { $split.Base } } else { $null }
        foreach ($panel in @($script:Ui.PkPalette, $script:Ui.PkRoles)) {
            foreach ($sp in $panel.Children) {
                $sw = $sp.Children[0]
                if ("$($sp.Tag)" -eq "$picked") {
                    $sw.BorderThickness = [System.Windows.Thickness]::new(3)
                    $sw.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'B.Accent')
                } else {
                    $sw.BorderThickness = [System.Windows.Thickness]::new(1)
                    $sw.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'B.Line')
                }
            }
        }
        $hex = $null
        try { $hex = Resolve-PickerHex $pk.Current -AsRole; $script:Ui.PkError.Text = '' } catch { $script:Ui.PkError.Text = $_.Exception.Message }
        if ($hex) {
            $script:Ui.PkSwatch.Background = Get-Brush $hex
            $script:Ui.PkHex.Text = $hex.ToUpperInvariant()
        }
        $script:Ui.PkWhat.Text = Get-ExpressionWords $pk.Current
        $script:Ui.PkUse.IsEnabled = -not $script:Ui.PkError.Text
        $script:Ui.PkReset.Visibility = if ($pk.Current -eq $pk.Default) { 'Hidden' } else { 'Visible' }
        # The square and the hue strip show the color being chosen now (base, or what it's mixed with).
        $shown = $null
        if ($simple) {
            $n = if ($pk.Slot -eq 'other') { $split.Other } else { $split.Base }
            try { $shown = Resolve-PickerHex $n } catch { }
        } elseif ($hex) { $shown = $hex }
        if ($shown) {
            if (-not $pk.Hsv -or (ConvertFrom-EditorHsv @($pk.Hsv)) -ne $shown.ToLowerInvariant()) { $pk.Hsv = ConvertTo-EditorHsv $shown }
            Show-PickerHsv
            if ($script:Ui.PkHexBox.Text -ne $shown -and -not $script:Ui.PkHexBox.IsKeyboardFocused) { $script:Ui.PkHexBox.Text = $shown }
        }
    } finally { $script:Updating = $false }
}

function Set-PickerExpression {
    # Any change in the selector lands here: the new expression, the controls, the live preview.
    param([string]$Text)
    $script:Pk.Current = $Text
    Sync-Picker
    Request-Deferred -Name 'pickerLive' -Ms 120
}

function Get-PickerParts {
    $pk = $script:Pk
    $s = $null
    try { $s = Split-PaletteExpression -Text $pk.Current } catch { }
    if (-not $s -or -not $s.Simple) { return [pscustomobject]@{ Base = $null; Adjust = 'none'; Amount = 0; Other = $null } }
    $s
}

function Set-PickerName {
    # A palette slot / role / hex picked: it becomes the color (or what it's mixed with).
    param([string]$Name)
    $pk = $script:Pk
    $s = Get-PickerParts
    if ($pk.Slot -eq 'other' -and $s.Adjust -eq 'mix') {
        Set-PickerExpression (Join-PaletteExpression -Base $s.Base -Adjust 'mix' -Amount $s.Amount -Other $Name)
    } elseif ($s.Base) {
        Set-PickerExpression (Join-PaletteExpression -Base $Name -Adjust $s.Adjust -Amount $s.Amount -Other $s.Other)
    } else {
        Set-PickerExpression $Name
    }
}

function Set-PickerAdjust {
    param([string]$Adjust)
    $s = Get-PickerParts
    $base = if ($s.Base) { $s.Base } else { $script:Ui.PkHex.Text.ToLowerInvariant() }
    $amount = if ($s.Adjust -ne 'none' -and $s.Amount) { $s.Amount } elseif ($Adjust -eq 'mix') { 50 } else { 20 }
    $other = if ($s.Other) { $s.Other } elseif ($Adjust -eq 'mix') { 'text' } else { $null }
    if ($Adjust -eq 'mix' -and $script:Pk.Kind -eq 'role' -and $other -eq $script:Pk.Role) { $other = 'color7' }
    if ($Adjust -eq 'none') { $script:Pk.Slot = 'base'; Set-PickerExpression $base; return }
    Set-PickerExpression (Join-PaletteExpression -Base $base -Adjust $Adjust -Amount $amount -Other $other)
    if ($Adjust -eq 'mix') { $script:Pk.Slot = 'other'; Sync-Picker }
}

function Set-PickerAmount {
    param([double]$Amount)
    $s = Get-PickerParts
    if (-not $s.Base -or $s.Adjust -eq 'none') { return }
    $script:Ui.PkAmountText.Text = "$([int][Math]::Round($Amount))%"
    Set-PickerExpression (Join-PaletteExpression -Base $s.Base -Adjust $s.Adjust -Amount $Amount -Other $s.Other)
}

function Read-PickerExpression {
    # Typed into the expression box: used when it reads, the error shown when it doesn't.
    $text = "$($script:Ui.PkExpr.Text)".Trim()
    try {
        $null = Resolve-PickerHex $text -AsRole
        $script:Pk.Current = $text
        Sync-Picker
        Request-Deferred -Name 'pickerLive' -Ms 60
    } catch {
        $script:Ui.PkError.Text = $_.Exception.Message
        $script:Ui.PkUse.IsEnabled = $false
    }
}

function Set-PickerValueInWork {
    # The selector's color into the profile (live preview and Use); $null = back to following.
    param($Text)
    $pk = $script:Pk
    if ($pk.Kind -eq 'role') {
        $script:Work.roles[$pk.Role] = $Text
        return
    }
    $ov = $script:Work.overrides
    if ($null -eq $Text -or $Text -eq $pk.Default) {
        if ($ov.Contains($pk.Target) -and $ov[$pk.Target].Contains($pk.Prop)) {
            $ov[$pk.Target].Remove($pk.Prop)
            if (-not $ov[$pk.Target].Count) { $ov.Remove($pk.Target) }
        }
    } else {
        if (-not $ov.Contains($pk.Target)) { $ov[$pk.Target] = [ordered]@{} }
        $ov[$pk.Target][$pk.Prop] = $Text
    }
}

function Update-PickerLive {
    if (-not $script:Pk -or $script:Ui.PkError.Text) { return }
    Set-PickerValueInWork $script:Pk.Current
    Update-Theme
}

function Close-Picker {
    param([switch]$Keep)
    if (-not $script:Pk) { return }
    $script:Deferred.Remove('pickerLive')
    $script:Deferred.Remove('pickerExpr')
    if ($Keep) { Set-PickerValueInWork $script:Pk.Current }
    else { Set-PickerValueInWork $script:Pk.Original }
    $script:Pk = $null
    $null = $script:Window.Focus()   # see Close-Ask
    $script:Ui.PickerLayer.Visibility = 'Collapsed'
    Update-Theme
}

# HSV for the square and the hue strip
function ConvertTo-EditorHsv {
    param([string]$Hex)
    $c = ConvertTo-PaletteRgb -Hex $Hex
    $r = $c.R / 255.0; $g = $c.G / 255.0; $b = $c.B / 255.0
    $hi = [Math]::Max($r, [Math]::Max($g, $b)); $lo = [Math]::Min($r, [Math]::Min($g, $b)); $d = $hi - $lo
    $hue = 0.0
    if ($d -gt 0) {
        if ($hi -eq $r) { $hue = 60 * ((($g - $b) / $d) % 6) }
        elseif ($hi -eq $g) { $hue = 60 * ((($b - $r) / $d) + 2) }
        else { $hue = 60 * ((($r - $g) / $d) + 4) }
    }
    if ($hue -lt 0) { $hue += 360 }
    $sat = if ($hi -eq 0) { 0.0 } else { $d / $hi }
    , @($hue, $sat, $hi)
}

function ConvertFrom-EditorHsv {
    param([double[]]$Hsv)
    $hue = $Hsv[0]; $sat = $Hsv[1]; $val = $Hsv[2]
    $c = $val * $sat
    $x = $c * (1 - [Math]::Abs((($hue / 60) % 2) - 1))
    $m = $val - $c
    $rgb = switch ([int][Math]::Floor(($hue % 360) / 60)) {
        0 { @($c, $x, 0) } 1 { @($x, $c, 0) } 2 { @(0, $c, $x) } 3 { @(0, $x, $c) } 4 { @($x, 0, $c) } default { @($c, 0, $x) }
    }
    '#{0:x2}{1:x2}{2:x2}' -f [int][Math]::Round(($rgb[0] + $m) * 255), [int][Math]::Round(($rgb[1] + $m) * 255), [int][Math]::Round(($rgb[2] + $m) * 255)
}

function Show-PickerHsv {
    $h = $script:Pk.Hsv
    $script:Ui.PkHueFill.Fill = Get-Brush (ConvertFrom-EditorHsv @($h[0], 1.0, 1.0))
    [System.Windows.Controls.Canvas]::SetLeft($script:Ui.PkSVThumb, $h[1] * $script:Ui.PkSV.Width - 6)
    [System.Windows.Controls.Canvas]::SetTop($script:Ui.PkSVThumb, (1 - $h[2]) * $script:Ui.PkSV.Height - 6)
    $script:Ui.PkSVThumb.Stroke = if ($h[2] -gt 0.6 -and $h[1] -lt 0.4) { [System.Windows.Media.Brushes]::Black } else { [System.Windows.Media.Brushes]::White }
    [System.Windows.Controls.Canvas]::SetLeft($script:Ui.PkHueThumb, $h[0] / 360 * $script:Ui.PkHue.Width - 2)
}

function Set-PickerFromSquare {
    param($Sender, $MouseArgs, [ValidateSet('sv', 'hue')][string]$Part)
    $pos = $MouseArgs.GetPosition($Sender)
    $h = @($script:Pk.Hsv)
    if (-not $h.Count) { $h = @(0.0, 0.0, 0.5) }
    if ($Part -eq 'sv') {
        $h[1] = [Math]::Min([Math]::Max($pos.X / $Sender.ActualWidth, 0), 1)
        $h[2] = 1 - [Math]::Min([Math]::Max($pos.Y / $Sender.ActualHeight, 0), 1)
    } else {
        $h[0] = [Math]::Min([Math]::Max($pos.X / $Sender.ActualWidth, 0), 0.9999) * 360
    }
    $script:Pk.Hsv = $h
    $hex = ConvertFrom-EditorHsv $h
    Set-PickerName -Name $hex
}

# ------------------------------------------------------------------------------------------
# Questions (an overlay, never a system dialog)
# ------------------------------------------------------------------------------------------
function Show-Ask {
    param([string]$Title, [string]$Text, [string]$Yes, [string]$No, [string]$Then)
    $script:Ask = $Then
    $script:Ui.AskTitle.Text = $Title
    $script:Ui.AskText.Text = $Text
    $script:Ui.AskYes.Content = $Yes
    $script:Ui.AskNo.Content = $No
    $script:Ui.AskYes.Visibility = 'Visible'
    $script:Ui.AskYes.IsEnabled = $true
    $script:Ui.AskNo.IsEnabled = $true
    $script:Ui.AskLayer.Visibility = 'Visible'
    $null = $script:Ui.AskNo.Focus()
}
function Close-Ask {
    # Focus leaves the question before it disappears (a focused element that vanishes mid-click
    # stalled the window in the sandbox) -- to the window itself, where Enter does nothing.
    $null = $script:Window.Focus()
    $script:Ask = $null
    $script:Ui.AskLayer.Visibility = 'Collapsed'
}
function Confirm-Ask {
    # Nothing happens inside the button's own click: the answer is acted on from the timer. A
    # deletion keeps the card up (as its progress) while Default is switched to -- in the
    # sandbox, taking the card down and starting that theme run straight after stalled the
    # window every time; leaving it up never did.
    $script:AskAnswer = $script:Ask
    $script:Ask = $null
    $script:Ui.AskYes.IsEnabled = $false
    $script:Ui.AskNo.IsEnabled = $false
    Request-Deferred -Name 'answer' -Ms 30
}
function Invoke-AskAnswer {
    $then = $script:AskAnswer
    $script:AskAnswer = $null
    switch ($then) {
        'discard' { $script:Window.Close() }
        'delete'  { Remove-EditorProfile }
        'from'    { Close-Ask; Use-StartFrom -Id $script:PendingFrom }
        default   { Close-Ask }
    }
}

# ------------------------------------------------------------------------------------------
# Save / use / delete -- a theme run is the pipeline in a process of its own
# ------------------------------------------------------------------------------------------
function Save-EditorProfile {
    <# $true when saved. The name is checked; the profile must resolve on this palette. #>
    $slot = Get-EditorSaveSlot
    if (-not $slot) { Set-Status -Warn -Text 'All 10 profile slots are in use -- delete one to make room.'; return $false }
    $name = "$($script:Ui.NameBox.Text)".Trim()
    Update-Known
    $err = Test-PaletteProfileName -Name $name -Id $slot -Profiles $script:Known
    if ($err) { Set-Status -Warn -Text $err; return $false }
    if ($script:ThemeError) { Set-Status -Warn -Text "Not saved: $script:ThemeError"; return $false }
    $script:Work.name = $name
    try { Save-PaletteProfile -Id $slot -Profile $script:Work }
    catch { Set-Status -Warn -Text "Not saved: $($_.Exception.Message)"; Write-EditorLog "save $slot FAILED: $($_.Exception.Message)"; return $false }
    Write-EditorLog "saved $slot ($(Get-PaletteSourceSummary -Source $script:Work.source))"
    $script:Mode = 'edit'
    $script:Id = $slot
    $script:Baseline = Get-WorkJson
    $script:Ui.FromRow.Visibility = 'Collapsed'
    Update-Known
    Sync-Header
    $true
}

function Invoke-EditorSave {
    param([switch]$Use)
    if ($script:Busy -or $script:Pk) { return }
    $chosen = Get-ChosenId
    if ($script:Mode -eq 'default' -and $Use -and -not (Test-Dirty) -and $chosen -ne 'default') {
        Start-EditorApply -Id 'default' -Why 'use'
        return
    }
    if ($script:Mode -eq 'edit' -and -not (Test-Dirty)) {
        if ($Use -and $script:Id -ne $chosen) { Start-EditorApply -Id $script:Id -Why 'use' }
        return
    }
    if (-not (Save-EditorProfile)) { return }
    $label = Get-EditorLabel
    if ($Use -or $script:Id -eq $chosen) { Start-EditorApply -Id $script:Id -Why 'use' }
    else { Set-Status -Text "Saved as $label. Choose it in SUPER+Alt+Space > Palette profiles, or Save and use." }
}

# A theme run is the pipeline in a process of its own, started and waited on from a runspace
# of its own too: the window's thread never touches the process (no stalls while it runs, and a
# wallust job can still run meanwhile).
$script:ApplyRs = [runspacefactory]::CreateRunspace()
$script:ApplyRs.Open()
$script:ApplyScript = {
    param($Exe, $Script, $Id)
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-ProfileId', $Id)) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        # 5 minutes is far beyond any theme run (the pipeline's own lock waits 90 s at most).
        if (-not $p.WaitForExit(300000)) { try { $p.Kill($true) } catch { }; return @{ Code = -1; Text = 'the theme run took over 5 minutes and was stopped' } }
        $text = ''
        if ($out.Wait(3000)) { $text += $out.Result }
        if ($err.Wait(1000)) { $text += "`n" + $err.Result }
        @{ Code = $p.ExitCode; Text = $text }
    } catch { @{ Code = -1; Text = "couldn't start the theme run: $($_.Exception.Message)" } }
}

function Start-EditorApply {
    param([Parameter(Mandatory)][string]$Id, [ValidateSet('use', 'delete')][string]$Why = 'use', [string]$DeleteId)
    $label = Get-PaletteProfileLabel -Id $Id -Name $(if ($Id -eq 'default') { '' } else { try { (Read-PaletteProfile -Id $Id).name } catch { '' } })
    $ps = [powershell]::Create()
    $ps.Runspace = $script:ApplyRs
    $null = $ps.AddScript($script:ApplyScript).AddArgument((Get-Process -Id $PID).Path).AddArgument((Join-Path $Root 'tools\apply-wallust-outputs.ps1')).AddArgument($Id)
    $script:Busy = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Id = $Id; Label = $label; Why = $Why; DeleteId = $DeleteId; Started = Get-Date }
    Write-EditorLog "theme run: $Id ($Why)"
    Set-Status -Text "Theming everything with $label$([char]0x2026)"
    Update-Buttons
}

function Step-EditorApply {
    $b = $script:Busy
    if (-not $b) { return }
    if (-not $b.Handle.IsCompleted) {
        $secs = [int]((Get-Date) - $b.Started).TotalSeconds
        if ($secs -ge 2) { Set-Status -Text "Theming everything with $($b.Label)$([char]0x2026) $secs s" }
        return
    }
    $res = $null
    try { $res = @($b.PS.EndInvoke($b.Handle)) | Select-Object -Last 1 } catch { $res = @{ Code = -1; Text = $_.Exception.GetBaseException().Message } }
    $b.PS.Dispose()
    if (-not $res) { $res = @{ Code = -1; Text = 'no answer from the theme run' } }
    $code = [int]$res.Code
    $text = "$($res.Text)"
    $raw = @($text -split "`r?`n" | ForEach-Object { ($_ -replace '\x1b\[[0-9;]*[A-Za-z]', '').Trim() } | Where-Object { $_ })
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $raw.Count; $i++) {
        if ($raw[$i] -match '^\[(OK|XX|!!|\.\.)\]$' -and $i + 1 -lt $raw.Count) { $lines.Add("$($raw[$i]) $($raw[$i + 1])"); $i++ }
        else { $lines.Add($raw[$i]) }
    }
    $script:Busy = $null
    Write-EditorLog "theme run $($b.Id) exit $code"
    $problems = @($lines | Where-Object { $_ -match '^\[(XX|!!)\]' } | ForEach-Object { $_ -replace '^\[(XX|!!)\]\s*', '' })
    if (-not $problems.Count -and $code -lt 0) { $problems = @($text) }
    $all = $lines -join "`n"
    switch ($code) {
        { ($_ -in @(0, 2)) -and $b.Why -eq 'delete' } {
            # Default is chosen now (the pipeline sets the choice before it reports a failed app).
            Complete-EditorDelete -Id $b.DeleteId
            return
        }
        0 {
            Set-Status -Text "Done: everything is themed with $($b.Label)$(if ($problems.Count) { " -- $($problems -join '; ')" })." -Details $all
        }
        2 { Set-Status -Warn -Text "Themed with $($b.Label), but: $($problems -join '; ')" -Details $all }
        default {
            $why = if ($problems.Count) { $problems -join '; ' } else { "exit $code" }
            if ($b.Why -eq 'delete') {
                Set-Status -Warn -Text "Not deleted -- switching to Default first didn't work: $why" -Details $all
                $script:Ui.AskTitle.Text = 'NOT DELETED'
                $script:Ui.AskText.Text = "Switching everything to Default first didn't work: $(ConvertTo-PaletteSafeText $why)"
                $script:Ui.AskYes.Visibility = 'Collapsed'
                $script:Ui.AskNo.Content = 'OK'
                $script:Ui.AskNo.IsEnabled = $true
            }
            else { Set-Status -Warn -Text "Nothing changed on screen: $why" -Details $all }
        }
    }
    # The editor wears the menus' colors: re-dress it when they changed.
    Update-Known
    Set-EditorBrushes
    Sync-Header
}

function Request-EditorDelete {
    if ($script:Busy -or $script:Mode -ne 'edit') { return }
    $label = Get-EditorLabel
    $extra = if ($script:Id -eq (Get-ChosenId)) { ' It''s the profile in use, so everything goes back to Default first.' } else { '' }
    Show-Ask -Title "DELETE $($label.ToUpperInvariant())?" -Text "Its file (config\palettes\$script:Id.json) is removed -- this can't be undone.$extra" -Yes 'Delete' -No 'Keep it' -Then 'delete'
}

function Remove-EditorProfile {
    if ($script:Id -eq (Get-ChosenId)) {
        # The question's card shows the progress (see Confirm-Ask).
        $script:Ui.AskTitle.Text = "DELETING $((Get-EditorLabel).ToUpperInvariant())"
        $script:Ui.AskText.Text = "Switching everything to Default first$([char]0x2026)"
        Start-EditorApply -Id 'default' -Why 'delete' -DeleteId $script:Id
        return
    }
    Complete-EditorDelete -Id $script:Id
}

function Complete-EditorDelete {
    param([string]$Id)
    try { Remove-PaletteProfile -Id $Id; Write-EditorLog "deleted $Id" }
    catch {
        Set-Status -Warn -Text "Not deleted: $($_.Exception.Message)"
        Close-Ask
        return
    }
    $script:Baseline = Get-WorkJson   # nothing left to ask about
    $script:Window.Close()
}

function Request-EditorClose {
    if ($script:Busy -and $script:Busy.Why -eq 'delete') { return }
    if ($script:Ask) { Close-Ask; return }
    if ($script:Pk) { Close-Picker; return }
    if (Test-Dirty) {
        $what = if ($script:Mode -eq 'default') { 'Default can''t change -- Save as new keeps them as a profile of your own.' } else { 'They haven''t been saved.' }
        Show-Ask -Title 'DISCARD YOUR CHANGES?' -Text $what -Yes 'Discard' -No 'Keep editing' -Then 'discard'
        return
    }
    $script:Window.Close()
}

# ------------------------------------------------------------------------------------------
# Opening a profile
# ------------------------------------------------------------------------------------------
function Open-EditorProfile {
    $chosen = Get-ChosenId
    $warn = $null
    $wantId = $null
    if ($ProfileId) {
        $wantId = ConvertTo-PaletteProfileId $ProfileId
        if (-not $wantId) { $warn = "There's no palette profile '$ProfileId' -- opened $(if ($New) { 'a new one' } else { 'the one in use' }) instead." }
    }
    if ($New -or ($wantId -and $wantId -ne 'default' -and -not (Test-Path -LiteralPath (Get-PaletteProfilePath -Id $wantId)))) {
        $script:Mode = 'new'
        $script:Id = if ($wantId -and $wantId -ne 'default') { $wantId } else { $null }
        $fromId = if ($From) { ConvertTo-PaletteProfileId $From } else { $chosen }
        if (-not $fromId) { $warn = "There's no palette profile '$From' to start from -- started from $(Get-PaletteProfileLabel -Id $chosen)."; $fromId = $chosen }
        Use-StartFrom -Id $fromId -First
    } else {
        $id = if ($wantId) { $wantId } else { $chosen }
        $script:Id = $id
        if ($id -eq 'default') {
            $script:Mode = 'default'
            $script:Work = Copy-PaletteProfile (Get-PaletteDefaultProfile)
            $script:Work.name = ''
        } else {
            $script:Mode = 'edit'
            try { $script:Work = Copy-PaletteProfile (Read-PaletteProfile -Id $id) }
            catch {
                $warn = "$($_.Exception.Message) -- showing Default's settings; saving replaces the file with what you see."
                $script:Work = Copy-PaletteProfile (Get-PaletteDefaultProfile)
                $script:Work.name = ''
            }
        }
        $script:Baseline = Get-WorkJson
        if ($script:Mode -eq 'edit' -and $warn -and $warn -match 'saving replaces') { $script:Baseline = '' }
    }
    if ($warn) { Set-Status -Warn -Text $warn }
}

function Use-StartFrom {
    <# A new profile's starting point: that profile's settings (its name stays yours). #>
    param([string]$Id, [switch]$First)
    $name = if ($First) { '' } else { "$($script:Ui.NameBox.Text)" }
    $p = $null
    try { $p = if ($Id -eq 'default') { Get-PaletteDefaultProfile } else { Read-PaletteProfile -Id $Id } } catch { $p = Get-PaletteDefaultProfile; $Id = 'default' }
    $script:Work = Copy-PaletteProfile $p
    $script:Work.name = ''
    $script:StartFrom = $Id
    $script:Baseline = Get-WorkJson
    $script:BaselineNoName = $script:Baseline
    $script:Work.name = $name
    if (-not $First) {
        Sync-SourceControls
        Sync-OptionControls
        Sync-FromPanel
        Sync-Header
        Request-EditorPalette
    }
}

function Build-FromPanel {
    $panel = $script:Ui.FromPanel
    $panel.Children.Clear()
    foreach ($p in Get-PaletteProfiles) {
        if (-not $p.Exists -or $p.Error) { continue }
        $rb = New-Seg -Text $p.Label -Tag $p.Id -Tip $p.Summary
        $rb.Add_Checked({
            param($s, $e)
            if ($script:Updating) { return }
            if (Test-SettingsChanged) {
                $script:PendingFrom = "$($s.Tag)"
                Sync-FromPanel
                Show-Ask -Title 'START OVER FROM THERE?' -Text 'The changes you made are replaced with that profile''s settings.' -Yes 'Start over' -No 'Keep mine' -Then 'from'
                return
            }
            Use-StartFrom -Id "$($s.Tag)"
        })
        $panel.Children.Add($rb) | Out-Null
    }
    Sync-FromPanel
}

function Sync-FromPanel {
    $script:Updating = $true
    try { foreach ($rb in $script:Ui.FromPanel.Children) { $rb.IsChecked = ("$($rb.Tag)" -eq $script:StartFrom) } }
    finally { $script:Updating = $false }
}

# ------------------------------------------------------------------------------------------
# Wiring
# ------------------------------------------------------------------------------------------
$u = $script:Ui
$u.Header.Add_MouseLeftButtonDown({ param($s, $e) try { $script:Window.DragMove() } catch { } })
$u.CloseX.Add_Click({ Request-EditorClose })
$u.BtnCancel.Add_Click({ Request-EditorClose })
$u.BtnSave.Add_Click({ Invoke-EditorSave })
$u.BtnSaveUse.Add_Click({ Invoke-EditorSave -Use })
$u.BtnDelete.Add_Click({ Request-EditorDelete })
$u.AskYes.Add_Click({ Confirm-Ask })
$u.AskNo.Add_Click({ $script:AskAnswer = $null; $script:Ask = $null; Request-Deferred -Name 'answer' -Ms 30 })

$u.NameBox.Add_TextChanged({
    if ($script:Updating) { return }
    $script:Work.name = "$($script:Ui.NameBox.Text)".Trim()
    Sync-Header
})

foreach ($rb in @($u.KindWallpaper, $u.KindMatch, $u.KindTheme, $u.KindRandom, $u.KindScheme)) {
    $rb.Add_Checked({ param($s, $e) if (-not $script:Updating) { Set-SourceField -Field 'kind' -Value "$($s.Tag)" } })
}
foreach ($rb in @($u.MethodKmeans, $u.MethodSalience, $u.MethodAnsi)) {
    $rb.Add_Checked({ param($s, $e) if (-not $script:Updating) { Set-SourceField -Field 'method' -Value "$($s.Tag)" } })
}
foreach ($rb in @($u.StyleDark, $u.StyleLight)) {
    $rb.Add_Checked({ param($s, $e) if (-not $script:Updating) { Set-SourceField -Field 'style' -Value "$($s.Tag)" } })
}
$u.SatOn.Add_Click({
    $on = $script:Ui.SatOn.IsChecked -eq $true
    Set-SourceField -Field 'saturation' -Value $(if ($on) { [int]$script:Ui.SatSlider.Value } else { 0 })
})
$u.SatSlider.Add_ValueChanged({
    if ($script:Updating) { return }
    $v = [int][Math]::Round($script:Ui.SatSlider.Value)
    $script:Ui.SatValue.Text = "$v"
    $script:Work.source.saturation = $v
    # A wallust run per stop would queue up while dragging: one when the slider rests.
    Request-Deferred -Name 'sat' -Ms 350
})
$u.Cols16.Add_Click({ Set-SourceField -Field 'colors16' -Value ($script:Ui.Cols16.IsChecked -eq $true) })
$u.Shuffle.Add_Click({ $script:RandomRound++; Request-EditorPalette })
$u.PresetDefault.Add_Click({ Set-RolePreset -Name 'default' })
$u.PresetTerminal.Add_Click({ Set-RolePreset -Name 'terminal' })
$u.SchemeFolder.Add_Click({
    $dir = Get-PaletteSchemesDir
    $null = New-Item -ItemType Directory -Force -Path $dir
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$dir`""
})
$u.ThemeSearch.Add_TextChanged({ Request-Deferred -Name 'themeSearch' -Ms 150 })
$u.ThemeList.Add_SelectionChanged({
    if ($script:Updating) { return }
    $n = $script:Ui.ThemeList.SelectedItem
    if ($n -and $script:Work.source.kind -eq 'theme' -and $n -ne $script:Work.source.name) {
        $script:Work.source.name = "$n"
        Request-EditorPalette
    }
})

foreach ($rb in @($u.TermLighten, $u.TermAuto, $u.TermOff)) {
    $rb.Add_Checked({ param($s, $e) if (-not $script:Updating) { $script:Work.readable.terminal = "$($s.Tag)"; Sync-OptionControls; Update-Theme } })
}
$u.ReadUi.Add_Click({ $script:Work.readable.ui = ($script:Ui.ReadUi.IsChecked -eq $true); Update-Theme })
foreach ($rb in @($u.ModeDark, $u.ModeLight, $u.ModeAuto)) {
    $rb.Add_Checked({ param($s, $e) if (-not $script:Updating) { $script:Work.appMode = "$($s.Tag)"; Update-Theme } })
}

# The preview: click a color to change it.
$u.Preview.Add_MouseLeftButtonUp({
    param($s, $e)
    $o = $e.OriginalSource
    while ($o) {
        if (($o -is [System.Windows.FrameworkElement] -or $o -is [System.Windows.FrameworkContentElement]) -and "$($o.Tag)" -match '^\s*\w+\s*=\s*(\w+)\.(\w+)') {
            $t = $Matches[1]; $p = $Matches[2]
            if (Get-PaletteTarget -Id $t) { Open-Picker -Kind 'prop' -Target $t -Prop $p; return }
        }
        $parent = [System.Windows.LogicalTreeHelper]::GetParent($o)
        if (-not $parent -and $o -is [System.Windows.Media.Visual]) { $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($o) }
        $o = $parent
    }
})

# The selector
$u.PkUse.Add_Click({ Close-Picker -Keep })
$u.PkCancel.Add_Click({ Close-Picker })
$u.PkReset.Add_Click({ Set-PickerExpression $script:Pk.Default })
foreach ($rb in @($u.PkAdjNone, $u.PkAdjLighten, $u.PkAdjDarken, $u.PkAdjMix)) {
    $rb.Add_Checked({ param($s, $e) if (-not $script:Updating) { Set-PickerAdjust -Adjust "$($s.Tag)" } })
}
foreach ($rb in @($u.PkSlotBase, $u.PkSlotOther)) {
    $rb.Add_Checked({ param($s, $e) if (-not $script:Updating) { $script:Pk.Slot = "$($s.Tag)"; Sync-Picker } })
}
$u.PkAmount.Add_ValueChanged({ if (-not $script:Updating -and $script:Pk) { Set-PickerAmount -Amount $script:Ui.PkAmount.Value } })
$u.PkExpr.Add_TextChanged({ if (-not $script:Updating -and $script:Pk) { Request-Deferred -Name 'pickerExpr' -Ms 300 } })
$u.PkHexBox.Add_TextChanged({
    if ($script:Updating -or -not $script:Pk) { return }
    $t = "$($script:Ui.PkHexBox.Text)".Trim()
    if ($t -match '^#?([0-9A-Fa-f]{6})$') { Set-PickerName -Name ('#' + $Matches[1].ToLowerInvariant()) }
})
$script:Dragging = $null
foreach ($pair in @(@($u.PkSV, 'sv'), @($u.PkHue, 'hue'))) {
    $pair[0].Tag = $pair[1]
    $pair[0].Add_MouseLeftButtonDown({ param($s, $e) $script:Dragging = "$($s.Tag)"; $null = $s.CaptureMouse(); Set-PickerFromSquare -Sender $s -MouseArgs $e -Part $s.Tag })
    $pair[0].Add_MouseMove({ param($s, $e) if ($script:Dragging -eq "$($s.Tag)") { Set-PickerFromSquare -Sender $s -MouseArgs $e -Part $s.Tag } })
    $pair[0].Add_MouseLeftButtonUp({ param($s, $e) $script:Dragging = $null; $s.ReleaseMouseCapture() })
}

$script:Window.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { $e.Handled = $true; Request-EditorClose; return }
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    if ($ctrl -and $e.Key -eq 'S') {
        $e.Handled = $true
        if ($script:Ui.BtnSave.Visibility -eq 'Visible' -and $script:Ui.BtnSave.IsEnabled) { Invoke-EditorSave }
        elseif ($script:Ui.BtnSaveUse.IsEnabled -and $script:Mode -eq 'edit' -and $script:Id -eq (Get-ChosenId)) { Invoke-EditorSave -Use }
        return
    }
    if ($e.Key -eq 'Return' -and $script:Pk) {
        $e.Handled = $true
        if ($script:Ui.PkExpr.IsKeyboardFocused) { $script:Deferred.Remove('pickerExpr'); Read-PickerExpression }
        elseif ($script:Ui.PkUse.IsEnabled) { Close-Picker -Keep }
    }
})
$script:Window.Add_Activated({
    # Back from Explorer with new scheme files: the list shows them.
    if ($script:Work -and $script:Work.source.kind -eq 'scheme') {
        Update-SchemeList
        if (-not (Test-Path -LiteralPath (Join-Path (Get-PaletteSchemesDir) "$($script:Work.source.file)"))) {
            $f = @(Get-PaletteSchemeFiles)
            if ($f.Count) { Set-SourceField -Field 'file' -Value $f[0] }
        }
        Update-Buttons
    }
})
$script:Window.Add_Closing({
    param($s, $e)
    # A deletion that's switching to Default first has to finish.
    if ($script:Busy -and $script:Busy.Why -eq 'delete') { $e.Cancel = $true }
})
$script:Window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    $e.Handled = $true
    $msg = $e.Exception.GetBaseException().Message
    Write-EditorLog "ERROR: $msg"
    try { Set-Status -Warn -Text "Something went wrong: $msg (logged in %LOCALAPPDATA%\710.DesktopRice\palette-editor.log)" } catch { }
})

# ------------------------------------------------------------------------------------------
# Go
# ------------------------------------------------------------------------------------------
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
# Fit the screen (a 1080p laptop at 125 % has about 830 px of height to give).
$wa = [System.Windows.SystemParameters]::WorkArea
$script:Window.Width = [Math]::Min($script:Window.Width, [Math]::Floor($wa.Width * 0.95))
$script:Window.Height = [Math]::Min($script:Window.Height, [Math]::Floor($wa.Height * 0.95))
$script:Window.MinWidth = [Math]::Min($script:Window.MinWidth, $script:Window.Width)
$script:Window.MinHeight = [Math]::Min($script:Window.MinHeight, $script:Window.Height)
$script:Window.Add_ContentRendered({ $null = $script:Window.Activate() })
Write-EditorLog "opened: $(Get-EditorLabel) ($script:Mode)"
try {
    $null = $script:Window.ShowDialog()
} finally {
    $script:Timer.Stop()
    try { $script:Rs.Dispose() } catch { }
    try { $script:ApplyRs.Dispose() } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
    Write-EditorLog 'closed'
}
exit 0
