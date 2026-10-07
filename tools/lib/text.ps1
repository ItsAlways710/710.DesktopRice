<#
.SYNOPSIS
  How 710sRice prints paths and names: never a Windows user name (the repo is public, and output
  gets pasted into issues), and lists of names in plain English. Loaded by tools\lib\activation.ps1.
  Only functions.
#>

function ConvertTo-SafePath {
    # A path as it can be shown on screen: the user's own profile folders as %LOCALAPPDATA% /
    # %APPDATA% / %USERPROFILE%, never the Windows user name. The repo is public and output
    # gets pasted into issues -- install's and uninstall's lines, doctor's report, repair's
    # (which shows install's). Anything outside those folders comes back as it was.
    param([string]$Path)
    $out = "$Path"
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
        $dir = [Environment]::GetEnvironmentVariable($v)
        if ($dir -and $out.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { return "%$v%$($out.Substring($dir.Length))" }
    }
    $out
}

function ConvertTo-SafeText {
    # ConvertTo-SafePath for a whole message rather than one path: the user's profile folders
    # ANYWHERE in $Text become %LOCALAPPDATA% / %APPDATA% / %USERPROFILE%, written with either
    # slash -- git's messages use C:/Users/<name>/... ("detected dubious ownership in repository
    # at '...'"). The longer folders go first, so %LOCALAPPDATA% wins over %USERPROFILE%; a folder
    # only matches as a whole (C:\Users\bob never eats part of C:\Users\bobby).
    param([string]$Text)
    $out = "$Text"
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
        $dir = [Environment]::GetEnvironmentVariable($v)
        if (-not $dir) { continue }
        $dir = $dir.TrimEnd('\', '/')
        foreach ($form in @($dir, ($dir -replace '\\', '/')) | Select-Object -Unique) {
            $out = [regex]::Replace($out, "$([regex]::Escape($form))(?=[\\/'`"\s:;,)]|$)", "%$v%",
                                    [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }
    $out
}

function Join-RiceNameList {
    # 'a', 'a and b', 'a, b and c'.
    param([string[]]$Names)
    $n = @($Names | Where-Object { $_ })
    if ($n.Count -le 1) { return "$($n -join '')" }
    "$(@($n | Select-Object -SkipLast 1) -join ', ') and $($n[-1])"
}
