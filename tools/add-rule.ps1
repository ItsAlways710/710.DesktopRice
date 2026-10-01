#Requires -Version 7.0
<#
.SYNOPSIS
  Add a rule to YOUR rules file, config\komorebi\rules.local.toml (gitignored -- the tracked
  rules.toml holds the rules this repo ships; plan doc Open item 38): a floating / ignore /
  manage / layered / transparency_ignore rule, a game, or a pin. Optionally applies it to
  one live window right now. The engine behind 710.ahk's "Quick add rule..." (Tiling menu);
  usable by hand too.

.DESCRIPTION
  Ported from winarchy's Add-WinarchyUserRule (module/Winarchy/Private/AppRules.ps1):
  validates the input, creates rules.local.toml if it doesn't exist yet, skips an exact
  duplicate (in either rules file -- no local copy of a rule that already ships), appends
  the entry. Every write keeps the file's own line endings (CRLF stays CRLF; winarchy
  b27bcbf, for games.toml) and its BOM if it has one. Unlike winarchy's, it doesn't
  recompile/reload itself -- the caller runs SUPER+Shift+R's reload-stack.ps1 afterwards,
  which already knows how to get komorebi to pick a rule up without losing your layouts
  (additions take komorebi's fast hot-reload path).

  Written for compile-komorebi-rules.ps1's own rules.toml reader, which is a deliberate
  subset of TOML: `key = "value"` with the value taken RAW -- no escape sequences, so a
  backslash (window titles with paths in them) is written as-is, and a value containing a
  double quote can't be represented at all. That case is refused (exit 1) rather than
  written in a form compile would silently skip.

  -Category game (Group 1 #5): a [[game]] block -- never tiled, and 710.ahk's game mode
  shows while it's focused. exe only. Already a game -- yours, or one games.toml ships --
  is a duplicate (exit 3, nothing written). Applied now like ignore.

  -Category pin (Group 1 #7): a [[pin]] block -- exe, screen, workspace -- that sends the
  app's windows to that workspace when they open. With -Hwnd, the screen and workspace are
  where that window is now: its monitor in `komorebic state` (serial / device_id) looked up
  in the screen map (display-index.local.json, tools\lib\monitors.ps1) -- never komorebi's
  own monitor order -- and its workspace's position. By hand: -Screen N -Workspace N. One
  pin per exe: pinning again replaces the old pin where it stands. No apply-now (the window
  is already there). Refused, nothing written: a window komorebi doesn't manage (exit 6);
  Windows Terminal or Explorer (exit 7 -- one exe behind every window of theirs); a game
  (exit 8 -- never tiled, a pin would do nothing); a screen the map doesn't number (exit 9 --
  `710sRice doctor` says how to fix the map).

  -Hwnd (optional): also make the rule true for that window now, since komorebi only
  applies rules to windows that open after them. The caller must have FOCUSED that window
  first -- komorebic's toggle-float / manage / unmanage all act on the focused window.
  Looks the window up in `komorebic state` so each command only runs when it would
  change something (toggle-float on an already-floating window would tile it instead).
  layered / transparency_ignore have no apply-now: an opaque rule takes effect the next
  time the window is focused (komorebi re-reads that list on every transparency pass), and
  a layered window is still turned away by `komorebic manage` until komorebi has reloaded
  the new rule -- which happens AFTER this script -- so the caller tells the user to
  relaunch the app instead.

  The value comes from -Value, or from $env:QUICKADD_VALUE when -Value isn't given -- so
  AHK never has to quote an arbitrary window title onto a command line.

  Exit codes: 0 = rule added (a pin: added or moved); 3 = identical rule already there
  (rules.local.toml, rules.toml, or for a game games.toml; nothing written, apply-now still
  ran); 2 = rule added but apply-now failed; 6 / 7 / 8 / 9 = a pin refused (above); 1 =
  nothing done (bad input, unwritable file, ...). Messages go to
  %LOCALAPPDATA%\710.DesktopRice\add-rule.log.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('floating', 'ignore', 'manage', 'layered', 'transparency_ignore', 'game', 'pin')][string]$Category,
    [Parameter(Mandatory)][ValidateSet('exe', 'class', 'title')][string]$Field,
    [string]$Value,
    [long]$Hwnd = 0,
    [int]$Screen = 0,
    [int]$Workspace = 0
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$RulesPath   = Join-Path $Root 'config\komorebi\rules.local.toml'   # yours -- written here
$ShippedPath = Join-Path $Root 'config\komorebi\rules.toml'         # shipped -- only read, for duplicates
$GamesPath   = Join-Path $Root 'games.toml'                         # shipped games -- only read
$BasePath    = Join-Path $Root 'config\komorebi\base.json'          # how many screens / workspaces a pin can name
$MapPath     = Join-Path $Root 'config\komorebi\display-index.local.json'

$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'add-rule.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# Log cap: past 1 MB this log becomes <name>.old (replacing the previous one) and a fresh
# one starts -- so at most ~2 MB, and the last chunk of history is always kept. Same rule
# in every 710.DesktopRice log writer (plan doc, open item 20).
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }
function Write-Log([string]$m) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Out-File -FilePath $log -Append -Encoding utf8
}

if (-not $PSBoundParameters.ContainsKey('Value')) { $Value = $env:QUICKADD_VALUE }
if ([string]::IsNullOrWhiteSpace($Value)) { Write-Log "refused: empty $Field value."; exit 1 }
if ($Value.Contains('"')) {
    Write-Log "refused: $Field value contains a double quote, which the rules files' reader can't represent: $Value"
    exit 1
}
if ($Value -match '[\r\n]') { Write-Log "refused: $Field value spans lines: $Value"; exit 1 }
if ($Category -in 'game', 'pin' -and $Field -ne 'exe') { Write-Log "refused: [[$Category]] matches on exe only (got $Field)."; exit 1 }

# --- The rules files: same line grammar compile-komorebi-rules.ps1 reads ------------------

function Read-RulesFile([string]$Path) {
    <# The file's text, its newline (CRLF if it has any, else LF) and whether it starts with a
       BOM -- so a write can keep all three. $null when there's no file. #>
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    [pscustomobject]@{ Text = $text; Nl = $(if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }); Bom = $bom }
}

function Get-RuleBlocks([string[]]$Lines) {
    <# Each [[section]] block: its section, first and last line index, and its key = value
       lines (strings unquoted, bare numbers as [int]). A block runs to the next blank line or
       [[section]] -- remove-rule.ps1's rule; comment lines inside it don't end it. #>
    $blocks = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (-not ($Lines[$i].Trim() -match '^\[\[(\w+)\]\]$')) { continue }
        $b = [pscustomobject]@{ Section = $Matches[1]; Start = $i; End = $i; Values = [ordered]@{} }
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            $l = $Lines[$j].Trim()
            if ($l -eq '' -or $l -match '^\[\[\w+\]\]$') { break }
            $b.End = $j
            if ($l -match '^(\w+)\s*=\s*"([^"]*)"$') { if (-not $b.Values.Contains($Matches[1])) { $b.Values[$Matches[1]] = $Matches[2] } }
            elseif ($l -match '^(\w+)\s*=\s*(\d+)$') { if (-not $b.Values.Contains($Matches[1])) { $b.Values[$Matches[1]] = [int]$Matches[2] } }
        }
        $blocks.Add($b)
    }
    $blocks
}

function Get-FileLines($File) { if ($File) { @($File.Text -split '\r?\n') } else { @() } }

function Get-GameExes {
    <# Every game: each exe = "..." line of games.toml (all its sections -- launchers too, as
       every reader takes them) plus your [[game]] blocks. As [pscustomobject] Exe / In. #>
    $g = Read-RulesFile $GamesPath
    foreach ($l in (Get-FileLines $g)) { if ($l -match '^\s*exe\s*=\s*"([^"]+)"') { [pscustomobject]@{ Exe = $Matches[1]; In = 'games.toml' } } }
    foreach ($b in (Get-RuleBlocks (Get-FileLines (Read-RulesFile $RulesPath)))) {
        if ($b.Section -eq 'game' -and $b.Values['exe']) { [pscustomobject]@{ Exe = "$($b.Values['exe'])"; In = 'rules.local.toml' } }
    }
}

function Write-RulesFile([string]$Path, [string]$Text, [bool]$Bom) {
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($Bom))
}

function Add-RuleBlock([string[]]$BlockLines) {
    <# Appends a block (its lines, no newline) to rules.local.toml in the file's own line
       endings, creating the file with its header first if it doesn't exist. #>
    $f = Read-RulesFile $RulesPath
    if ($f) {
        $nl = $f.Nl
        # Blank line between entries; don't glue onto a last line missing its newline.
        $lead = if (-not $f.Text) { '' } elseif ($f.Text.EndsWith("`n")) { $nl } else { $nl + $nl }
        [System.IO.File]::AppendAllText($RulesPath, $lead + ($BlockLines -join $nl) + $nl, [System.Text.UTF8Encoding]::new($false))
    } else {
        # Same text as 710.ahk's EditMyRules() writes -- keep the two in step.
        $header = "# Your own komorebi rules -- this machine only (gitignored), the highest-priority`n" +
                  "# layer: above rules.toml (the rules this repo ships), games.toml and the vendored`n" +
                  "# community ASC rules. Quick add rule writes here; compiled into komorebi.json by`n" +
                  "# tools\compile-komorebi-rules.ps1 (SUPER+Shift+R). Sections: [[floating]], [[ignore]],`n" +
                  "# [[manage]], [[layered]], [[transparency_ignore]], ... with one of exe / class /`n" +
                  "# title per entry; [[game]] with an exe; [[pin]] with an exe, screen = N, workspace = N.`n" +
                  "# Want a rule on every machine? Move it into rules.toml (a game: games.toml) and commit.`n`n"
        Write-RulesFile $RulesPath ($header + ($BlockLines -join "`n") + "`n") $false
        Write-Log "created $RulesPath"
    }
}

# --- komorebi's view of a window ----------------------------------------------------------

function Get-KomorebiState {
    $komorebic = Join-Path $env:ProgramFiles 'komorebi\bin\komorebic.exe'
    if (-not (Test-Path $komorebic)) { $komorebic = (Get-Command komorebic -ErrorAction Stop).Source }
    $raw = & $komorebic state 2>&1
    if ($LASTEXITCODE -ne 0) { throw "komorebic state failed ($LASTEXITCODE) -- is komorebi running?" }
    [pscustomobject]@{ Komorebic = $komorebic; State = (($raw -join "`n") | ConvertFrom-Json) }
}

function Find-StateWindow($State, [long]$Handle) {
    <# Where komorebi has the window: Where = tiled / floating / unmanaged, plus its monitor
       (the state's element) and its monitor / workspace positions. #>
    $mons = @($State.monitors.elements)
    for ($i = 0; $i -lt $mons.Count; $i++) {
        $wss = @($mons[$i].workspaces.elements)
        for ($j = 0; $j -lt $wss.Count; $j++) {
            $ws = $wss[$j]
            $where = $null
            foreach ($c in @($ws.containers.elements)) { if (@($c.windows.elements).hwnd -contains $Handle) { $where = 'tiled' } }
            if (@($ws.monocle_container.windows.elements).hwnd -contains $Handle) { $where = 'tiled' }
            if ($ws.maximized_window -and $ws.maximized_window.hwnd -eq $Handle) { $where = 'tiled' }
            if (@($ws.floating_windows.elements).hwnd -contains $Handle) { $where = 'floating' }
            if ($where) { return [pscustomobject]@{ Where = $where; Monitor = $mons[$i]; Monitors = $mons; MonitorIndex = $i; WorkspaceIndex = $j } }
        }
    }
    [pscustomobject]@{ Where = 'unmanaged'; Monitor = $null; Monitors = $mons; MonitorIndex = -1; WorkspaceIndex = -1 }
}

# --- A pin --------------------------------------------------------------------------------

if ($Category -eq 'pin') {
    $pin = "$Value -> screen {0}, workspace {1}"
    if ($Value -in 'WindowsTerminal.exe', 'explorer.exe') {   # -in: case-insensitive, as Windows names are
        Write-Log "refused: $Value can't be pinned -- one exe runs every window of its kind, so every one would follow the pin."
        exit 7
    }
    $game = @(Get-GameExes | Where-Object { $_.Exe -ieq $Value } | Select-Object -First 1)
    if ($game.Count) { Write-Log "refused: $Value is a game ($($game[0].In)) -- never tiled, so a pin would do nothing."; exit 8 }

    if ($Hwnd -ne 0) {
        try { $k = Get-KomorebiState } catch { Write-Log "pin: $($_.Exception.Message)"; exit 1 }
        $w = Find-StateWindow $k.State $Hwnd
        if ($w.Where -eq 'unmanaged') { Write-Log "refused: komorebi doesn't manage window $Hwnd ($Value) -- nothing pinned."; exit 6 }
        try {
            . (Join-Path $Root 'tools\lib\monitors.ps1')
            $map = Read-DisplayIndexMap -Path $MapPath
        } catch { Write-Log "refused: the screen map can't be read ($($_.Exception.Message)) -- 710sRice doctor says how to fix it."; exit 9 }
        $n = if ($map) { Get-ScreenNumber -Map $map -Monitor $w.Monitor -All $w.Monitors } else { $null }
        if (-not $n) { Write-Log "refused: the screen window $Hwnd is on has no number in the screen map -- 710sRice doctor says how to fix it."; exit 9 }
        $Screen = $n; $Workspace = $w.WorkspaceIndex + 1
    } elseif ($Screen -lt 1 -or $Workspace -lt 1) {
        Write-Log "refused: a pin needs -Hwnd, or -Screen and -Workspace."
        exit 1
    }
    $pin = $pin -f $Screen, $Workspace

    # A screen / workspace base.json has (the compile would only skip it with a warning).
    try {
        $base = Get-Content $BasePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $mons = @($base.monitors)
        if ($Screen -gt $mons.Count) { Write-Log "refused: $pin -- base.json has $($mons.Count) screens."; exit 1 }
        $wsCount = @($mons[$Screen - 1].workspaces).Count
        if ($Workspace -gt $wsCount) { Write-Log "refused: $pin -- screen $Screen has $wsCount workspaces."; exit 1 }
    } catch { Write-Log "refused: $pin -- couldn't read base.json: $($_.Exception.Message)"; exit 1 }

    $blockLines = @('[[pin]]', "exe = `"$Value`"", "screen = $Screen", "workspace = $Workspace")
    try {
        $f = Read-RulesFile $RulesPath
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($l in (Get-FileLines $f)) { $lines.Add($l) }
        $endsWithNewline = $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq ''
        if ($endsWithNewline) { $lines.RemoveAt($lines.Count - 1) }
        $all = @(Get-RuleBlocks $lines)
        $old = @($all | Where-Object { $_.Section -eq 'pin' -and "$($_.Values['exe'])" -ieq $Value })
        if (-not $old.Count) {
            Add-RuleBlock $blockLines
            Write-Log "pinned: $pin"
            exit 0
        }
        $first = $old[0]
        if ($old.Count -eq 1 -and "$($first.Values['exe'])" -ceq $Value -and $first.Values['screen'] -eq $Screen -and $first.Values['workspace'] -eq $Workspace) {
            Write-Log "already pinned there: $pin -- nothing written."
            exit 3
        }
        $was = "screen $($first.Values['screen']), workspace $($first.Values['workspace'])"
        # One pin per exe: the first block becomes the new pin where it stands (any comment
        # above it stays); any further ones for the same exe -- only a hand edit makes those --
        # go, with the comment lines directly above them, as remove-rule.ps1 cuts.
        # (Never widened into the block before it -- a comment line can end a block.)
        for ($x = $old.Count - 1; $x -ge 1; $x--) {
            $s = $old[$x].Start
            $floor = 1 + (@($all | Where-Object { $_.Start -lt $old[$x].Start } | ForEach-Object { $_.End }) + -1 | Measure-Object -Maximum).Maximum
            while ($s -gt $floor -and $lines[$s - 1].Trim().StartsWith('#')) { $s-- }
            $lines.RemoveRange($s, $old[$x].End - $s + 1)
        }
        $lines.RemoveRange($first.Start, $first.End - $first.Start + 1)
        $lines.InsertRange($first.Start, [string[]]$blockLines)
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($l in $lines) {
            if ($l.Trim() -eq '' -and $out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { continue }
            $out.Add($l)
        }
        while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
        Write-RulesFile $RulesPath (($out -join $f.Nl) + $(if ($endsWithNewline) { $f.Nl } else { '' })) $f.Bom
        Write-Log "pinned: $pin (moved from $was$(if ($old.Count -gt 1) { "; $($old.Count - 1) more pin(s) for it removed" }))"
        exit 0
    } catch {
        Write-Log "couldn't write ${RulesPath}: $($_.Exception.Message)"
        exit 1
    }
}

# --- 1. Duplicate check -------------------------------------------------------------------
$duplicateIn = $null
foreach ($path in @($RulesPath, $ShippedPath)) {
    if ($duplicateIn) { break }
    foreach ($b in (Get-RuleBlocks (Get-FileLines (Read-RulesFile $path)))) {
        if ($b.Section -eq $Category -and $b.Values.Contains($Field) -and "$($b.Values[$Field])" -ceq $Value) { $duplicateIn = Split-Path $path -Leaf; break }
    }
}
if (-not $duplicateIn -and $Category -eq 'game') {
    $g = @(Get-GameExes | Where-Object { $_.Exe -ceq $Value } | Select-Object -First 1)
    if ($g.Count) { $duplicateIn = $g[0].In }
}

# --- 2. Append --------------------------------------------------------------------------
if ($duplicateIn) {
    $what = if ($Category -eq 'game') { "already a game ($duplicateIn)" } else { "already there ($duplicateIn)" }
    Write-Log "${what}: [[$Category]] $Field = `"$Value`" -- nothing written."
} else {
    try {
        Add-RuleBlock @("[[$Category]]", "$Field = `"$Value`"")
        Write-Log "added: [[$Category]] $Field = `"$Value`""
    } catch {
        Write-Log "couldn't write ${RulesPath}: $($_.Exception.Message)"
        exit 1
    }
}

# --- 3. Apply now to the (already focused) window ----------------------------------------
$applyFailed = $false
if ($Hwnd -ne 0 -and $Category -notin 'floating', 'ignore', 'manage', 'game') {
    Write-Log "no apply-now for [[$Category]] -- $(if ($Category -eq 'layered') { 'relaunch the app to tile it' } else { 'takes effect the next time the window is focused' })."
} elseif ($Hwnd -ne 0) {
    try {
        $k = Get-KomorebiState
        $where = (Find-StateWindow $k.State $Hwnd).Where

        $cmd = switch ($Category) {
            'floating' { if ($where -eq 'tiled') { 'toggle-float' } }
            # A game is never tiled -- the same as ignore, here.
            { $_ -in 'ignore', 'game' } { if ($where -ne 'unmanaged') { 'unmanage' } }
            # A floating window is already managed -- `manage` wouldn't tile it, toggle-float does.
            'manage'   { if ($where -eq 'unmanaged') { 'manage' } elseif ($where -eq 'floating') { 'toggle-float' } }
            # layered / transparency_ignore: no apply-now (see the header) -- $null here.
        }
        if ($cmd) {
            $out = & $k.Komorebic $cmd 2>&1
            if ($LASTEXITCODE -ne 0) { throw "komorebic $cmd failed ($LASTEXITCODE): $out" }
            Write-Log "applied now: window $Hwnd was $where -> komorebic $cmd"
        } else {
            Write-Log "applied now: window $Hwnd already $where -- nothing to change for [[$Category]]."
        }
    } catch {
        Write-Log "apply-now failed for window ${Hwnd}: $($_.Exception.Message)"
        $applyFailed = $true
    }
}

if ($duplicateIn) { exit 3 }
if ($applyFailed) { exit 2 }
exit 0
