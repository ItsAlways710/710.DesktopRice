# The lock screen follows the wallpaper as YOUR lock-screen picture (Windows' per-user one), set
# by scripts\Set-LockScreen.ps1 -- which has to run in Windows PowerShell 5.1 (PowerShell 7 can't
# call WinRT). Dot-sourced by the wallpaper pipeline (tools\apply-wallust-outputs.ps1) and by
# tools\lib\activation.ps1 (install's tasks step, uninstall); doctor reads the record. No
# dependencies of its own: the pipeline stays free of activation.ps1.
# Why a per-user picture and not the old machine policy: scripts\Set-LockScreen.ps1's header.

function Get-LockScreenRecordPath { Join-Path $env:LOCALAPPDATA '710.DesktopRice\lockscreen.json' }

function Read-LockScreenRecord {
    <# The last set's outcome (Set-LockScreen.ps1 writes it; so does Invoke-LockScreenSetter when
       the script never got to): time, image (a file name, never a folder), ok, policy (a machine
       policy shows its own picture over yours), reason. $null when there's none. #>
    $f = Get-LockScreenRecordPath
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { [IO.File]::ReadAllText($f) | ConvertFrom-Json -AsHashtable } catch { $null }
}

function Write-LockScreenRecord {
    param([bool]$Ok, [string]$Image, [string]$Reason)
    try {
        $o = [ordered]@{ time = (Get-Date -Format 's'); image = $(if ($Image) { Split-Path -Leaf $Image } else { '' }); ok = $Ok; policy = $false; reason = $Reason }
        $f = Get-LockScreenRecordPath
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f)
        [IO.File]::WriteAllText($f, ($o | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    } catch { }
}

function Invoke-LockScreenSetter {
    <# Runs scripts\Set-LockScreen.ps1 in Windows PowerShell 5.1 with no window at all
       (CreateNoWindow: no console is ever made -- the way Start-Komorebi runs komorebic), and
       waits for it: the caller gets the result, and quick wallpaper changes stay in order (the
       pipeline holds its lock meanwhile). The timeout is only for a WinRT call that never
       answers. As the caller -- the user on a wallpaper change; install / uninstall run
       elevated, as the same user.
       -> ExitCode (the script's: 0 set, 1 no picture file, 2 set but a policy overrides it,
       3 Windows refused; ours: 4 timed out, 5 couldn't start powershell.exe) and Message (what
       happened, in words -- the script's last line). #>
    param([Parameter(Mandatory)][string]$Root, [string]$Image, [int]$TimeoutSec = 30)
    $ps = if ($env:WINDIR) { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
    if (-not $ps -or -not (Test-Path -LiteralPath $ps)) {
        $why = "Windows PowerShell (powershell.exe) wasn't found"
        Write-LockScreenRecord -Ok $false -Image $Image -Reason $why
        return [pscustomobject]@{ ExitCode = 5; Message = $why }
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new($ps)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'scripts\Set-LockScreen.ps1'))) {
        $psi.ArgumentList.Add($a)
    }
    if ($Image) { $psi.ArgumentList.Add('-Image'); $psi.ArgumentList.Add($Image) }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch {
        $why = "couldn't start Windows PowerShell ($($_.Exception.Message))"
        Write-LockScreenRecord -Ok $false -Image $Image -Reason $why
        return [pscustomobject]@{ ExitCode = 5; Message = $why }
    }
    try {
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { }
            $why = "Windows didn't answer within $TimeoutSec s"
            Write-LockScreenRecord -Ok $false -Image $Image -Reason $why
            return [pscustomobject]@{ ExitCode = 4; Message = $why }
        }
        $p.WaitForExit()   # and let the readers finish
        $said = @("$($out.Result)" -split "`r?`n" | Where-Object { $_.Trim() })
        $errs = @("$($err.Result)" -split "`r?`n" | Where-Object { $_.Trim() })
        $msg = if ($said.Count) { $said[-1].Trim() } elseif ($errs.Count) { $errs[0].Trim() } else { '' }
        [pscustomobject]@{ ExitCode = $p.ExitCode; Message = $msg }
    } finally { $p.Dispose() }
}
