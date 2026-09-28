<#
.SYNOPSIS
  Sets YOUR lock-screen picture to the wallpaper (or to -Image).

.DESCRIPTION
  The lock screen's leg of the wallpaper pipeline. It sets Windows' own per-user lock-screen
  picture -- the one Settings > Personalization > Lock screen > Picture sets -- through
  Windows.System.UserProfile.LockScreen.SetImageFileAsync. Windows keeps its own copy the
  moment the picture is set, so the screen before sign-in shows it at the next boot with no
  Win+L first.

  Why not the machine policy it replaced (HKLM PersonalizationCSP, 2026-09-22 .. 09-28): that
  pointed Windows at the wallpaper file, and the boot screen only picked a new picture up at
  the next lock -- a restart after a wallpaper change came up black. It also needed admin, so
  it needed an elevated scheduled task, and that task needed a hidden launcher. This needs
  none of it: it runs as you. (Plan doc items 46 B and 48; proven on the Dell 2026-09-28.)

  Windows PowerShell 5.1 only (powershell.exe): PowerShell 7 can't call WinRT APIs by itself.
  Started with no window by tools\lib\lockscreen.ps1's Invoke-LockScreenSetter, from:
    - the wallpaper pipeline (tools\apply-wallust-outputs.ps1), on every wallpaper change;
    - install's tasks step, once, after it retires the old sync (Remove-RetiredLockScreenSync);
    - uninstall, to put your original picture back (Restore-LockScreenPicture).

  Before the FIRST set ever, the original is saved once: the picture Windows reports and the
  Spotlight / Slideshow settings, in original-state\lockscreen-picture.json (activation.ps1's
  Save-OriginalState path and shape). Every run then writes lockscreen.json -- when, which file
  (its name only), and how it went -- for `710sRice doctor`.

  Exit codes: 0 set; 1 no picture file to use; 2 set, but a lock-screen policy on this machine
  overrides it; 3 Windows refused. The last line printed says what happened, in words.
#>
[CmdletBinding()]
param(
    # The picture. Left out: the wallpaper that's up now (HKCU\Control Panel\Desktop\WallPaper).
    [string]$Image
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$stateDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$cdm      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$lockKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen'

function ConvertTo-Safe([string]$Text) {
    # Nothing printed or recorded names the user's folders (the repo is public; output gets pasted).
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
        $d = [Environment]::GetEnvironmentVariable($v)
        if ($d) { $Text = [regex]::Replace($Text, [regex]::Escape($d.TrimEnd('\')), "%$v%", 'IgnoreCase') }
    }
    $Text
}

function Write-Utf8File([string]$Path, [string]$Text) {
    # No BOM -- PowerShell 7 reads these back.
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-RegSnapshot([string]$Path, [string]$Name) {
    # activation.ps1's Get-RegValueSnapshot, same shape -- Set-RegValueFromSnapshot restores it.
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if (-not $item) { return [ordered]@{ Existed = $false; Value = $null; Type = $null } }
    $kind = 'String'
    try { $kind = (Get-Item -LiteralPath $Path).GetValueKind($Name).ToString() } catch { }
    [ordered]@{ Existed = $true; Value = $item.$Name; Type = $kind }
}

function Test-LockScreenPolicy {
    # A machine policy that shows its own picture over yours: the PersonalizationCSP values (the
    # old sync's, or a company's) or the Group Policy "Force a specific default lock screen image".
    $csp = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -ErrorAction SilentlyContinue
    $gpo = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -ErrorAction SilentlyContinue
    [bool](($csp -and ($csp.LockScreenImagePath -or $csp.LockScreenImageUrl)) -or ($gpo -and $gpo.LockScreenImage))
}

function Initialize-WinRT {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
    [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime] | Out-Null
}

function Wait-WinRT($Operation, [Type]$ResultType) {
    # WinRT's async calls as a .NET Task, waited on. No result type = an IAsyncAction.
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq $(if ($ResultType) { 'IAsyncOperation`1' } else { 'IAsyncAction' })
    } | Select-Object -First 1
    if ($ResultType) { $asTask = $asTask.MakeGenericMethod($ResultType) }
    $task = $asTask.Invoke($null, @($Operation))
    $task.Wait(-1) | Out-Null
    if ($ResultType) { $task.Result }
}

function Get-CurrentLockScreenFile {
    # The picture Windows reports as yours: the ORIGINAL file, not a copy (checked on the Dell,
    # 2026-09-28) -- so uninstall can point straight back at it. $null when it isn't a plain file.
    $uri = [Windows.System.UserProfile.LockScreen]::OriginalImageFile
    if ($uri -and $uri.IsFile) { $uri.LocalPath } else { $null }
}

function Set-LockScreenFile([string]$Path) {
    $file = Wait-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    Wait-WinRT ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($file))
}

function Save-OriginalOnce {
    # Written once ever -- a second, third, Nth set never overwrites the real original with what is
    # by then our own. Hardened = -Activate's hardening had already switched Spotlight off (its
    # policy value is set): those two values are then its to put back on uninstall, not ours.
    $file = Join-Path $stateDir 'original-state\lockscreen-picture.json'
    if (Test-Path -LiteralPath $file) { return }
    $current = $null
    try { $current = Get-CurrentLockScreenFile } catch { }
    $spotlightOff = Get-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsSpotlightFeatures' -ErrorAction SilentlyContinue
    $o = [ordered]@{
        Image                            = $current
        Hardened                         = [bool]($spotlightOff -and $spotlightOff.DisableWindowsSpotlightFeatures -eq 1)
        RotatingLockScreenEnabled        = Get-RegSnapshot $cdm 'RotatingLockScreenEnabled'
        RotatingLockScreenOverlayEnabled = Get-RegSnapshot $cdm 'RotatingLockScreenOverlayEnabled'
        SlideshowEnabled                 = Get-RegSnapshot $lockKey 'SlideshowEnabled'
    }
    Write-Utf8File $file ($o | ConvertTo-Json -Depth 5)
}

function Write-Record([bool]$Ok, [string]$Name, [string]$Reason, [bool]$Policy) {
    # What doctor reads (tools\lib\lockscreen.ps1's Read-LockScreenRecord). Best-effort.
    try {
        $o = [ordered]@{ time = (Get-Date -Format 's'); image = $Name; ok = $Ok; policy = $Policy; reason = (ConvertTo-Safe $Reason) }
        Write-Utf8File (Join-Path $stateDir 'lockscreen.json') ($o | ConvertTo-Json)
    } catch { }
}

if (-not $Image) {
    $Image = (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name 'WallPaper' -ErrorAction SilentlyContinue).WallPaper
}
if (-not $Image -or -not (Test-Path -LiteralPath $Image -PathType Leaf)) {
    $why = if ($Image) { "the picture ($(Split-Path -Leaf $Image)) isn't there" } else { 'no wallpaper is set' }
    Write-Record $false $(if ($Image) { Split-Path -Leaf $Image } else { '' }) $why $false
    Write-Output "nothing to set -- $why"
    exit 1
}
$name = Split-Path -Leaf $Image

try {
    Initialize-WinRT
    Save-OriginalOnce
    Set-LockScreenFile $Image
} catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $why = ConvertTo-Safe ("$($e.Message)".Trim())
    Write-Record $false $name $why $false
    Write-Output "Windows refused: $why"
    exit 3
}

$policy = Test-LockScreenPolicy
Write-Record $true $name '' $policy
if ($policy) {
    Write-Output "set to $name, but a lock-screen policy on this machine shows its own picture instead"
    exit 2
}
Write-Output "set to $name"
exit 0
