#Requires -Version 7.0
<#
.SYNOPSIS
  Compiles config/komorebi/base.json + vendor/asc/applications.json + games.toml +
  config/komorebi/rules.toml + config/komorebi/display-index.local.json into the real
  config/komorebi/komorebi.json that komorebi reads. Run this after editing any of those
  inputs, then reload komorebi.

  This file is NOT tracked in git (see .gitignore) - it's always regenerated from its
  sources, so it can never drift from them and never needs hand-editing.

.NOTES
  Two kinds of rule category, handled differently:
    - "placement" (ignore_rules / manage_rules / floating_applications): a window can
      only go one place, so when two layers disagree about the SAME window, the
      higher-priority layer wins outright and the loser's entry is dropped, not just
      out-voted.
    - "attribute" (transparency_ignore_rules / tray_and_multi_window_applications /
      object_name_change_applications / slow_application_identifiers /
      layered_applications): these describe behavior, never conflict, so every layer's
      entries are simply unioned.

  Priority, low to high: vendor/asc -> games.toml -> config/komorebi/rules.toml.
  "Same window" identity = kind+id (ignoring matching_strategy); a compound (array)
  rule's identity is the sorted combination of all its conditions.

  display_index_preferences is handled separately from the three rule layers above: it
  isn't a rule at all, it's a monitor-index -> serial_number_id map, and it's exactly as
  machine-specific as a secret (a different machine's monitor arrangement would make a
  hardcoded value actively wrong, not just inapplicable). So it never comes from
  base.json or any tracked source - it comes from config/komorebi/display-index.local.json,
  a small gitignored file that install.ps1 generates from that machine's own
  `komorebic.exe monitor-information` output (same pattern as config/ahk/user.ahk: not
  versioned, survives `git pull`, exists only where actually needed). When that file is
  absent - a fresh clone, or a machine install.ps1 hasn't been run on yet - the key is
  simply omitted from the compiled output, and komorebi falls back to whatever order
  Windows enumerates that session.
#>

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)  # tools/.. = repo root

$BasePath         = Join-Path $RepoRoot 'config\komorebi\base.json'
$AscPath          = Join-Path $RepoRoot 'vendor\asc\applications.json'
$GamesPath        = Join-Path $RepoRoot 'games.toml'
$RulesPath        = Join-Path $RepoRoot 'config\komorebi\rules.toml'
$DisplayIndexPath = Join-Path $RepoRoot 'config\komorebi\display-index.local.json'
$OutPath          = Join-Path $RepoRoot 'config\komorebi\komorebi.json'

# Category key: what a source file calls it -> the real komorebi.json array name.
$PlacementCategories = [ordered]@{
    ignore   = 'ignore_rules'
    manage   = 'manage_rules'
    floating = 'floating_applications'
}
$AttributeCategories = [ordered]@{
    layered               = 'layered_applications'
    object_name_change    = 'object_name_change_applications'
    tray_and_multi_window = 'tray_and_multi_window_applications'
    slow_application      = 'slow_application_identifiers'
    transparency_ignore   = 'transparency_ignore_rules'
}
function Get-AllCategories {
    $all = [ordered]@{}
    foreach ($m in @($PlacementCategories, $AttributeCategories)) {
        foreach ($k in $m.Keys) { $all[$k] = $m[$k] }
    }
    $all
}

function ConvertTo-RuleObject {
    # Normalizes one rule (a single condition, or an array of conditions = AND) to a
    # plain object with kind/id/matching_strategy (defaulting matching_strategy to
    # "Equals", same default komorebi itself uses).
    param([Parameter(Mandatory)]$Rule)
    $one = {
        param($r)
        $id = if ($r -is [hashtable]) { $r['id'] } else { $r.id }
        $kind = if ($r -is [hashtable]) { $r['kind'] } else { $r.kind }
        $strategy = if ($r -is [hashtable]) { $r['matching_strategy'] } else { $r.matching_strategy }
        [pscustomobject]@{ kind = $kind; id = $id; matching_strategy = ($strategy ? $strategy : 'Equals') }
    }
    if ($Rule -is [System.Collections.IEnumerable] -and $Rule -isnot [string] -and $Rule -isnot [hashtable]) {
        @(foreach ($r in $Rule) { & $one $r })
    } else {
        & $one $Rule
    }
}

function Get-RuleTargetKey {
    # Identity used to decide "is this the same window another layer opined about",
    # ignoring matching_strategy - Equals vs Legacy on the same exe is still the same
    # window as far as who-wins is concerned.
    param([Parameter(Mandatory)]$Rule)
    $parts = foreach ($r in @($Rule)) { "$($r.kind)=$($r.id)".ToLowerInvariant() }
    ($parts | Sort-Object) -join '&'
}

function Get-RuleExactKey {
    # Identity used only for de-duplicating within the same category (includes
    # matching_strategy, since that's a real difference for exact-duplicate purposes).
    param([Parameter(Mandatory)]$Rule)
    $parts = foreach ($r in @($Rule)) { "$($r.kind)=$($r.id)/$($r.matching_strategy)".ToLowerInvariant() }
    ($parts | Sort-Object) -join '&'
}

function Get-AscLayer {
    param([string[]]$Disabled = @())
    if (-not (Test-Path $AscPath)) { return @() }
    $asc = Get-Content $AscPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    $categories = Get-AllCategories
    $skip = @($Disabled | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($app in ($asc.Keys | Sort-Object)) {
        if ($app.StartsWith('$')) { continue }
        if ($app.ToLowerInvariant() -in $skip) { continue }
        foreach ($key in $categories.Keys) {
            if (-not $asc[$app].ContainsKey($key)) { continue }
            foreach ($rule in $asc[$app][$key]) {
                $out.Add(@{ Category = $categories[$key]; Rule = ConvertTo-RuleObject -Rule $rule; Source = "asc:$app" })
            }
        }
    }
    $out
}

function Get-GamesLayer {
    # games.toml is a flat "exe = ""Name.exe""" list under [[launchers]] / [[games]] -
    # every entry becomes an ignore_rules entry. Parsed line-by-line on purpose (not a
    # general TOML parser): this file's shape is simple and fixed, and a tiny parser
    # scoped to exactly what we use is easier to read and debug than a dependency.
    if (-not (Test-Path $GamesPath)) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content $GamesPath -Encoding UTF8) {
        if ($line -match '^\s*exe\s*=\s*"([^"]+)"') {
            $out.Add(@{
                Category = 'ignore_rules'
                Rule     = [pscustomobject]@{ kind = 'Exe'; id = $Matches[1]; matching_strategy = 'Equals' }
                Source   = 'games.toml'
            })
        }
    }
    $out
}

function Get-UserRulesLayer {
    # config/komorebi/rules.toml - your own overrides. Doesn't need to exist; an absent
    # file just means "no overrides yet", not an error.
    #   [[ignore]]
    #   exe = "SomeApp.exe"
    #   [[disable]]
    #   asc = "Some ASC App Name"     # skip a whole ASC-named app's rules entirely
    #
    # Returns a single [pscustomobject] with .Entries / .Disabled, not two separate
    # return values - PowerShell flattens arrays written to the output stream, so
    # `return @(), @()` silently collapses to $null, $null when both are empty
    # (exactly the case on a first run, before rules.toml exists). Wrapping them in
    # one object sidesteps that footgun entirely.
    if (-not (Test-Path $RulesPath)) { return [pscustomobject]@{ Entries = @(); Disabled = @() } }
    $categories = Get-AllCategories
    $currentSection = $null
    $currentEntry = $null
    $sections = [System.Collections.Generic.List[object]]::new()
    foreach ($rawLine in Get-Content $RulesPath -Encoding UTF8) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[\[(\w+)\]\]$') {
            if ($currentEntry) { $sections.Add($currentEntry) }
            $currentEntry = [ordered]@{ __section = $Matches[1] }
            continue
        }
        if ($line -match '^(\w+)\s*=\s*"([^"]*)"$' -and $currentEntry) {
            $currentEntry[$Matches[1]] = $Matches[2]
        }
    }
    if ($currentEntry) { $sections.Add($currentEntry) }

    $disabled = @($sections | Where-Object { $_.__section -eq 'disable' } | ForEach-Object { $_['asc'] })
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in ($sections | Where-Object { $_.__section -ne 'disable' })) {
        $section = $entry.__section
        if (-not $categories.Contains($section)) {
            Write-Warning "rules.toml: unknown section [[$section]], skipping."
            continue
        }
        $kind = $null; $id = $null
        if ($entry.Contains('exe'))   { $kind = 'Exe';   $id = $entry['exe'] }
        elseif ($entry.Contains('class')) { $kind = 'Class'; $id = $entry['class'] }
        elseif ($entry.Contains('title')) { $kind = 'Title'; $id = $entry['title'] }
        else { Write-Warning "rules.toml: [[$section]] entry needs exe/class/title, skipping."; continue }
        $strategy = if ($entry.Contains('matching_strategy')) { $entry['matching_strategy'] } else { 'Equals' }
        $out.Add(@{
            Category = $categories[$section]
            Rule     = [pscustomobject]@{ kind = $kind; id = $id; matching_strategy = $strategy }
            Source   = 'user:rules.toml'
        })
    }
    return [pscustomobject]@{ Entries = $out; Disabled = $disabled }
}

function Get-DisplayIndexPreferences {
    # config/komorebi/display-index.local.json - machine-local, gitignored, written by
    # install.ps1 from a real `komorebic.exe monitor-information` run on that machine.
    # Expected shape: a flat object mapping monitor-config array index (as a string) to
    # that monitor's serial_number_id (as a string), e.g. {"0": "0", "1": "1234567890"} (made-up serial).
    # Supports up to 4 keys (4 displays) - just more entries in the same map, nothing
    # structural changes past that. Returns $null (not @{}) when there's nothing to
    # merge, so the caller can tell "omit the key" apart from "merge an empty map".
    if (-not (Test-Path $DisplayIndexPath)) { return $null }
    $raw = Get-Content $DisplayIndexPath -Raw -Encoding UTF8
    if (-not $raw.Trim()) { return $null }
    try {
        $map = $raw | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "config/komorebi/display-index.local.json exists but isn't valid JSON, ignoring it: $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $map -or $map.Count -eq 0) { return $null }
    if ($map.Count -gt 4) {
        Write-Warning "display-index.local.json has $($map.Count) entries; only 4 displays are supported, using it as-is anyway."
    }
    $map
}

function Merge-Rules {
    # $Layers is an array of arrays, lowest priority first. Left un-typed on purpose:
    # a typed [object[]] would flatten the layer boundaries into one list and lose the
    # priority information the override logic depends on.
    param([Parameter(Mandatory)]$Layers)

    # Named $placementCategoryNames, NOT $placementCategories - PowerShell variable names
    # are case-insensitive and unqualified lookups walk the CALL STACK, not lexical scope.
    # A local named $placementCategories would shadow the script-scoped $PlacementCategories
    # hashtable for every function called from here too (including Get-AllCategories below),
    # silently breaking it. Learned this the hard way - see git history if it recurs.
    $placementCategoryNames = @($PlacementCategories.Values)
    $merged = [ordered]@{}
    foreach ($cat in (Get-AllCategories).Values) { $merged[$cat] = [System.Collections.Generic.List[object]]::new() }

    $placementWinner = @{}   # target key -> @{ Level; Entries }
    $seen = @{}

    for ($level = 0; $level -lt $Layers.Count; $level++) {
        foreach ($entry in $Layers[$level]) {
            if ($entry.Category -in $placementCategoryNames) {
                $target = Get-RuleTargetKey -Rule $entry.Rule
                if (-not $placementWinner.ContainsKey($target) -or $placementWinner[$target].Level -lt $level) {
                    $placementWinner[$target] = @{ Level = $level; Entries = [System.Collections.Generic.List[object]]::new() }
                }
                if ($placementWinner[$target].Level -eq $level) { $placementWinner[$target].Entries.Add($entry) }
                continue
            }
            if (-not $merged.Contains($entry.Category)) {
                Write-Warning "Unrecognized category '$($entry.Category)' from $($entry.Source) - skipping."
                continue
            }
            $key = "$($entry.Category)|" + (Get-RuleExactKey -Rule $entry.Rule)
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $merged[$entry.Category].Add($entry.Rule)
        }
    }
    foreach ($target in ($placementWinner.Keys | Sort-Object)) {
        foreach ($entry in $placementWinner[$target].Entries) {
            if (-not $merged.Contains($entry.Category)) {
                Write-Warning "Unrecognized category '$($entry.Category)' from $($entry.Source) - skipping."
                continue
            }
            $key = "$($entry.Category)|" + (Get-RuleExactKey -Rule $entry.Rule)
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $merged[$entry.Category].Add($entry.Rule)
        }
    }
    $merged
}

# --- Compile -----------------------------------------------------------------------

try {
    if (-not (Test-Path $BasePath)) { throw "Missing $BasePath - nothing to compile onto." }
    $base = Get-Content $BasePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $userRules   = Get-UserRulesLayer
    $userLayer   = $userRules.Entries
    $disabledAsc = $userRules.Disabled
    $layers = @(
        ,(Get-AscLayer -Disabled $disabledAsc)   # level 0 - lowest priority
        ,(Get-GamesLayer)                        # level 1
        ,$userLayer                              # level 2 - highest priority
    )
    $merged = Merge-Rules -Layers $layers

    foreach ($cat in $merged.Keys) {
        $rules = @($merged[$cat])
        if ($rules.Count -eq 0) {
            if ($base.PSObject.Properties[$cat]) { $base.PSObject.Properties.Remove($cat) }
            continue
        }
        if ($base.PSObject.Properties[$cat]) { $base.$cat = $rules }
        else { $base | Add-Member -NotePropertyName $cat -NotePropertyValue $rules }
    }

    # display_index_preferences: not a rule layer, machine-local, merged in only when
    # config/komorebi/display-index.local.json exists (see Get-DisplayIndexPreferences).
    $displayIndex = Get-DisplayIndexPreferences
    if ($displayIndex) {
        if ($base.PSObject.Properties['display_index_preferences']) {
            $base.display_index_preferences = $displayIndex
        } else {
            $base | Add-Member -NotePropertyName 'display_index_preferences' -NotePropertyValue $displayIndex
        }
    } elseif ($base.PSObject.Properties['display_index_preferences']) {
        # base.json itself should never carry this (it's tracked and shared across every
        # machine's git pull), but strip it defensively if it ever ends up there anyway.
        $base.PSObject.Properties.Remove('display_index_preferences')
    }

    # Only write komorebi.json when the compiled result actually differs from what's
    # already there. komorebi watches this file and hot-reloads it on ANY write -- and
    # that reload resets every workspace back to its config layout, wiping whatever
    # layouts/column counts were set live (confirmed 2026-09-23: a no-op recompile via
    # SUPER+Shift+R flipped two Scrolling workspaces back to BSP). An identical rewrite
    # would pay that cost for nothing.
    $json = $base | ConvertTo-Json -Depth 50
    $existing = if (Test-Path $OutPath) { Get-Content -Path $OutPath -Raw } else { $null }
    # Line endings normalized on both sides, so a CRLF/LF difference alone never
    # counts as "changed".
    if ($null -ne $existing -and ($existing -replace "`r`n", "`n").TrimEnd() -ceq ($json -replace "`r`n", "`n").TrimEnd()) {
        Write-Host "Unchanged $OutPath (left alone -- komorebi reloads on every write)"
    } else {
        $json | Set-Content -Path $OutPath -Encoding UTF8
        Write-Host "Compiled $OutPath"
    }
    foreach ($cat in (Get-AllCategories).Values) {
        $count = @($merged[$cat]).Count
        if ($count -gt 0) { Write-Host ("  {0,-38} {1}" -f $cat, $count) }
    }
    if ($displayIndex) {
        Write-Host ("  {0,-38} {1}" -f 'display_index_preferences', "$($displayIndex.Count) monitor(s)")
    }
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    throw
}
