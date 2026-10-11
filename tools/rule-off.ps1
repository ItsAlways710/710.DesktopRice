#Requires -Version 7.0
<#
.SYNOPSIS
  Turn off a shipped rule on this machine: the engine behind 710.ahk's "Turn off a shipped
  rule..." (Tiling menu). Lists the shipped rules that match a window, and turns one off with an
  [[off]] block in YOUR rules file, config\komorebi\rules.local.toml (tools\lib\rules-off.ps1 has
  the format). Usable by hand too.

.DESCRIPTION
  -List: the shipped rules -- vendor\asc, games.toml, rules.toml -- that komorebi would match to
  the window in $env:RULEOFF_EXE / RULEOFF_CLASS / RULEOFF_TITLE / RULEOFF_PATH, from what the
  compiler last saw (shipped-rules.json; tools\lib\rules-off.ps1). When that's missing or older
  than one of those three files, the compiler runs first in -Check mode, which writes nothing
  else: no komorebi.json, no reload. One your rules.local.toml has turned off -- read now, not
  from the compile -- isn't listed. Written to
  %LOCALAPPDATA%\710.DesktopRice\rule-off.tsv, one rule a line, five tab-separated fields: its
  section, its key (the [[off]] block's two halves), its name in the menu (Ignore, Game, ...),
  its conditions as the menu shows them, and where it comes from.

  -Add: turns off the rule $env:RULEOFF_SECTION / $env:RULEOFF_KEY name, appending
      # Turned off <date>: <$env:RULEOFF_NOTE>
      [[off]]
      <section> = "<key>"
  to rules.local.toml -- creating it with its header first if needed. Every write keeps the
  file's own line endings and its BOM (add-rule.ps1's way). Values ride in the environment,
  never on a command line: window titles can hold anything.

  Doesn't reload anything: the caller runs SUPER+Shift+R's reload-stack.ps1, which sees a rule
  went out of komorebi.json and restarts komorebi -- the only way to drop a live rule.

  Exit codes: -List: 0 = listed (at least one); 4 = no shipped rule matches that window.
  -Add: 0 = turned off; 3 = already off. Both: 1 = nothing done (bad input, the compiler
  failed, unwritable file, ...). Messages go to %LOCALAPPDATA%\710.DesktopRice\rule-off.log.
#>
[CmdletBinding()]
param([switch]$List, [switch]$Add)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\rules-off.ps1')
$RulesPath = Join-Path $Root 'config\komorebi\rules.local.toml'

$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'rule-off.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# Log cap: past 1 MB this log becomes <name>.old (replacing the previous one) and a fresh one
# starts -- the same rule in every 710.DesktopRice log writer.
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }
function Write-Log([string]$m) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Out-File -FilePath $log -Append -Encoding utf8
}

if ($List -eq $Add) { Write-Log 'refused: give -List or -Add.'; exit 1 }

# --- How a rule reads in the menu -------------------------------------------------------------
function Get-RuleName($Rule) {
    # The menu's name for what a rule does -- Quick add's words where it has them. A games.toml
    # ignore rule is a game: game mode counts it too.
    if ($Rule.section -eq 'ignore' -and @($Rule.sources) -contains 'games.toml') { return 'Game' }
    switch ($Rule.section) {
        'ignore'                { 'Ignore' }
        'manage'                { 'Manage' }
        'floating'              { 'Float' }
        'layered'               { 'Layered' }
        'transparency_ignore'   { 'Opaque' }
        'tray_and_multi_window' { 'Tray app' }
        'object_name_change'    { 'Name change' }
        'slow_application'      { 'Slow app' }
        default                 { $Rule.section }
    }
}

function Get-ConditionText($Condition) {
    # exe = steam.exe, title ≠ Steam, class starts with Foo, ...
    $k = "$($Condition.kind)".ToLowerInvariant()
    $op = switch ("$($Condition.strategy)") {
        'Equals'           { '=' }
        'DoesNotEqual'     { [string][char]0x2260 }
        'StartsWith'       { 'starts with' }
        'DoesNotStartWith' { "doesn't start with" }
        'EndsWith'         { 'ends with' }
        'DoesNotEndWith'   { "doesn't end with" }
        'Contains'         { 'contains' }
        'DoesNotContain'   { "doesn't contain" }
        'Regex'            { 'matches' }
        default            { if ($k -in 'title', 'class') { 'starts or ends with' } else { '=' } }
    }
    "$k $op $($Condition.id)"
}

function Get-SourceText($Rule) {
    # Where it comes from: ASC: <app>, games.toml, rules.toml.
    (@($Rule.sources) | ForEach-Object {
        if ($_ -like 'asc:*') { 'ASC: ' + $_.Substring(4) } elseif ($_ -like 'user:*') { $_.Substring(5) } else { $_ }
    }) -join ', '
}

# --- -List ------------------------------------------------------------------------------------
if ($List) {
    $window = [pscustomobject]@{ Exe = $env:RULEOFF_EXE; Class = $env:RULEOFF_CLASS; Title = $env:RULEOFF_TITLE; Path = $env:RULEOFF_PATH }
    if ([string]::IsNullOrEmpty($window.Exe)) { Write-Log 'refused: no window (RULEOFF_EXE is empty).'; exit 1 }
    $cache = Get-RiceShippedRulesPath
    $sources = @('vendor\asc\applications.json', 'games.toml', 'config\komorebi\rules.toml') |
        ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path -LiteralPath $_ }
    $stale = -not (Test-Path -LiteralPath $cache)
    if (-not $stale) {
        $seen = (Get-Item -LiteralPath $cache).LastWriteTimeUtc
        $stale = [bool]@($sources | Where-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc -gt $seen }).Count
    }
    if ($stale) {
        # -Check: komorebi.json is only compared, never written; RICE_WRITE_SHIPPED_RULES lets
        # this one run write the menu's file all the same.
        $env:RICE_WRITE_SHIPPED_RULES = '1'
        try { $null = & (Join-Path $PSScriptRoot 'compile-komorebi-rules.ps1') -Check *>&1 }
        catch { Write-Log "the compiler failed: $($_.Exception.Message)" }
        finally { Remove-Item Env:RICE_WRITE_SHIPPED_RULES -ErrorAction SilentlyContinue }
    }
    if (-not (Test-Path -LiteralPath $cache)) { Write-Log "no shipped rules to list ($cache is missing)."; exit 1 }
    $rules = @(Get-Content -LiteralPath $cache -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
    $off = @(Read-RiceOffRules -Path $RulesPath | ForEach-Object { "$($_.Section)|$($_.Key)".ToLowerInvariant() })
    $hits = @($rules | Where-Object { $off -notcontains "$($_.section)|$($_.key)" -and (Test-RiceRuleMatchesWindow -Rule $_ -Window $window) })
    $out = Join-Path $logDir 'rule-off.tsv'
    $lines = foreach ($r in $hits) {
        (@($r.section, $r.key, (Get-RuleName $r), ((@($r.conditions) | ForEach-Object { Get-ConditionText $_ }) -join ' & '), (Get-SourceText $r)) |
            ForEach-Object { "$_" -replace '[\t\r\n]', ' ' }) -join "`t"
    }
    [IO.File]::WriteAllLines($out, [string[]]@($lines), [Text.UTF8Encoding]::new($false))
    Write-Log "listed $($hits.Count) shipped rule(s) for $($window.Exe) (of $($rules.Count) shipped)."
    exit $(if ($hits.Count) { 0 } else { 4 })
}

# --- -Add -------------------------------------------------------------------------------------
$section = "$env:RULEOFF_SECTION"; $key = "$env:RULEOFF_KEY"; $note = "$env:RULEOFF_NOTE"
if ($section -notmatch '^\w+$' -or [string]::IsNullOrWhiteSpace($key)) { Write-Log "refused: bad rule ($section / $key)."; exit 1 }
if ($key -match '["\r\n]') { Write-Log "refused: the rule's key holds a double quote or a line break, which rules.local.toml can't hold: $key"; exit 1 }
$note = $note -replace '[\r\n]', ' '
if (@(Read-RiceOffRules -Path $RulesPath | Where-Object { $_.Section -eq $section -and $_.Key -eq $key }).Count) {
    Write-Log "already off: [[off]] $section = `"$key`"."
    exit 3
}
$block = @("# Turned off $(Get-Date -Format 'yyyy-MM-dd'): $note", '[[off]]', "$section = `"$key`"")
try {
    if (Test-Path -LiteralPath $RulesPath) {
        # The file's own newline and BOM; a blank line between blocks, never glued onto a last
        # line missing its newline.
        $bytes = [IO.File]::ReadAllBytes($RulesPath)
        $text = [Text.UTF8Encoding]::new($false).GetString($bytes)
        $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lead = if (-not $text.TrimStart([char]0xFEFF)) { '' } elseif ($text.EndsWith("`n")) { $nl } else { $nl + $nl }
        [IO.File]::AppendAllText($RulesPath, $lead + ($block -join $nl) + $nl, [Text.UTF8Encoding]::new($false))
    } else {
        # Same text as add-rule.ps1 and 710.ahk's EditMyRules() write -- keep the three in step.
        $header = "# Your own komorebi rules -- this machine only (gitignored), the highest-priority`n" +
                  "# layer: above rules.toml (the rules this repo ships), games.toml and the vendored`n" +
                  "# community ASC rules. Quick add rule writes here; compiled into komorebi.json by`n" +
                  "# tools\compile-komorebi-rules.ps1 (SUPER+Shift+R). Sections: [[floating]], [[ignore]],`n" +
                  "# [[manage]], [[layered]], [[transparency_ignore]], ... with one of exe / class /`n" +
                  "# title per entry; [[game]] with an exe; [[pin]] with an exe, screen = N, workspace = N.`n" +
                  "# Want a rule on every machine? Move it into rules.toml (a game: games.toml) and commit.`n`n"
        [IO.File]::WriteAllText($RulesPath, $header + ($block -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        Write-Log "created $RulesPath"
    }
} catch {
    Write-Log "couldn't write ${RulesPath}: $($_.Exception.Message)"
    exit 1
}
Write-Log "turned off: [[off]] $section = `"$key`" ($note)."
exit 0
