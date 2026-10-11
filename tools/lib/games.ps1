<#
.SYNOPSIS
  The games, as game mode counts them: every exe = "..." line of games.toml, less the ones you
  turned off (an [[off]] of a game's ignore rule -- Tiling > Turn off a shipped rule...,
  tools\lib\rules-off.ps1), plus the [[game]] blocks of your rules.local.toml. 710.ahk's
  LoadGames (config\ahk\710\game-mode.ahk) reads the same files the same way, in AutoHotkey.
  scripts\Start-Komorebi.ps1 dot-sources this under Windows PowerShell 5.1, so it stays
  5.1-safe: no ?., no ternary. Only functions.
#>

function Get-RiceGameExes {
    # The games' exes, each once (case aside). Wrap the call in @() for an array of one or none.
    param([Parameter(Mandatory)][string]$Root)
    $gamesToml  = Join-Path $Root 'games.toml'
    $localRules = Join-Path $Root 'config\komorebi\rules.local.toml'
    $off = @(); $yours = @()
    if (Test-Path -LiteralPath $localRules) {
        $section = ''
        foreach ($line in Get-Content -LiteralPath $localRules -Encoding UTF8) {
            $t = $line.Trim()
            if ($t -match '^\[\[(\w+)\]\]$') { $section = $Matches[1] }
            elseif ($section -eq 'game' -and $t -match '^exe\s*=\s*"([^"]+)"$') { $yours += $Matches[1] }
            elseif ($section -eq 'off' -and $t -match '^ignore\s*=\s*"exe=(.+)/equals"$') { $off += $Matches[1] }
        }
    }
    $shipped = @()
    if (Test-Path -LiteralPath $gamesToml) {
        foreach ($line in Get-Content -LiteralPath $gamesToml -Encoding UTF8) {
            # -notcontains ignores case: an [[off]] key is written in lower case.
            if ($line -match '^\s*exe\s*=\s*"([^"]+)"' -and $off -notcontains $Matches[1]) { $shipped += $Matches[1] }
        }
    }
    @($shipped) + @($yours) | Sort-Object -Unique
}
