<#
.SYNOPSIS
  install's compile step: config\komorebi\komorebi.json compiled from its sources (base.json, the
  rules, your rules.local.toml, games.toml, the vendored ASC file) by tools\compile-komorebi-rules.ps1;
  doctor's komorebi.json and ASC lines. Uninstall deletes komorebi.json in its section 9. Loaded by
  tools\lib\activation.ps1. Only functions.
#>

# --- install's step -------------------------------------------------------------------------------
function Install-CompileStep {
    # --- 10. Recompile komorebi.json -----------------------------------------------------------
    Write-Host "`n-- Compiling komorebi.json --" -ForegroundColor Cyan
    & (Join-Path $Root 'tools\compile-komorebi-rules.ps1')
}

# --- Doctor's checks: komorebi.json and the ASC file in Generated configs -------------------------
# komorebi.json is asked of its own writer in read-only mode (-Check), so doctor never carries a
# second copy of how it's made.
function Test-DoctorKomorebiJson {
    # compile-komorebi-rules.ps1 -Check: a real compile, in memory, against the file on disk.
    # Its warnings are rules the compile skips -- a rule that silently never applies.
    $out  = Join-Path $Root 'config\komorebi\komorebi.json'
    $global:LASTEXITCODE = 0
    try {
        $stream = @(& (Join-Path $Root 'tools\compile-komorebi-rules.ps1') -Check 3>&1 6>$null)
    } catch {
        return New-DoctorResult -Id 'komorebi-json' -Status 'XX' -Text "komorebi.json won't compile" `
            -Detail $_.Exception.Message -Fix 'fix the file named above, then 710sRice reload' -NeedsYou
    }
    $code = $LASTEXITCODE
    switch ($code) {
        0 { New-DoctorResult -Id 'komorebi-json' -Status 'OK' -Text 'komorebi.json is current with its sources' }
        3 {
            $text = if (Test-Path -LiteralPath $out) { 'komorebi.json is out of date with its sources' } else { 'komorebi.json is missing' }
            # A running komorebi: reload -- the hot reload plus its layouts put back. Not
            # running: just the compile step -- reload-stack.ps1 STARTS komorebi when it's down
            # (and `reload` then 710.ahk, and so the bar), and a stopped stack has no layouts to
            # keep; komorebi reads the new file at its next start.
            if (Get-Process komorebi -ErrorAction SilentlyContinue) {
                New-DoctorResult -Id 'komorebi-json' -Status 'XX' -Text $text -Fix '710sRice reload' -Repair 'reload'
            } else {
                New-DoctorResult -Id 'komorebi-json' -Status 'XX' -Text $text -Fix '710sRice install -Only compile' -Step 'compile'
            }
        }
        default { New-DoctorResult -Id 'komorebi-json' -Status '!!' -Text "komorebi.json -- couldn't check (the compiler exited $code)" }
    }
    $warnings = @($stream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    if ($warnings.Count) {
        # Your rules (Quick add's file) have their own menu item; anything else is named in the warning.
        $fix = if (-not @($warnings | Where-Object { $_ -notlike 'rules.local.toml:*' }).Count) {
            'fix the line shown (Tiling > Edit my rules... opens rules.local.toml), then 710sRice reload'
        } else { 'fix what the lines above name, then 710sRice reload' }
        New-DoctorResult -Id 'komorebi-json-warnings' -Status '!!' -Text 'komorebi.json compiles, with warnings' -Detail $warnings -Fix $fix
    }
}

function Get-DoctorLfSha256 {
    # sha256 of a text file's bytes with CRLF turned into LF -- the file as the repo stores it.
    # Git for Windows' default (core.autocrlf) checks text files out with CRLF, so a raw hash
    # would never match a pin taken from the LF file; line endings don't change what it says.
    # Decode/encode round-trips a valid UTF-8 file byte for byte, a BOM included.
    param([Parameter(Mandatory)][string]$Path)
    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)) -replace "`r`n", "`n"
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
}

function Test-DoctorAscPin {
    # vendor\asc\applications.json -- the community rules, pinned to one upstream commit -- as
    # pinned: pin.toml's sha256. Changed = someone edited a vendored file; re-pinning is a
    # deliberate maintainer step, so this is worth knowing, not a problem repair touches.
    $file = Join-Path $Root 'vendor\asc\applications.json'
    $pin  = Join-Path $Root 'vendor\asc\pin.toml'
    $fix  = 'git checkout -- vendor\asc\applications.json'
    $want = if ((Test-Path -LiteralPath $pin) -and (Get-Content -LiteralPath $pin -Raw) -match '(?m)^\s*sha256\s*=\s*"([0-9a-fA-F]{64})"') { $Matches[1].ToLowerInvariant() }
    if (-not $want) { return New-DoctorResult -Id 'asc' -Status '!!' -Text "ASC rules file -- couldn't check (vendor\asc\pin.toml has no sha256)" }
    if (-not (Test-Path -LiteralPath $file)) { return New-DoctorResult -Id 'asc' -Status '!!' -Text 'ASC rules file is missing (vendor\asc\applications.json)' -Fix $fix }
    if ((Get-DoctorLfSha256 $file) -eq $want) { return New-DoctorResult -Id 'asc' -Status 'OK' -Text 'ASC rules file matches its pin' }
    New-DoctorResult -Id 'asc' -Status '!!' -Text "ASC rules file doesn't match its pin (vendor\asc\pin.toml)" -Fix $fix
}
