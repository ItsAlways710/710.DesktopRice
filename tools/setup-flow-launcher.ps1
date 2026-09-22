<#
.SYNOPSIS
    One-time setup for Flow Launcher: merges the "app" ActionKeyword into its
    own Settings.json (scoped to the built-in Program plugin), and applies
    the project's identity toggles (unified tray icon, no self-update nag).

.DESCRIPTION
    Ported from winarchy's Set-WinarchyFlowAppsKeyword and
    Set-WinarchyFlowIdentity (module/Winarchy/Private/Identity.ps1). Additive
    only for the ActionKeyword -- does not touch Flow's "*" global search
    keyword or anything else in Settings.json. Idempotent: safe to re-run,
    only backs up and writes if something actually needs to change.

    Also installs the official Flow-Launcher.Plugin.Everything plugin (pinned v1.7.7,
    from its GitHub release zip) if it's missing -- ported from winarchy's
    Install-WinarchyFlowEverythingPlugin (Identity.ps1 @ 4574fc7, tag v1.4.0). Without it,
    Flow falls back to its own much slower/weaker "Explorer" plugin for file search, which
    defeats voidtools Everything being installed at all. Requires Everything itself to
    already be installed (install.ps1 brings it via winget); if it isn't, the plugin would
    be inert, so this just warns and skips rather than downloading it for nothing.

    ActionKeyword merge: this is what makes 710.ahk's ToggleFlowApps()
    (SUPER+Ctrl+Space) actually scope its query to installed programs only --
    real parity with Omarchy's Walker "Apps" launcher, no hand-curated app
    list. Flow already indexes installed programs itself; this just gives
    that index its own keyword.

    Identity toggles: HideNotifyIcon (Flow keeps its own tray icon hidden --
    710.DesktopRice uses a single shared tray icon hosted by 710.ahk, same
    approach winarchy uses) and AutoUpdates/AutoUpdatePlugins/
    DontPromptUpdateMsg (Flow stops checking for and nagging about its own
    updates -- independent of anything this repo's own install.ps1/doctor
    will eventually do).

    Requires Flow Launcher to have been run at least once (so its
    Settings.json and Program-plugin entry exist). Run this by hand for now
    -- folds into install.ps1 once that exists, see
    claude/winarchy-decoupling-plan.md.

    Must be run with pwsh (PowerShell 7+), not legacy `powershell.exe` --
    ConvertFrom-Json -AsHashtable isn't available in Windows PowerShell 5.1.
#>

$ErrorActionPreference = 'Stop'

$settingsPath = Join-Path "$env:APPDATA\FlowLauncher" 'Settings\Settings.json'
if (-not (Test-Path $settingsPath)) {
    Write-Warning "Flow Launcher Settings.json not found at $settingsPath -- run Flow Launcher at least once first, then re-run this script."
    exit 1
}

$settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
$changed = $false

# --- ActionKeyword: "app" scoped to the built-in Program plugin ------------
# Fixed ID of Flow's built-in "Program" plugin (Flow.Launcher.Plugin.Program/plugin.json).
$programPluginId = '791FC278BA414111B8D1886DFE447410'
$plugins = $settings['PluginSettings']['Plugins']
if (-not $plugins -or -not $plugins.ContainsKey($programPluginId)) {
    Write-Warning "Flow's Program plugin settings not found (did you run Flow Launcher at least once?) -- Apps keyword not applied."
} else {
    $program = $plugins[$programPluginId]
    # The outer @(...) around the whole if/else is load-bearing, not stylistic: without
    # it, assigning the OUTPUT of an if/else statement collapses a single-element array
    # to a bare scalar (same class of footgun as compile-komorebi-rules.ps1's documented
    # "return @(), @()" case, just triggered by if/else assignment instead of return).
    # Confirmed by direct repro: a pre-existing single-keyword ActionKeywords (e.g. just
    # ["*"]) silently became the STRING "*", so `+ 'app'` string-concatenated instead of
    # array-appending, and a second run concatenated onto the corrupted result again.
    $keywords = @(if ($null -eq $program['ActionKeywords']) { @() } else { @($program['ActionKeywords']) })
    if ($keywords -contains 'app') {
        Write-Host "Apps keyword already applied."
    } else {
        $program['ActionKeywords'] = $keywords + 'app'
        $changed = $true
        Write-Host "Apps keyword will be applied ('app ')."
    }
}

# --- Identity: unified tray icon, no self-update nag ------------------------
$identity = @{
    HideNotifyIcon      = $true
    AutoUpdates         = $false
    AutoUpdatePlugins   = $false
    DontPromptUpdateMsg = $true
}
$identityNeeded = $false
foreach ($k in $identity.Keys) {
    if (-not $settings.ContainsKey($k) -or $settings[$k] -ne $identity[$k]) {
        $identityNeeded = $true
        break
    }
}
if ($identityNeeded) {
    foreach ($k in $identity.Keys) { $settings[$k] = $identity[$k] }
    $changed = $true
    Write-Host "Identity toggles will be applied (tray hidden, self-update off)."
} else {
    Write-Host "Identity toggles already applied."
}

if (-not $changed) {
    Write-Host "Settings.json already fully configured: $settingsPath"
} else {
    # Simple one-time backup before the JSON round-trip rewrite (we don't have
    # winarchy's New-WinarchySnapshot module here -- this is the cheap
    # equivalent, not a full snapshot system).
    Copy-Item $settingsPath "$settingsPath.bak" -Force
    $settings | ConvertTo-Json -Depth 50 | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Host "Flow Launcher settings updated: $settingsPath"
    Write-Host "Backup of the previous Settings.json saved to: $settingsPath.bak"
}

# Everything-plugin install below always runs, even when Settings.json itself needed no
# change -- it used to sit behind an early `exit 0` here on the (very common) idempotent
# path, which meant a re-run could never actually install the plugin once the keyword/
# identity settings were already correct. Fixed so both steps are independently idempotent
# instead of the second depending on the first having work to do.

# --- Everything plugin: pinned release zip, installed once, idempotent -------------
# Ported from winarchy's Install-WinarchyFlowEverythingPlugin (Identity.ps1 @ 4574fc7).
$EverythingPluginId = 'D2D2C23B084D411DB66FE0C79D6C2A6E'
$EverythingPluginVersion = '1.7.7'
$EverythingPluginUrl = "https://github.com/Flow-Launcher/Flow.Launcher.Plugin.Everything/releases/download/v$EverythingPluginVersion/Flow.Launcher.Plugin.Everything.zip"

$everythingExe = @("$env:ProgramFiles\Everything\Everything.exe", "${env:ProgramFiles(x86)}\Everything\Everything.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $everythingExe) {
    Write-Warning 'voidtools Everything not installed; Flow Everything plugin not installed (winget install voidtools.Everything).'
} else {
    $pluginsDir = Join-Path "$env:APPDATA\FlowLauncher" 'Plugins'
    $alreadyInstalled = (Test-Path $pluginsDir) -and (
        Get-ChildItem $pluginsDir -Directory -ErrorAction SilentlyContinue | Where-Object {
            $manifest = Join-Path $_.FullName 'plugin.json'
            (Test-Path $manifest) -and ((Get-Content $manifest -Raw | ConvertFrom-Json).ID -eq $EverythingPluginId)
        } | Select-Object -First 1
    )
    if ($alreadyInstalled) {
        Write-Host 'Flow Everything plugin already installed.'
    } elseif (-not (Test-Path $pluginsDir)) {
        Write-Warning 'Flow Launcher Plugins dir not found (did you run Flow at least once?); Everything plugin not installed.'
    } else {
        $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) 'Flow.Launcher.Plugin.Everything.zip'
        $destDir = Join-Path $pluginsDir "Everything-$EverythingPluginVersion"
        try {
            Invoke-WebRequest -Uri $EverythingPluginUrl -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath $destDir -Force
            Write-Host "Flow Everything plugin installed: $destDir (restart Flow to load it)"
        } catch {
            Write-Warning "Could not install the Flow Everything plugin: $($_.Exception.Message)"
        } finally {
            Remove-Item $zipPath -ErrorAction SilentlyContinue
        }
    }
}
