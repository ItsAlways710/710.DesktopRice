#Requires -Version 7.0
<#
.SYNOPSIS
  Remove one rule from YOUR rules file, config\komorebi\rules.local.toml. The engine
  behind 710.ahk's "Remove a rule..." (Tiling menu); usable by hand too. add-rule.ps1's
  counterpart.

.DESCRIPTION
  Cuts exactly one [[section]] block -- the one whose section is -Category and which has
  the line  <Field> = "<Value>"  -- together with any comment lines directly touching it
  from above (they describe that rule; the rule goes, so do they). The file's own header
  is safe as long as a blank line follows it, which is how add-rule.ps1 and 710.ahk write
  it. Leftover runs of blank lines are collapsed to one. Everything else in the file is
  left byte-for-byte as it was.

  Refuses -- and changes nothing -- if no block matches, or more than one does. Only ever
  touches rules.local.toml: the rules this repo ships (rules.toml) aren't removable here
  (plan doc Open item 38; edit and commit rules.toml for those).

  Doesn't reload anything itself -- the caller runs SUPER+Shift+R's reload-stack.ps1, which
  sees a rule was REMOVED and restarts komorebi (its hot reload can only add rules), so
  every open window gets checked again straight away.

  Same line grammar compile-komorebi-rules.ps1 reads: `key = "value"`, value taken raw.
  The value comes from -Value, or from $env:REMOVERULE_VALUE when -Value isn't given -- so
  AHK never has to quote an arbitrary window title onto a command line.

  Exit codes: 0 = removed; 4 = no such rule; 5 = more than one match (nothing removed);
  1 = nothing done (bad input, no file, unwritable, ...). Messages go to
  %LOCALAPPDATA%\710.DesktopRice\remove-rule.log.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\w+$')][string]$Category,
    [Parameter(Mandatory)][ValidateSet('exe', 'class', 'title')][string]$Field,
    [string]$Value
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$RulesPath = Join-Path $Root 'config\komorebi\rules.local.toml'

$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'remove-rule.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# Log cap: past 1 MB this log becomes <name>.old (replacing the previous one) and a fresh
# one starts -- so at most ~2 MB, and the last chunk of history is always kept. Same rule
# in every 710.DesktopRice log writer (plan doc, open item 20).
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }
function Write-Log([string]$m) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Out-File -FilePath $log -Append -Encoding utf8
}

if (-not $PSBoundParameters.ContainsKey('Value')) { $Value = $env:REMOVERULE_VALUE }
if ([string]::IsNullOrEmpty($Value)) { Write-Log "refused: empty $Field value."; exit 1 }
if (-not (Test-Path $RulesPath)) { Write-Log "refused: $RulesPath doesn't exist -- nothing to remove."; exit 1 }

$text = [System.IO.File]::ReadAllText($RulesPath)
$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = [System.Collections.Generic.List[string]]::new([string[]]($text -split '\r?\n'))
# A trailing newline leaves one empty string at the end of the split -- set it aside so it
# can't count as a blank line between blocks, and put it back on write.
$endsWithNewline = $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq ''
if ($endsWithNewline) { $lines.RemoveAt($lines.Count - 1) }

# --- 1. Find the matching block(s) ------------------------------------------------------
# A block = its [[section]] line + the lines after it, up to the next blank line or the
# next [[section]]. Comment lines inside a block don't end it.
# (Not named $matches: PowerShell variables are case-insensitive, so that IS $Matches,
# which every -match below overwrites -- the same shadowing trap the plan doc's gotchas
# list for compile-komorebi-rules.ps1.)
$found = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if (-not ($lines[$i].Trim() -match '^\[\[(\w+)\]\]$')) { continue }
    $section = $Matches[1]
    $end = $i
    $hit = $false
    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
        $l = $lines[$j].Trim()
        if ($l -eq '' -or $l -match '^\[\[\w+\]\]$') { break }
        $end = $j
        if ($section -eq $Category -and $l -match '^(\w+)\s*=\s*"([^"]*)"$' -and
            $Matches[1] -eq $Field -and $Matches[2] -ceq $Value) { $hit = $true }
    }
    if ($hit) { $found.Add([pscustomobject]@{ Start = $i; End = $end }) }
}
if ($found.Count -eq 0) { Write-Log "not found: [[$Category]] $Field = `"$Value`" -- nothing removed."; exit 4 }
if ($found.Count -gt 1) { Write-Log "ambiguous: $($found.Count) blocks match [[$Category]] $Field = `"$Value`" -- nothing removed."; exit 5 }

# --- 2. Widen to the comment lines directly above it, then cut --------------------------
$start = $found[0].Start
while ($start -gt 0 -and $lines[$start - 1].Trim().StartsWith('#')) { $start-- }
$count = $found[0].End - $start + 1
$lines.RemoveRange($start, $count)

# --- 3. Collapse blank-line runs to one, no blank lines at the very end -----------------
$out = [System.Collections.Generic.List[string]]::new()
foreach ($l in $lines) {
    if ($l.Trim() -eq '' -and $out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { continue }
    $out.Add($l)
}
while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }

try {
    $newText = ($out -join $nl) + $(if ($out.Count -gt 0 -and $endsWithNewline) { $nl } else { '' })
    [System.IO.File]::WriteAllText($RulesPath, $newText, [System.Text.UTF8Encoding]::new($false))
} catch {
    Write-Log "couldn't write ${RulesPath}: $($_.Exception.Message)"
    exit 1
}
Write-Log "removed: [[$Category]] $Field = `"$Value`" ($count line(s), incl. any comments directly above it)."
exit 0
