#Requires -Version 7.0
<#
.SYNOPSIS
  Wallpaper rotation's change: a random wallpaper from the gallery's folders -- never the one
  that's up -- made the desktop wallpaper, then themed by the same pipeline as a gallery pick.
  710.ahk runs it on the rotation's clock (config\ahk\710\wallpaper-rotation.ahk); nothing else
  does.

.DESCRIPTION
  The folders are the gallery's own (config\yasb\config.yaml, the wallpapers widget's image_path):
  this repo's assets\wallpapers, then YASB_WALLPAPER_PATH and YASB_WALLPAPER_PATH_2 .. _10. Those
  are read from the registry -- yours over the machine's, as a sign-in sets them -- rather than
  from this process, whose environment is 710.ahk's from whenever it started: a folder added with
  setx counts from the next change (the bar itself needs `710sRice reload bar` to see it).
  Subfolders and hidden files count, and a folder that isn't there is skipped, as YASB 2.0.7 does
  it (core\widgets\services\wallpapers\images.py, collect_image_files). So do its file types: a
  name ending in png, jpg, jpeg, gif, bmp, tif or tiff, and webp from Windows 11 build 26100.8037
  or 26220.7653 on (supported_types; its test is "ends with", so it's this one's too). A file
  that two slots both reach counts once.

  Set with Set-DesktopWallpaper (tools\lib\wallpaper.ps1: SystemParametersInfo, the call install's
  theme step makes), then tools\apply-wallust-outputs.ps1 -Image, the pipeline a gallery pick
  runs (YASB's run_after) -- in a pwsh of its own, the way YASB starts it, so nothing of this
  script's leaks into it.

  The log: wallpaper-rotation.log in the logs folder (710.ahk writes its side of it there too).
  File names only, never their folders, and no user folders in any error: a log can end up
  pasted into an issue.

  Exit codes: 0 changed and themed; 1 changed, not themed (the pipeline's 1: wallust made no
  palette -- the pipeline's own toast says so -- or another theme run held its lock); 2 changed
  and themed, but an app couldn't be (the pipeline's 2: doctor names it); 3 nothing to change to
  (no wallpaper in those folders but the one that's up); 4 Windows didn't take it; 5 anything
  else (the log says what).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'tools\lib\wallpaper.ps1')
. (Join-Path $Root 'tools\lib\text.ps1')

$logDir = Join-Path $env:LOCALAPPDATA '710.DesktopRice'
$log = Join-Path $logDir 'wallpaper-rotation.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# Log cap: past 1 MB this log becomes <name>.old (replacing the previous one) and a fresh one
# starts -- the rule every 710.DesktopRice log writer follows.
if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
    Move-Item -LiteralPath $log -Destination "$log.old" -Force -ErrorAction SilentlyContinue
}
function Write-Log([string]$m) {
    try {
        '{0}  rotate-wallpaper: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m |
            Out-File -LiteralPath $log -Append -Encoding utf8
    } catch { }
}

function Get-GalleryFolder {
    # config\yasb\config.yaml's image_path, in its order.
    Join-Path $Root 'assets\wallpapers'
    foreach ($name in @('YASB_WALLPAPER_PATH') + @(2..10 | ForEach-Object { "YASB_WALLPAPER_PATH_$_" })) {
        $value = [Environment]::GetEnvironmentVariable($name, 'User')
        if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($name, 'Machine') }
        if (-not [string]::IsNullOrWhiteSpace($value)) { $value }
    }
}

function Get-GalleryFileType {
    # YASB 2.0.7's FILE_TYPES, and webp where its supported_types allows it: this build and its
    # UBR (the number after the dot in the OS build) against the first builds that take webp.
    $types = @('png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff')
    $build = [Environment]::OSVersion.Version.Build
    $ubr = 0
    try { $ubr = [int](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR) } catch { }
    if (($build -ge 26220 -and $ubr -ge 7653) -or ($build -ge 26100 -and $ubr -ge 8037)) { $types += 'webp' }
    $types
}

try {
    $folders = @(Get-GalleryFolder)
    $types = @(Get-GalleryFileType)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [Collections.Generic.List[string]]::new()
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $folder -File -Recurse -Force -ErrorAction SilentlyContinue) {
            $name = $file.Name.ToLowerInvariant()
            foreach ($type in $types) {
                if ($name.EndsWith($type)) {
                    if ($seen.Add($file.FullName)) { $files.Add($file.FullName) }
                    break
                }
            }
        }
    }
    $current = Get-CurrentWallpaper
    $choices = @($files | Where-Object { $_ -ne $current })
    if (-not $choices.Count) {
        Write-Log "nothing to change to: $($files.Count) wallpaper(s) in the gallery's $($folders.Count) folder(s), none but the one that's up"
        exit 3
    }
    $pick = Get-Random -InputObject $choices
    Write-Log ('picked {0} ({1} to choose from)' -f (Split-Path -Leaf $pick), $choices.Count)

    try { Set-DesktopWallpaper -Path $pick }
    catch {
        Write-Log "Windows didn't take it: $(ConvertTo-SafeText $_.Exception.Message)"
        exit 4
    }

    # pwsh.exe by name, the way 710.ahk and YASB start it.
    $pipeline = Join-Path $Root 'tools\apply-wallust-outputs.ps1'
    $null = & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $pipeline -Image $pick 2>&1
    $code = $LASTEXITCODE
    Write-Log "theme run: exit $code"
    exit $(if ($code -in 0, 1, 2) { $code } else { 5 })
} catch {
    Write-Log "failed: $(ConvertTo-SafeText $_.Exception.Message)"
    exit 5
}
