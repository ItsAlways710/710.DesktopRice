# Start-Komorebi.ps1 -- resilient komorebi startup for 710.DesktopRice's autostart.
#
# Launched hidden by the At-LogOn Scheduled Task (tools/lib/activation.ps1's
# Get-AutostartComponents). Ported from winarchy's scripts/Start-Komorebi.ps1 @ 4574fc7
# (tag v1.4.0). Fixes the same two causes of komorebi staying OFFLINE after logon/unlock:
#   a) an early panic (Application Error 0xc0000409 -- Rust abort).
#   b) "failed call to AllowSetForegroundWindow after 5 retries" (komorebi's main.rs:219):
#      komorebi starts before the session has a real foreground window yet. Typical on a
#      fast unlock: the LogonTrigger fires before the desktop has settled.
# No-op if komorebi is already running.

$root = Split-Path $PSScriptRoot -Parent
$Root = $root
$env:KOMOREBI_CONFIG_HOME = Join-Path $root 'config\komorebi'
$exe    = Join-Path $env:ProgramFiles 'komorebi\bin\komorebi.exe'
$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'komorebi-autostart.log'
$outLog = Join-Path $logDir 'komorebi.out.log'
$errLog = Join-Path $logDir 'komorebi.err.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# Log cap: past 1 MB this log becomes <name>.old (replacing the previous one) and a fresh
# one starts -- so at most ~2 MB, and the last chunk of history is always kept. Same rule
# in every 710.DesktopRice log writer (plan doc, open item 20).
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }

# P/Invoke to detect a real foreground window and lower the lock timeout. Without this,
# komorebi's own AllowSetForegroundWindow call is refused while the desktop hasn't settled.
Add-Type -Namespace Win710 -Name Fg -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint a, uint b, System.IntPtr c, uint d);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@

function Reset-ForegroundLock {
    # Synthesizes an Alt tap (down/up). Windows releases the foreground lock when the
    # session receives an input event, letting komorebi's AllowSetForegroundWindow
    # succeed. Without this, on a boot where some other app is holding the foreground,
    # komorebi cuts out after 5 retries (main.rs:219) for the whole budget below.
    [Win710.Fg]::keybd_event(0x12, 0, 0, [System.UIntPtr]::Zero)        # VK_MENU down
    [Win710.Fg]::keybd_event(0x12, 0, 0x2, [System.UIntPtr]::Zero)      # VK_MENU up (KEYEVENTF_KEYUP)
}

function Test-ForegroundReady {
    [bool]((Get-Process explorer -ErrorAction SilentlyContinue) -and `
           ([Win710.Fg]::GetForegroundWindow() -ne [System.IntPtr]::Zero))
}

function Write-Log([string]$m) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Out-File -FilePath $log -Append -Encoding utf8
}

function Test-KomorebiRunning { [bool](Get-Process komorebi -ErrorAction SilentlyContinue) }

function Invoke-Komorebic {
    <# Runs komorebic.exe with no console window and returns its stdout. Same technique
       as tools\lib\window-slots.ps1's own Invoke-Komorebic, duplicated locally here
       rather than dot-sourced -- this script runs under legacy Windows PowerShell 5.1
       (see Get-AutostartComponents), and window-slots.ps1 needs PS7's ?. operator just to
       parse, so dot-sourcing it would throw. .NET Framework's ProcessStartInfo also lacks
       .ArgumentList (added in .NET Core 2.1), so this builds a plain .Arguments string
       instead -- fine for every call site here (bare subcommands/digits, no spaces).
       Without CreateNoWindow, Windows allocates a fresh, briefly-visible console per
       invocation -- confirmed live on Dell as 2 of the "3 shells flash at boot" (the 3rd
       is Start-Yasb.ps1's own equivalent fix). Reads $komorebic from the caller's scope,
       same as Write-Log above reads $log. #>
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $komorebic
    $info.Arguments = ($Arguments -join ' ')
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($info)
    $out = $p.StandardOutput.ReadToEnd()
    $null = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $out
}

if (-not (Test-Path $exe)) { Write-Log "komorebi.exe not found at $exe; aborting."; exit 1 }
if (Test-KomorebiRunning)  { Write-Log 'komorebi already running; nothing to do.'; exit 0 }

Write-Log '--- startup (autostart) ---'

# (No komorebi.sock / komorebi.hwnd.json cleanup here, deliberately. Winarchy's version
# deletes both before launching; our port pointed that loop at our own log folder, so it
# never touched anything (the files live in %LOCALAPPDATA%\komorebi). Removed 2026-09-23
# rather than fixed: komorebi 0.1.41 deletes a leftover socket itself right before it
# binds (WindowManager::new: remove_file(&socket), then UnixListener::bind), also deletes
# it on a clean `komorebic stop`, and keeps rewriting komorebi.hwnd.json while it runs.)

# Game-mode state is per-session: session float rules die with komorebi. If the flag
# survives a reboot, AHK starts up believing it's mid-game with no way to know otherwise.
$stateDir = Join-Path $root 'state'
foreach ($stale in @('game-mode.flag', 'game-mode-floated')) {
    $f = Join-Path $stateDir $stale
    if (Test-Path $f) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        Write-Log "cleared stale session state: $stale"
    }
}

$overallDeadline = (Get-Date).AddMinutes(5)

# 1) Wait for a real foreground (explorer + a non-zero foreground window), not just explorer.
while ((Get-Date) -lt $overallDeadline -and -not (Test-ForegroundReady)) { Start-Sleep -Milliseconds 500 }
Start-Sleep -Seconds 2

# 2) Time-budgeted attempts: re-wait for foreground each round, lower the lock timeout,
#    launch hidden, and check it survives >8s. Retries until $overallDeadline, not just a
#    handful of seconds.
$attempt = 0
while ((Get-Date) -lt $overallDeadline) {
    if (Test-KomorebiRunning) { Write-Log 'komorebi alive; done.'; exit 0 }
    $attempt++

    while ((Get-Date) -lt $overallDeadline -and -not (Test-ForegroundReady)) { Start-Sleep -Milliseconds 500 }
    [Win710.Fg]::SystemParametersInfo(0x2001, 0, [System.IntPtr]::Zero, 0x3) | Out-Null
    Reset-ForegroundLock

    Write-Log "attempt ${attempt}: launching komorebi.exe"
    try {
        $p = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    } catch {
        Write-Log "attempt ${attempt}: failed to launch: $($_.Exception.Message)"
        Start-Sleep -Seconds 2
        continue
    }

    Start-Sleep -Seconds 8
    if (-not $p.HasExited) {
        Write-Log "attempt ${attempt}: komorebi still alive after 8s. OK."
        # Mitigation: on some boots the primary monitor (index 0) ends up focused on
        # workspace 2 (index 1) instead of 1. Root cause unknown; force the primary
        # monitor's workspace 0 only on a fresh startup. Needs the socket already bound,
        # hence after the survival check.
        $komorebic = Join-Path (Split-Path $exe) 'komorebic.exe'
        if (Test-Path $komorebic) {
            try {
                $null = Invoke-Komorebic focus-monitor-workspace 0 0
                Write-Log 'primary monitor refocused to workspace 0.'
            } catch { Write-Log "couldn't refocus workspace 0: $($_.Exception.Message)" }

            # Put wallust's border colors back. `komorebic border-colour` is runtime-only
            # state, so every komorebi start comes up on komorebi's own default (blue)
            # borders until something re-pushes them -- confirmed live 2026-09-23. Done
            # here, right after the survival check, so boots AND reload-stack.ps1's
            # "komorebi wasn't running" path both get it. apply-wallust-outputs.ps1 needs
            # PS7 and this script runs under 5.1, so it goes through pwsh -- with
            # CreateNoWindow, same no-flash reasoning as Invoke-Komorebic above. Waited on
            # (it's a handful of komorebic calls) so the result lands in this log.
            $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if ($pwsh) {
                try {
                    $info = New-Object System.Diagnostics.ProcessStartInfo
                    $info.FileName = $pwsh
                    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'tools\apply-wallust-outputs.ps1') + '" -BordersOnly'
                    $info.UseShellExecute = $false
                    $info.CreateNoWindow = $true
                    $info.RedirectStandardOutput = $true
                    $info.RedirectStandardError = $true
                    $bp = [System.Diagnostics.Process]::Start($info)
                    $null = $bp.StandardOutput.ReadToEnd()
                    $bErr = $bp.StandardError.ReadToEnd()
                    $bp.WaitForExit()
                    if ($bp.ExitCode -eq 0) { Write-Log 'wallust border colors re-applied.' }
                    else { Write-Log "couldn't re-apply wallust border colors (exit $($bp.ExitCode)): $bErr" }
                } catch { Write-Log "couldn't re-apply wallust border colors: $($_.Exception.Message)" }
            } else { Write-Log 'pwsh not found -- wallust border colors not re-applied.' }

            # Unmanage games.toml windows that komorebi already tiled on its initial scan
            # (a retile/ignore-rule doesn't retroactively unmanage them). Only matters when
            # komorebi (re)starts with a game open -- SUPER+Shift+R removing a rule, or a
            # crash -- never at a normal boot.
            # games.toml is read right here with a 5.1-safe loop (same `exe = "..."` grammar
            # as window-slots.ps1's Get-GameExes). Until 2026-09-23 this dot-sourced
            # window-slots.ps1 instead, which needs PS7's ?. just to parse -- so under this
            # script's 5.1 host the step threw on every single start and never ran once.
            try {
                $gamesToml = Join-Path $root 'games.toml'
                # outer @() so 0 or 1 games still gives an array (the plan doc's
                # collapse-to-scalar gotcha)
                $games = @(@(
                    if (Test-Path $gamesToml) {
                        foreach ($line in Get-Content $gamesToml -Encoding UTF8) {
                            if ($line -match '^\s*exe\s*=\s*"([^"]+)"') { $Matches[1] }
                        }
                    }
                ) | Sort-Object -Unique)
                $stateJson = Invoke-Komorebic state | ConvertFrom-Json
                $tiledExes = @(
                    foreach ($m in $stateJson.monitors.elements) {
                        foreach ($ws in $m.workspaces.elements) {
                            foreach ($c in $ws.containers.elements) {
                                foreach ($w in $c.windows.elements) { $w.exe }
                            }
                        }
                    }
                ) | Sort-Object -Unique
                $toFree = @($tiledExes | Where-Object { $games -contains $_ })
                foreach ($gameExe in $toFree) {
                    & $komorebic eager-focus $gameExe *> $null
                    & $komorebic unmanage *> $null
                }
                if ($toFree.Count -gt 0) {
                    & $komorebic retile *> $null
                    Write-Log "unmanaged $($toFree.Count) games.toml window(s) that were already tiled ($($toFree -join ', ')) + retile."
                } else {
                    Write-Log "games check: $($games.Count) games listed in games.toml, none tiled."
                }
            } catch { Write-Log "couldn't unmanage games.toml windows post-startup: $($_.Exception.Message)" }
        }
        exit 0
    }

    $code = try { $p.ExitCode } catch { '?' }
    Write-Log "attempt ${attempt}: komorebi exited quickly (code '$code'). stderr:"
    $stderr = if (Test-Path $errLog) { (Get-Content $errLog -Raw -ErrorAction SilentlyContinue) } else { '' }
    if ($stderr) { foreach ($ln in ($stderr -split "`r?`n" | Where-Object { $_ })) { Write-Log "    | $ln" } }
    else { Write-Log '    | (empty stderr)' }

    if ($stderr -match 'AllowSetForegroundWindow') {
        Write-Log "attempt ${attempt}: foreground still not ready; waiting longer before retry."
        Start-Sleep -Seconds 5
    } else {
        Start-Sleep -Seconds 3
    }
}

Write-Log "5 minute budget exhausted; komorebi never came up."
exit 1
