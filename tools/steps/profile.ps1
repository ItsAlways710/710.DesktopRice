<#
.SYNOPSIS
  install's profile step: the pwsh $PROFILE hook -- a marked block in your profile that loads
  this clone's config\pwsh\profile.ps1 -- written by install, taken out by uninstall (section 3,
  Remove-ShellProfile), and doctor's "Shell profile hook" line. Loaded by tools\lib\activation.ps1.
  Only functions, and the block's two marker lines.
#>

# --- Shell profile hook ($PROFILE -> config\pwsh\profile.ps1) ------------------------
# Ported from winarchy's ShellProfile.ps1 @ 4574fc7: a marker-delimited block inserted (or
# updated) in pwsh's CurrentUserAllHosts $PROFILE, idempotent, snapshotting the profile
# before any change (Copy-Item .bak, this repo's own established pattern -- see
# tools/components/flow.ps1 -- rather than winarchy's own New-WinarchySnapshot module).
$script:ProfileMarkerStart = '# >>> managed by 710.DesktopRice >>>'
$script:ProfileMarkerEnd = '# <<< managed by 710.DesktopRice <<<'

function Get-ShellProfilePath {
    # Computed by hand (not $PROFILE) so this works even when the calling session isn't
    # pwsh with $PROFILE populated.
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\profile.ps1'
}

function Get-ShellProfileBlock {
    # The exact block install writes into $PROFILE for this clone -- one definition, read by
    # Install-ShellProfile and by `710sRice doctor` (Get-ShellProfileHookState). The path goes
    # in single quotes, so a ' in it is doubled: a clone under a folder with an apostrophe broke
    # every new PS7 window (winarchy 731a0a1, Group 1 W5). Every other path's block is
    # byte-identical to before; an old unescaped one reads as "points somewhere else" to doctor,
    # whose fix (-Only profile) rewrites it.
    $managed = Join-Path $Root 'config\pwsh\profile.ps1'
    @(
        $script:ProfileMarkerStart
        ". '$($managed.Replace("'", "''"))'"
        $script:ProfileMarkerEnd
    ) -join "`r`n"
}

function Get-ShellProfileHookState {
    <# Read-only, for doctor: 'installed' ($PROFILE holds this clone's block exactly as
       Install-ShellProfile writes it), 'other' (a 710.DesktopRice block pointing somewhere
       else -- a moved clone, say), or 'missing' (no block, or no profile file at all). #>
    $profilePath = Get-ShellProfilePath
    if (-not (Test-Path -LiteralPath $profilePath)) { return 'missing' }
    $existing = Get-Content -LiteralPath $profilePath -Raw
    $pattern = '(?s)' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd)
    if ("$existing" -notmatch $pattern) { return 'missing' }
    if (($Matches[0] -replace '\r?\n', "`r`n") -eq (Get-ShellProfileBlock)) { 'installed' } else { 'other' }
}

function Install-ShellProfile {
    $profilePath = Get-ShellProfilePath
    $block = Get-ShellProfileBlock

    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
    $pattern = '(?s)' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd)

    if ($existing -match $pattern) {
        if (($Matches[0] -replace '\r?\n', "`r`n") -eq $block) {
            Step-Ok "Profile hook already installed: $(ConvertTo-SafePath $profilePath)"
            return
        }
        Copy-Item $profilePath "$profilePath.bak" -Force
        $updated = [regex]::Replace($existing, $pattern, $block.Replace('$', '$$'))
        Set-Content -Path $profilePath -Value $updated -Encoding utf8NoBOM
        Step-Ok "Profile hook updated: $(ConvertTo-SafePath $profilePath) (previous saved to $(ConvertTo-SafePath "$profilePath.bak"))"
        return
    }

    if (Test-Path $profilePath) { Copy-Item $profilePath "$profilePath.bak" -Force }
    else { New-Item -ItemType Directory -Path (Split-Path $profilePath) -Force | Out-Null }
    $newContent = if ($existing.Trim()) { $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n" } else { $block + "`r`n" }
    Set-Content -Path $profilePath -Value $newContent -Encoding utf8NoBOM
    Step-Ok "Profile hook installed: $(ConvertTo-SafePath $profilePath)"
}

function Remove-ShellProfile {
    $profilePath = Get-ShellProfilePath
    if (-not (Test-Path $profilePath)) {
        Step-Info 'No pwsh $PROFILE found; nothing to remove.'
        return
    }
    $existing = Get-Content $profilePath -Raw
    $pattern = '(?s)\r?\n?' + [regex]::Escape($script:ProfileMarkerStart) + '.*?' + [regex]::Escape($script:ProfileMarkerEnd) + '\r?\n?'
    if ($existing -notmatch $pattern) {
        Step-Info 'Profile hook not present; nothing to remove.'
        return
    }
    Copy-Item $profilePath "$profilePath.bak" -Force
    $updated = [regex]::Replace($existing, $pattern, "`r`n").Trim()
    if ($updated) { Set-Content -Path $profilePath -Value ($updated + "`r`n") -Encoding utf8NoBOM }
    else { Remove-Item $profilePath }
    Step-Ok "Profile hook removed: $(ConvertTo-SafePath $profilePath) (previous saved to $(ConvertTo-SafePath "$profilePath.bak"))"
}

# --- install's step -------------------------------------------------------------------------------
function Install-ProfileStep {
    # --- 7. Shell profile hook ($PROFILE -> config\pwsh\profile.ps1) -------------------------
    # Also unconditional -- winarchy calls Install-WinarchyShellProfile in its own install.ps1
    # outside the -Activate block too. Idempotent; snapshots the previous $PROFILE to a .bak
    # alongside it before changing anything.
    # `$PROFILE literally: the hook line below names the real file (as %USERPROFILE%\...), and
    # an expanded $PROFILE printed both the user name and the wrong file -- the hook goes into
    # profile.ps1 (every host), not Microsoft.PowerShell_profile.ps1.
    Write-Host "`n-- Shell profile (`$PROFILE hook) --" -ForegroundColor Cyan
    Install-ShellProfile
}

# --- Doctor's check: the Shell profile hook line in Integrations ------------------------------
function Test-DoctorProfileHook {
    # $PROFILE's 710.DesktopRice block, compared with exactly what install writes for this clone.
    $fix = @{ Fix = '710sRice install -Only profile'; Step = 'profile' }
    switch (Get-ShellProfileHookState) {
        'installed' { New-DoctorResult -Id 'profile' -Status 'OK' -Text 'Shell profile hook -> this clone' }
        'other'     { New-DoctorResult -Id 'profile' -Status 'XX' -Text 'Shell profile hook points at another copy' @fix }
        default     { New-DoctorResult -Id 'profile' -Status 'XX' -Text "Shell profile hook isn't installed" @fix }
    }
}
