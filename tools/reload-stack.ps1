#Requires -Version 7.0
<#
.SYNOPSIS
  SUPER+Shift+R: make every config edit take effect without a logoff -- recompile the
  komorebi rules (komorebi picks them up), keep your live workspace layouts, put the
  wallust borders back, and restart YASB when it actually needs it.
  AHK restarts itself afterwards (710.ahk's ReloadStack()), which is why AHK isn't
  touched here.

.DESCRIPTION
  Launched hidden by 710.ahk's ReloadStack() via RunWait; AHK reads the exit code to pick
  its notification. Every step logs to %LOCALAPPDATA%\710.DesktopRice\reload-stack.log.

  How komorebi actually reloads (all confirmed live 2026-09-23, not assumed):
    - `komorebic reload-configuration` is NOT it. Per komorebi's own CLI reference it only
      reloads *legacy* komorebi.ahk/komorebi.ps1 configs -- a no-op for our komorebi.json.
      (winarchy's Invoke-WinarchyReload calls it too; it never did anything there either.)
    - komorebi watches komorebi.json itself and hot-reloads it (ReloadStaticConfiguration
      in komorebi.out.log) ~2s after any write. That reload is what picks up new rules --
      and it also resets EVERY workspace to its config layout, wiping live layouts and
      scrolling column counts.
  So:
    0. Snapshot every workspace's layout + scrolling column count (`komorebic state`).
    1. Compile rules, and bail if that fails -- a broken rules.toml never reaches komorebi.
       compile-komorebi-rules.ps1 only rewrites komorebi.json when the result actually
       changed, so a plain SUPER+Shift+R with no rule edits doesn't trigger komorebi's
       reload at all, and there's nothing to restore.
    2. If komorebi.json DID change: wait for komorebi's own reload to show up as processed
       in komorebi.out.log, then put back every layout and column count it reset. Column
       counts can only be set on the FOCUSED workspace (`scrolling-layout-columns`), so
       those workspaces get focused one by one, then every monitor goes back to the
       workspace it was showing -- a brief, accepted flicker. Then re-push the wallust
       borders (`komorebic border-colour` is runtime-only state). If komorebi isn't running
       at all, its autostart task starts it and Start-Komorebi.ps1 does the borders.
       BUT the hot reload only ever ADDS rules (populate_rules() in komorebi's
       static_config.rs never clears a rule list), so if any rule was REMOVED from
       komorebi.json, komorebi gets a clean stop + restart through its autostart task
       instead, then the same layout/column restore once Start-Komorebi.ps1 has finished.
       Rule additions (quick-add-rule's whole job) stay on the fast hot-reload path.
    3. YASB: kill + restart, never `yasbc reload` -- its hot reload re-subscribes the
       komorebi widgets to the named pipe without closing the old subscription (watch_config
       stays off for the same reason). ONLY when needed, though: YASB isn't running,
       komorebi was restarted in step 2 (the widgets need the new komorebi), or config.yaml
       differs from the fingerprint Start-Yasb.ps1 recorded at YASB's last start (or there
       is none). Otherwise it's left alone -- every restart makes Windows re-broadcast the
       work area (YASB is an app bar), and Claude Desktop stacks a native title bar per
       broadcast (plan doc Open item 40). styles.css and wallpaper colours hot-reload on
       their own (watch_stylesheet) and never needed the restart.

  Starting things goes through the registered autostart Scheduled Tasks
  (`schtasks /Run \710.DesktopRice\<name>`) -- the exact wscript/run-hidden.vbs path boot
  uses, so no console flash, non-elevated like every autostart task (LeastPrivilege), and
  no second copy of every launch command line to keep in sync. An unregistered task (a
  machine that never ran install.ps1 -Activate) is logged and skipped.

  Exit codes: 0 = everything reloaded; 1 = rule compile failed, nothing was touched;
  2 = compile was fine but at least one later step failed (see the log).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log    = Join-Path $logDir 'reload-stack.log'
$komorebiOut = Join-Path $logDir 'komorebi.out.log'   # Start-Komorebi.ps1 redirects komorebi's stdout here
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# Log cap: past 1 MB this log becomes <name>.old (replacing the previous one) and a fresh
# one starts -- so at most ~2 MB, and the last chunk of history is always kept. Same rule
# in every 710.DesktopRice log writer (plan doc, open item 20).
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue }

function Write-Log([string]$m) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Out-File -FilePath $log -Append -Encoding utf8
}

$TaskFolder = '\710.DesktopRice'   # keep in sync with tools\lib\activation.ps1's $script:TaskFolder

function Test-AutostartTask([string]$Name) {
    # Capture-and-discard, not `*> $null` -- schtasks.exe's "cannot find the file" text
    # leaks straight past *> (see the plan doc's PowerShell gotchas, e886f42).
    $null = & schtasks.exe /Query /TN "$TaskFolder\$Name" 2>&1
    $LASTEXITCODE -eq 0
}

function Start-AutostartTask([string]$Name) {
    <# Fires the component's own autostart task. Returns $true if it was fired -- which
       only means Task Scheduler accepted it; the launcher scripts themselves log whether
       the component actually came up (komorebi-autostart.log, yasb-autostart.log, ...). #>
    if (-not (Test-AutostartTask $Name)) {
        Write-Log "   ${Name}: autostart task $TaskFolder\$Name isn't registered (install.ps1 -Activate never ran?) -- skipped."
        return $false
    }
    $out = & schtasks.exe /Run /TN "$TaskFolder\$Name" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "   ${Name}: schtasks /Run failed ($LASTEXITCODE): $out"
        return $false
    }
    Write-Log "   ${Name}: autostart task fired."
    $true
}

# --- komorebi state helpers ---------------------------------------------------------------
$komorebic = Join-Path $env:ProgramFiles 'komorebi\bin\komorebic.exe'
if (-not (Test-Path $komorebic)) { $komorebic = (Get-Command komorebic -ErrorAction SilentlyContinue)?.Source }

function Invoke-Kc {
    # komorebic, output captured (so nothing leaks into this hidden host), exit code checked.
    $out = & $komorebic @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "komorebic $($args -join ' ') failed ($LASTEXITCODE): $out" }
    $out
}

function Get-LayoutSnapshot {
    <# Every monitor/workspace's layout name + scrolling column count, plus which workspace
       each monitor is showing and which monitor has focus -- the same monitors.elements /
       workspaces.elements shape Start-Komorebi.ps1 already walks. Custom layouts come back
       as $null (nothing to restore by name) and get skipped. #>
    $st = (Invoke-Kc state) -join "`n" | ConvertFrom-Json
    $mons = @($st.monitors.elements)
    [pscustomobject]@{
        FocusedMonitor = [int]$st.monitors.focused
        Monitors = @(for ($m = 0; $m -lt $mons.Count; $m++) {
            $wss = @($mons[$m].workspaces.elements)
            [pscustomobject]@{
                Index            = $m
                FocusedWorkspace = [int]$mons[$m].workspaces.focused
                Workspaces       = @(for ($w = 0; $w -lt $wss.Count; $w++) {
                    [pscustomobject]@{
                        Index   = $w
                        Name    = $wss[$w].name
                        Layout  = $wss[$w].layout.Default
                        Columns = $(if ($wss[$w].layout_options -and $wss[$w].layout_options.scrolling) { $wss[$w].layout_options.scrolling.columns })
                    }
                })
            }
        })
    }
}

function ConvertTo-CliLayout([string]$Name) {
    # State says VerticalStack / RightMainVerticalStack / BSP; `workspace-layout` wants
    # vertical-stack / right-main-vertical-stack / bsp (komorebic's documented values).
    ($Name -creplace '(?<=[a-z])(?=[A-Z])', '-').ToLowerInvariant()
}

function Get-StaticReloadCount {
    <# How many ReloadStaticConfiguration commands komorebi has logged as processed. -1 if
       the log can't be read (komorebi started some way other than Start-Komorebi.ps1) --
       the caller then falls back to a plain wait. #>
    try {
        if (-not (Test-Path $komorebiOut)) { return -1 }
        @(Select-String -Path $komorebiOut -SimpleMatch 'ReloadStaticConfiguration' |
            Where-Object { $_.Line -like '*processed*' }).Count
    } catch { -1 }
}

function Get-RemovedRuleCount($OldCfg, $NewCfg) {
    <# komorebi's hot reload only ever ADDS rules: static_config.rs's populate_rules() pushes
       each rule "if not already present" and the rule lists (ignore/floating/manage/tray/
       layered/...) are never cleared (checked against the v0.1.41 source, and confirmed
       live 2026-09-23 -- a deleted Notepad float rule kept floating new Notepads after a
       reload). So what matters is whether any rule that WAS in komorebi.json is gone now.
       Every top-level array except `monitors` is a rule list; compare them entry by entry.
       Both files come from the same deterministic compiler, so a compressed-JSON string is
       a fair identity for each entry. #>
    if (-not $OldCfg) { return 0 }
    $removed = 0
    foreach ($p in $OldCfg.PSObject.Properties) {
        if ($p.Name -eq 'monitors' -or $p.Value -isnot [System.Array]) { continue }
        $newList = $NewCfg.PSObject.Properties[$p.Name]?.Value
        $newSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($e in @($newList)) { if ($null -ne $e) { [void]$newSet.Add(($e | ConvertTo-Json -Depth 20 -Compress)) } }
        foreach ($e in $p.Value) {
            if (-not $newSet.Contains(($e | ConvertTo-Json -Depth 20 -Compress))) { $removed++ }
        }
    }
    $removed
}

function Wait-KomorebiLauncher {
    <# After firing komorebi's autostart task: wait for Start-Komorebi.ps1 itself to finish
       -- not just for komorebi.exe to exist. Its own post-start steps (refocus the primary
       monitor to workspace 0, wallust borders, games unmanage) run ~8s after launch, and
       restoring layouts/focus before they're done would just get the refocus stamped over
       the top. Falls back to "komorebic state answers" if the launcher process can't be seen. #>
    $launcherSeen = $false
    try {
        $appear = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $appear) {
            if (@(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('Start-Komorebi.ps1') }).Count -gt 0) { $launcherSeen = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if ($launcherSeen) {
            $done = (Get-Date).AddSeconds(120)
            while ((Get-Date) -lt $done -and @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('Start-Komorebi.ps1') }).Count -gt 0) {
                Start-Sleep -Milliseconds 500
            }
        }
    } catch { $launcherSeen = $false }
    # Either way, don't return until komorebi actually answers.
    $ready = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $ready) {
        if (Get-Process komorebi -ErrorAction SilentlyContinue) {
            $null = & $komorebic state 2>&1
            if ($LASTEXITCODE -eq 0) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    $false
}

function Restore-Layouts($Snap) {
    $now = Get-LayoutSnapshot
    $columnFixes = [System.Collections.Generic.List[object]]::new()
    $restored = 0
    foreach ($mon in $Snap.Monitors) {
        $nowMon = $now.Monitors | Where-Object Index -eq $mon.Index
        foreach ($ws in $mon.Workspaces) {
            $nowWs = if ($nowMon) { $nowMon.Workspaces | Where-Object Index -eq $ws.Index }
            if (-not $nowWs -or $nowWs.Name -ne $ws.Name) {
                Write-Log "   monitor $($mon.Index) workspace $($ws.Index) ('$($ws.Name)') isn't where it was -- left alone."
                continue
            }
            if ($ws.Layout -and $nowWs.Layout -ne $ws.Layout) {
                $null = Invoke-Kc workspace-layout $mon.Index $ws.Index (ConvertTo-CliLayout $ws.Layout)
                Write-Log "   '$($ws.Name)': $($nowWs.Layout) -> $($ws.Layout) (restored)."
                $restored++
            }
            if ($ws.Layout -eq 'Scrolling' -and $ws.Columns -and $nowWs.Columns -ne $ws.Columns) {
                $columnFixes.Add([pscustomobject]@{ Monitor = $mon.Index; Workspace = $ws.Index; Name = $ws.Name; Columns = $ws.Columns })
            }
        }
    }
    if ($columnFixes.Count -gt 0) {
        # scrolling-layout-columns only touches the FOCUSED workspace: visit each one...
        foreach ($fix in $columnFixes) {
            $null = Invoke-Kc focus-monitor-workspace $fix.Monitor $fix.Workspace
            $null = Invoke-Kc scrolling-layout-columns $fix.Columns
            Write-Log "   '$($fix.Name)': scrolling columns -> $($fix.Columns) (restored)."
        }
        # ...then put every monitor we visited back on the workspace it was showing, the
        # originally-focused monitor last so it ends up with focus again.
        $visited = @($columnFixes.Monitor | Sort-Object -Unique)
        foreach ($m in @($visited | Where-Object { $_ -ne $Snap.FocusedMonitor }) + @($Snap.FocusedMonitor)) {
            $mon = $Snap.Monitors | Where-Object Index -eq $m
            if ($mon) { $null = Invoke-Kc focus-monitor-workspace $m $mon.FocusedWorkspace }
        }
    }
    if ($restored -eq 0 -and $columnFixes.Count -eq 0) { Write-Log '   nothing needed restoring.' }
}

$failed = $false
Write-Log '--- reload-stack (SUPER+Shift+R) ---'
$komorebiUp = [bool](Get-Process komorebi -ErrorAction SilentlyContinue) -and [bool]$komorebic

# --- 0. Snapshot live layouts -------------------------------------------------------------
$snapshot = $null
if ($komorebiUp) {
    try {
        $snapshot = Get-LayoutSnapshot
        Write-Log "0. layouts snapshotted ($(@($snapshot.Monitors.Workspaces).Count) workspaces)."
    } catch {
        Write-Log "0. couldn't snapshot layouts -- they won't be restored if komorebi reloads: $($_.Exception.Message)"
    }
}

# --- 1. Compile rules ---------------------------------------------------------------------
$config = Join-Path $Root 'config\komorebi\komorebi.json'
$hashBefore = if (Test-Path $config) { (Get-FileHash $config).Hash } else { '' }
$oldCfg = $null
if (Test-Path $config) { try { $oldCfg = Get-Content $config -Raw | ConvertFrom-Json } catch { } }
$reloadsBefore = Get-StaticReloadCount
try {
    & (Join-Path $Root 'tools\compile-komorebi-rules.ps1') *> $null
} catch {
    Write-Log "1. rule compile FAILED -- nothing reloaded: $($_.Exception.Message)"
    exit 1
}
$configChanged = (Test-Path $config) -and ((Get-FileHash $config).Hash -ne $hashBefore)
Write-Log ("1. rules compiled -- komorebi.json {0}." -f ($(if ($configChanged) { 'CHANGED (komorebi will reload it)' } else { 'unchanged (komorebi left alone)' })))

# --- 2. komorebi ----------------------------------------------------------------------------
$removedRules = 0
$komorebiRestarted = $false   # step 3 restarts YASB after a komorebi restart
if ($komorebiUp -and $configChanged) {
    try { $removedRules = Get-RemovedRuleCount $oldCfg (Get-Content $config -Raw | ConvertFrom-Json) }
    catch { Write-Log "   couldn't diff old/new rules ($($_.Exception.Message)) -- restarting komorebi to be safe."; $removedRules = 1 }
}

if ($komorebiUp -and $removedRules -gt 0) {
    # Rules were REMOVED -- komorebi's hot reload can't drop them, only a fresh komorebi
    # can. Clean `stop` (dumps its state file, so layout types come back on start), start it
    # through its own autostart task, wait for Start-Komorebi.ps1 to finish, then restore
    # anything still off (column counts don't survive a restart).
    Write-Log "2. $removedRules rule(s) removed -- komorebi only ever adds rules on reload, so restarting it."
    $komorebiRestarted = $true
    try {
        $null = Invoke-Kc stop
        $gone = (Get-Date).AddSeconds(10)
        while ((Get-Process komorebi -ErrorAction SilentlyContinue) -and (Get-Date) -lt $gone) { Start-Sleep -Milliseconds 200 }
        if (Get-Process komorebi -ErrorAction SilentlyContinue) { throw 'komorebi still running 10s after `komorebic stop`' }
        Write-Log '   komorebi stopped.'
    } catch {
        Write-Log "   couldn't stop komorebi cleanly -- left running with the old rules still live: $($_.Exception.Message)"
        $failed = $true
    }
    if (-not (Get-Process komorebi -ErrorAction SilentlyContinue)) {
        if (Start-AutostartTask 'komorebi') {
            if (Wait-KomorebiLauncher) {
                Write-Log '   komorebi back up (Start-Komorebi.ps1 finished).'
                if ($snapshot) {
                    try { Restore-Layouts $snapshot }
                    catch { Write-Log "   layout restore failed: $($_.Exception.Message)"; $failed = $true }
                }
            } else {
                Write-Log "   komorebi didn't come back within the wait -- see komorebi-autostart.log."
                $failed = $true
            }
        } else { $failed = $true }
    }
    if (Get-Process komorebi -ErrorAction SilentlyContinue) {
        try {
            & (Join-Path $Root 'tools\apply-wallust-outputs.ps1') -BordersOnly *> $null
            if ($LASTEXITCODE -eq 0) { Write-Log '   wallust borders re-applied.' }
            else { Write-Log "   border re-apply failed (apply-wallust-outputs.ps1 -BordersOnly exit $LASTEXITCODE)."; $failed = $true }
        } catch { Write-Log "   border re-apply threw: $($_.Exception.Message)"; $failed = $true }
    }
} elseif ($komorebiUp) {
    if ($configChanged) {
        if ($reloadsBefore -ge 0) {
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-StaticReloadCount) -le $reloadsBefore -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
            if ((Get-StaticReloadCount) -gt $reloadsBefore) {
                Write-Log '2. komorebi reloaded the new komorebi.json.'
            } else {
                Write-Log "2. komorebi did NOT log a reload of komorebi.json within 10s -- new rules may not be live (a komorebi stop/start would force it)."
                $failed = $true
            }
        } else {
            Write-Log "2. can't read komorebi.out.log to see komorebi's reload -- waiting 4s instead."
            Start-Sleep -Seconds 4
        }
        if ($snapshot) {
            try { Restore-Layouts $snapshot }
            catch { Write-Log "   layout restore failed: $($_.Exception.Message)"; $failed = $true }
        }
    } else {
        Write-Log '2. komorebi: config unchanged, no reload needed.'
    }
    try {
        & (Join-Path $Root 'tools\apply-wallust-outputs.ps1') -BordersOnly *> $null
        if ($LASTEXITCODE -eq 0) { Write-Log '   wallust borders re-applied.' }
        else { Write-Log "   border re-apply failed (apply-wallust-outputs.ps1 -BordersOnly exit $LASTEXITCODE)."; $failed = $true }
    } catch {
        # e.g. no wallust colors.json yet -- that script throws rather than exits.
        Write-Log "   border re-apply threw: $($_.Exception.Message)"
        $failed = $true
    }
} elseif (-not $komorebic) {
    Write-Log '2. komorebic.exe is nowhere to be found -- komorebi skipped.'
    $failed = $true
} else {
    Write-Log "2. komorebi wasn't running -- starting it (Start-Komorebi.ps1 re-applies borders once it's up)."
    $komorebiRestarted = $true
    if (-not (Start-AutostartTask 'komorebi')) { $failed = $true }
}

# --- 3. YASB: kill + restart, only when it has to ----------------------------------------------
$yasbReason = $null
if (-not (Get-Process yasb -ErrorAction SilentlyContinue)) {
    $yasbReason = 'not running'
} elseif ($komorebiRestarted) {
    $yasbReason = 'komorebi was restarted'
} else {
    $fingerprint = Join-Path $logDir 'yasb-config.sha256'
    if (-not (Test-Path $fingerprint)) {
        $yasbReason = 'no config.yaml fingerprint from its last start'
    } else {
        try {
            $now = (Get-FileHash (Join-Path $Root 'config\yasb\config.yaml') -Algorithm SHA256).Hash
            if ($now -ne (Get-Content $fingerprint -Raw).Trim()) { $yasbReason = 'config.yaml changed' }
        } catch { $yasbReason = "couldn't compare config.yaml ($($_.Exception.Message))" }
    }
}
if (-not $yasbReason) {
    Write-Log '3. YASB left running (config.yaml unchanged, komorebi not restarted).'
} elseif (Get-Process yasb -ErrorAction SilentlyContinue) {
    Write-Log "3. YASB restarting ($yasbReason)."
    Stop-Process -Name yasb -Force -ErrorAction SilentlyContinue
    # Start-Yasb.ps1 no-ops if it still sees a yasb process, so wait for the kill to land.
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Process yasb -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (Get-Process yasb -ErrorAction SilentlyContinue) {
        Write-Log '3. YASB still alive 5s after kill -- not restarting it.'
        $failed = $true
    } else {
        Write-Log '3. YASB stopped.'
    }
} else {
    Write-Log "3. YASB wasn't running."
}
if (-not (Get-Process yasb -ErrorAction SilentlyContinue)) {
    if (-not (Start-AutostartTask 'yasb')) { $failed = $true }
}

if ($failed) { Write-Log 'done, with failures (see above).'; exit 2 }
Write-Log 'done.'
exit 0
