<#
.SYNOPSIS
  versions.md's table -- the one list of what 710sRice installs and at which version -- and the two
  questions asked of a row: does winget install it (Test-WingetRow), is it pinned (Test-PinnedRow).
  Loaded by tools\lib\activation.ps1; tools\install-wallust.ps1 loads it on its own (it stands
  alone). Only functions.

.DESCRIPTION
  versions.md is the one list of what this repo installs and at which version
  (claude/cli-plan.md, Stage 2 -- "pins in one place"). Everything reads that table; nothing
  keeps a second copy of a pin. A pin bump is one line in versions.md.
#>

function Get-VersionsTable {
    # Hand-rolled parser for versions.md's one real table -- not a general Markdown
    # parser, scoped to exactly that file's fixed column layout (see versions.md's own
    # "table format is load-bearing" note: Component | Version | Source | Install ID |
    # Pre-existing? | Last touched). Returns an array of @{ Component; Version; Source;
    # InstallId; Keep; PreExisting; System; LastTouched }. Moved here from uninstall.ps1
    # (2026-09-26).
    #
    # Pre-existing? is read explicitly (Group 1, W9 -- 2026-09-30): Keep is exactly one of
    #   no      removed by a plain uninstall (unless -Keep <id>)
    #   yes     kept by a plain uninstall, removed by -Force
    #   system  installed if missing, NEVER removed by uninstall, -Force included (PowerShell 7,
    #           which uninstall itself runs on, and Windows Terminal, part of Windows 11)
    # and anything else THROWS, naming the row: a typo must never read as "no" -- which is what
    # the old `-match '^\s*yes'` made of it, i.e. "remove it". PreExisting ($true for yes and
    # system) and System are there for the callers that only ask "protected?" / "never?".
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    $inTable = $false
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('|')) { $inTable = $false; continue }
        $cells = @($trimmed.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells[0] -eq 'Component') { $inTable = $true; continue }   # header row
        if ($cells[0] -match '^-+$') { continue }                       # separator row
        if (-not $inTable) { continue }
        if ($cells.Count -lt 6) { continue }
        $keep = $cells[4].ToLowerInvariant()
        if ($keep -notin 'no', 'yes', 'system') {
            throw "versions.md: $($cells[0])'s Pre-existing? is '$($cells[4])' -- it has to be yes, no or system (nothing was changed)"
        }
        $rows.Add([pscustomobject]@{
            Component   = $cells[0]
            Version     = $cells[1]
            Source      = $cells[2]
            InstallId   = $cells[3]
            Keep        = $keep
            PreExisting = ($keep -ne 'no')
            System      = ($keep -eq 'system')
            LastTouched = $cells[5]
        })
    }
    return @($rows)
}

function Test-WingetRow {
    # A row winget installs: Source `winget`, or `msstore` (winget, from the Microsoft Store
    # source -- PowerShell 7, whose Store/MSIX build isn't in winget's default source).
    param($Row)
    $Row.Source -in 'winget', 'msstore'
}

function Test-PinnedRow {
    # A pin: any Version but `latest`. Installed at exactly that version and winget-pinned,
    # so a general `winget upgrade --all` elsewhere can't move it off what was tested here.
    param($Row)
    [bool]$Row.Version -and $Row.Version -ne 'latest'
}
