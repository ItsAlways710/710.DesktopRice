# Start-Yasb.ps1 -- starts YASB waiting for the shell to be ready, with retries.
# No-op if YASB is already running. Ported from winarchy's scripts/Start-Yasb.ps1 @ 4574fc7.

param(
    [Parameter(Mandatory)][string]$YasbExe,
    [Parameter(Mandatory)][string]$YasbConfigHome
)

$env:YASB_CONFIG_HOME = $YasbConfigHome
$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'yasb-autostart.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Add-Type -Namespace Win710 -Name FgYasb -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
'@

function Test-ForegroundReady {
    [bool]((Get-Process explorer -ErrorAction SilentlyContinue) -and `
           ([Win710.FgYasb]::GetForegroundWindow() -ne [System.IntPtr]::Zero))
}

function Write-Log([string]$m) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Out-File -FilePath $log -Append -Encoding utf8
}

function Test-YasbRunning { [bool](Get-Process yasb -ErrorAction SilentlyContinue) }

if (-not (Test-Path $YasbExe)) { Write-Log "yasbc.exe not found at $YasbExe; aborting."; exit 1 }
if (Test-YasbRunning) { Write-Log 'YASB already running; nothing to do.'; exit 0 }

Write-Log '--- startup (autostart) ---'

$overallDeadline = (Get-Date).AddMinutes(1)
$attempt = 0
while ((Get-Date) -lt $overallDeadline) {
    if (Test-YasbRunning) { Write-Log 'YASB alive; done.'; exit 0 }
    $attempt++

    while ((Get-Date) -lt $overallDeadline -and -not (Test-ForegroundReady)) { Start-Sleep -Milliseconds 500 }

    Write-Log "attempt ${attempt}: launching yasbc start"
    try { & $YasbExe start }
    catch {
        Write-Log "attempt ${attempt}: failed to launch: $($_.Exception.Message)"
        Start-Sleep -Seconds 2
        continue
    }

    Start-Sleep -Seconds 3
    if (Test-YasbRunning) { Write-Log "attempt ${attempt}: YASB alive after 3s. OK."; exit 0 }

    Write-Log "attempt ${attempt}: YASB didn't stay up."
    Start-Sleep -Seconds 2
}

Write-Log "1 minute budget exhausted; YASB never came up."
exit 1
