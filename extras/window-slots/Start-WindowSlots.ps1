# Start-WindowSlots.ps1 -- keeps every PINNED window in the slot (tile position within its
# workspace) the user gave it. It never moves a window to another monitor or workspace --
# see window-slots.ps1's header.
#
# NOT WIRED IN (unwired 2026-09-24) -- see README.md in this folder. It used to be launched
# hidden by an At-LogOn Scheduled Task (tools/lib/activation.ps1's Get-AutostartComponents). Subscribes to komorebi's events over a named pipe and reacts
# based on who moved the window:
#   - a window appeared (or left)  -> reconcile against config/windows.toml's pinned slots.
#   - the user moved it            -> learn: the saved slot becomes wherever it is now.
#
# WHO moved it is deduced by comparing each workspace's window SET against the previous
# burst, not from the event type -- so a new gesture (or komorebi renaming its events)
# can't cause a user's own reorder to be reverted.
#
# The pipe is drained on a separate thread; the work happens on the main one. Not
# decorative: each event carries the full state (~24 KB), so two or three unread events
# fill the pipe's buffer, and komorebi then blocks writing to it -- it stops answering
# `komorebic state` and the reconciler goes blind right after something moves.
#
# Named pipe, not a socket: a Unix domain socket leaves a file on disk whose lifecycle
# already cost this project dearly once (a stale komorebi.sock left komorebi OFFLINE at
# boot). A pipe leaves no residue.
#
# The subscription dies with komorebi, so the outer loop waits and re-subscribes rather
# than treating the process as finished.
#
# Ported from winarchy's module/Winarchy/Private/WindowSlots.ps1 + scripts/Start-
# WindowSlots.ps1 @ 4574fc7 (tag v1.4.0), including the 631143e refinement (only pinned
# apps are slot-enforced/learned; explorer/terminal processes excluded; 800ms debounce).
# See tools/lib/window-slots.ps1's own header for the two monitor-identity deviations from
# winarchy (serial_number_id instead of device_id; no live display_index_preferences write).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # extras\window-slots\.. \.. = repo root
. (Join-Path $PSScriptRoot 'window-slots.ps1')

$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir 'window-slots.log'
# Log cap: past 1 MB this log becomes window-slots.log.old (replacing the previous one) --
# same rule as every other 710.DesktopRice log (plan doc, open item 20). Until 2026-09-23
# this deleted the log outright, losing its history. Checked again on every write below
# because this daemon runs for the whole session.
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }

function Write-Log {
    param([string]$Message)
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }
    "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message | Add-Content -Path $log -Encoding UTF8
}

$debounceMs = 800
$pipeName = '710-window-slots'

# Single instance: the pipe is the lock. Without this, the autostart task and a manual
# launch fight over the same pipe name, and whichever loses retries in a loop, filling the
# log.
if (Test-WindowSlotsRunning) {
    Write-Log 'another instance already holds the pipe; exiting'
    return
}

Write-Log 'started'

while ($true) {
    if (-not (Test-Process 'komorebi')) {
        Start-Sleep -Seconds 5
        continue
    }

    $server = $null
    $reader = $null
    $runspace = $null
    $pump = $null
    try {
        $server = New-Object System.IO.Pipes.NamedPipeServerStream(
            $pipeName, [System.IO.Pipes.PipeDirection]::In, 1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $null = Invoke-Komorebic subscribe-pipe $pipeName
        $server.WaitForConnection()
        $reader = New-Object System.IO.StreamReader($server)

        # Thread that only drains the pipe: keeps komorebi unblocked while the main
        # thread reorders. Only the event TYPE is queued, not the state alongside it.
        $events = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('reader', $reader)
        $runspace.SessionStateProxy.SetVariable('events', $events)
        $pump = [powershell]::Create()
        $pump.Runspace = $runspace
        $null = $pump.AddScript({
                while ($true) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line) { $events.Enqueue('!eof'); break }
                    try { $events.Enqueue(($line | ConvertFrom-Json).event.type) } catch { }
                }
            })
        $handle = $pump.BeginInvoke()
        Write-Log 'subscribed'

        # Reference taken BEFORE the first event: without this the user's very first move
        # would have nothing to compare against and would go unlearned.
        $signature = try { Get-WorkspaceSignature -State (Get-KomorebiState) } catch { $null }
        # Moves the reconciler itself emitted: while these are still arriving, a reorder
        # is ours, not the user's, so it isn't learned.
        $selfMoves = 0
        $pending = $false
        $quiet = 0
        # circuit breaker for a reconciliation that doesn't converge
        $burst = 0
        $burstLimit = 10
        $suspendUntil = [datetime]::MinValue
        $lastReconcile = [datetime]::MinValue

        while (-not $handle.IsCompleted) {
            $type = $null
            if ($events.TryDequeue([ref]$type)) {
                if ($type -eq '!eof') { break }
                if (Test-SlotEvent -Type $type) { $pending = $true }
                $quiet = 0
                continue
            }

            Start-Sleep -Milliseconds 50
            $quiet += 50
            if (-not $pending -or $quiet -lt $debounceMs) { continue }
            $pending = $false

            try {
                $state = Get-KomorebiState
                $current = Get-WorkspaceSignature -State $state
                $appeared = Test-WindowsAppeared -Previous $signature -Current $current

                if (($appeared -or $selfMoves -gt 0) -and (Get-Date) -lt $suspendUntil) {
                    $signature = $current
                    continue
                }

                if ($appeared -or $selfMoves -gt 0) {
                    $changed = if ($appeared) { Get-ChangedWorkspaceKeys -Previous $signature -Current $current } else { $null }
                    $emitted = [int](Invoke-SlotReconcile -Quiet -State $state -Workspaces $changed)
                    $selfMoves = $emitted
                    if (-not $emitted -or ((Get-Date) - $lastReconcile).TotalSeconds -gt 10) { $burst = 0 }
                    $lastReconcile = Get-Date
                    if ($emitted) {
                        $burst++
                        if ($burst -ge $burstLimit) {
                            Write-Log "reconcile loop detected ($burst in a row); pausing 60s"
                            $suspendUntil = (Get-Date).AddSeconds(60)
                            $burst = 0
                            $selfMoves = 0
                            $signature = Get-WorkspaceSignature -State (Get-KomorebiState)
                            continue
                        }
                        Write-Log "reconciled ($emitted move(s))"
                        # the reference is the corrected state, not the one that triggered it
                        $signature = Get-WorkspaceSignature -State (Get-KomorebiState)
                        continue
                    }
                } elseif ($signature) {
                    if (Update-SlotFromState -Quiet -State $state) { Write-Log 'learned new slots' }
                }
                $signature = $current
            } catch { Write-Log "error: $($_.Exception.Message)" }
        }
    } catch { Write-Log "subscription error: $($_.Exception.Message)" }
    finally {
        if ($pump) { $pump.Stop(); $pump.Dispose() }
        if ($runspace) { $runspace.Dispose() }
        if ($reader) { $reader.Dispose() }
        if ($server) { $server.Dispose() }
        try { $null = Invoke-Komorebic unsubscribe-pipe $pipeName } catch { }
    }

    Write-Log 'disconnected; waiting for komorebi'
    Start-Sleep -Seconds 5
}
