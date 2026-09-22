# Start-Ahk.ps1 -- starts the AHK dispatcher waiting for the shell to be ready, with
# retries. No-op if AHK is already running. Ported from winarchy's scripts/Start-Ahk.ps1
# @ 4574fc7.

param(
    [Parameter(Mandatory)][string]$AhkExe,
    [Parameter(Mandatory)][string]$ScriptPath
)

$exe    = $AhkExe
$script = $ScriptPath
$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'ahk-autostart.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Add-Type -Namespace Win710 -Name FgAhk -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
'@

function Test-ForegroundReady {
    [bool]((Get-Process explorer -ErrorAction SilentlyContinue) -and `
           ([Win710.FgAhk]::GetForegroundWindow() -ne [System.IntPtr]::Zero))
}

function Write-Log([string]$m) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Out-File -FilePath $log -Append -Encoding utf8
}

function Test-AhkRunning { [bool](Get-Process AutoHotkey64 -ErrorAction SilentlyContinue) }

if (-not (Test-Path $exe)) { Write-Log "AutoHotkey64.exe not found at $exe; aborting."; exit 1 }
if (Test-AhkRunning) { Write-Log 'AHK already running; nothing to do.'; exit 0 }

# Belt-and-suspenders: clears any Claude Code sub-session flags this launcher process
# itself inherited, in addition to 710.ahk's own EnvSet('CLAUDE_CODE_CHILD_SESSION') /
# EnvSet('CLAUDECODE') at its own startup (see config/ahk/710.ahk).
Remove-Item Env:CLAUDE_CODE_CHILD_SESSION, Env:CLAUDECODE -ErrorAction SilentlyContinue

Write-Log '--- startup (autostart) ---'

$overallDeadline = (Get-Date).AddMinutes(2)
$attempt = 0
while ((Get-Date) -lt $overallDeadline) {
    if (Test-AhkRunning) { Write-Log 'AHK alive; done.'; exit 0 }
    $attempt++

    while ((Get-Date) -lt $overallDeadline -and -not (Test-ForegroundReady)) { Start-Sleep -Milliseconds 500 }

    Write-Log "attempt ${attempt}: launching AutoHotkey64.exe"
    try {
        $p = Start-Process -FilePath $exe -ArgumentList "`"$script`"" -WindowStyle Hidden -PassThru
    } catch {
        Write-Log "attempt ${attempt}: failed to launch: $($_.Exception.Message)"
        Start-Sleep -Seconds 2
        continue
    }

    Start-Sleep -Seconds 3
    if (-not $p.HasExited) { Write-Log "attempt ${attempt}: AHK still alive after 3s. OK."; exit 0 }

    $code = try { $p.ExitCode } catch { '?' }
    Write-Log "attempt ${attempt}: AHK exited quickly (code '$code')."
    Start-Sleep -Seconds 2
}

Write-Log "2 minute budget exhausted; AHK never came up."
exit 1
