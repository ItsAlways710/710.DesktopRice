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
    - `710sRice deactivate`, after it puts full time's settings back (Set-LockScreenToWallpaper);
    - uninstall, to put your original picture back (Restore-LockScreenPicture, with -KeepMode).

  Setting the picture alone isn't enough: Windows only shows it while its own lock-screen choice
  is Picture. With Windows Spotlight chosen, a picture set through the API never shows (proven on
  the Dell, 2026-10-03: with RotatingLockScreenEnabled gone, Settings said Windows spotlight and
  the lock screen showed Windows' default image; RotatingLockScreenEnabled = 0 alone brought the
  picture back, on Win+L and at boot). So every set also chooses Picture, the way Settings does:
  RotatingLockScreenEnabled = 0, and SlideshowEnabled = 0 if a slideshow was on. A full-time
  machine's hardening held that choice; on demand nothing did. -KeepMode leaves the choice alone
  (uninstall's put-back of your original picture restores the choice itself, from the snapshot).

  The screens before sign-in -- the clock screen at boot and the password screen -- don't read
  your choice at all: they read Windows' own copy of it, kept per account under
  HKLM\...\Authentication\LogonUI\Creative\<your SID>. Settings > Lock screen > Picture writes
  that copy too; setting only yours left it on Spotlight. On Godzilla (2026-10-04, on demand)
  Win+L showed the picture while both boot screens stayed on Windows Spotlight -- that copy said
  RotatingLockScreenEnabled 1, LockImageFlags 3, and Windows kept filling it with Spotlight
  pictures overnight. Picking Picture in Settings changed exactly those two values, to 0 and 1,
  and both boot screens followed after a restart. So every set that chooses Picture writes them
  too (Set-SignInScreenPicture). It sits under HKLM, but Windows lets each account change its own
  copy: a set running as you writes it (Godzilla, 2026-10-04). If Windows ever refuses, the line
  says so and doctor names the fix. Saved once before its first change
  (original-state\lockscreen-signin.json); uninstall puts it back.

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
    [string]$Image,
    # Leave Windows' Picture / Spotlight / Slideshow choice as it is.
    [switch]$KeepMode
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$stateDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$cdm      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$lockKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen'
# Windows' own copy of the choice, read by the screens before sign-in (header). Per account.
$signInKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Creative\' +
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

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

function Set-PictureMode {
    # Windows' lock-screen choice = Picture, as Settings > Personalization > Lock screen > Picture
    # sets it: Spotlight off (RotatingLockScreenEnabled = 0; absent means Spotlight, Windows' own
    # default) and a slideshow off (SlideshowEnabled = 0, only when it's on). Without it the
    # picture just set never shows while Spotlight is chosen. Save-OriginalOnce has already saved
    # both as they were, for uninstall. -> 'Spotlight' / 'Slideshow' (the choice it replaced), or
    # '' (Picture already).
    $was = ''
    $slide = Get-ItemProperty -LiteralPath $lockKey -Name 'SlideshowEnabled' -ErrorAction SilentlyContinue
    if ($slide -and $slide.SlideshowEnabled -ne 0) {
        Set-ItemProperty -LiteralPath $lockKey -Name 'SlideshowEnabled' -Value 0 -Type DWord
        $was = 'Slideshow'
    }
    $rot = Get-ItemProperty -LiteralPath $cdm -Name 'RotatingLockScreenEnabled' -ErrorAction SilentlyContinue
    if (-not $rot -or $rot.RotatingLockScreenEnabled -ne 0) {
        if (-not (Test-Path -LiteralPath $cdm)) { $null = New-Item -Path $cdm -Force }
        Set-ItemProperty -LiteralPath $cdm -Name 'RotatingLockScreenEnabled' -Value 0 -Type DWord
        if (-not $was) { $was = 'Spotlight' }
    }
    $was
}

function Save-SignInOriginalOnce {
    # Windows' sign-in copy of the choice as it was, before this script first changes it -- both
    # values, in Get-RegSnapshot's shape, once ever (like Save-OriginalOnce). Uninstall puts it
    # back: activation.ps1's Restore-LockScreenPicture.
    $file = Join-Path $stateDir 'original-state\lockscreen-signin.json'
    if (Test-Path -LiteralPath $file) { return }
    $o = [ordered]@{
        RotatingLockScreenEnabled = Get-RegSnapshot $signInKey 'RotatingLockScreenEnabled'
        LockImageFlags            = Get-RegSnapshot $signInKey 'LockImageFlags'
    }
    Write-Utf8File $file ($o | ConvertTo-Json -Depth 5)
}

function Set-SignInScreenPicture {
    # The screens before sign-in (header): Windows' own copy of the choice, set to Picture the way
    # Settings sets it -- RotatingLockScreenEnabled 0, LockImageFlags 1 -- only when that copy says
    # otherwise. No copy at all (an account Spotlight never touched) has nothing to disagree with:
    # left alone. -> 'set', '' (Picture already, or no copy), or 'denied' (Windows refused the
    # write; the original is saved by then, which is fine: it's still the original).
    $rot = Get-ItemProperty -LiteralPath $signInKey -Name 'RotatingLockScreenEnabled' -ErrorAction SilentlyContinue
    if (-not $rot -or $rot.RotatingLockScreenEnabled -eq 0) { return '' }
    Save-SignInOriginalOnce
    try {
        Set-ItemProperty -LiteralPath $signInKey -Name 'RotatingLockScreenEnabled' -Value 0 -Type DWord -ErrorAction Stop
        Set-ItemProperty -LiteralPath $signInKey -Name 'LockImageFlags' -Value 1 -Type DWord -ErrorAction Stop
    } catch {
        if ($_.Exception -is [System.Security.SecurityException] -or $_.Exception -is [System.UnauthorizedAccessException]) { return 'denied' }
        throw
    }
    'set'
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

# Windows' Picture choice, so the picture shows (Set-PictureMode), and the same in Windows' own
# copy for the screens before sign-in (Set-SignInScreenPicture). Not when told to keep the choice.
$modeNote = ''
if (-not $KeepMode) {
    try {
        $was = Set-PictureMode
        if ($was) { $modeNote = ", and Windows' lock screen switched from $was to Picture" }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $modeNote = ", but Windows' lock-screen choice couldn't be set to Picture ($(ConvertTo-Safe ("$($e.Message)".Trim())))"
    }
    try {
        switch (Set-SignInScreenPicture) {
            'set'    { $modeNote += '; the screens before sign-in switched to Picture too' }
            'denied' { $modeNote += '; the screens before sign-in still show Windows spotlight (Windows refused the change; try 710sRice install -Only palette)' }
        }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $modeNote += "; the screens before sign-in couldn't be switched to Picture ($(ConvertTo-Safe ("$($e.Message)".Trim())))"
    }
}

$policy = Test-LockScreenPolicy
Write-Record $true $name '' $policy
if ($policy) {
    Write-Output "set to $name$modeNote, but a lock-screen policy on this machine shows its own picture instead"
    exit 2
}
Write-Output "set to $name$modeNote"
exit 0
