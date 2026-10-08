<#
.SYNOPSIS
  install's theme and palette steps: the default wallpaper and everything themed from it (theme:
  every plain run) and the current wallpaper's colours made again (palette: named only -- doctor's
  fix for a stale or missing theme). Both run the wallpaper pipeline, tools\apply-wallust-outputs.ps1
  (wallust, then every palette target: tools\palette\targets\). What uninstall puts back of it in
  its section 3: the wallpaper, the Windows accent, Flow's theme (Windows Terminal's colours: the
  terminal component; the lock screen: tools\lib\lockscreen.ps1; the generated palette files:
  section 9). Doctor's theme lines. Loaded by tools\lib\activation.ps1. Only functions.
#>

# --- install's steps ------------------------------------------------------------------------------
function Install-ThemeStep {
    param([bool]$OnlyRun)
    $wallustExe = Get-WallustExe
    # --- 4. Default theme (wallpaper + everything themed from it) -------------------------
    # EVERY run, no "already themed?" check (user's call, 2026-09-23 -- the old check skipped
    # this whenever the current wallpaper came from assets\wallpapers, which could leave e.g.
    # Windows Terminal on whatever uninstall had restored it to). Sets
    # assets\wallpapers\710Default001.png as the desktop wallpaper and runs the exact same
    # wallpaper pipeline (tools\apply-wallust-outputs.ps1) YASB's Wallpapers widget runs on every
    # real wallpaper change (see config\yasb\config.yaml's run_after) -- so komorebi borders, the
    # Windows accent color, Windows Terminal and your lock-screen picture all end up themed to
    # it too, via the one real code path rather than a second, parallel "first theme"
    # implementation.
    Write-Host "`n-- Default theme --" -ForegroundColor Cyan
    $defaultWallpaper = Join-Path $Root 'assets\wallpapers\710Default001.png'

    if (-not (Test-Path $defaultWallpaper)) {
        Step-Warn "Default wallpaper not found at $(ConvertTo-SafePath $defaultWallpaper) -- skipping the default theme."
    } elseif (-not (Test-Path $wallustExe) -or -not (Test-Path (Join-Path $Root 'config\wallust\wallust.toml'))) {
        # The wallust step installs both; -Only theme on its own can find them missing.
        Step-Warn "wallust isn't set up (no wallust.exe or wallust.toml) -- skipping the default theme.$(if ($OnlyRun) { ' Add the wallust step: 710sRice install -Only wallust,theme' })"
    } else {
        try {
            # One-time snapshot of whatever wallpaper was here before -- Set-DesktopWallpaper
            # below is about to overwrite it, and uninstall.ps1's Restore-OriginalWallpaper
            # needs this to put the real original back, not just delete our own value (both in
            # tools\lib\wallpaper.ps1).
            Save-OriginalWallpaper
            Set-DesktopWallpaper -Path $defaultWallpaper
            Step-Ok "Desktop wallpaper set to $(ConvertTo-SafePath $defaultWallpaper)"

            # The wallpaper pipeline itself, in-process (install already needs PS7), with the
            # chosen palette profile -- Default on a fresh install. It prints what it themed
            # (komorebi only if it's up), the lock screen included.
            & (Join-Path $Root 'tools\apply-wallust-outputs.ps1') -Image $defaultWallpaper
            switch ($LASTEXITCODE) {
                0       { Step-Ok 'Default wallpaper themed (details above).' }
                2       { Step-Warn 'Default wallpaper themed, but not everything took (see above) -- 710sRice doctor says what.' }
                default { Step-Warn "The default wallpaper is up, but its theme wasn't applied (see above)." }
            }
        } catch {
            Step-Warn "Could not apply the default theme: $($_.Exception.Message)"
        }
    }
}

function Install-PaletteStep {
    $wallustExe = Get-WallustExe
    # --- palette: the current wallpaper's colours, re-applied (named-only) ---------------
    # The opposite of theme: no wallpaper change. Runs exactly what YASB's wallpaper widget
    # runs after every change (the pipeline, config\yasb\config.yaml's run_after) on the
    # wallpaper that's up now (Get-CurrentWallpaper -- the value Set-LockScreen.ps1 reads).
    # Same image, same profile, same palette (wallust caches it per image), so on a healthy
    # machine nothing visibly changes -- it's the fix for missing or stale theme files (the
    # bar's and menus' colours, the prompt, Flow's theme, Terminal's scheme). It never falls
    # back to the default wallpaper: that's the theme step, the reset.
    Write-Host "`n-- Palette (current wallpaper) --" -ForegroundColor Cyan
    $currentWallpaper = Get-CurrentWallpaper
    if (-not $currentWallpaper -or -not (Test-Path -LiteralPath $currentWallpaper)) {
        Step-Warn "The current wallpaper ($(if ($currentWallpaper) { ConvertTo-SafePath $currentWallpaper } else { 'none set' })) is gone -- pick one with SUPER+W; that re-themes everything from it."
    } elseif (-not (Test-Path $wallustExe) -or -not (Test-Path (Join-Path $Root 'config\wallust\wallust.toml'))) {
        Step-Warn "wallust isn't set up (no wallust.exe or wallust.toml) -- add the wallust step: 710sRice install -Only wallust,palette"
    } else {
        try {
            & (Join-Path $Root 'tools\apply-wallust-outputs.ps1') -Image $currentWallpaper
            switch ($LASTEXITCODE) {
                0       { Step-Ok "Palette re-applied from the current wallpaper ($(Split-Path -Leaf $currentWallpaper)) -- details above." }
                2       { Step-Warn 'Palette re-applied, but not everything took (see above) -- 710sRice doctor says what.' }
                default { Step-Warn "Palette not re-applied (see above) -- the theme on screen is unchanged." }
            }
        } catch {
            Step-Warn "Could not re-apply the palette: $($_.Exception.Message)"
        }
    }
}

# --- Restoring theming side effects (wallpaper/accent/Flow) -- uninstall-only ------------
# The wallpaper/lock-screen restore functions live next to what they revert
# (Restore-OriginalWallpaper in tools\lib\wallpaper.ps1, Restore-LockScreenPicture in
# tools\lib\lockscreen.ps1). These two cover the rest of what the theme step and
# tools\apply-wallust-outputs.ps1 change on a real wallpaper/theme apply, plus Flow
# Launcher's theme -- both called from uninstall.ps1 (Undo-WindowsAccent, Undo-FlowTheme, below).
# (Windows Terminal's and Flow's own settings are their components': tools\components\terminal.ps1,
# flow.ps1.)
function Restore-WindowsAccent {
    <# Reverts the accent-color/dark-mode values tools\apply-wallust-outputs.ps1 sets,
       back to its own 'windows-accent' snapshot (taken there, via a small duplicated
       inline copy of Save-OriginalState/Get-RegValueSnapshot -- see that script on why it
       doesn't dot-source the install-side libraries). $null means that script
       never actually ran on this machine -- safe no-op. #>
    $snap = Get-OriginalState -Label 'windows-accent'
    if (-not $snap) { return $false }
    $personalize = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $dwm = 'HKCU:\SOFTWARE\Microsoft\Windows\DWM'
    Set-RegValueFromSnapshot -Path $personalize -Name 'AppsUseLightTheme' -Snapshot $snap.Personalize_AppsUseLightTheme
    Set-RegValueFromSnapshot -Path $personalize -Name 'SystemUsesLightTheme' -Snapshot $snap.Personalize_SystemUsesLightTheme
    Set-RegValueFromSnapshot -Path $personalize -Name 'ColorPrevalence' -Snapshot $snap.Personalize_ColorPrevalence
    Set-RegValueFromSnapshot -Path $dwm -Name 'ColorPrevalence' -Snapshot $snap.Dwm_ColorPrevalence
    Set-RegValueFromSnapshot -Path $dwm -Name 'AccentColor' -Snapshot $snap.Dwm_AccentColor
    Set-RegValueFromSnapshot -Path $dwm -Name 'ColorizationColor' -Snapshot $snap.Dwm_ColorizationColor
    Send-SettingChangeBroadcast
    Remove-OriginalState -Label 'windows-accent'
    return $true
}

function Restore-FlowTheme {
    <# Undoes the palette pipeline's Flow target (tools\palette\targets\flow.ps1): Flow's selected
       theme goes back to what it was before (the 'flow-theme' snapshot) and our 710sRice.xaml is
       deleted. Only while Flow is still on ours -- a theme you picked yourself since stays. The
       old theme comes back only if its file still exists (Flow shows an error box at start for a
       theme it can't find -- winarchy's Winarchy.xaml, say, once that's gone); otherwise the key
       goes and Flow uses its own default. Flow is stopped first and NOT relaunched, as in
       the flow component's uninstall (tools\components\flow.ps1). $false when there was nothing
       to undo. #>
    $snap = Get-OriginalState -Label 'flow-theme'
    $flowRoot = Join-Path $env:APPDATA 'FlowLauncher'
    $xaml = Join-Path $flowRoot 'Themes\710sRice.xaml'
    if (-not $snap -and -not (Test-Path -LiteralPath $xaml)) { return $false }
    $flow = @(Get-Process -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)
    if ($flow.Count) {
        $flow | Stop-Process -Force
        $flow | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
    }
    $settingsPath = Join-Path $flowRoot 'Settings\Settings.json'
    if ($snap -and (Test-Path -LiteralPath $settingsPath)) {
        $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ("$($settings['Theme'])" -eq '710sRice') {
            $old = "$($snap.Theme)"
            $oldThere = $old -and (@(Join-Path $flowRoot "Themes\$old.xaml") + @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'FlowLauncher\app-*\Themes') -Filter "$old.xaml" -File -ErrorAction SilentlyContinue | ForEach-Object FullName) |
                        Where-Object { Test-Path -LiteralPath $_ }).Count
            if ($snap.ThemeExisted -and $oldThere) { $settings['Theme'] = $old } else { $settings.Remove('Theme') }
            $settings | ConvertTo-Json -Depth 50 | Set-Content -Path $settingsPath -Encoding UTF8
        }
    }
    Remove-Item -LiteralPath $xaml -Force -ErrorAction SilentlyContinue
    Remove-OriginalState -Label 'flow-theme'
    $true
}

function Undo-Wallpaper {
    # uninstall, section 3: the desktop wallpaper you had before 710sRice first set its default
    # (Restore-OriginalWallpaper, tools\lib\wallpaper.ps1), and a line saying how that went.
    if (Restore-OriginalWallpaper) { Step-Ok 'Desktop wallpaper restored to whatever it was before this repo ever set a default' }
    else { Step-Info 'This repo never actually changed the wallpaper on this machine (already using one of its own) -- nothing to restore.' }
}

function Undo-WindowsAccent {
    # uninstall, section 3: the accent colour and light / dark settings as they were (Restore-WindowsAccent),
    # and a line saying how that went.
    if (Restore-WindowsAccent) { Step-Ok 'Windows accent color and light/dark-mode settings restored' }
    else { Step-Info 'tools\apply-wallust-outputs.ps1 never actually ran on this machine -- nothing to restore.' }
}

function Undo-FlowTheme {
    # uninstall, section 3: Flow Launcher's own theme back (Restore-FlowTheme), and a line saying how
    # that went.
    if (Restore-FlowTheme) { Step-Ok "Flow Launcher's theme put back and 710sRice.xaml removed" }
    else { Step-Info 'Flow Launcher was never themed by the palette -- nothing to restore.' }
}

# --- Doctor's checks: the theme lines in Generated configs, Flow's in Integrations ----------------
# (doctor.ps1 loads tools\lib\palette.ps1 for these: the chosen profile and its targets, read the
# way the wallpaper pipeline reads them.)

function Get-DoctorShownPath {
    # A file as the report names it: repo-relative inside the clone, else ConvertTo-SafePath.
    param([string]$Path)
    if ($Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($Root.Length).TrimStart('\', '/') }
    ConvertTo-SafePath $Path
}

function Test-DoctorPaletteProfile {
    # The chosen palette profile (SUPER+Alt+Space > Palette profiles, 710sRice palette use),
    # usable or not. A chosen profile that's gone or broken is still themed -- with Default,
    # the pipeline's fallback -- so it's [!!]: the choice is yours to fix, repair never
    # changes it. Broken profiles nobody chose are just noted.
    $chosen = Get-ActivePaletteProfileId
    $active = Resolve-ActivePaletteProfile
    $all = @(Get-PaletteProfiles)
    if ($chosen -ne $active.Id) {
        $chosenLabel = ($all | Where-Object Id -eq $chosen | Select-Object -First 1).Label
        New-DoctorResult -Id 'palette-profile' -Status '!!' -Text "Palette profile: $chosenLabel is chosen but can't be used -- Default is used instead" `
            -Detail @("$($active.Warning -replace ' -- using Default$', '')") -Fix "710sRice palette use default (or fix it in SUPER+Alt+Space > Palette profiles > Edit)"
    } else {
        $p = $all | Where-Object Id -eq $active.Id | Select-Object -First 1
        New-DoctorResult -Id 'palette-profile' -Status 'OK' -Text "Palette profile: $($p.Label) ($(Get-PaletteSourceSummary -Source $active.Profile.source))"
    }
    foreach ($b in $all | Where-Object { $_.Exists -and $_.Error -and $_.Id -ne $chosen }) {
        New-DoctorResult -Id "palette-profile:$($b.Id)" -Status '..' -Text "$($b.Label) can't be used: $($b.Error -replace '^[^:]+: ', '')"
    }
}

function Test-DoctorThemeFiles {
    # What the wallpaper pipeline (tools\apply-wallust-outputs.ps1) leaves behind: the palette it
    # made last (config\wallust\generated\palette.json -- the one kept when wallust fails) and
    # every file the chosen palette profile's file targets write (the bar's and menus' colours,
    # colors.json, the prompt, Flow's theme). Made again from the current wallpaper by the palette
    # step, which never changes the wallpaper itself.
    $active = Resolve-ActivePaletteProfile
    $problems = @(); $names = @()
    if (-not (Read-PaletteLastGood)) { $problems += 'no palette made yet (config\wallust\generated\palette.json)' }
    foreach ($t in Get-PaletteTargets) {
        if (-not $t.Template -or -not $t.Output -or $t.Id -in $active.Profile.off) { continue }
        $path = & $t.Output
        if (-not $path) { continue }
        $names += $t.Label
        if (-not (Test-Path -LiteralPath $path)) { $problems += "$($t.Label): $(Get-DoctorShownPath $path) is missing" }
    }
    if ($problems.Count) {
        return New-DoctorResult -Id 'theme-files' -Status 'XX' -Text "Theme files: $($problems -join '; ')" -Fix '710sRice install -Only palette' -Step 'palette'
    }
    New-DoctorResult -Id 'theme-files' -Status 'OK' -Text "Theme files: the palette, $($names -join ', ')"
}

function Test-DoctorThemeInputs {
    # The theme on screen made from what's in the repo now, with the profile chosen now. The
    # pipeline stamps what it was made from after every run that applied everything
    # (theme-inputs.sha256: tools\apply-wallust-outputs.ps1, tools\lib\palette.ps1, every file in
    # tools\palette\targets, and "profile:<id>" = the chosen profile file's hash) -- the list comes
    # from Get-PaletteThemeInputs (tools\lib\palette.ps1), the one the pipeline writes with. A pull
    # that brings a new target or template, a profile changed by hand, a choice made behind the
    # pipeline's back, a run that stopped part-way: each leaves the old look until the next
    # wallpaper change. No stamp at all = an install from before the stamp.
    $stamp = Join-Path (Get-DoctorLogDir) 'theme-inputs.sha256'
    $fix = @{ Fix = '710sRice install -Only palette'; Step = 'palette' }
    $made = [ordered]@{}
    if (Test-Path -LiteralPath $stamp) {
        foreach ($line in @(Get-Content -LiteralPath $stamp)) {
            if ($line -match '^([0-9a-f]{64})\s+(\S.*)$') { $made[$Matches[2].Trim()] = $Matches[1] }
        }
    }
    if (-not $made.Count) {   # no stamp, or nothing readable in it
        return New-DoctorResult -Id 'theme-inputs' -Status 'XX' -Text 'No record of what made the theme' @fix
    }
    $active = Resolve-ActivePaletteProfile
    $label = Get-PaletteProfileLabel -Id $active.Id -Name $active.Profile.name
    $now = Get-PaletteThemeInputs -ProfileId $active.Id
    $what = @(
        $madeProfile = @($made.Keys | Where-Object { $_ -like 'profile:*' }) | Select-Object -First 1
        $nowProfile = "profile:$($active.Id)"
        if (-not $madeProfile) { 'made before palette profiles' }
        elseif ($madeProfile -ne $nowProfile) {
            $was = $madeProfile.Substring(8)
            $wasLabel = if ($was -in $script:PaletteProfileIds) { Get-PaletteProfileLabel -Id $was } else { $was }
            "made with $wasLabel -- $label is chosen now"
        } elseif ($made[$madeProfile] -ne $now[$nowProfile]) { "$label has changed since" }
        foreach ($rel in $now.Keys) {
            if ($rel -like 'profile:*') { continue }
            $leaf = Split-Path -Leaf $rel
            if (-not $made.Contains($rel)) { "new: $leaf" }
            elseif ($made[$rel] -ne $now[$rel]) { "$leaf changed" }
        }
        foreach ($rel in $made.Keys) { if ($rel -notlike 'profile:*' -and -not $now.Contains($rel)) { "gone: $(Split-Path -Leaf $rel)" } }
    )
    if ($what.Count) {
        return New-DoctorResult -Id 'theme-inputs' -Status 'XX' -Text "Theme isn't what the repo and $label make now" -Detail $what @fix
    }
    New-DoctorResult -Id 'theme-inputs' -Status 'OK' -Text "Theme made from the current files, with $label"
}

function Test-DoctorPaletteLastRun {
    # How the last theme run went (palette-status.json, written by the pipeline). A wallust
    # failure leaves the old theme on screen by design -- this is where it says so, next to the
    # toast 710.ahk showed at the time. Nothing to fix by command for a wallpaper wallust can't
    # read, so it's [!!]; a target that failed is also why the stamp above says [XX].
    $s = Get-PaletteStatus
    if (-not $s) { return }
    $when = try { $t = [datetime]::Parse("$($s.time)"); if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') } else { $t.ToString('yyyy-MM-dd HH:mm') } } catch { "$($s.time)" }
    $who = ''
    if ("$($s.profile)" -in $script:PaletteProfileIds) {
        $name = try { (Read-PaletteProfile -Id "$($s.profile)").name } catch { '' }
        $who = Get-PaletteProfileLabel -Id "$($s.profile)" -Name $name
    }
    if ($s.ok) { return New-DoctorResult -Id 'palette-last' -Status 'OK' -Text "Last theme run: $when$(if ($who) { ", $who" })" }
    $detail = @("$(ConvertTo-SafeText "$($s.reason)")")
    if ($s.image) { $detail = @("wallpaper: $($s.image)") + $detail }
    if ("$($s.stage)" -eq 'targets') {
        return New-DoctorResult -Id 'palette-last' -Status 'XX' -Text "The last theme run ($when) didn't apply everything" -Detail $detail -Fix '710sRice install -Only palette' -Step 'palette'
    }
    New-DoctorResult -Id 'palette-last' -Status '!!' -Text "The last theme run ($when) couldn't make a palette -- the theme on screen is from before it" `
        -Detail $detail -Fix 'pick another wallpaper (SUPER+W), or another palette source (SUPER+Alt+Space > Palette profiles)'
}

function Test-DoctorFlowTheme {
    # Flow on the palette's theme (tools\palette\targets\flow.ps1): selected in its settings and
    # the file there. Skipped when the chosen profile switches Flow off, or Flow has never run
    # (the line above says so). Picking another theme in Flow's own settings reads as [XX] here:
    # the palette re-selects its own on every wallpaper change -- switch Flow off in the profile
    # to keep one of yours.
    $active = Resolve-ActivePaletteProfile
    if ('flow' -in $active.Profile.off) {
        return New-DoctorResult -Id 'flow-theme' -Status '..' -Text "Flow Launcher's colours: off in $(Get-PaletteProfileLabel -Id $active.Id -Name $active.Profile.name)"
    }
    $settingsPath = Join-Path $env:APPDATA 'FlowLauncher\Settings\Settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return }
    $theme = "$(([IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -AsHashtable)['Theme'])"
    $file = Test-Path -LiteralPath (Join-Path $env:APPDATA 'FlowLauncher\Themes\710sRice.xaml')
    if ($theme -eq '710sRice' -and $file) { return New-DoctorResult -Id 'flow-theme' -Status 'OK' -Text 'Flow Launcher themed (710sRice)' }
    $why = if ($theme -ne '710sRice') { "it's on '$(if ($theme) { $theme } else { "Flow's default" })'" } else { '710sRice.xaml is missing' }
    New-DoctorResult -Id 'flow-theme' -Status 'XX' -Text "Flow Launcher isn't on the palette's theme ($why)" -Fix '710sRice install -Only palette' -Step 'palette'
}
