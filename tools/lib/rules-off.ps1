<#
.SYNOPSIS
  Shipped rules turned off on this machine: the [[off]] blocks of config\komorebi\rules.local.toml
  (Tiling > Turn off a shipped rule..., tools\rule-off.ps1). tools\compile-komorebi-rules.ps1
  dot-sources this and calls Remove-RiceOffRules on its layers; tools\rule-off.ps1 dot-sources it
  for the menu. Only functions.

.NOTES
  An [[off]] block names one shipped rule exactly, the way the compiler tells rules apart:

    # (a comment line saying what it is -- the menu writes one)
    [[off]]
    ignore = "exe=steamwebhelper.exe/equals&title=steam/doesnotequal"

  The key is the rule's list, by the rules files' section names (ignore, manage, floating,
  layered, transparency_ignore, tray_and_multi_window, object_name_change, slow_application);
  the value is the rule as the compiler's Get-RuleExactKey writes it: each condition
  kind=id/matching strategy, lower case, sorted, joined with &. It takes that rule out of every
  shipped layer it's in (vendor\asc, games.toml, rules.toml) -- your own rules are yours to
  remove. Placement rules (ignore, manage, floating) can already be outvoted by one of yours;
  this is what turns off the rest: Layered, Opaque and the other extra-behavior rules, every
  layer's of which are added together, and a game, whose ignore rule only an [[off]] lifts.
#>

function Read-RiceOffRules {
    <# The [[off]] blocks of rules.local.toml, in file order: {Section; Key}. A block's first
       name = "value" line names the rule; a block runs to the next [[section]] line, as in
       the compiler's own reader. Nothing when there's no file. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $inOff = $false; $named = $false
    foreach ($raw in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $raw.Trim()
        if ($line -match '^\[\[(\w+)\]\]$') { $inOff = ($Matches[1] -eq 'off'); $named = $false; continue }
        if ($inOff -and -not $named -and $line -match '^(\w+)\s*=\s*"([^"]*)"$') {
            $named = $true
            [pscustomobject]@{ Section = $Matches[1]; Key = $Matches[2] }
        }
    }
}

function Get-RiceShippedRulesPath {
    # What the last compile saw of the shipped rules, for the Turn off menu. Machine-local, beside
    # 710sRice's logs; uninstall's last section takes the folder.
    Join-Path $env:LOCALAPPDATA '710.DesktopRice\shipped-rules.json'
}

function Remove-RiceOffRules {
    <# The compiler's step for your [[off]] blocks, between reading the layers and merging them.
       Each [[off]] takes its rule out of the shipped layers ($Layers[0..2]: vendor\asc,
       games.toml, rules.toml); $Layers[3], yours, is left as it is. An [[off]] that matches no
       shipped rule is a warning -- an update changed or dropped that rule -- which doctor's
       komorebi.json warnings line shows. Uses the compiler's Get-AllCategories and
       Get-RuleExactKey, so it runs only dot-sourced into the compiler.
       Unless -Check (doctor: nothing written), it also writes every shipped rule -- its
       conditions, where it comes from, whether it's turned off -- to shipped-rules.json for the
       Turn off menu (tools\rule-off.ps1), which asks for it under -Check too with
       $env:RICE_WRITE_SHIPPED_RULES. Returns the layers in a wrapper (.Layers): an array of
       lists put out bare would be unrolled. #>
    param([Parameter(Mandatory)]$Layers, [Parameter(Mandatory)][string]$Path, [switch]$Check)
    $lists = Get-AllCategories                      # section name -> komorebi.json list
    $sectionOf = @{}
    foreach ($s in $lists.Keys) { $sectionOf[$lists[$s]] = $s }
    $off = @{}                                      # "list|key" -> its [[off]]
    foreach ($o in @(Read-RiceOffRules -Path $Path)) {
        if (-not $lists.Contains($o.Section)) {
            Write-Warning "rules.local.toml: [[off]] $($o.Section) = ""$($o.Key)"" -- there's no $($o.Section) rule list, skipping."
            continue
        }
        $off["$($lists[$o.Section])|$($o.Key.ToLowerInvariant())"] = $o
    }
    $found = @{}
    $shipped = [ordered]@{}                         # "list|key" -> the rule, for the menu
    $out = @(for ($level = 0; $level -lt $Layers.Count; $level++) {
        if ($level -gt 2) { , $Layers[$level]; continue }
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $Layers[$level]) {
            $id = "$($entry.Category)|$(Get-RuleExactKey -Rule $entry.Rule)"
            if (-not $shipped.Contains($id)) {
                $shipped[$id] = [ordered]@{
                    section    = $sectionOf[$entry.Category]
                    key        = $id.Substring($id.IndexOf('|') + 1)
                    conditions = @(foreach ($c in @($entry.Rule)) { [ordered]@{ kind = "$($c.kind)"; id = "$($c.id)"; strategy = "$($c.matching_strategy)" } })
                    sources    = [System.Collections.Generic.List[string]]::new()
                    off        = $off.ContainsKey($id)
                }
            }
            if (-not $shipped[$id].sources.Contains($entry.Source)) { $shipped[$id].sources.Add($entry.Source) }
            if ($off.ContainsKey($id)) { $found[$id] = $true; continue }
            $kept.Add($entry)
        }
        , $kept
    })
    foreach ($id in $off.Keys) {
        if ($found.ContainsKey($id)) { continue }
        $o = $off[$id]
        Write-Warning "rules.local.toml: [[off]] $($o.Section) = ""$($o.Key)"" matches no shipped rule (an update changed or dropped it) -- Tiling > Remove a rule... takes it out."
    }
    if (-not $Check -or $env:RICE_WRITE_SHIPPED_RULES) {
        try {
            $file = Get-RiceShippedRulesPath
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file)
            $json = ConvertTo-Json -InputObject @($shipped.Values) -Depth 6
            [IO.File]::WriteAllText("$file.tmp", $json, [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath "$file.tmp" -Destination $file -Force
        } catch { }                                 # the menu compiles again when it finds none
    }
    [pscustomobject]@{ Layers = $out }
}

function Test-RiceRuleCondition {
    <# One condition of a rule against a window ({Exe; Class; Title; Path}), the way komorebi
       0.1.41 matches (window.rs should_act_individual): case-sensitive; Legacy, or no strategy,
       is "starts or ends with" for a title or class and "equals" for an exe or path; a Regex
       that doesn't compile matches nothing. #>
    param([Parameter(Mandatory)]$Condition, [Parameter(Mandatory)]$Window)
    $value = switch ("$($Condition.kind)") { 'Exe' { $Window.Exe } 'Class' { $Window.Class } 'Title' { $Window.Title } 'Path' { $Window.Path } }
    if ($null -eq $value) { return $false }
    $value = "$value"; $id = "$($Condition.id)"
    $o = [StringComparison]::Ordinal
    switch ("$($Condition.strategy)") {
        'Equals'           { return $value.Equals($id, $o) }
        'DoesNotEqual'     { return -not $value.Equals($id, $o) }
        'StartsWith'       { return $value.StartsWith($id, $o) }
        'DoesNotStartWith' { return -not $value.StartsWith($id, $o) }
        'EndsWith'         { return $value.EndsWith($id, $o) }
        'DoesNotEndWith'   { return -not $value.EndsWith($id, $o) }
        'Contains'         { return $value.Contains($id, $o) }
        'DoesNotContain'   { return -not $value.Contains($id, $o) }
        'Regex'            { try { return [regex]::IsMatch($value, $id) } catch { return $false } }
    }
    if ("$($Condition.kind)" -in 'Title', 'Class') { return $value.StartsWith($id, $o) -or $value.EndsWith($id, $o) }
    $value.Equals($id, $o)
}

function Test-RiceRuleMatchesWindow {
    # A rule matches when every one of its conditions does (a compound rule is AND).
    param([Parameter(Mandatory)]$Rule, [Parameter(Mandatory)]$Window)
    foreach ($c in @($Rule.conditions)) { if (-not (Test-RiceRuleCondition -Condition $c -Window $Window)) { return $false } }
    $true
}
