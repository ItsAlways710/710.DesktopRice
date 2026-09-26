<#
.SYNOPSIS
  Window-slots: keeps each pinned window in the tile position the user gave it.
  Dot-sourced by Start-WindowSlots.ps1 (the daemon) and save-window-layout.ps1 (captures
  the current arrangement into config/windows.toml), both in this folder.
  NOT WIRED IN (unwired 2026-09-24) -- see README.md in this folder.

.DESCRIPTION
  Ported from winarchy (module/Winarchy/Private/WindowSlots.ps1, WindowPlacement.ps1,
  Util.ps1's Invoke-WinarchyKomorebic/Test-WinarchyProcess), pinned to origin/main @ 4574fc7
  (tag v1.4.0), including the 631143e refinement: only PINNED windows (`pin = true` in
  config/windows.toml) are slot-enforced and learned; explorer.exe/WindowsTerminal.exe/
  wezterm-gui.exe/conhost.exe are never captured; the daemon's debounce is 800ms (up from
  the original 250ms).

  Two deliberate differences from winarchy's own version, both about monitor identity:

  1. windows.toml's `monitor` field holds this repo's already-established identifier,
     serial_number_id (matching install.ps1 Section 4 / config/komorebi/display-
     index.local.json), not winarchy's device_id. Get-MonitorIndexMap below reads
     serial_number_id off each live monitor in `komorebic state`'s own JSON, assuming that
     field is present there the same way it's present in `komorebic monitor-information`'s
     JSON (both are believed to serialize the same underlying Monitor struct, just via
     different subcommands -- this has NOT been confirmed against a real live run, since
     this sandbox has no way to invoke komorebic.exe at all; if that assumption is wrong, a
     monitor just won't resolve and its windows are skipped with a warning, same as any
     other "monitor not connected" case). komorebi's own docs recommend serial_number_id
     over device_id for exactly this kind of mapping anyway (device_id changes across a
     restart, serial_number_id doesn't), so this isn't only a consistency choice.

  2. winarchy's newest commit (631143e) also added a LIVE write of this same identity map
     into komorebi.json's display_index_preferences key, every time window-placement rules
     are re-applied. This repo does NOT port that -- it already had its own, older,
     install-time mechanism for that exact key (install.ps1 Section 4), which is kept
     instead. Documented as a design deviation in the plan doc, since ours hasn't had a
     real multi-monitor reconnect/disconnect test either.

  Placement-on-open (winarchy's Add-WinarchyWindowRulesToKomorebiJson, which injects saved
  preferences as initial_workspace_rules/workspace_rules into komorebi.json) was NOT
  ported, and nothing else does it: tools/compile-komorebi-rules.ps1 never reads
  config/windows.toml. (An earlier version of this comment claimed compile did it
  offline -- it never did; corrected 2026-09-25.) So this code only ever reorders a pinned
  window's TILE POSITION within the workspace it already opened on; it never moves a
  window to its saved monitor or workspace. In winarchy, too, that half came from komorebi's
  own workspace rules, and "learning" only ever meant the tile position.
  Closed 2026-09-25: the monitor/workspace half is planned instead as a Quick add
  "pin to this workspace" action on komorebi's own rules, with no daemon (plan doc, Open
  item 43, parked until the Godzilla install).
#>

# --- komorebi process / CLI helpers ---------------------------------------------------
function Test-Process {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Process -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-Komorebic {
    <# Runs komorebic without opening a console window, returns its stdout. Launched from
       a process with no console of its own (the daemon runs hidden) with CreateNoWindow
       and redirected stdout -- without this, Windows assigns each invocation a fresh
       console window, which komorebi itself tiles for an instant: exactly the kind of
       feedback loop the reconciler exists to avoid causing. #>
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
    $exe = (Get-Command komorebic -ErrorAction SilentlyContinue)?.Source
    if (-not $exe) { throw 'komorebic not found in PATH.' }
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEnd()
    $null = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $out
}

function Get-KomorebiState {
    <# Live komorebi state as an object. Retries: queried right after a reorder, komorebic
       can take longer than expected and answer empty even though komorebi is healthy. #>
    if (-not (Test-Process 'komorebi')) { throw 'komorebi is not running; there is no live state to read.' }
    foreach ($attempt in 1, 2, 3) {
        $raw = Invoke-Komorebic state
        if ($raw.Trim()) { return $raw | ConvertFrom-Json }
        Start-Sleep -Milliseconds (300 * $attempt)
    }
    throw 'komorebic state returned nothing after 3 attempts.'
}

# --- config/windows.toml: hand-rolled reader/writer -----------------------------------
# Same "tiny parser scoped to exactly what we use" philosophy as tools/compile-komorebi-
# rules.ps1's games.toml/rules.toml parsers -- not a general TOML library.
function Get-WindowPrefsPath { Join-Path $Root 'config\windows.toml' }

function Import-WindowPrefs {
    <# Saved preferences. Empty array if the file doesn't exist yet. #>
    $path = Get-WindowPrefsPath
    if (-not (Test-Path $path)) { return @() }
    $entries = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($rawLine in Get-Content $path -Encoding UTF8) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -eq '[[windows]]') {
            if ($cur -and $cur['exe']) { $entries.Add($cur) }
            $cur = @{}
            continue
        }
        if (-not $cur) { continue }
        if ($line -match '^(\w+)\s*=\s*"([^"]*)"$') { $cur[$Matches[1]] = $Matches[2]; continue }
        if ($line -match '^(\w+)\s*=\s*(-?\d+)$') { $cur[$Matches[1]] = [int]$Matches[2]; continue }
        if ($line -match '^(\w+)\s*=\s*(true|false)$') { $cur[$Matches[1]] = ($Matches[2] -eq 'true'); continue }
    }
    if ($cur -and $cur['exe']) { $entries.Add($cur) }

    @(foreach ($entry in $entries) {
        [pscustomobject]@{
            Exe           = $entry['exe']
            Monitor       = "$($entry['monitor'])"
            Workspace     = [int]$entry['workspace']
            WorkspaceName = if ($entry.ContainsKey('workspace_name')) { $entry['workspace_name'] } else { '' }
            Slot          = if ($entry.ContainsKey('slot')) { [int]$entry['slot'] } else { $null }
            Pin           = $entry.ContainsKey('pin') -and $entry['pin']
        }
    })
}

function Export-WindowPrefs {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pref)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Window placement preferences for THIS machine.')
    $lines.Add('# Captured with tools\save-window-layout.ps1 (arrange your windows, then run it).')
    $lines.Add('# `monitor` is this machine''s komorebic monitor-information serial_number_id (see')
    $lines.Add('# config\komorebi\display-index.local.json for the same machine''s index -> serial map).')
    $lines.Add('# `pin = true` enforces both workspace AND slot permanently, and the autostart daemon')
    $lines.Add('# (scripts\Start-WindowSlots.ps1) keeps re-applying its slot if you move it. Without')
    $lines.Add('# `pin`, an app is only ever placed once, when it opens -- nothing reorders it afterwards.')
    $lines.Add('# `slot` is the tile position within the workspace (0 = first); only meaningful, and only')
    $lines.Add('# saved/applied, for pinned apps.')
    foreach ($p in ($Pref | Sort-Object Exe)) {
        $lines.Add('')
        $lines.Add('[[windows]]')
        $lines.Add("exe = `"$($p.Exe)`"")
        $lines.Add("monitor = `"$($p.Monitor)`"")
        $lines.Add("workspace = $($p.Workspace)")
        if ($p.WorkspaceName) { $lines.Add("workspace_name = `"$($p.WorkspaceName)`"") }
        if ($p.Pin -and $null -ne $p.Slot) { $lines.Add("slot = $($p.Slot)") }
        if ($p.Pin) { $lines.Add('pin = true') }
    }
    Set-Content -Path (Get-WindowPrefsPath) -Value ($lines -join "`r`n") -Encoding UTF8 -NoNewline
}

# --- Monitor identity + what NOT to place ----------------------------------------------
function Get-MonitorIndexMap {
    <# serial_number_id -> live monitor index. See this file's header for why
       serial_number_id and not winarchy's device_id. #>
    param([Parameter(Mandatory)]$State)
    $map = @{}
    $index = -1
    foreach ($monitor in $State.monitors.elements) {
        $index++
        if ($monitor.serial_number_id) { $map["$($monitor.serial_number_id)"] = $index }
    }
    $map
}

function Get-GameExes {
    <# Same simple, deliberately-not-a-real-parser read as tools/compile-komorebi-
       rules.ps1's Get-GamesLayer: every `exe = "..."` line in games.toml, regardless of
       which [[section]] it's under. #>
    $gamesToml = Join-Path $Root 'games.toml'
    if (-not (Test-Path $gamesToml)) { return @() }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content $gamesToml -Encoding UTF8) {
        if ($line -match '^\s*exe\s*=\s*"([^"]+)"') { $out.Add($Matches[1]) }
    }
    @($out | Sort-Object -Unique)
}

function Get-UnplaceableExes {
    <# Exes that don't make sense to place: games/launchers, and what komorebi.json
       already ignores outright. Also, per the 631143e refinement, explorer/terminal
       processes -- capturing these as a "preference" just means the shell you happened to
       have open when you saved gets pinned to that spot forever. #>
    $exes = [System.Collections.Generic.List[string]]::new()
    foreach ($exe in 'explorer.exe', 'WindowsTerminal.exe', 'wezterm-gui.exe', 'conhost.exe') { $exes.Add($exe) }
    foreach ($game in Get-GameExes) { $exes.Add($game) }
    $komorebiJson = Join-Path $Root 'config\komorebi\komorebi.json'
    if (Test-Path $komorebiJson) {
        try {
            $config = Get-Content $komorebiJson -Raw | ConvertFrom-Json
            foreach ($rule in $config.ignore_rules) {
                if ($rule.kind -eq 'Exe' -and $rule.id) { $exes.Add($rule.id) }
            }
        } catch { }
    }
    @($exes | Sort-Object -Unique)
}

function Get-WindowPlacements {
    <# Flattens live komorebi state to (Exe, Monitor, Workspace, WorkspaceName, Slot),
       one entry per exe (first window wins if it has more than one). #>
    param([Parameter(Mandatory)]$State)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $out = foreach ($monitor in $State.monitors.elements) {
        $index = -1
        foreach ($workspace in $monitor.workspaces.elements) {
            $index++
            $slot = -1
            foreach ($container in $workspace.containers.elements) {
                $slot++
                foreach ($window in $container.windows.elements) {
                    if (-not $window.exe) { continue }
                    if (-not $seen.Add($window.exe)) { continue }
                    [pscustomobject]@{
                        Exe = $window.exe; Monitor = "$($monitor.serial_number_id)"
                        Workspace = $index; WorkspaceName = $workspace.name; Slot = $slot; Pin = $false
                    }
                }
            }
        }
    }
    $out
}

# --- Pure calculation: signature diffing + slot moves (unchanged from winarchy) -------
function Get-WorkspaceExes {
    param([Parameter(Mandatory)]$Workspace)
    @(foreach ($container in $Workspace.containers.elements) {
        $window = @($container.windows.elements)[0]
        if ($window) { $window.exe } else { '' }
    })
}

function Get-WorkspaceSignature {
    param([Parameter(Mandatory)]$State)
    $signature = @{}
    $monitorIndex = -1
    foreach ($monitor in $State.monitors.elements) {
        $monitorIndex++
        $workspaceIndex = -1
        foreach ($workspace in $monitor.workspaces.elements) {
            $workspaceIndex++
            $exes = @(Get-WorkspaceExes -Workspace $workspace | Sort-Object)
            $signature["$monitorIndex,$workspaceIndex"] = $exes -join '|'
        }
    }
    $signature
}

function Test-WindowsAppeared {
    param($Previous, [Parameter(Mandatory)]$Current)
    if (-not $Previous) { return $false }
    foreach ($key in $Current.Keys) {
        if (-not $Previous.ContainsKey($key)) { return $true }
        if ($Previous[$key] -ne $Current[$key]) { return $true }
    }
    foreach ($key in $Previous.Keys) { if (-not $Current.ContainsKey($key)) { return $true } }
    $false
}

function Get-ChangedWorkspaceKeys {
    param($Previous, [Parameter(Mandatory)]$Current)
    $keys = [System.Collections.Generic.HashSet[string]]::new()
    if (-not $Previous) {
        foreach ($key in $Current.Keys) { $null = $keys.Add($key) }
        return , $keys
    }
    foreach ($key in $Current.Keys) {
        if (-not $Previous.ContainsKey($key) -or $Previous[$key] -ne $Current[$key]) { $null = $keys.Add($key) }
    }
    foreach ($key in $Previous.Keys) { if (-not $Current.ContainsKey($key)) { $null = $keys.Add($key) } }
    , $keys
}

function Get-SlotMoves {
    <# Pending moves so every pinned app with a saved slot ends up there. Pure: only reads
       $State, never touches komorebi. Empty array = state already satisfies every slot. #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pref, $Workspaces = $null)
    $withSlot = @($Pref | Where-Object { $_.Pin -and $null -ne $_.Slot })
    if ($withSlot.Count -eq 0) { return @() }
    $map = Get-MonitorIndexMap -State $State

    $moves = [System.Collections.Generic.List[object]]::new()
    $monitorIndex = -1
    foreach ($monitor in $State.monitors.elements) {
        $monitorIndex++
        $workspaceIndex = -1
        foreach ($workspace in $monitor.workspaces.elements) {
            $workspaceIndex++
            if ($Workspaces -and -not $Workspaces.Contains("$monitorIndex,$workspaceIndex")) { continue }
            $exes = [System.Collections.Generic.List[string]]::new()
            foreach ($exe in (Get-WorkspaceExes -Workspace $workspace)) { $exes.Add($exe) }
            if ($exes.Count -lt 2) { continue }
            $focusedIndex = if ($workspace.containers.PSObject.Properties['focused']) { [int]$workspace.containers.focused } else { 0 }

            $targets = @($withSlot |
                Where-Object { $map.ContainsKey($_.Monitor) -and $map[$_.Monitor] -eq $monitorIndex } |
                Where-Object { $_.Workspace -eq $workspaceIndex } |
                Sort-Object Slot)

            $claimed = [System.Collections.Generic.HashSet[int]]::new()
            foreach ($target in $targets) {
                $from = -1
                for ($i = 0; $i -lt $exes.Count; $i++) { if ($exes[$i] -ieq $target.Exe) { $from = $i; break } }
                if ($from -lt 0) { continue }
                $to = [Math]::Min($target.Slot, $exes.Count - 1)
                if (-not $claimed.Add($to)) { continue }
                if ($from -eq $to) { continue }
                $exes.RemoveAt($from)
                $exes.Insert($to, $target.Exe)
                $moves.Add([pscustomobject]@{
                    Exe = $target.Exe; Monitor = $monitorIndex; Workspace = $workspaceIndex
                    From = $from; To = $to; Focused = $focusedIndex; Count = $exes.Count
                })
                $focusedIndex = $to
            }
        }
    }
    @($moves)
}

function Get-SlotCommands {
    <# One move as the komorebic argument sequence that executes it: navigate by index
       (monitor, workspace, cycle-focus), NOT eager-focus <exe> -- eager-focus grabs the
       first window matching the exe, which can be on another monitor entirely and would
       reorder the wrong workspace with two windows of the same app open. #>
    param([Parameter(Mandatory)]$Move)
    $out = , @('focus-monitor-workspace', "$($Move.Monitor)", "$($Move.Workspace)")
    $steps = ($Move.From - $Move.Focused) % $Move.Count
    if ($steps -lt 0) { $steps += $Move.Count }
    for ($i = 0; $i -lt $steps; $i++) { $out += , @('cycle-focus', 'next') }
    $direction = if ($Move.To -gt $Move.From) { 'next' } else { 'previous' }
    for ($i = 0; $i -lt [Math]::Abs($Move.To - $Move.From); $i++) { $out += , @('cycle-move', $direction) }
    @($out)
}

function Get-FocusedHwnd {
    param([Parameter(Mandatory)]$State)
    function Get-Focused($collection) {
        if (-not $collection -or -not $collection.PSObject.Properties['focused']) { return }
        $elements = @($collection.elements)
        if ($collection.focused -ge $elements.Count) { return }
        $elements[$collection.focused]
    }
    $monitor = Get-Focused $State.monitors
    if (-not $monitor) { return }
    $workspace = Get-Focused $monitor.workspaces
    if (-not $workspace) { return }
    $container = Get-Focused $workspace.containers
    if (-not $container) { return }
    (Get-Focused $container.windows).hwnd
}

function Get-WindowLocation {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Hwnd)
    $monitorIndex = -1
    foreach ($monitor in $State.monitors.elements) {
        $monitorIndex++
        $workspaceIndex = -1
        foreach ($workspace in $monitor.workspaces.elements) {
            $workspaceIndex++
            $containerIndex = -1
            foreach ($container in $workspace.containers.elements) {
                $containerIndex++
                foreach ($window in $container.windows.elements) {
                    if ($window.hwnd -ne $Hwnd) { continue }
                    return [pscustomobject]@{
                        Monitor = $monitorIndex; Workspace = $workspaceIndex; Index = $containerIndex
                        Focused = if ($workspace.containers.PSObject.Properties['focused']) { [int]$workspace.containers.focused } else { 0 }
                        Count = @($workspace.containers.elements).Count
                    }
                }
            }
        }
    }
}

function Get-FocusCommands {
    param([Parameter(Mandatory)]$Location)
    $out = , @('focus-monitor-workspace', "$($Location.Monitor)", "$($Location.Workspace)")
    $steps = ($Location.Index - $Location.Focused) % $Location.Count
    if ($steps -lt 0) { $steps += $Location.Count }
    for ($i = 0; $i -lt $steps; $i++) { $out += , @('cycle-focus', 'next') }
    @($out)
}

function Get-SlotRestore {
    <# Where the window the user had focused ends up after the moves are applied.
       Replays the moves over indices rather than re-reading `komorebic state`: right
       after a reorder, komorebi can answer that query empty for a while, and the user's
       focus can't depend on that timing. #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Move)
    if ($Move.Count -eq 0) { return }
    $hwnd = Get-FocusedHwnd -State $State
    if (-not $hwnd) { return }
    $location = Get-WindowLocation -State $State -Hwnd $hwnd
    if (-not $location) { return }
    $index = $location.Index
    $last = $null
    foreach ($m in $Move) {
        if ($m.Monitor -ne $location.Monitor -or $m.Workspace -ne $location.Workspace) { continue }
        $last = $m
        if ($index -eq $m.From) { $index = $m.To; continue }
        if ($m.From -lt $index -and $m.To -ge $index) { $index-- }
        elseif ($m.From -gt $index -and $m.To -le $index) { $index++ }
    }
    if (-not $last) { $last = @($Move)[-1] }
    [pscustomobject]@{
        Monitor = $location.Monitor; Workspace = $location.Workspace; Index = $index
        Focused = if ($last.Monitor -eq $location.Monitor -and $last.Workspace -eq $location.Workspace) { $last.To } else { $location.Focused }
        Count = $location.Count
    }
}

function Invoke-SlotReconcile {
    <# Moves every pinned-with-slot app to its position. No-op if already satisfied.
       Returns the number of move-events this will generate (the daemon uses this to
       avoid learning its own correction as if the user had made it). #>
    param([switch]$Quiet, $State, $Workspaces = $null)
    $prefs = @(Import-WindowPrefs)
    if (@($prefs | Where-Object { $_.Pin -and $null -ne $_.Slot }).Count -eq 0) {
        if (-not $Quiet) { Step-Info 'No pinned slots saved; nothing to order.' }
        return
    }
    if (-not $State -and -not (Test-Process 'komorebi')) {
        if (-not $Quiet) { Step-Warn 'komorebi is not running; nothing to order.' }
        return
    }
    $state = if ($State) { $State } else { Get-KomorebiState }
    $moves = @(Get-SlotMoves -State $state -Pref $prefs -Workspaces $Workspaces)
    if ($moves.Count -eq 0) {
        if (-not $Quiet) { Step-Ok 'Every pinned window is already in its slot.' }
        return
    }
    $restore = Get-SlotRestore -State $state -Move $moves
    $steps = 0
    foreach ($move in $moves) {
        foreach ($command in (Get-SlotCommands -Move $move)) {
            $null = Invoke-Komorebic @command
            if ($command[0] -eq 'cycle-move') { $steps++ }
        }
    }
    if ($restore) { foreach ($command in (Get-FocusCommands -Location $restore)) { $null = Invoke-Komorebic @command } }
    if (-not $Quiet) { Step-Ok "$($moves.Count) window(s) moved to their slot." }
    $steps
}

function Get-LiveSlotKeys {
    <# Live slot of every window, keyed `exe|serial|workspace` (an app can have windows in
       more than one workspace, so exe alone isn't enough). #>
    param([Parameter(Mandatory)]$State)
    $live = @{}
    foreach ($monitor in $State.monitors.elements) {
        $workspaceIndex = -1
        foreach ($workspace in $monitor.workspaces.elements) {
            $workspaceIndex++
            $slot = -1
            foreach ($container in $workspace.containers.elements) {
                $slot++
                foreach ($window in $container.windows.elements) {
                    if (-not $window.exe) { continue }
                    $key = "$($window.exe)|$($monitor.serial_number_id)|$workspaceIndex"
                    if (-not $live.ContainsKey($key)) { $live[$key] = $slot }
                }
            }
        }
    }
    $live
}

function Get-LearnedSlots {
    <# Preferences with slot updated to the live position -- pinned apps only. #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pref)
    $live = Get-LiveSlotKeys -State $State
    $changed = $false
    foreach ($entry in $Pref) {
        if (-not $entry.Pin) { continue }
        $key = "$($entry.Exe)|$($entry.Monitor)|$($entry.Workspace)"
        if (-not $live.ContainsKey($key)) { continue }
        if ($live[$key] -eq $entry.Slot) { continue }
        $entry.Slot = $live[$key]
        $changed = $true
    }
    if (-not $changed) { return $null }
    @($Pref)
}

function Resolve-SlotConflicts {
    <# Unique slots per workspace: a duplicate is bumped to the next free one. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pref, [hashtable]$Live = @{})
    $changed = $false
    $groups = $Pref | Where-Object { $_.Pin -and $null -ne $_.Slot } | Group-Object { "$($_.Monitor)|$($_.Workspace)" }
    foreach ($group in $groups) {
        $taken = [System.Collections.Generic.HashSet[int]]::new()
        $ordered = $group.Group | Sort-Object @{ Expression = { -not $Live.ContainsKey("$($_.Exe)|$($_.Monitor)|$($_.Workspace)") } }, Slot, Exe
        foreach ($entry in $ordered) {
            $slot = $entry.Slot
            while (-not $taken.Add($slot)) { $slot++ }
            if ($slot -ne $entry.Slot) { $entry.Slot = $slot; $changed = $true }
        }
    }
    $changed
}

function Update-SlotFromState {
    <# Learns the slot the user just gave a pinned window. #>
    param([switch]$Quiet, $State)
    $prefs = @(Import-WindowPrefs)
    if ($prefs.Count -eq 0) { return }
    if (-not $State -and -not (Test-Process 'komorebi')) { return }
    if (-not $State) { $State = Get-KomorebiState }
    $learned = Get-LearnedSlots -State $State -Pref $prefs
    if (-not $learned) { return }
    $null = Resolve-SlotConflicts -Pref $learned -Live (Get-LiveSlotKeys -State $State)
    Export-WindowPrefs -Pref $learned
    if (-not $Quiet) { Step-Ok 'Slots updated from the current arrangement.' }
    $true
}

function Test-SlotEvent {
    <# Is this event worth looking at the state for? Just a noise filter -- WHO moved the
       window is decided from the workspace signature, not this name. #>
    param([string]$Type)
    $Type -in @(
        'ManageWindow', 'UnmanageWindow', 'Manage', 'Unmanage', 'Show', 'Hide', 'Uncloak', 'Cloak', 'Destroy',
        'MoveWindow', 'CycleMoveWindow', 'Promote', 'PromoteSwap', 'PromoteWindow',
        'MouseCapture', 'MoveResizeEnd'
    )
}

function Test-WindowSlotsRunning {
    <# The daemon is alive AND subscribed: the named pipe exists only while the
       subscription is open, and disappears with the process. #>
    Test-Path '\\.\pipe\710-window-slots'
}

function Stop-WindowSlotsDaemon {
    <# Matched by command line via Win32_Process, not `Get-Process -Name pwsh` alone --
       System.Diagnostics.Process (what Get-Process returns) doesn't populate a CommandLine
       property on Windows, so a `$_.CommandLine -like ...` filter against it silently
       matches nothing and this would otherwise never actually stop the daemon. Also scopes
       to THIS repo's launcher specifically, so an unrelated pwsh process is never killed. #>
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains('Start-WindowSlots.ps1') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {
        # Win32_Process unavailable for some reason -- fall back to killing any pwsh
        # holding the daemon's named pipe open, which is a strict superset (best-effort,
        # matches every pwsh.exe rather than just ours) but only fires when the precise
        # match above couldn't even be attempted.
        if (Test-WindowSlotsRunning) {
            Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- tools/save-window-layout.ps1 support ----------------------------------------------
function Save-WindowLayout {
    <# Captures the current arrangement into config/windows.toml. Additive merge: saving
       with only half your session open must not delete preferences for apps that simply
       weren't running at the time. -Exe captures a single app; -WhatIf previews without
       writing. Newly-captured apps are unpinned by default (Slot cleared) -- pin is a
       decision `tools\pin-window.ps1`-equivalent... actually just hand-edit `pin = true`
       into config/windows.toml, or re-save after deciding; capture alone never pins. #>
    param([string]$Exe, [switch]$WhatIf)
    if ($Exe -and $Exe -notlike '*.exe') { $Exe = "$Exe.exe" }
    $state = Get-KomorebiState
    $skip = @(Get-UnplaceableExes)
    $live = @(Get-WindowPlacements -State $state |
        Where-Object { $skip -notcontains $_.Exe } |
        Where-Object { -not $Exe -or $_.Exe -ieq $Exe })
    if ($live.Count -eq 0) {
        if ($Exe) { Step-Warn "'$Exe' is not a managed window right now." }
        else { Step-Warn 'No managed windows to capture.' }
        return
    }
    if ($WhatIf) {
        Step-Info 'Would save:'
        foreach ($p in ($live | Sort-Object Exe)) {
            Write-Host ("    {0,-34} workspace {1} ({2}), slot {3}" -f $p.Exe, $p.Workspace, $p.WorkspaceName, $p.Slot)
        }
        return
    }
    $prefs = @(Import-WindowPrefs)
    $added = 0; $updated = 0
    foreach ($placement in $live) {
        $existing = $prefs | Where-Object { $_.Exe -ieq $placement.Exe } | Select-Object -First 1
        if ($existing) {
            $placement.Pin = $existing.Pin   # pin is a user decision, capture never overwrites it
            $prefs = @($prefs | Where-Object { $_.Exe -ine $placement.Exe })
            $updated++
        } else { $added++ }
        if (-not $placement.Pin) { $placement.Slot = $null }
        $prefs += $placement
    }
    $null = Resolve-SlotConflicts -Pref $prefs -Live (Get-LiveSlotKeys -State $state)
    Export-WindowPrefs -Pref $prefs
    Step-Ok "Layout saved: $added new, $updated updated ($($prefs.Count) total) -> $(Get-WindowPrefsPath)"
    Step-Info 'To have a saved placement enforced continuously, edit its entry in config\windows.toml and set pin = true.'
}
