<#
.SYNOPSIS
    Flow Launcher setup: scoped search keywords ("app " = installed programs, "f " = file
    search on voidtools Everything), identity toggles (single tray icon, no self-update
    nag), and removal of the legacy standalone Everything plugin. Idempotent.

.DESCRIPTION
    Keywords (both additive -- Flow's "*" global search is untouched):
      - "app" on the built-in Program plugin: 710.ahk's SUPER+Ctrl+Space preloads "app ",
        so that search is scoped to installed programs (parity with Omarchy's Walker Apps).
      - "f" on the built-in Explorer plugin, as its FILE SEARCH keyword, with the plugin's
        index engine set to Everything: 710.ahk's SUPER+S preloads "f ". Two places have
        to agree, checked against Flow 2.1.3's own source: Flow's core routes a typed
        "f ..." to whichever plugin lists "f" in its ActionKeywords (Settings.json), and
        the Explorer plugin then decides what "f" MEANS from its own settings file
        (FileSearchActionKeyword + FileSearchKeywordEnabled; IndexSearchEngine 1 =
        Everything, 0 = Windows Search).
    Legacy Everything plugin (Flow.Launcher.Plugin.Everything, ID D2D2C23B...): this script
    used to install it (pinned v1.7.7). It's archived upstream and fails on Flow 2.x, and
    the built-in Explorer plugin on the Everything engine replaces it -- so it's now
    REMOVED (folder + its Settings.json entry). Ported from winarchy a4dd1f7 (v1.5.0),
    which reached the same conclusion; Flow 2.1.3 / Everything 1.4.1.1032 are the versions
    both repos pin.

    Flow is STOPPED before anything is written, and deliberately NOT relaunched:
      - A running Flow keeps its settings in memory and saves them back over the files on
        exit, and holds its plugin DLLs locked (the likely source of the old "Access-Denied
        on Everything-plugin DLLs" install anomaly). Force-stopping it first means our
        writes stick and the legacy folder can actually be deleted. (Winarchy a4dd1f7's
        Save-WinarchyFlowSettings does the same.)
      - Not relaunched because install.ps1 usually runs elevated: a Flow started from here
        would run as admin, and so would everything launched from it (the same trap as an
        AHK restarted from an admin shell). The next SUPER+Space / SUPER+S / SUPER+Ctrl+Space
        cold-starts it through non-elevated AHK instead.

    Identity toggles: HideNotifyIcon (710.ahk hosts the one shared tray icon) and
    AutoUpdates/AutoUpdatePlugins/DontPromptUpdateMsg off (Flow is version-pinned).

    Query box: LastQueryMode = Empty, so Flow always opens blank. Flow's default
    (Selected) reopens with the previous query still in the box, so a plain SUPER+Space
    showed whatever SUPER+S / SUPER+Ctrl+Space had typed last ('f ' / 'app '). The scoped
    hotkeys type their own keyword, so they don't need the old query either.

    True-uninstall snapshots (restored by tools\lib\activation.ps1's
    Restore-FlowLauncherSettings), each taken ONCE, before the first change they cover:
      - 'flow-settings'          Program keywords + identity toggles (unchanged shape).
      - 'flow-explorer-settings' Explorer keywords + its three file-search fields. Separate
        label because 'flow-settings' predates them and is snapshot-once by design -- on a
        machine that already has it, those fields would never be captured.
      - 'flow-querymode'         LastQueryMode, its own label for the same reason.

    Requires Flow to have run at least once (so Settings.json exists). pwsh 7+ only
    (ConvertFrom-Json -AsHashtable).
#>

$ErrorActionPreference = 'Stop'

function Save-OriginalStateOnce {
    <# Self-contained one-time snapshot -- this script has no dependency on tools\lib\
       activation.ps1 and this keeps it that way, so this duplicates that file's
       Save-OriginalState rather than dot-sourcing it. Same path convention
       (%LOCALAPPDATA%\710.DesktopRice\original-state\<label>.json), so uninstall.ps1's
       Restore-FlowLauncherSettings (which DOES dot-source that file) can read what this
       writes. Keep both copies in sync if this shape ever changes. #>
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)]$Data)
    $dir = Join-Path $env:LOCALAPPDATA '710.DesktopRice\original-state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir "$Label.json"
    if (Test-Path $file) { return }
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
}

function Get-Field([hashtable]$Table, [string]$Key) {
    # {Existed, Value} -- so a restore can tell "was false" apart from "wasn't there".
    @{ Existed = [bool]($Table -and $Table.ContainsKey($Key)); Value = $(if ($Table) { $Table[$Key] }) }
}

$programPluginId        = '791FC278BA414111B8D1886DFE447410'   # built-in Program
$explorerPluginId       = '572be03c74c642baae319fc283e561a8'   # built-in Explorer
$legacyEverythingPlugin = 'D2D2C23B084D411DB66FE0C79D6C2A6E'   # standalone Everything plugin (archived)

$flowRoot     = Join-Path $env:APPDATA 'FlowLauncher'
$settingsPath = Join-Path $flowRoot 'Settings\Settings.json'
$explorerPath = Join-Path $flowRoot 'Settings\Plugins\Flow.Launcher.Plugin.Explorer\Settings.json'
$pluginsDir   = Join-Path $flowRoot 'Plugins'
$everythingExe = @("$env:ProgramFiles\Everything\Everything.exe", "${env:ProgramFiles(x86)}\Everything\Everything.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not (Test-Path $settingsPath)) {
    Write-Warning "Flow Launcher Settings.json not found at $settingsPath -- run Flow Launcher at least once first, then re-run this script."
    exit 1
}

$settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
$plugins  = $settings['PluginSettings']['Plugins']
$explorer = if (Test-Path $explorerPath) { Get-Content $explorerPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }

# --- Snapshots (once each, before anything below can change what they capture) ---------
$programExisted = $plugins -and $plugins.ContainsKey($programPluginId)
Save-OriginalStateOnce -Label 'flow-settings' -Data @{
    ProgramPluginId       = $programPluginId
    ActionKeywordsExisted = $programExisted -and $null -ne $plugins[$programPluginId]['ActionKeywords']
    ActionKeywords        = if ($programExisted) { @(if ($null -eq $plugins[$programPluginId]['ActionKeywords']) { @() } else { @($plugins[$programPluginId]['ActionKeywords']) }) } else { @() }
    Identity              = @{
        HideNotifyIcon      = Get-Field $settings 'HideNotifyIcon'
        AutoUpdates         = Get-Field $settings 'AutoUpdates'
        AutoUpdatePlugins   = Get-Field $settings 'AutoUpdatePlugins'
        DontPromptUpdateMsg = Get-Field $settings 'DontPromptUpdateMsg'
    }
}
$explorerEntry = if ($plugins -and $plugins.ContainsKey($explorerPluginId)) { $plugins[$explorerPluginId] }
Save-OriginalStateOnce -Label 'flow-explorer-settings' -Data @{
    ExplorerPluginId      = $explorerPluginId
    ActionKeywordsExisted = [bool]($explorerEntry -and $null -ne $explorerEntry['ActionKeywords'])
    ActionKeywords        = @(if ($explorerEntry -and $null -ne $explorerEntry['ActionKeywords']) { @($explorerEntry['ActionKeywords']) })
    ExplorerFileExisted   = [bool]$explorer
    Fields                = @{
        FileSearchActionKeyword  = Get-Field $explorer 'FileSearchActionKeyword'
        FileSearchKeywordEnabled = Get-Field $explorer 'FileSearchKeywordEnabled'
        IndexSearchEngine        = Get-Field $explorer 'IndexSearchEngine'
    }
}

Save-OriginalStateOnce -Label 'flow-querymode' -Data @{
    LastQueryMode = Get-Field $settings 'LastQueryMode'
}

$settingsChanged = $false
$explorerChanged = $false
$todo = [System.Collections.Generic.List[string]]::new()

function Add-Keyword([string]$PluginId, [string]$Keyword, [string]$Label) {
    <# Additive: appends $Keyword to that plugin's ActionKeywords if it isn't there. The
       outer @(...) is load-bearing: without it, a one-element list (e.g. just ["*"])
       collapses to a bare string and `+ 'app'` string-concatenates into "*app" -- this
       repo's own 8a55240 fix, and exactly the bug winarchy fixed in a4dd1f7. #>
    if (-not $plugins -or -not $plugins.ContainsKey($PluginId)) {
        Write-Warning "Flow's $Label plugin settings not found (has Flow run at least once?) -- '$Keyword' keyword not applied."
        return
    }
    $keywords = @(if ($null -eq $plugins[$PluginId]['ActionKeywords']) { @() } else { @($plugins[$PluginId]['ActionKeywords']) })
    if ($keywords -contains $Keyword) { return }
    $plugins[$PluginId]['ActionKeywords'] = @($keywords) + $Keyword
    $script:settingsChanged = $true
    $todo.Add("$Label keyword '$Keyword'")
}

# --- Keywords -----------------------------------------------------------------------------
Add-Keyword $programPluginId 'app' 'Program'
Add-Keyword $explorerPluginId 'f' 'Explorer'

# --- Explorer plugin: file search on the Everything index ---------------------------------
if (-not $explorer) {
    Write-Warning "Flow Explorer plugin settings not found at $explorerPath (has Flow run at least once?) -- file search keyword not applied."
} else {
    $desired = [ordered]@{ FileSearchActionKeyword = 'f'; FileSearchKeywordEnabled = $true }
    if ($everythingExe) { $desired['IndexSearchEngine'] = 1 }   # 1 = Everything (0 = Windows Search)
    else { Write-Warning 'voidtools Everything not installed -- Explorer file search left on its current engine (winget install voidtools.Everything).' }
    foreach ($k in $desired.Keys) {
        if ($explorer[$k] -ne $desired[$k]) { $explorer[$k] = $desired[$k]; $explorerChanged = $true }
    }
    if ($explorerChanged) { $todo.Add("Explorer file search ('f', engine $(if ($everythingExe) { 'Everything' } else { 'unchanged' }))") }
}

# --- Legacy standalone Everything plugin: settings entry + folder ---------------------------
if ($plugins -and $plugins.ContainsKey($legacyEverythingPlugin)) {
    $plugins.Remove($legacyEverythingPlugin)
    $settingsChanged = $true
    $todo.Add('legacy Everything plugin settings entry removed')
}
$legacyDirs = @(if (Test-Path $pluginsDir) {
    Get-ChildItem $pluginsDir -Directory -ErrorAction SilentlyContinue | Where-Object {
        $manifest = Join-Path $_.FullName 'plugin.json'
        (Test-Path $manifest) -and ((Get-Content $manifest -Raw | ConvertFrom-Json).ID -eq $legacyEverythingPlugin)
    }
})

# --- Identity: unified tray icon, no self-update nag --------------------------------------
$identity = [ordered]@{ HideNotifyIcon = $true; AutoUpdates = $false; AutoUpdatePlugins = $false; DontPromptUpdateMsg = $true }
foreach ($k in $identity.Keys) {
    if (-not $settings.ContainsKey($k) -or $settings[$k] -ne $identity[$k]) {
        $settings[$k] = $identity[$k]
        if (-not $todo.Contains('identity toggles')) { $todo.Add('identity toggles') }
        $settingsChanged = $true
    }
}

# --- Query box: open empty (see header) ----------------------------------------------------
if ($settings['LastQueryMode'] -ne 'Empty') {
    $settings['LastQueryMode'] = 'Empty'
    $settingsChanged = $true
    $todo.Add('query box opens empty')
}

if (-not $settingsChanged -and -not $explorerChanged -and $legacyDirs.Count -eq 0) {
    Write-Host 'Flow Launcher already fully configured.'
    exit 0
}

# --- Apply, with Flow stopped (see header for why it isn't relaunched) ----------------------
$flow = @(Get-Process -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)
if ($flow.Count) {
    $flow | Stop-Process -Force
    $flow | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
    Write-Host 'Flow Launcher stopped to write its settings -- it starts again on your next SUPER+Space / SUPER+S.'
}
if ($settingsChanged) {
    Copy-Item $settingsPath "$settingsPath.bak" -Force   # quick previous-write copy; the snapshot above is what uninstall restores
    $settings | ConvertTo-Json -Depth 50 | Set-Content -Path $settingsPath -Encoding UTF8
}
if ($explorerChanged) {
    Copy-Item $explorerPath "$explorerPath.bak" -Force
    $explorer | ConvertTo-Json -Depth 50 | Set-Content -Path $explorerPath -Encoding UTF8
}
foreach ($d in $legacyDirs) {
    try {
        Remove-Item $d.FullName -Recurse -Force
        $todo.Add("legacy Everything plugin folder removed ($($d.Name))")
    } catch {
        Write-Warning "Couldn't remove the legacy Everything plugin folder $($d.FullName): $($_.Exception.Message)"
    }
}
Write-Host "Flow Launcher configured: $($todo -join '; ')."
