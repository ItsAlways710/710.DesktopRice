<#
.SYNOPSIS
  The screen map (config\komorebi\display-index.local.json): which physical screen is screen
  1, 2, 3, 4 -- komorebi's display_index_preferences, config block -> screen. Dot-sourced by
  tools\write-display-index.ps1 (the writer) and tools\lib\doctor.ps1 (its check) -- one rule
  for what identifies a screen, so the two can't disagree. PS7 only (it runs under pwsh, never
  the 5.1 launchers). Never run directly.

.DESCRIPTION
  A stable map (Group 1 #7, 2026-09-30): numbers once given are kept -- a screen that's
  unplugged keeps its number for when it's back; a screen the map doesn't know takes the lowest
  free number; four at most (base.json has four screen blocks, 9 workspaces each). Until then
  the whole file was rewritten in komorebi's listing order at every install run, so which
  screen was which could change -- fine for workspaces, not for pins (#7), which name a screen.

  A screen is identified by its serial_number_id -- komorebi's docs recommend it for this key
  -- unless it has none, or another connected screen reports the same one (identical TVs can),
  then by its device_id. komorebi v0.1.41 matches either (static_config.rs: serial, or
  device_id, against each display_index_preferences value). An existing map is kept as it is:
  its values were written as serials, and stay matched.

  The values are hardware identifiers: never printed, only counted.
#>

function Get-MonitorKey {
    <# The value that identifies $Monitor in the map: its serial, unless it has none or shares it
       with another of $All (the connected screens), else its device_id. $null when it has
       neither. #>
    param([Parameter(Mandatory)]$Monitor, [object[]]$All = @())
    $serial = "$($Monitor.serial_number_id)".Trim()
    if ($serial) {
        $same = @($All | Where-Object { "$($_.serial_number_id)".Trim() -eq $serial }).Count
        if ($same -le 1) { return $serial }
    }
    $dev = "$($Monitor.device_id)".Trim()
    if ($dev) { return $dev }
    $null
}

function Read-DisplayIndexMap {
    <# The map file as an ordered "0".."3" -> value table (numeric order), $null when there's no
       file. Throws on a file that isn't a JSON object of index -> text. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw
    if (-not "$raw".Trim()) { throw 'display-index.local.json is empty' }
    $obj = $raw | ConvertFrom-Json -AsHashtable
    if ($obj -isnot [System.Collections.IDictionary]) { throw "display-index.local.json isn't a JSON object" }
    foreach ($k in @($obj.Keys)) { if ("$k" -notmatch '^\d+$') { throw "display-index.local.json has a key that isn't a screen index ('$k')" } }
    $map = [ordered]@{}
    foreach ($k in @($obj.Keys | Sort-Object { [int]"$_" })) { $map["$k"] = "$($obj[$k])" }
    $map
}

function Update-DisplayIndexMap {
    <# The map with every connected screen in it: $Map's entries kept as they are, each connected
       screen the map doesn't know given the lowest free index (0-3), in $Monitors' order.
       Returns Map (the new table), Added (the indexes given now), Beyond (connected screens left
       out: no free index), NoId (connected screens with neither a serial nor a device_id). #>
    param($Map, [Parameter(Mandatory)][object[]]$Monitors, [int]$Max = 4)
    $new = [ordered]@{}
    if ($Map) { foreach ($k in $Map.Keys) { $new["$k"] = "$($Map[$k])" } }
    $added = [System.Collections.Generic.List[int]]::new()
    $beyond = 0; $noId = 0
    foreach ($m in $Monitors) {
        $key = Get-MonitorKey -Monitor $m -All $Monitors
        if (-not $key) { $noId++; continue }
        if (@($new.Values) -contains $key) { continue }
        $free = @(0..($Max - 1) | Where-Object { -not $new.Contains("$_") } | Select-Object -First 1)
        if (-not $free.Count) { $beyond++; continue }
        $new["$($free[0])"] = $key
        $added.Add($free[0])
    }
    # Numeric order, so an unchanged map writes the same bytes.
    $sorted = [ordered]@{}
    foreach ($k in @($new.Keys | Sort-Object { [int]"$_" })) { $sorted[$k] = $new[$k] }
    [pscustomobject]@{ Map = $sorted; Added = @($added); Beyond = $beyond; NoId = $noId }
}

function Get-ScreenNumber {
    <# A connected screen's number as you see it (the map's index + 1), or $null when the map
       doesn't list it. #>
    param([Parameter(Mandatory)]$Map, [Parameter(Mandatory)]$Monitor, [object[]]$All = @())
    $key = Get-MonitorKey -Monitor $Monitor -All $All
    if (-not $key) { return $null }
    foreach ($k in $Map.Keys) { if ("$($Map[$k])" -eq $key) { return [int]$k + 1 } }
    $null
}
