#Requires -Version 7.0
<#
.SYNOPSIS
    Palette Profiles -- colour expressions: read one into a small tree, and resolve it to a colour.

.DESCRIPTION
    tools\lib\palette.ps1 loads this (its "Expressions" section, moved here whole), so every
    caller of that library has it. Part of the theme stamp, like palette.ps1: what's here decides
    the colours. The expressions themselves are described in palette.ps1's header.
#>

function ConvertFrom-PaletteExpression {
    <# Parses one expression into a small tree: @{Kind='hex'; Value} | @{Kind='name'; Name} |
       @{Kind='lighten'|'darken'; Arg; Amount} | @{Kind='mix'; Arg; Other; Amount}. Throws a
       readable message on anything else (the editor and doctor show it). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $state = @{ s = $Text; i = 0 }
    $skip = { while ($state.i -lt $state.s.Length -and [char]::IsWhiteSpace($state.s[$state.i])) { $state.i++ } }
    $parse = $null
    $parse = {
        & $skip
        $rest = $state.s.Substring($state.i)
        if ($rest -match '^#[0-9A-Fa-f]{6}(?![0-9A-Za-z])') {
            $state.i += 7
            return @{ Kind = 'hex'; Value = $Matches[0] }
        }
        if ($rest -notmatch '^[A-Za-z][A-Za-z0-9]*') { throw "expected a colour at '$rest'" }
        $word = $Matches[0]
        $state.i += $word.Length
        & $skip
        if ($state.i -lt $state.s.Length -and $state.s[$state.i] -eq '(') {
            $fn = $word.ToLowerInvariant()
            if ($fn -notin 'lighten', 'darken', 'mix') { throw "unknown function '$word' (lighten, darken or mix)" }
            $state.i++
            $arg = & $parse
            $other = $null
            & $skip
            if ($state.i -ge $state.s.Length -or $state.s[$state.i] -ne ',') { throw "$fn(...) needs a comma after its colour" }
            $state.i++
            if ($fn -eq 'mix') {
                $other = & $parse
                & $skip
                if ($state.i -ge $state.s.Length -or $state.s[$state.i] -ne ',') { throw 'mix(a, b, n) needs three parts' }
                $state.i++
            }
            & $skip
            $num = $state.s.Substring($state.i)
            if ($num -notmatch '^\d+(\.\d+)?') { throw "$fn(...) needs an amount from 0 to 100" }
            $amount = [double]$Matches[0]
            if ($amount -lt 0 -or $amount -gt 100) { throw "$fn(...) amount $amount isn't between 0 and 100" }
            $state.i += $Matches[0].Length
            & $skip
            if ($state.i -ge $state.s.Length -or $state.s[$state.i] -ne ')') { throw "$fn(...) is missing its ')'" }
            $state.i++
            $node = @{ Kind = $fn; Arg = $arg; Amount = $amount }
            if ($fn -eq 'mix') { $node.Other = $other }
            return $node
        }
        @{ Kind = 'name'; Name = $word }
    }
    if (-not $Text.Trim()) { throw 'empty colour' }
    $tree = & $parse
    & $skip
    if ($state.i -lt $state.s.Length) { throw "unexpected '$($state.s.Substring($state.i))'" }
    $tree
}

function Resolve-PaletteExpression {
    <# An expression -> '#rrggbb'. Names: the palette's 19 slots, then roles -- $Roles holds
       either finished hex values or, while roles are being resolved, their expressions
       ($RoleDefs + $Visiting catch a role that refers back to itself). #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][System.Collections.IDictionary]$Palette,
          [System.Collections.IDictionary]$Roles = @{}, [System.Collections.IDictionary]$RoleDefs = @{},
          [System.Collections.Generic.HashSet[string]]$Visiting)
    if ($null -eq $Visiting) { $Visiting = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    $tree = ConvertFrom-PaletteExpression -Text $Text
    Resolve-PaletteTree -Tree $tree -Palette $Palette -Roles $Roles -RoleDefs $RoleDefs -Visiting $Visiting
}

function Resolve-PaletteTree {
    param($Tree, $Palette, $Roles, $RoleDefs, $Visiting)
    switch ($Tree.Kind) {
        'hex'  { return $Tree.Value }
        'name' {
            $n = $Tree.Name
            if ($Palette.Contains($n)) { return $Palette[$n] }
            if ($Roles.Contains($n)) { return $Roles[$n] }
            if ($RoleDefs.Contains($n)) {
                if (-not $Visiting.Add($n)) { throw "role '$n' refers back to itself" }
                $v = Resolve-PaletteExpression -Text $RoleDefs[$n] -Palette $Palette -Roles $Roles -RoleDefs $RoleDefs -Visiting $Visiting
                $null = $Visiting.Remove($n)
                $Roles[$n] = $v
                return $v
            }
            throw "unknown colour '$n'"
        }
        'lighten' { return Get-PaletteShadedHex -Hex (Resolve-PaletteTree $Tree.Arg $Palette $Roles $RoleDefs $Visiting) -Factor ($Tree.Amount / 100) }
        'darken'  { return Get-PaletteShadedHex -Hex (Resolve-PaletteTree $Tree.Arg $Palette $Roles $RoleDefs $Visiting) -Factor (-$Tree.Amount / 100) }
        'mix' {
            return Get-PaletteMixedHex -A (Resolve-PaletteTree $Tree.Arg $Palette $Roles $RoleDefs $Visiting) `
                                       -B (Resolve-PaletteTree $Tree.Other $Palette $Roles $RoleDefs $Visiting) -Weight ($Tree.Amount / 100)
        }
    }
    throw "can't read that colour"
}
