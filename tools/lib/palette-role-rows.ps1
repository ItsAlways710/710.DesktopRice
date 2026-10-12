#Requires -Version 7.0
<#
.SYNOPSIS
    The palette editor's roles: a row per role, and under each the app colors that follow it.

.DESCRIPTION
    The nine role rows are built when the editor starts, but the app colors under a role (60
    in all) only the first time it's opened, and painted then: few visits open a role, and
    building all of them was the slowest step of the editor's start. Update-RoleRows repaints
    whatever has been built, on every change.

    tools\palette-editor.ps1 dot-sources this, so it runs in the editor's own scope: its
    $script:Ui, $script:Layout, $script:Work and $script:Theme, and New-Swatch, New-Text,
    Get-ExpressionWords, Get-PropLabel, Open-Picker and Reset-Override. WPF only, and the
    editor's alone.
#>

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

        # The app colors under it go in here the first time it's opened (Build-RoleAppRows).
        $props = [System.Windows.Controls.StackPanel]::new()
        $props.Margin = [System.Windows.Thickness]::new(66, 0, 0, 6)
        $props.Visibility = 'Collapsed'
        $wrap.Children.Add($props) | Out-Null
        $script:Ui.RolesPanel.Children.Add($wrap) | Out-Null
        $script:RoleUi[$role] = @{ Row = $row; Swatch = $sw; Expr = $expr; Count = $count; Props = $props; Chev = $chev; Built = $false }
    }
}

function Build-RoleAppRows {
    <# A role's app colors, a row each, into its panel: the first time it's opened. #>
    param([string]$Role)
    $r = $script:RoleUi[$Role]
    foreach ($it in $script:Layout[$Role]) {
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
        $r.Props.Children.Add($pr) | Out-Null
        $script:PropUi[$key] = @{ Row = $pr; Swatch = $psw; Label = $pl; Expr = $pe; Reset = $reset; Target = $it.Target; Prop = $it.Prop; Role = $Role }
    }
    $r.Built = $true
}

function Switch-RoleOpen {
    # The first opening builds the role's app colors and paints them (Update-AppRows).
    param([string]$Role)
    $r = $script:RoleUi[$Role]
    $open = $r.Props.Visibility -ne 'Visible'
    if ($open -and -not $r.Built) {
        Build-RoleAppRows -Role $Role
        if ($script:Theme) { Update-AppRows -Role $Role }
    }
    $r.Props.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
    $r.Chev.RenderTransform = if ($open) { [System.Windows.Media.RotateTransform]::new(90) } else { $null }
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
    Update-AppRows
}

function Update-AppRows {
    <# Paints the app colors built so far, or only -Role's (at its first opening). #>
    param([string]$Role)
    $th = $script:Theme
    $raised = @{}
    foreach ($x in $th.Raised) { if ($x -match '^(\w+\.\w+) (#\w+)->(#\w+)$') { $raised[$Matches[1]] = $Matches[2] } }
    foreach ($key in $script:PropUi.Keys) {
        $p = $script:PropUi[$key]
        if ($Role -and $p.Role -ne $Role) { continue }
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
