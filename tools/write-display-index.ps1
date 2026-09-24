#Requires -Version 7.0
<#
.SYNOPSIS
  Writes config\komorebi\display-index.local.json -- which physical monitor is komorebi's
  monitor 0, 1, 2, 3 -- from a live `komorebic monitor-information` on this machine.

.DESCRIPTION
  Windows doesn't guarantee the order it lists monitors in, so komorebi's
  display_index_preferences pins each config index to a monitor's serial_number_id. The
  serials are this machine's real hardware, so the map is generated here, gitignored, and
  merged into komorebi.json by compile-komorebi-rules.ps1.

  komorebic can only answer while komorebi is running. Two callers:
    - install.ps1, every run: refreshes the map when komorebi is up (that's how a new
      monitor gets picked up); when it isn't, says so and leaves it to the next one.
    - scripts\Start-Komorebi.ps1, with -Compile, once komorebi is up and only if the file
      doesn't exist yet (a fresh install, or after uninstall): writes it and recompiles
      komorebi.json, which komorebi then hot-reloads.
  Moved here out of install.ps1 on 2026-09-24: on a fresh install komorebi had never run
  yet, so the install-time call always failed (komorebic panicked, "os error 10061" --
  nothing listening) and the map only appeared after a second install run.

  Never writes a guessed map, and any failure leaves an existing file alone. A monitor
  without a serial_number_id is left out of the map with a warning (same as before).

  Exit codes: 0 = written (and compiled, with -Compile); 2 = komorebi isn't running, so
  nothing was done; 1 = detection, the write or the compile failed.
#>
param([switch]$Compile)
$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent $PSScriptRoot
$target = Join-Path $Root 'config\komorebi\display-index.local.json'

if (-not (Get-Process komorebi -ErrorAction SilentlyContinue)) {
    Write-Host "komorebi isn't running, so there's nobody to ask about monitors yet."
    exit 2
}

# Where winget installs it (and the only place Start-Komorebi.ps1 looks); PATH as a
# fallback. Invoked directly and CommandNotFoundException caught, rather than a
# Get-Command check first -- Get-Command proved unreliable at finding a freshly PATH'd
# .exe when install.ps1's copy of this was built.
$komorebic = Join-Path $env:ProgramFiles 'komorebi\bin\komorebic.exe'
if (-not (Test-Path $komorebic)) { $komorebic = 'komorebic.exe' }
try {
    $raw = & $komorebic monitor-information 2>$null
} catch [System.Management.Automation.CommandNotFoundException] {
    Write-Warning "komorebic.exe not found (not in $env:ProgramFiles\komorebi\bin or on PATH)."
    exit 1
} catch {
    Write-Warning "komorebic.exe monitor-information failed: $($_.Exception.Message)"
    exit 1
}
if (-not $raw) {
    Write-Warning 'komorebic.exe monitor-information returned no output.'
    exit 1
}
try {
    $parsed = ($raw -join "`n") | ConvertFrom-Json
} catch {
    $dumpPath = Join-Path $env:TEMP 'monitor-information.raw.txt'
    ($raw -join "`n") | Set-Content -Path $dumpPath -Encoding UTF8
    Write-Warning "Couldn't parse komorebic.exe monitor-information as JSON. Raw output saved to $dumpPath."
    exit 1
}
$monitors = @($parsed)
if ($monitors.Count -eq 0) {
    Write-Warning 'komorebic.exe monitor-information reported zero monitors.'
    exit 1
}
if ($monitors.Count -gt 4) {
    Write-Warning "$($monitors.Count) monitors detected; this repo's design supports 4, using the first 4 in reported order."
    $monitors = $monitors[0..3]
}
$map = [ordered]@{}
for ($i = 0; $i -lt $monitors.Count; $i++) {
    $serial = $monitors[$i].serial_number_id
    if ([string]::IsNullOrWhiteSpace($serial)) {
        Write-Warning "Monitor index $i has no serial_number_id -- leaving it out (the map will be incomplete for this monitor)."
        continue
    }
    $map["$i"] = "$serial"
}
if ($map.Count -eq 0) {
    Write-Warning 'No monitor had a usable serial_number_id -- nothing to write.'
    exit 1
}

try {
    $map | ConvertTo-Json | Set-Content -Path $target -Encoding UTF8
} catch {
    Write-Warning "couldn't write ${target}: $($_.Exception.Message)"
    exit 1
}
Write-Host "Wrote $($map.Count) monitor(s) to $target"

if ($Compile) {
    # compile-komorebi-rules.ps1 throws on failure (after printing why) rather than
    # setting an exit code.
    try { & (Join-Path $PSScriptRoot 'compile-komorebi-rules.ps1') }
    catch { Write-Warning "komorebi.json recompile failed: $($_.Exception.Message)"; exit 1 }
}
exit 0
