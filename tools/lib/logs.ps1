<#
.SYNOPSIS
  `710sRice logs`: the logs folder -- its path and its logs listed here, newest first, and the
  folder opened in Explorer. Dot-sourced by 710sRice.ps1's logs row, and only there: it uses the
  dispatcher's own Write-RiceError and $script:RiceExit. Only functions.
#>

function Show-RiceLogs {
    # The folder every 710.DesktopRice log lives in: its path and logs here, newest first (which
    # one just moved), and the folder in Explorer. From an admin window Explorer hands the
    # folder to your running (normal) shell, so that window isn't elevated. The path is shown
    # as %LOCALAPPDATA%\..., never expanded: that carries the Windows user name.
    $dir   = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
    $shown = '%LOCALAPPDATA%\710.DesktopRice'
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-RiceError "Nothing logged yet -- $shown doesn't exist"
        $script:RiceExit = 1
        return
    }
    Write-Host ''
    Write-Host "  $shown"
    $logs = @(Get-ChildItem -LiteralPath $dir -File |
              Where-Object { $_.Name -like '*.log' -or $_.Name -like '*.log.old' } |
              Sort-Object LastWriteTime -Descending)
    foreach ($f in $logs) {
        $size = if ($f.Length -ge 1MB) { '{0:N1} MB' -f ($f.Length / 1MB) }
                elseif ($f.Length -ge 1KB) { '{0:N0} KB' -f ($f.Length / 1KB) }
                else { "$($f.Length) B" }
        Write-Host ('    {0,-28}{1,9}   {2:yyyy-MM-dd HH:mm:ss}' -f $f.Name, $size, $f.LastWriteTime)
    }
    if (-not $logs.Count) { Write-Host '    (no .log files yet)' }
    Write-Host ''
    Invoke-Item -LiteralPath $dir
}
