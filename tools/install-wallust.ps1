<#
.SYNOPSIS
    Downloads and installs the pinned wallust binary from its Codeberg release.

.DESCRIPTION
    wallust has no winget or scoop package, so this is the real mechanism
    install.ps1 will use for it. This script IS that logic, standalone, until
    install.ps1 exists and folds it in directly. Pinned deliberately (not
    "latest") since wallust is alpha software feeding live colors into
    komorebi borders, YASB, and Windows Terminal.

    The extracted binary lands in tools/bin/wallust/, inside the repo tree but
    gitignored — never committed, always re-downloadable byte-for-byte.
#>

$ErrorActionPreference = "Stop"

$WallustVersion = "4.1.0-alpha"
$AssetName      = "wallust-$WallustVersion-x86_64-pc-windows-gnu.tar.gz"
$SumsName       = "wallust-$WallustVersion-SHA256SUMS.txt"
$BaseUrl        = "https://codeberg.org/explosion-mental/wallust/releases/download/$WallustVersion"

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$TargetDir = Join-Path $RepoRoot "tools\bin\wallust"
$TempDir   = Join-Path $env:TEMP "wallust-install-$WallustVersion"

New-Item -ItemType Directory -Force -Path $TempDir   | Out-Null
New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null

$AssetPath = Join-Path $TempDir $AssetName
$SumsPath  = Join-Path $TempDir $SumsName

Write-Host "Downloading wallust $WallustVersion..."
Invoke-WebRequest -Uri "$BaseUrl/$AssetName" -OutFile $AssetPath
Invoke-WebRequest -Uri "$BaseUrl/$SumsName"  -OutFile $SumsPath

Write-Host "Verifying checksum..."
$expectedLine = Get-Content $SumsPath | Where-Object { $_ -match [regex]::Escape($AssetName) }
if (-not $expectedLine) {
    throw "Could not find a checksum entry for $AssetName in $SumsName"
}
$expectedHash = ($expectedLine -split '\s+')[0].ToLower()
$actualHash   = (Get-FileHash -Path $AssetPath -Algorithm SHA256).Hash.ToLower()
if ($expectedHash -ne $actualHash) {
    throw "Checksum mismatch for $AssetName`nExpected: $expectedHash`nActual:   $actualHash"
}
Write-Host "Checksum OK ($actualHash)."

Write-Host "Extracting..."
tar -xzf $AssetPath -C $TempDir

$exeSource = Get-ChildItem -Path $TempDir -Recurse -Filter "wallust.exe" | Select-Object -First 1
if (-not $exeSource) {
    throw "wallust.exe not found after extracting $AssetName"
}
Copy-Item -Path $exeSource.FullName -Destination (Join-Path $TargetDir "wallust.exe") -Force

Remove-Item -Recurse -Force $TempDir

Write-Host "wallust $WallustVersion installed to $TargetDir"
& (Join-Path $TargetDir "wallust.exe") --version
