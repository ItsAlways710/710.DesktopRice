#Requires -Version 7.0
<#
.SYNOPSIS
    The wallpaper pipeline: makes the palette with the chosen palette profile and themes
    everything from it -- the bar, the menus, the prompt, Flow, komorebi's borders and stack
    tabs, Windows' accent and Windows Terminal.

.DESCRIPTION
    YASB's Wallpapers widget runs this after every wallpaper change (config\yasb\config.yaml's
    run_after, with -Image {image}); so do install's theme and palette steps, a profile switch
    (tools\palette-profiles.ps1, -Reapply), and -- for komorebi's colours alone -- every komorebi
    start (scripts\Start-Komorebi.ps1) and SUPER+Shift+R (tools\reload-stack.ps1). The name
    predates Palette Profiles; every caller, and every bar still holding its old two
    run_after lines, keeps working because it didn't change.

    What happens (the how: tools\lib\palette.ps1; the why: claude/palette-profiles-plan.md):
      1. One run at a time (a wallpaper change and a profile switch can meet).
      2. The chosen profile (Default when nothing's chosen, or when the chosen one is gone).
      3. The palette: wallust with the profile's source, -s and one dump template -- or, for a
         run that doesn't change the wallpaper (-Reapply), the last good palette when it came
         from the same source and wallpaper. wallust FAILS -> nothing is touched: the last
         good palette and everything on screen stay, palette-status.json says why (doctor
         shows it), 710.ahk gets a toast, exit 1.
      4. Every colour resolved (pure -- a broken profile stops here, nothing written).
      5. Each target applied in order; one failing doesn't stop the rest (exit 2).
      6. Wallpaper changes only: the lock-screen sync task is fired.
      7. Only when every target applied: the theme stamp (theme-inputs.sha256) that
         `710sRice doctor` compares with the repo and the chosen profile.

    Exit codes: 0 themed; 1 nothing changed (no palette, a broken profile, another run held
    the lock for 90 s; -BordersOnly: komorebi isn't running); 2 themed, but a target failed.

.PARAMETER Image
    The wallpaper YASB just set. Left out: the one that's up now (the registry).
.PARAMETER Reapply
    No wallpaper change -- a profile was chosen or saved. Reuses the last good palette when the
    profile's source and the wallpaper are the ones it came from; the lock screen is left alone.
.PARAMETER ProfileId
    Theme with this profile instead of the chosen one, and make it the chosen one if that
    works (a profile switch: the old choice stays when wallust can't make the new palette).
.PARAMETER BordersOnly
    Re-push komorebi's borders and stack tabs only (runtime-only state: komorebi starts on its
    own blue borders). From the last good palette; with none yet, a full -Reapply instead.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Image,
    [switch]$Reapply,
    [string]$ProfileId,
    [switch]$BordersOnly
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'tools\lib\palette.ps1')

function Write-Line {
    param([string]$Status, [string]$Text)
    $color = switch ($Status) { 'OK' { 'Green' } '!!' { 'Yellow' } 'XX' { 'Red' } default { 'Gray' } }
    Write-Host "  [$Status] " -ForegroundColor $color -NoNewline
    Write-Host (ConvertTo-PaletteSafeText $Text)
}

$lock = Enter-PaletteLock -TimeoutSec 90
if (-not $lock) {
    Write-Line 'XX' 'Another theme run is still going after 90 s -- nothing changed.'
    Write-PaletteLog 'gave up: another theme run held the lock for 90 s'
    exit 1
}
try {
    $mode = if ($BordersOnly) { 'borders' } elseif ($Reapply -or $ProfileId) { 'reapply' } else { 'full' }

    # --- 2. the profile ---------------------------------------------------------------------
    if ($ProfileId) {
        $id = ConvertTo-PaletteProfileId $ProfileId
        if (-not $id) { Write-Line 'XX' "No palette profile '$ProfileId' (default, 0-9, or a profile's name)."; exit 1 }
        try { $active = [pscustomobject]@{ Id = $id; Profile = (Read-PaletteProfile -Id $id); Warning = $null } }
        catch { Write-Line 'XX' "$($_.Exception.Message) -- nothing changed."; exit 1 }
    } else {
        try { $active = Resolve-ActivePaletteProfile }
        catch { Write-Line 'XX' "The Default profile can't be read: $($_.Exception.Message)"; Write-PaletteLog "Default unreadable: $($_.Exception.Message)"; exit 1 }
    }
    $profileLabel = Get-PaletteProfileLabel -Id $active.Id -Name $active.Profile.name
    $source = $active.Profile.source
    $key = Get-PaletteSourceKey -Source $source
    Write-PaletteLog -Start "--- $mode run: $profileLabel ($(Get-PaletteSourceSummary -Source $source))"
    if ($active.Warning) { Write-Line '!!' $active.Warning; Write-PaletteLog $active.Warning }

    # --- 3. the palette ---------------------------------------------------------------------
    $last = Read-PaletteLastGood
    $palette = $null
    if ($mode -eq 'borders' -and $last) {
        $palette = $last.Palette
    } else {
        if ($mode -eq 'borders') { $mode = 'reapply'; Write-PaletteLog 'no palette made yet -- a full re-theme instead of borders only' }
        if (-not $Image) { $Image = Get-PaletteCurrentWallpaper }
        $usesImage = Test-PaletteSourceUsesImage -Source $source
        $reuse = $mode -eq 'reapply' -and $last -and $last.SourceKey -eq $key -and $source.kind -ne 'random' -and
                 (-not $usesImage -or ($last.Image -eq "$Image" -and $last.ImageStamp -eq (Get-PaletteImageStamp $Image)))
        # A random theme is new on every wallpaper change, but a profile save / switch keeps the one it has.
        if ($mode -eq 'reapply' -and $last -and $source.kind -eq 'random' -and $last.SourceKey -eq $key) { $reuse = $true }
        if ($reuse) {
            $palette = $last.Palette
            Write-PaletteLog 'palette: the last one (same source and wallpaper)'
        } else {
            # The dump config (config\wallust\wallust.toml) is generated per clone; a stale one --
            # a pull brought a new template -- is rewritten first (quietly; exit 0 = current).
            & (Join-Path $Root 'tools\write-wallust-config.ps1') 6>$null 3>$null | Out-Null
            $imageName = if ($Image) { Split-Path -Leaf $Image } else { '' }
            try {
                $palette = Get-PaletteFromSource -Source $source -Image $Image -ConfigDir (Join-Path $Root 'config\wallust') `
                    -DumpPath (Join-Path (Get-PaletteGeneratedDir) 'palette.next.json')
                Save-PaletteLastGood -Palette $palette -SourceKey $key -Image $Image
                Write-PaletteLog "palette made$(if ($imageName) { " from $imageName" })"
            } catch {
                $why = ConvertTo-PaletteSafeText $_.Exception.Message
                $what = if ($usesImage -and $imageName) { "from $imageName" } else { "($(Get-PaletteSourceSummary -Source $source))" }
                Write-Line 'XX' "Couldn't make a palette $what -- $why"
                Write-Line '..' "Nothing changed: the theme on screen is the last good one."
                Write-PaletteLog "FAILED: $why -- kept the last good palette, nothing changed"
                Set-PaletteStatus -Ok $false -Reason $why -Image $Image -ProfileId $active.Id
                $null = Send-PaletteAhkMessage -Name '710sRice.PaletteFailed'
                exit 1
            }
        }
    }

    # --- 4. every colour --------------------------------------------------------------------
    try { $theme = Resolve-PaletteTheme -Profile $active.Profile -Palette $palette }
    catch {
        $why = ConvertTo-PaletteSafeText "$profileLabel`: $($_.Exception.Message)"
        Write-Line 'XX' "$why -- nothing changed."
        Write-PaletteLog "FAILED to resolve: $why"
        if ($mode -ne 'borders') { Set-PaletteStatus -Ok $false -Reason $why -Image $Image -ProfileId $active.Id }
        exit 1
    }

    # --- 5. the targets -----------------------------------------------------------------------
    if ($mode -eq 'borders') {
        $r = @(Invoke-PaletteTargets -Theme $theme -Mode 'borders' -Only 'komorebi')
        $r | ForEach-Object { Write-PaletteLog "  $($_.Status): $($_.Message)" }
        if ($r.Count -and $r[0].Status -eq 'ok') { Write-Host 'Borders and stack tabs re-applied to komorebi.'; exit 0 }
        if ($r.Count -and $r[0].Status -eq 'off') { Write-Host 'komorebi is off in this palette profile -- left alone.'; exit 0 }
        Write-Host "$(if ($r.Count) { $r[0].Message } else { 'no komorebi target' })"
        exit 1
    }

    $where = if ($Image -and (Test-PaletteSourceUsesImage -Source $source)) { " from $(Split-Path -Leaf $Image)" } else { '' }
    Write-Host "Palette: $profileLabel -- $(Get-PaletteSourceSummary -Source $source)$where"
    $results = @(Invoke-PaletteTargets -Theme $theme -Mode $mode)
    foreach ($r in $results) {
        Write-PaletteLog "  $($r.Status): $($r.Message)"
        switch ($r.Status) {
            'ok'      { Write-Line 'OK' $r.Message }
            'skipped' { Write-Line '..' $r.Message }
            'off'     { Write-Line '..' "$($r.Label): off in this profile" }
            default   { Write-Line 'XX' $r.Message }
        }
    }
    $failed = @($results | Where-Object Status -eq 'failed')

    # --- 6. the lock screen (a wallpaper change only) -------------------------------------------
    # Fires the elevated on-demand task (Register-LockScreenSyncTask) -- Task Scheduler elevates
    # it, so this needs no admin. A machine that never registered it: a quiet no-op.
    # `$null = ... 2>&1`, not `*> $null`: the latter leaks schtasks' "ERROR:" text.
    if ($mode -eq 'full') {
        $lockScreenTask = '\710.DesktopRice\lock-screen-sync'
        $null = & schtasks.exe /Query /TN $lockScreenTask 2>&1
        if ($LASTEXITCODE -eq 0) { $null = & schtasks.exe /Run /TN $lockScreenTask 2>&1 }
    }

    # --- 7. choice + stamp --------------------------------------------------------------------
    if ($ProfileId -and $active.Id -ne (Get-ActivePaletteProfileId)) {
        Set-ActivePaletteProfileId -Id $active.Id
        Write-PaletteLog "chosen profile is now $profileLabel"
    }
    if ($failed.Count) {
        # No stamp: doctor keeps saying the theme isn't current until a run applies everything.
        Set-PaletteStatus -Ok $false -Stage 'targets' -Reason (($failed | ForEach-Object Message) -join '; ') -Image $Image -ProfileId $active.Id
        exit 2
    }
    Write-PaletteThemeStamp -ProfileId $active.Id
    Set-PaletteStatus -Ok $true -ProfileId $active.Id
    exit 0
} finally {
    Exit-PaletteLock $lock
}
