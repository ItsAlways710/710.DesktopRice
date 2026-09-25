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
# Log cap: past 1 MB this log becomes <name>.old (replacing the previous one) and a fresh
# one starts -- so at most ~2 MB, and the last chunk of history is always kept. Same rule
# in every 710.DesktopRice log writer (plan doc, open item 20).
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }

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

# Either build counts: AutoHotkey64_UIA.exe is what the autostart launches now (UI Access,
# plan doc Open item 36); plain AutoHotkey64.exe is the per-user-install fallback. Missing
# the UIA name here would launch a second 710.ahk on top of a running one, whose
# #SingleInstance can't close a UIA instance anyway -- just a popup and an early exit.
function Test-AhkRunning { [bool](Get-Process AutoHotkey64, AutoHotkey64_UIA -ErrorAction SilentlyContinue) }

$exeName = Split-Path $exe -Leaf
if (-not (Test-Path $exe)) { Write-Log "$exeName not found at $exe; aborting."; exit 1 }
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

    Write-Log "attempt ${attempt}: launching $exeName"
    try {
        $p = Start-Process -FilePath $exe -ArgumentList "`"$script`"" -WindowStyle Hidden -PassThru
    } catch {
        Write-Log "attempt ${attempt}: failed to launch: $($_.Exception.Message)"
        Start-Sleep -Seconds 2
        continue
    }

    # Start-Process = ShellExecute, which the UIA exe needs (AutoHotkey's docs: a UIA exe
    # can't be started via CreateProcess). Liveness is checked by process name rather than
    # $p.HasExited: a normal process can be refused access to a UI Access process (found
    # live: Stop-Process on one is 'Access is denied'), so the handle can't be trusted.
    Start-Sleep -Seconds 3
    if (Test-AhkRunning) { Write-Log "attempt ${attempt}: AHK still alive after 3s. OK."; exit 0 }

    $code = try { $p.ExitCode } catch { '?' }
    Write-Log "attempt ${attempt}: AHK exited quickly (code '$code')."
    Start-Sleep -Seconds 2
}

Write-Log "2 minute budget exhausted; AHK never came up."
exit 1
