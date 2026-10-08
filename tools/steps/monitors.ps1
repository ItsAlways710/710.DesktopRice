<#
.SYNOPSIS
  install's monitors step: which physical screen is screen 1-4 -- config\komorebi\
  display-index.local.json, written by tools\write-display-index.ps1 by the rules in
  tools\lib\monitors.ps1 (only while komorebi runs; komorebi's launcher writes it the first time
  otherwise) -- and doctor's display-index line. Uninstall deletes the file in its section 9.
  Loaded by tools\lib\activation.ps1. Only functions.

  The map (komorebi's display_index_preferences) is keyed by serial_number_id, which komorebi's
  own docs (multi-monitor-setup.md) recommend for this key, or the device_id when a screen has no
  serial or shares it. winarchy writes a live, device_id-keyed copy from its window-slots daemon
  instead; that daemon's port was dropped from this repo (Group 1 #7).
#>

# --- install's step -------------------------------------------------------------------------------
function Install-MonitorsStep {
    # --- 5. Monitor identity (display_index_preferences) ----------------------------------
    # komorebic can only report monitors while komorebi is running, so on a fresh install
    # (komorebi never started yet) this can't work -- scripts\Start-Komorebi.ps1 writes the
    # file itself the first time komorebi comes up and it's missing. Here it's a refresh:
    # re-running install.ps1 while komorebi is up picks up a monitor change.
    Write-Host "`n-- Monitor identity (display_index_preferences) --" -ForegroundColor Cyan
    try { & (Join-Path $Root 'tools\write-display-index.ps1') }
    catch { Write-Warning $_.Exception.Message; $global:LASTEXITCODE = 1 }
    switch ($LASTEXITCODE) {
        0       { Step-Ok 'Monitor order pinned (display-index.local.json)' }
        2       { Step-Info "komorebi isn't running yet -- it writes this itself the first time it starts." }
        default { Step-Warn "Monitor order not written (see above) -- komorebi.json will omit display_index_preferences; komorebi falls back to Windows' own monitor order." }
    }
}

# --- Doctor's check: the display-index line in Generated configs ---------------------------------
# Monitor serials are never printed -- counts only (a serial is a hardware identifier; one was
# scrubbed from this repo's history).
function Test-DoctorDisplayIndex {
    # display-index.local.json: which physical screen is screen 1, 2, 3, 4 (komorebi's 0-3).
    # A stable map (Group 1 #7, tools\lib\monitors.ps1 -- the writer's own rules): numbers are
    # kept, a new screen takes the next free one, so the monitors step can always be run safely
    # to add one -- hence [XX] for a connected screen the map doesn't have. A screen in the map
    # but not connected is normal (a laptop off its dock). A fifth screen has no number to take:
    # a plain fact. The connected screens can only be compared while komorebi runs.
    if (-not (Get-Command Update-DisplayIndexMap -ErrorAction SilentlyContinue)) { . (Join-Path $Root 'tools\lib\monitors.ps1') }
    $file = Join-Path $Root 'config\komorebi\display-index.local.json'
    $fix  = @{ Fix = '710sRice install -Only monitors, then 710sRice reload'; Step = 'monitors' }
    $running = [bool](Get-Process komorebi -ErrorAction SilentlyContinue)
    # A broken file (unreadable / empty): the monitors step can only rewrite it while komorebi
    # runs, and komorebi's launcher only writes one that's MISSING -- so with komorebi down,
    # nothing can fix it until the stack is started.
    $broken = if ($running) { $fix + @{ Repair = 'reload' } }
              else { @{ Fix = '710sRice start, then 710sRice doctor -repair'; NeedsYou = $true } }
    if (-not (Test-Path -LiteralPath $file)) {
        if ($running) { return New-DoctorResult -Id 'display-index' -Status 'XX' -Text 'display-index.local.json is missing' @fix -Repair 'reload' }
        return New-DoctorResult -Id 'display-index' -Status '..' -Text 'display-index.local.json not written yet -- komorebi writes it when it next starts'
    }
    try { $map = Read-DisplayIndexMap -Path $file }
    catch {
        $why = if ("$($_.Exception.Message)" -match 'empty') { 'is empty' } else { "isn't valid ($($_.Exception.Message -replace '^display-index\.local\.json ', ''))" }
        return New-DoctorResult -Id 'display-index' -Status 'XX' -Text "display-index.local.json $why" @broken
    }
    if (-not $map -or -not $map.Count) { return New-DoctorResult -Id 'display-index' -Status 'XX' -Text 'display-index.local.json is empty' @broken }
    if (-not $running) {
        return New-DoctorResult -Id 'display-index' -Status 'OK' -Text "display-index.local.json: $(Get-DoctorPlural $map.Count 'screen' 'screens') mapped (komorebi isn't running -- not compared)"
    }
    $kc = Get-DoctorKomorebic
    if (-not $kc) { return New-DoctorResult -Id 'display-index' -Status '!!' -Text "display-index.local.json -- couldn't check (komorebic.exe not found)" }
    $raw = @(& $kc monitor-information 2>$null) -join "`n"
    if (-not $raw.Trim()) { return New-DoctorResult -Id 'display-index' -Status '!!' -Text "display-index.local.json -- couldn't check (komorebic monitor-information said nothing)" }
    $connected = @($raw | ConvertFrom-Json)
    $r = Update-DisplayIndexMap -Map $map -Monitors $connected
    if ($r.Added.Count) {
        New-DoctorResult -Id 'display-index' -Status 'XX' -Text "display-index.local.json doesn't have $($r.Added.Count) of the $($connected.Count) connected screens (it would give $(if ($r.Added.Count -eq 1) { 'it number' } else { 'them numbers' }) $(($r.Added | ForEach-Object { $_ + 1 }) -join ', '); the others keep theirs)" @fix -Repair 'reload'
    } else {
        $which = switch ($connected.Count) { 1 { 'the connected screen' } 2 { 'both connected screens' } default { "all $($connected.Count) connected screens" } }
        $which = if ($r.Beyond -or $r.NoId) { "$($connected.Count - $r.Beyond - $r.NoId) of the $($connected.Count) connected screens" } else { $which }
        New-DoctorResult -Id 'display-index' -Status 'OK' -Text "display-index.local.json: $which mapped"
    }
    if ($r.Beyond) {
        New-DoctorResult -Id 'display-index-more' -Status '..' -Text "$(Get-DoctorPlural $r.Beyond 'screen' 'screens') beyond the 4 this repo maps -- komorebi runs $(if ($r.Beyond -eq 1) { 'it' } else { 'them' }) on its defaults (one workspace)"
    }
}
