<#
.SYNOPSIS
  Your user environment: registered user variables, the user PATH (read and written raw), and the
  broadcast that tells Windows a setting changed. Loaded by tools\lib\activation.ps1. Only
  functions.
#>

function Send-SettingChangeBroadcast {
    <# HWND_BROADCAST + WM_SETTINGCHANGE(<Area>), SMTO_ABORTIFHUNG. The default area,
       "ImmersiveColorSet", makes an accent-color change apply live, no logoff/restart.
       "Environment" tells Explorer to rebuild its environment block from the registry, so
       whatever it launches next (a new Terminal from Start, the Run dialog) sees a changed
       user PATH -- the user-PATH helpers below send that one. Ported inline from
       tools\apply-wallust-outputs.ps1's own copy of this P/Invoke (that script keeps its
       own -- see this file's header note above -- this copy is for Restore-WindowsAccent,
       called from uninstall.ps1, which already dot-sources this file). #>
    param([string]$Area = 'ImmersiveColorSet')
    if (-not ('TenSeven.Native.SettingChange' -as [type])) {
        Add-Type -Namespace TenSeven.Native -Name SettingChange -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    [TenSeven.Native.SettingChange]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, $Area, 2, 1000, [ref]$result) | Out-Null
}

# --- User environment variables ---------------------------------------------------------------
# (Not PATH: that one is read and written raw -- see below.)
function Get-UserEnvVar {
    # A variable as registered for the user (what a new window gets).
    param([Parameter(Mandatory)][string]$Name)
    [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Remove-UserEnvVar {
    # Gone from the user's registered variables and from this process.
    param([Parameter(Mandatory)][string]$Name)
    [Environment]::SetEnvironmentVariable($Name, $null, 'User')
    Remove-Item -Path "env:$Name" -ErrorAction SilentlyContinue
}

function Set-UserEnvVar {
    # Registered for the user (new windows and tasks get it; .NET tells Explorer) and set in this
    # process too.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "env:$Name" -Value $Value
}

# --- User PATH: the 710sRice command -------------------------------------------------------
# install.ps1 puts <repo>\bin on the user PATH (bin\ holds exactly one file, 710sRice.cmd);
# uninstall.ps1 takes it off again. Doctor can use the same helpers later.
#
# The user Path is read and written RAW. GetValue(..., DoNotExpandEnvironmentNames) hands back
# entries like %USERPROFILE%\AppData\Local\Microsoft\WindowsApps exactly as stored, and the
# write goes back as REG_EXPAND_SZ, so they keep expanding. The obvious one-liner --
# [Environment]::Get/SetEnvironmentVariable('Path', ..., 'User') -- returns the values
# already expanded and writes REG_SZ, freezing every %VAR% entry into a fixed path for good.
# winarchy's install.ps1 (section 3) and uninstall.ps1 do exactly that. Not here.
#
# The text work is split out as plain string functions (Add-PathEntryToText,
# Remove-PathEntryFromText) so it can be tested anywhere; only Get-/Set-UserPathRaw touch the
# registry.

function Test-SamePathEntry {
    <# $Entry (a raw PATH entry, %VARS% and all) names the same folder as $Dir: both expanded,
       surrounding quotes/blanks and a trailing \ dropped, case ignored. Deliberately NOT a
       substring match -- C:\710.DesktopRice\bin-old is not C:\710.DesktopRice\bin. #>
    param([string]$Entry, [Parameter(Mandatory)][string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Entry)) { return $false }
    $a = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\')
    $b = [Environment]::ExpandEnvironmentVariables($Dir.Trim().Trim('"')).TrimEnd('\')
    [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

function Add-PathEntryToText {
    <# $Raw with $Dir appended, or $null when $Dir is already in it. Every existing entry --
       order, %VARS%, empty slots, a trailing ; -- stays exactly as written, so removing $Dir
       again gives back the original text byte for byte. #>
    param([AllowEmptyString()][AllowNull()][string]$Raw, [Parameter(Mandatory)][string]$Dir)
    foreach ($entry in ("$Raw" -split ';')) { if (Test-SamePathEntry $entry $Dir) { return $null } }
    if ([string]::IsNullOrEmpty($Raw)) { return $Dir }
    if ($Raw.EndsWith(';')) { return "$Raw$Dir;" }
    "$Raw;$Dir"
}

function Remove-PathEntryFromText {
    <# $Raw minus every entry naming $Dir (a duplicate goes too), or $null when none did.
       Everything else -- order, %VARS%, empty slots, a trailing ; -- stays exactly as
       written. Returns '' when $Dir was the only entry. #>
    param([AllowEmptyString()][AllowNull()][string]$Raw, [Parameter(Mandatory)][string]$Dir)
    $parts = "$Raw" -split ';'
    $kept = @($parts | Where-Object { -not (Test-SamePathEntry $_ $Dir) })
    if ($kept.Count -eq $parts.Count) { return $null }
    $kept -join ';'
}

function Get-UserPathRaw {
    <# The user Path exactly as stored (%VARS% unexpanded); '' when there isn't one. #>
    (Get-Item -Path 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
}

function Set-UserPathRaw {
    <# Writes the user Path back as REG_EXPAND_SZ (Windows' own type for it) -- or removes the
       value when nothing is left -- then tells Explorer. #>
    param([AllowEmptyString()][string]$Raw)
    if ($Raw) {
        Set-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -Value $Raw -Type ExpandString
    } else {
        Remove-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -ErrorAction SilentlyContinue
    }
    Send-SettingChangeBroadcast -Area 'Environment'
}

function Add-UserPathEntry {
    <# Puts $Dir on the user PATH if it isn't there yet (appended last) and on this process's
       PATH too, so it works in the window that ran install. $true if the registry changed. #>
    param([Parameter(Mandatory)][string]$Dir)
    if (-not @(("$env:Path" -split ';') | Where-Object { Test-SamePathEntry $_ $Dir })) {
        $env:Path = "$("$env:Path".TrimEnd(';'));$Dir"
    }
    $new = Add-PathEntryToText -Raw (Get-UserPathRaw) -Dir $Dir
    if ($null -eq $new) { return $false }
    Set-UserPathRaw -Raw $new
    $true
}

function Remove-UserPathEntry {
    <# Takes every entry naming $Dir off the user PATH, and off this process's PATH. Nothing
       matched = no write at all (the value and its type stay untouched). $true if the
       registry changed. #>
    param([Parameter(Mandatory)][string]$Dir)
    $env:Path = @(("$env:Path" -split ';') | Where-Object { -not (Test-SamePathEntry $_ $Dir) }) -join ';'
    $new = Remove-PathEntryFromText -Raw (Get-UserPathRaw) -Dir $Dir
    if ($null -eq $new) { return $false }
    Set-UserPathRaw -Raw $new
    $true
}
