#Requires -Version 7.0
<#
.SYNOPSIS
  Keeps config\komorebi\display-index.local.json -- which physical screen is screen 1, 2, 3,
  4 (komorebi's monitor 0-3) -- up to date from a live `komorebic monitor-information`.

.DESCRIPTION
  Windows doesn't guarantee the order it lists monitors in, so komorebi's
  display_index_preferences ties each config block (base.json's four screens) to a screen's
  identity. Those are this machine's real hardware, so the map is generated here, gitignored,
  and merged into komorebi.json by compile-komorebi-rules.ps1.

  A stable map (Group 1 #7): numbers already given are kept -- an unplugged screen keeps its
  number for when it's back; a connected screen the map doesn't have takes the lowest free one;
  four at most. A screen is identified by its serial_number_id, or its device_id when it has no
  serial or shares it with another connected screen. The rules live in tools\lib\monitors.ps1
  (doctor reads the same ones). Nothing changed = the file isn't touched at all.

  komorebic can only answer while komorebi is running. Two callers:
    - install.ps1's monitors step, every run: adds a screen that's new since (komorebi up);
      when komorebi isn't running, says so and leaves it to the next one.
    - scripts\Start-Komorebi.ps1, with -Compile, once komorebi is up and only if the file
      doesn't exist yet (a fresh install, or after uninstall): writes it and recompiles
      komorebi.json, which komorebi then hot-reloads.

  Never writes a guessed map, and any failure leaves an existing file alone. The identities are
  hardware identifiers: counted, never printed.

  Exit codes: 0 = up to date (written, or already right; compiled with -Compile); 2 = komorebi
  isn't running, so nothing was done; 1 = detection, the write or the compile failed.
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
    # %TEMP% as text, not the expanded path: that one carries the Windows user name.
    Write-Warning "Couldn't parse komorebic.exe monitor-information as JSON. Raw output saved to %TEMP%\monitor-information.raw.txt."
    exit 1
}
$monitors = @($parsed)
if ($monitors.Count -eq 0) {
    Write-Warning 'komorebic.exe monitor-information reported zero monitors.'
    exit 1
}
. (Join-Path $PSScriptRoot 'lib\monitors.ps1')
try { $old = Read-DisplayIndexMap -Path $target }
catch {
    # A broken file is replaced by a fresh map (nothing in it could be kept anyway).
    Write-Warning "$($_.Exception.Message) -- writing a fresh one."
    $old = $null
}
$r = Update-DisplayIndexMap -Map $old -Monitors $monitors
if ($r.NoId) { Write-Warning "$($r.NoId) screen(s) report neither a serial nor a device_id -- left out of the map." }
if ($r.Beyond) { Write-Warning "$($r.Beyond) screen(s) beyond the 4 this repo maps -- they run on komorebi's defaults (one workspace, no config)." }
if ($r.Map.Count -eq 0) {
    Write-Warning 'No screen could be identified -- nothing to write.'
    exit 1
}
$same = $old -and ((ConvertTo-Json $old -Compress) -eq (ConvertTo-Json $r.Map -Compress))
if ($same) {
    Write-Host "Screen map up to date ($($r.Map.Count) screen(s); unchanged)"
} else {
    try {
        $r.Map | ConvertTo-Json | Set-Content -Path $target -Encoding UTF8
    } catch {
        Write-Warning "couldn't write ${target}: $($_.Exception.Message)"
        exit 1
    }
    $what = if (-not $old) { "$($r.Map.Count) screen(s) mapped" } else { "screen(s) $(($r.Added | ForEach-Object { $_ + 1 }) -join ', ') added; the others kept their numbers" }
    Write-Host "Wrote config\komorebi\display-index.local.json: $what"
}

if ($Compile) {
    # compile-komorebi-rules.ps1 throws on failure (after printing why) rather than
    # setting an exit code.
    try { & (Join-Path $PSScriptRoot 'compile-komorebi-rules.ps1') }
    catch { Write-Warning "komorebi.json recompile failed: $($_.Exception.Message)"; exit 1 }
}
exit 0
