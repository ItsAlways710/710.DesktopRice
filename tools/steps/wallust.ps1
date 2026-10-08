<#
.SYNOPSIS
  install's wallust step: wallust (the palette maker; a github release, no winget package) at
  versions.md's pin, and config\wallust\wallust.toml generated for this clone; where the binary
  lives (Get-WallustExe -- the theme and palette steps use it too); doctor's wallust and
  wallust.toml lines. Uninstall removes the binary in its section 7 (versions.md's keep rules,
  like every package) and wallust.toml in section 9. Loaded by tools\lib\activation.ps1. Only
  functions.
#>

function Get-WallustExe {
    # wallust.exe, where the wallust step puts it (tools\install-wallust.ps1). The theme and palette
    # steps need it too, and can run without the wallust step (-Only theme / -Only palette), so they
    # ask here.
    Join-Path $Root 'tools\bin\wallust\wallust.exe'
}

# --- install's step -------------------------------------------------------------------------------
function Install-WallustStep {
    # install's wallust step. What didn't install goes on install's list (-NotInstalled): the run
    # finishes every step, then says so and exits 1.
    param($NotInstalled)
    $wallustExe = Get-WallustExe
    # --- 3. wallust -----------------------------------------------------------------------
    Write-Host "`n-- wallust --" -ForegroundColor Cyan
    # The pin is versions.md's wallust row (github-release: no winget package exists).
    $wallustRow = @(Get-VersionsTable -Path (Join-Path $Root 'versions.md')) | Where-Object { $_.InstallId -like '*wallust*' } | Select-Object -First 1
    $WallustPinnedVersion = if ($wallustRow) { $wallustRow.Version } else { $null }
    $wallustUpToDate = $false
    if (-not $WallustPinnedVersion) {
        Step-Warn 'versions.md has no wallust row -- wallust not checked or installed.'
        $wallustUpToDate = $true   # nothing to install it at; the theme step says so if it's missing
    } elseif (Test-Path $wallustExe) {
        try {
            $verOut = & $wallustExe --version 2>$null | Out-String
            if ($verOut -match [regex]::Escape($WallustPinnedVersion)) { $wallustUpToDate = $true }
        } catch { }
    }
    if ($wallustUpToDate) {
        if ($WallustPinnedVersion) { Step-Ok "wallust $WallustPinnedVersion already installed" }
    } else {
        Step-Info "Installing wallust $WallustPinnedVersion ..."
        try {
            & (Join-Path $Root 'tools\install-wallust.ps1') -Version $WallustPinnedVersion
            Step-Ok "wallust installed"
        } catch {
            Write-Host "  [XX] wallust install failed: $($_.Exception.Message) -- the rest of the install carries on without it." -ForegroundColor Red
            $NotInstalled.Add('wallust')
        }
    }

    # wallust.toml is generated from a tracked template with this repo's real location filled
    # in (wallust's template targets must be absolute paths). Before section 4's `wallust run`.
    & (Join-Path $Root 'tools\write-wallust-config.ps1')
    if ($LASTEXITCODE -ne 0) { Step-Warn 'wallust.toml not written (see message above) -- wallpaper theming will fail until it is.' }
    else { Step-Ok 'wallust.toml current' }
}

# --- Doctor's checks: wallust in Packages and pins, wallust.toml in Generated configs --------------
function Test-DoctorWallust {
    # wallust at versions.md's pin, by the very test install's wallust step makes (its
    # --version output contains the pin) -- so this check and its fix can't disagree.
    $row = Get-DoctorVersionRows | Where-Object { $_.InstallId -like '*wallust*' } | Select-Object -First 1
    if (-not $row) { return }   # no wallust row: nothing to hold it to
    $pin = $row.Version
    $exe = Join-Path $Root 'tools\bin\wallust\wallust.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return New-DoctorResult -Id 'wallust' -Status 'XX' -Text "wallust isn't installed" -Fix '710sRice install -Only wallust' -Step 'wallust'
    }
    $out = "$(& $exe --version 2>$null)"
    $ver = if ($out -match '^\s*wallust\s+(\S+)') { $Matches[1] } else { '' }
    if ($out -match [regex]::Escape($pin)) {
        return New-DoctorResult -Id 'wallust' -Status 'OK' -Text "wallust $(if ($ver) { $ver } else { $pin }) -- at its pin"
    }
    $text = if ($ver) { "wallust $ver -- its pin is $pin" } else { "wallust -- its version couldn't be read (its pin is $pin)" }
    New-DoctorResult -Id 'wallust' -Status 'XX' -Text $text -Fix '710sRice install -Only wallust' -Step 'wallust'
}

function Test-DoctorWallustToml {
    # write-wallust-config.ps1 -Check: wallust.toml is generated with this clone's own path in
    # it (wallust's template targets are absolute), so a moved clone needs it written again.
    $global:LASTEXITCODE = 0
    $stream = @(& (Join-Path $Root 'tools\write-wallust-config.ps1') -Check 3>&1 6>$null)
    $code = $LASTEXITCODE
    switch ($code) {
        0 { return New-DoctorResult -Id 'wallust-toml' -Status 'OK' -Text 'wallust.toml generated for this clone' }
        3 { return New-DoctorResult -Id 'wallust-toml' -Status 'XX' -Text "wallust.toml isn't generated for this clone (missing, or from a moved clone)" -Fix '710sRice install -Only wallust' -Step 'wallust' }
    }
    # 1: it can't be generated here at all (no template, or a path wallust.toml can't hold).
    $why = @($stream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    New-DoctorResult -Id 'wallust-toml' -Status 'XX' -Text "wallust.toml can't be generated for this clone" -Detail $why `
        -Fix 'deal with what the line above says, then 710sRice install -Only wallust' -NeedsYou
}
