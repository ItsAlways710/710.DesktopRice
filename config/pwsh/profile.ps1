# managed profile for 710.DesktopRice (PowerShell 7).
# DO NOT hand-edit: user customization goes in user.ps1 (same folder, gitignored), which
# is dot-sourced last and can redefine anything here.
# Every init is behind a guard: no binary means no error, just a skipped piece. This file
# must NEVER throw -- a broken $PROFILE blocks every new shell.
#
# Ported from winarchy's config/pwsh/profile.ps1 @ 4574fc7 (tag v1.4.0), essentially as-is
# -- see claude/winarchy-decoupling-plan.md for what changed (paths only: this repo's own
# state\pwsh-init cache dir and starship.toml, both relative to this file same as upstream).

if ($env:NO_COLOR -eq '') {
    Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue
    if ($PSStyle.OutputRendering -eq 'PlainText') { $PSStyle.OutputRendering = 'Host' }
}

# --- PSReadLine: fish-style predictions -------------------------------------------
if (Get-Module PSReadLine) {
    try {
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle ListView -ErrorAction Stop
    }
    catch {
        try { Set-PSReadLineOption -PredictionSource History } catch { }
    }
    try {
        Set-PSReadLineOption -HistorySearchCursorMovesToEnd
        Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
        Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    }
    catch { }
}

# --- Modern aliases: eza / bat -----------------------------------------------------
if (Get-Command eza -CommandType Application -ErrorAction SilentlyContinue) {
    function ls { eza --group-directories-first --icons @args }
    function ll { eza -l --group-directories-first --icons --git @args }
    function la { eza -la --group-directories-first --icons --git @args }
    function lt { eza --tree --level=2 --icons @args }
}
if (Get-Command bat -CommandType Application -ErrorAction SilentlyContinue) {
    Set-Alias -Name cat -Value bat -Option AllScope -Force
}

# zoxide/starship init scripts are static per binary version: cache them in
# state\pwsh-init\ to avoid paying the binary's spawn cost on every single shell. Returns
# the cached script's path -- caller must dot-source it in the profile's own scope
# (calling it from inside a function would lose the init's definitions).
function script:Get-ToolInit {
    param([string]$Tool, [string[]]$InitArgs)
    # there can be more than one install (choco/scoop/winget): take the first
    $exe = Get-Command $Tool -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $exe) { return $null }
    try {
        $cacheDir = Join-Path $PSScriptRoot '..\..\state\pwsh-init'
        $cache = Join-Path $cacheDir "$Tool.ps1"
        $stale = -not (Test-Path $cache) -or
            ((Get-Item $cache).LastWriteTimeUtc -lt (Get-Item $exe.Source).LastWriteTimeUtc)
        if ($stale) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
            & $exe.Source @InitArgs | Set-Content -Path $cache -Encoding utf8NoBOM
        }
        return $cache
    }
    catch { return $null }
}

# --- zoxide: smart cd (z / zi) ------------------------------------------------------
$710Init = Get-ToolInit -Tool zoxide -InitArgs @('init', 'powershell')
if ($710Init) { try { . $710Init } catch { } }

# --- PSFzf: Ctrl+R fuzzy history, Ctrl+T files --------------------------------------
# Lazy: importing PSFzf costs ~300ms, so it's deferred to the first Ctrl+R/Ctrl+T.
if (Get-Command fzf -CommandType Application -ErrorAction SilentlyContinue) {
    try {
        Set-PSReadLineKeyHandler -Key 'Ctrl+r' -ScriptBlock {
            if (-not (Get-Module PSFzf)) { Import-Module PSFzf -ErrorAction Stop }
            Invoke-FzfPsReadlineHandlerHistory
        }
        Set-PSReadLineKeyHandler -Key 'Ctrl+t' -ScriptBlock {
            if (-not (Get-Module PSFzf)) { Import-Module PSFzf -ErrorAction Stop }
            Invoke-FzfPsReadlineHandlerProvider
        }
    }
    catch { }
}

# --- starship: themed prompt (last, so nothing else overrides it) -------------------
# starship.toml is wallust-generated (see config/wallust/wallust.toml's [templates] and
# tools/apply-wallust-outputs.ps1) -- absent until wallust has run at least once, in which
# case starship just falls back to its own built-in defaults. Same "safe to be missing"
# posture as config/komorebi/display-index.local.json elsewhere in this repo.
$env:STARSHIP_CONFIG = Join-Path $PSScriptRoot 'starship.toml'
$710Init = Get-ToolInit -Tool starship -InitArgs @('init', 'powershell', '--print-full-init')
if ($710Init) { try { . $710Init } catch { } }

# --- User override (can redefine everything above) -----------------------------------
$710UserProfile = Join-Path $PSScriptRoot 'user.ps1'
if (Test-Path $710UserProfile) {
    try { . $710UserProfile } catch { Write-Warning "710.DesktopRice user.ps1: $($_.Exception.Message)" }
}
