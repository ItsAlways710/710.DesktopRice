# Start-Yasb.ps1 -- starts YASB waiting for the shell to be ready, with retries.
# No-op if YASB is already running. Ported from winarchy's scripts/Start-Yasb.ps1 @ 4574fc7.
#
# Only 710.ahk runs this (StartBar, config\ahk\710.ahk: "The apps 710.ahk starts"), through
# Windows PowerShell, with no arguments but -Reason (what the log's header line says). Until
# 2026-10-06 the bar's own Scheduled Task ran it, and everything a task starts sits in a job
# that refuses a child's request to start apart from it -- an MO2 opened from the bar's taskbar
# drawer couldn't start any of its tools (Error 5). -YasbExe / -YasbConfigHome still work (an
# old task's command line passes them); without them: yasbc.exe where winget puts it, else on
# PATH, and this clone's config\yasb.
#
# The environment is read fresh from the registry first (Update-ProcessEnvironment): 710.ahk's
# own is the one it started with, so without this a bar restarted later wouldn't see a variable
# set or removed since (the README's YASB_WALLPAPER_PATH, then `710sRice reload bar`) -- the
# task's start always had a fresh one.

param(
    [string]$YasbExe,
    [string]$YasbConfigHome,
    [string]$Reason = 'autostart'
)

function Update-ProcessEnvironment {
    <# This process's variables as a new sign-in would set them: the machine's, then yours over
       them, Path the two joined (Windows' own order). A variable of the rice's (YASB_* or
       DESKTOPRICE_*) that's in neither any more goes too -- removed since 710.ahk started.
       Windows' per-session ones (USERNAME, APPDATA, ...) aren't in either list and stay as they
       are. Windows PowerShell 5.1: [Environment] reads the registry and expands REG_EXPAND_SZ.
       -Machine / -User: the two lists, for a test. #>
    param($Machine = [Environment]::GetEnvironmentVariables('Machine'),
          $User    = [Environment]::GetEnvironmentVariables('User'))
    $machine = $Machine
    $user    = $User
    foreach ($vars in $machine, $user) {
        foreach ($name in @($vars.Keys)) {
            if ($name -ieq 'Path' -or $name -ieq 'PSModulePath') { continue }
            [Environment]::SetEnvironmentVariable($name, [string]$vars[$name], 'Process')
        }
    }
    # Names compared ignoring case, as Windows does (these hashtables don't: a user Path saved
    # as PATH would otherwise be dropped, and every app opened from the bar would miss it).
    $pathOf = { param($vars) foreach ($k in @($vars.Keys)) { if ($k -ieq 'Path') { return [string]$vars[$k] } } }
    $env:Path = (@((& $pathOf $machine), (& $pathOf $user)) | Where-Object { $_ }) -join ';'
    $known = @($machine.Keys) + @($user.Keys)
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        if ($name -notmatch '^(YASB_|DESKTOPRICE_)') { continue }
        if (-not @($known | Where-Object { $_ -ieq $name }).Count) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }
}
try { Update-ProcessEnvironment } catch { }   # best-effort: the inherited environment otherwise

if (-not $YasbExe -and $env:ProgramFiles) {
    $next = Join-Path $env:ProgramFiles 'YASB\yasbc.exe'
    if (Test-Path -LiteralPath $next) { $YasbExe = $next }
}
if (-not $YasbExe) { $YasbExe = (Get-Command yasbc.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if (-not $YasbConfigHome) { $YasbConfigHome = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\yasb' }

$env:YASB_CONFIG_HOME = $YasbConfigHome
$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'yasb-autostart.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# Log cap: past 1 MB this log becomes <name>.old (replacing the previous one) and a fresh
# one starts -- so at most ~2 MB, and the last chunk of history is always kept. Same rule
# in every 710.DesktopRice log writer (plan doc, open item 20).
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }

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

function Invoke-Hidden {
    <# Runs an exe with no console window. Same technique as Start-Komorebi.ps1's own
       Invoke-Komorebic (see that function's docstring for the full rationale -- this
       script runs under legacy Windows PowerShell 5.1 too, same reason). Without
       CreateNoWindow, `& $YasbExe start` gets Windows its own fresh, briefly-visible
       console -- confirmed live on Dell as the 3rd of the "3 shells flash at boot". #>
    param([Parameter(Mandatory)][string]$FilePath,
          [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = ($Arguments -join ' ')
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($info)
    $null = $p.StandardOutput.ReadToEnd()
    $null = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
}

if (-not $YasbExe -or -not (Test-Path -LiteralPath $YasbExe)) { Write-Log "yasbc.exe not found$(if ($YasbExe) { " at $YasbExe" } else { ' (not in Program Files\YASB, not on PATH)' }); aborting."; exit 1 }
if (Test-YasbRunning) { Write-Log 'YASB already running; nothing to do.'; exit 0 }

Write-Log "--- startup ($Reason) ---"

# Bluetooth in the bar: config.yaml's network group lists "bluetooth$env:DESKTOPRICE_NO_BLUETOOTH"
# -- 'bluetooth' (YASB's icon, "off" while the radio is off) on a machine with an adapter,
# 'bluetooth_none' (an empty widget) on one without (tools\lib\bluetooth.ps1). Asked at every bar
# start, so the bar always matches the hardware -- the user variable the install's bluetooth step
# sets is only for a YASB started some other way. Anything wrong here: no variable, the icon shows.
try {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\lib\bluetooth.ps1')
    $env:DESKTOPRICE_NO_BLUETOOTH = Get-BluetoothBarValue
    Write-Log $(if ($env:DESKTOPRICE_NO_BLUETOOTH) { 'bluetooth: no adapter -- the bar leaves its icon out' } else { 'bluetooth: adapter found -- the bar shows its icon' })
} catch {
    Remove-Item Env:DESKTOPRICE_NO_BLUETOOTH -ErrorAction SilentlyContinue
    Write-Log "bluetooth: couldn't check ($($_.Exception.Message)) -- the bar shows its icon"
}

# Fingerprint of the config.yaml this YASB is about to load. tools\reload-stack.ps1 compares
# against it and leaves YASB running when nothing it reads has changed -- because every YASB
# restart hands its screen strip back and takes it again (it's a Windows app bar), Windows
# re-broadcasts the work area to every window, and Claude Desktop stacks one more native
# title bar per restart until relaunched (found 2026-09-25; plan doc Open item 40). No
# fingerprint = reload-stack restarts YASB, the safe default.
$fingerprint = Join-Path $logDir 'yasb-config.sha256'
try {
    (Get-FileHash (Join-Path $YasbConfigHome 'config.yaml') -Algorithm SHA256 -ErrorAction Stop).Hash |
        Set-Content -Path $fingerprint -Encoding ascii
} catch {
    Remove-Item $fingerprint -ErrorAction SilentlyContinue
    Write-Log "couldn't fingerprint config.yaml ($($_.Exception.Message)) -- the next SUPER+Shift+R will restart YASB."
}

$overallDeadline = (Get-Date).AddMinutes(1)
$attempt = 0
while ((Get-Date) -lt $overallDeadline) {
    if (Test-YasbRunning) { Write-Log 'YASB alive; done.'; exit 0 }
    $attempt++

    while ((Get-Date) -lt $overallDeadline -and -not (Test-ForegroundReady)) { Start-Sleep -Milliseconds 500 }

    Write-Log "attempt ${attempt}: launching yasbc start"
    try { Invoke-Hidden -FilePath $YasbExe -Arguments 'start' }
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
