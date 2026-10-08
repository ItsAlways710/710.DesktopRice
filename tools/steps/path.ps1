<#
.SYNOPSIS
  install's path step: this clone's bin\ (bin\710sRice.cmd, the `710sRice` command) on your user
  PATH; what uninstall puts back (section 4: only that entry comes off); doctor's "710sRice
  command" line. The PATH itself is read and written by tools\lib\userenv.ps1. Loaded by
  tools\lib\activation.ps1. Only functions.
#>

# --- install's step -------------------------------------------------------------------------------
function Install-PathStep {
    # --- 2c. PATH: the 710sRice command --------------------------------------------------
    # bin\ holds one file, 710sRice.cmd -- a one-line shim that runs 710sRice.ps1 with pwsh -- so
    # `710sRice <command>` works from any PS7 window opened from now on. Add-UserPathEntry keeps
    # every other user PATH entry exactly as stored (%VARS% and all), appends ours, writes it back
    # as REG_EXPAND_SZ and tells Explorer; it also adds bin\ to this window. A failure here
    # only costs the shortcut, so it warns instead of stopping the install.
    Write-Host "`n-- 710sRice command --" -ForegroundColor Cyan
    $riceBin = Join-Path $Root 'bin'
    try {
        if (Add-UserPathEntry -Dir $riceBin) {
            Step-Ok "710sRice command: $(ConvertTo-SafePath $riceBin) added to your PATH (open a new PS7 window to use it)"
        } else {
            Step-Ok '710sRice command: already on your PATH'
        }
    } catch {
        Step-Warn "710sRice command: couldn't add $riceBin to your PATH -- $($_.Exception.Message)"
    }
}

# --- Uninstall's part (section 4) ---------------------------------------------------------------
function Undo-RiceCommandPath {
    # uninstall, section 4: this clone's bin\ off your user PATH -- every other entry written back
    # exactly as stored (Remove-UserPathEntry) -- and a line saying how that went.
    param([string]$RiceBin)
    if (Remove-UserPathEntry -Dir $riceBin) {
        Step-Ok "710sRice command: $(ConvertTo-SafePath $riceBin) removed from your PATH"
    } else {
        Step-Info "710sRice command: wasn't on your PATH"
    }
}

# --- Doctor's check: the 710sRice command line in Repo and command -------------------------------
# Registry reads sit behind these small functions (the Linux sandbox has no HKCU:, and they
# are what a test stubs). Get-UserPathRaw and Test-SamePathEntry come from userenv.ps1 --
# install's own PATH helpers, so "on your PATH" means exactly what install means by it.

function Get-DoctorMachinePathRaw {
    (Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
}

function Get-DoctorScriptCommand {
    # This clone's 710sRice.ps1 as a command that works typed into any PS7 window -- for when
    # the bare `710sRice` isn't on PATH, or runs some other copy. A plain path needs no
    # quoting; anything else (a space, a quote, a $...) gets the call operator. A clone under
    # the user's own folders (the README's `git clone` from a fresh window lands in the home
    # folder) is written with $env:USERPROFILE & co., never the user name -- still typeable.
    param([Parameter(Mandatory)][string]$CommandLine)
    $ps1  = Join-Path $Root '710sRice.ps1'
    $safe = ConvertTo-SafePath $ps1
    if ($safe -match '^%(\w+)%(.*)$') {
        $rest = $Matches[2] -replace '([`$"])', '`$1'   # escaped for a double-quoted string
        return "& `"`$env:$($Matches[1])$rest`" $CommandLine"
    }
    if ($ps1 -match '^[A-Za-z]:\\[\w.\\-]+$') { return "$ps1 $CommandLine" }
    "& '$($ps1 -replace "'", "''")' $CommandLine"
}

function Test-DoctorPath {
    # This clone's bin\ (bin\710sRice.cmd, the `710sRice` command) on the user PATH -- what any
    # new window gets. Missing: say whether a new window would find some other copy instead.
    $bin = Join-Path $Root 'bin'
    if (@("$(Get-UserPathRaw)" -split ';' | Where-Object { Test-SamePathEntry $_ $bin }).Count) {
        return New-DoctorResult -Id 'path' -Status 'OK' -Text "710sRice command: $(ConvertTo-SafePath $bin) is on your PATH"
    }
    # A new window's PATH is the machine's entries, then the user's. [IO.Path]::Combine, not
    # Join-Path: Join-Path throws on a drive that isn't there (an unplugged USB or network
    # drive still on PATH), and one stale entry mustn't sink the check.
    $other = $null
    foreach ($entry in @("$(Get-DoctorMachinePathRaw)" -split ';') + @("$(Get-UserPathRaw)" -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
        try { $found = Test-Path -LiteralPath ([IO.Path]::Combine($dir, '710sRice.cmd')) } catch { $found = $false }
        if ($found) { $other = $dir; break }
    }
    New-DoctorResult -Id 'path' -Status 'XX' -Text "710sRice command: $(ConvertTo-SafePath $bin) isn't on your PATH" `
        -Detail $(if ($other) { "710sRice on your PATH runs another copy: $(ConvertTo-SafePath $other)" }) `
        -Fix (Get-DoctorScriptCommand 'install -Only path') -Step 'path'
}
