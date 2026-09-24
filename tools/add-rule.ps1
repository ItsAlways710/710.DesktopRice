#Requires -Version 7.0
<#
.SYNOPSIS
  Append a floating / ignore / manage rule to config\komorebi\rules.toml, and optionally
  apply it to one live window right now. The engine behind 710.ahk's "Quick add rule..."
  (Tiling menu); usable by hand too.

.DESCRIPTION
  Ported from winarchy's Add-WinarchyUserRule (module/Winarchy/Private/AppRules.ps1):
  validates the input, creates rules.toml if it doesn't exist yet, skips an exact
  duplicate, appends the entry. Unlike winarchy's, it doesn't recompile/reload itself --
  the caller runs SUPER+Shift+R's reload-stack.ps1 afterwards, which already knows how to
  get komorebi to pick a rule up without losing your layouts (additions take komorebi's
  fast hot-reload path).

  Written for compile-komorebi-rules.ps1's own rules.toml reader, which is a deliberate
  subset of TOML: `key = "value"` with the value taken RAW -- no escape sequences, so a
  backslash (window titles with paths in them) is written as-is, and a value containing a
  double quote can't be represented at all. That case is refused (exit 1) rather than
  written in a form compile would silently skip.

  -Hwnd (optional): also make the rule true for that window now, since komorebi only
  applies rules to windows that open after them. The caller must have FOCUSED that window
  first -- komorebic's toggle-float / manage / unmanage all act on the focused window.
  Looks the window up in `komorebic state` so each command only runs when it would
  change something (toggle-float on an already-floating window would tile it instead).

  The value comes from -Value, or from $env:QUICKADD_VALUE when -Value isn't given -- so
  AHK never has to quote an arbitrary window title onto a command line.

  Exit codes: 0 = rule added; 3 = identical rule already in rules.toml (nothing written,
  apply-now still ran); 2 = rule added but apply-now failed; 1 = nothing done (bad input,
  unwritable file, ...). Messages go to %LOCALAPPDATA%\710.DesktopRice\add-rule.log.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('floating', 'ignore', 'manage')][string]$Category,
    [Parameter(Mandatory)][ValidateSet('exe', 'class', 'title')][string]$Field,
    [string]$Value,
    [long]$Hwnd = 0
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$RulesPath = Join-Path $Root 'config\komorebi\rules.toml'

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
    Write-Log "refused: $Field value contains a double quote, which rules.toml's reader can't represent: $Value"
    exit 1
}
if ($Value -match '[\r\n]') { Write-Log "refused: $Field value spans lines: $Value"; exit 1 }

# --- 1. Duplicate check, with the same line grammar compile-komorebi-rules.ps1 reads ------
$duplicate = $false
if (Test-Path $RulesPath) {
    $section = $null
    foreach ($raw in Get-Content $RulesPath -Encoding UTF8) {
        $line = $raw.Trim()
        if ($line -match '^\[\[(\w+)\]\]$') { $section = $Matches[1]; continue }
        if ($section -eq $Category -and $line -match '^(\w+)\s*=\s*"([^"]*)"$' -and
            $Matches[1] -eq $Field -and $Matches[2] -ceq $Value) { $duplicate = $true; break }
    }
}

# --- 2. Append --------------------------------------------------------------------------
if ($duplicate) {
    Write-Log "already there: [[$Category]] $Field = `"$Value`" -- nothing written."
} else {
    try {
        $block = "[[$Category]]`n$Field = `"$Value`"`n"
        if (Test-Path $RulesPath) {
            # Blank line between entries; don't glue onto a last line missing its newline.
            $existing = Get-Content $RulesPath -Raw -Encoding UTF8
            $lead = if (-not $existing) { '' } elseif ($existing.EndsWith("`n")) { "`n" } else { "`n`n" }
            [System.IO.File]::AppendAllText($RulesPath, $lead + $block, [System.Text.UTF8Encoding]::new($false))
        } else {
            $header = "# Your own komorebi rule overrides -- highest priority layer, above games.toml and`n" +
                      "# the vendored community ASC rules. Compiled into komorebi.json by`n" +
                      "# tools\compile-komorebi-rules.ps1 (run by SUPER+Shift+R). Tracked in git on`n" +
                      "# purpose, so rules follow you to every machine. Sections: [[floating]],`n" +
                      "# [[ignore]], [[manage]], ... with one of exe / class / title per entry.`n`n"
            [System.IO.File]::WriteAllText($RulesPath, $header + $block, [System.Text.UTF8Encoding]::new($false))
            Write-Log "created $RulesPath"
        }
        Write-Log "added: [[$Category]] $Field = `"$Value`""
    } catch {
        Write-Log "couldn't write ${RulesPath}: $($_.Exception.Message)"
        exit 1
    }
}

# --- 3. Apply now to the (already focused) window ----------------------------------------
$applyFailed = $false
if ($Hwnd -ne 0) {
    try {
        $komorebic = Join-Path $env:ProgramFiles 'komorebi\bin\komorebic.exe'
        if (-not (Test-Path $komorebic)) { $komorebic = (Get-Command komorebic -ErrorAction Stop).Source }
        $raw = & $komorebic state 2>&1
        if ($LASTEXITCODE -ne 0) { throw "komorebic state failed ($LASTEXITCODE) -- is komorebi running?" }
        $st = ($raw -join "`n") | ConvertFrom-Json

        # Where is this window as far as komorebi is concerned?
        $where = 'unmanaged'
        foreach ($m in @($st.monitors.elements)) {
            foreach ($ws in @($m.workspaces.elements)) {
                foreach ($c in @($ws.containers.elements)) {
                    if (@($c.windows.elements).hwnd -contains $Hwnd) { $where = 'tiled' }
                }
                if (@($ws.monocle_container.windows.elements).hwnd -contains $Hwnd) { $where = 'tiled' }
                if ($ws.maximized_window -and $ws.maximized_window.hwnd -eq $Hwnd) { $where = 'tiled' }
                if (@($ws.floating_windows.elements).hwnd -contains $Hwnd) { $where = 'floating' }
            }
        }

        $cmd = switch ($Category) {
            'floating' { if ($where -eq 'tiled') { 'toggle-float' } }
            'ignore'   { if ($where -ne 'unmanaged') { 'unmanage' } }
            # A floating window is already managed -- `manage` wouldn't tile it, toggle-float does.
            'manage'   { if ($where -eq 'unmanaged') { 'manage' } elseif ($where -eq 'floating') { 'toggle-float' } }
        }
        if ($cmd) {
            $out = & $komorebic $cmd 2>&1
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

if ($duplicate) { exit 3 }
if ($applyFailed) { exit 2 }
exit 0
