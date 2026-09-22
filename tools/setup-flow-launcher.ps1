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
    $keywords = if ($null -eq $program['ActionKeywords']) { @() } else { @($program['ActionKeywords']) }
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
    Write-Host "Nothing to do -- Flow Launcher already fully configured: $settingsPath"
    exit 0
}

# Simple one-time backup before the JSON round-trip rewrite (we don't have
# winarchy's New-WinarchySnapshot module here -- this is the cheap
# equivalent, not a full snapshot system).
Copy-Item $settingsPath "$settingsPath.bak" -Force

$settings | ConvertTo-Json -Depth 50 | Set-Content -Path $settingsPath -Encoding UTF8
Write-Host "Flow Launcher settings updated: $settingsPath"
Write-Host "Backup of the previous Settings.json saved to: $settingsPath.bak"
