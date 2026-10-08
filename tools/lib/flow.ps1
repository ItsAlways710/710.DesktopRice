<#
.SYNOPSIS
  Flow Launcher's files and its own sign-in start: where its settings are and reading them, its
  own task or Run value, stopping it; and the snapshots the flow component takes before it changes
  anything (Save-FlowSnapshots) and puts back on uninstall (Restore-FlowLauncherSettings). Shared
  by the flow component (tools\components\flow.ps1: its step, its revert, doctor's lines), which
  keeps what the step changes (Get-FlowSetup). Loaded by tools\lib\activation.ps1. Only functions.
#>

function Get-FlowPaths {
    $data = Join-Path $env:APPDATA 'FlowLauncher'
    [pscustomobject]@{
        Exe      = Join-Path $env:LOCALAPPDATA 'FlowLauncher\Flow.Launcher.exe'
        Data     = $data
        Settings = Join-Path $data 'Settings\Settings.json'
        Explorer = Join-Path $data 'Settings\Plugins\Flow.Launcher.Plugin.Explorer\Settings.json'
        Plugins  = Join-Path $data 'Plugins'
    }
}

function Read-FlowJson {
    # A settings file as a hashtable; $null when it isn't there. A file that doesn't parse
    # throws -- never treated as "not there" (that would start the first-run path over a
    # real profile).
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
    catch { throw "$(ConvertTo-SafePath $Path) isn't readable JSON ($($_.Exception.Message))" }
}

function Test-FlowProfile {
    # Flow has run: both files it creates on its first start are there. -Readable: and they
    # parse (the first start's wait -- a file mid-write isn't ready yet).
    param($Paths, [switch]$Readable)
    if (-not (Test-Path -LiteralPath $Paths.Settings) -or -not (Test-Path -LiteralPath $Paths.Explorer)) { return $false }
    if (-not $Readable) { return $true }
    try { [bool](Read-FlowJson $Paths.Settings) -and [bool](Read-FlowJson $Paths.Explorer) } catch { $false }
}

function Get-FlowField {
    # {Existed, Value} -- so a restore can tell "was false" apart from "wasn't there".
    param([System.Collections.IDictionary]$Table, [string]$Key)
    @{ Existed = [bool]($Table -and $Table.Contains($Key)); Value = $(if ($Table) { $Table[$Key] }) }
}

function Test-FlowOwnTask {
    # Flow's own sign-in task (AutoStartup.cs: "Flow.Launcher Startup", in the root folder).
    $null = & schtasks.exe /Query /TN '\Flow.Launcher Startup' 2>&1
    $LASTEXITCODE -eq 0
}

function Test-FlowRunValue {
    # The HKCU Run value Flow uses when its task option is off.
    [bool](Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)
}

function Stop-FlowLauncher {
    # Flow (the stub and the app are both Flow.Launcher) stopped; $true when it was running.
    $flow = @(Get-Process -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)
    if (-not $flow.Count) { return $false }
    $flow | Stop-Process -Force -ErrorAction SilentlyContinue
    $flow | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
    $true
}

function Save-FlowSnapshots {
    # Each once, before the first change it covers (see the file's header), from the files
    # as they are now. The fonts and the fullscreen setting only when this run changes them
    # -- doctor reads those two snapshots as "710sRice set it here".
    param($Paths, $Setup)
    $settings = Read-FlowJson $Paths.Settings
    $explorer = Read-FlowJson $Paths.Explorer
    $plugins  = if ($settings['PluginSettings']) { $settings['PluginSettings']['Plugins'] }
    $programId  = '791FC278BA414111B8D1886DFE447410'
    $explorerId = '572be03c74c642baae319fc283e561a8'
    $program = if ($plugins -and $plugins.Contains($programId)) { $plugins[$programId] }
    Save-OriginalState -Label 'flow-settings' -Data @{
        ProgramPluginId       = $programId
        ActionKeywordsExisted = [bool]($program -and $null -ne $program['ActionKeywords'])
        ActionKeywords        = @(if ($program -and $null -ne $program['ActionKeywords']) { @($program['ActionKeywords']) })
        Identity              = @{
            HideNotifyIcon      = Get-FlowField $settings 'HideNotifyIcon'
            AutoUpdates         = Get-FlowField $settings 'AutoUpdates'
            AutoUpdatePlugins   = Get-FlowField $settings 'AutoUpdatePlugins'
            DontPromptUpdateMsg = Get-FlowField $settings 'DontPromptUpdateMsg'
        }
    }
    $entry = if ($plugins -and $plugins.Contains($explorerId)) { $plugins[$explorerId] }
    Save-OriginalState -Label 'flow-explorer-settings' -Data @{
        ExplorerPluginId      = $explorerId
        ActionKeywordsExisted = [bool]($entry -and $null -ne $entry['ActionKeywords'])
        ActionKeywords        = @(if ($entry -and $null -ne $entry['ActionKeywords']) { @($entry['ActionKeywords']) })
        ExplorerFileExisted   = [bool]$explorer
        Fields                = @{
            FileSearchActionKeyword  = Get-FlowField $explorer 'FileSearchActionKeyword'
            FileSearchKeywordEnabled = Get-FlowField $explorer 'FileSearchKeywordEnabled'
            IndexSearchEngine        = Get-FlowField $explorer 'IndexSearchEngine'
        }
    }
    Save-OriginalState -Label 'flow-querymode' -Data @{ LastQueryMode = Get-FlowField $settings 'LastQueryMode' }
    Save-OriginalState -Label 'flow-startup' -Data @{
        StartFlowLauncherOnSystemStartup = Get-FlowField $settings 'StartFlowLauncherOnSystemStartup'
        UseLogonTaskForStartup           = Get-FlowField $settings 'UseLogonTaskForStartup'
    }
    if ($Setup.FontsWrong.Count) {
        Save-OriginalState -Label 'flow-fonts' -Data @{
            QueryBoxFont  = Get-FlowField $settings 'QueryBoxFont'
            ResultFont    = Get-FlowField $settings 'ResultFont'
            ResultSubFont = Get-FlowField $settings 'ResultSubFont'
        }
    }
    if ($Setup.FullscreenOff) { Save-OriginalState -Label 'flow-fullscreen' -Data @{ IgnoreHotkeysOnFullscreen = Get-FlowField $settings 'IgnoreHotkeysOnFullscreen' } }
}

function Restore-FlowLauncherSettings {
    <# Uninstall: Flow's settings back from the six snapshots, and the legacy Everything
       plugin folder removed if one is still there (matched by its plugin ID). Flow is stopped
       first and NOT started again (uninstall runs elevated; the package goes next anyway).
       Read-modify-write of the current files, so anything else changed in Flow since
       survives. $false when no snapshot was ever taken (nothing to restore). #>
    $p = Get-FlowPaths
    $labels = 'flow-settings', 'flow-explorer-settings', 'flow-querymode', 'flow-startup', 'flow-fonts', 'flow-fullscreen'
    $snap = @{}; foreach ($l in $labels) { $snap[$l] = Get-OriginalState -Label $l }
    [void](Stop-FlowLauncher)
    if (Test-Path -LiteralPath $p.Plugins) {
        Get-ChildItem -LiteralPath $p.Plugins -Directory -ErrorAction SilentlyContinue | Where-Object {
            $manifest = Join-Path $_.FullName 'plugin.json'
            (Test-Path -LiteralPath $manifest) -and ((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).ID -eq 'D2D2C23B084D411DB66FE0C79D6C2A6E')
        } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not @($snap.Values | Where-Object { $_ }).Count) { return $false }
    $settings = Read-FlowJson $p.Settings
    if (-not $settings) {
        Step-Info 'Flow Launcher Settings.json not found -- nothing to restore.'
        foreach ($l in $labels) { Remove-OriginalState -Label $l }
        return $true
    }
    $plugins = if ($settings['PluginSettings']) { $settings['PluginSettings']['Plugins'] }
    $put = {
        param($Table, $Key, $Field)
        if ($Field.Existed) { $Table[$Key] = $Field.Value } elseif ($Table.Contains($Key)) { $Table.Remove($Key) }
    }
    if ($s = $snap['flow-settings']) {
        if ($plugins -and $plugins.Contains($s.ProgramPluginId)) {
            $program = $plugins[$s.ProgramPluginId]
            if ($s.ActionKeywordsExisted) { $program['ActionKeywords'] = @($s.ActionKeywords) }
            elseif ($program.Contains('ActionKeywords')) { $program.Remove('ActionKeywords') }
        }
        foreach ($k in $s.Identity.Keys) { & $put $settings $k $s.Identity[$k] }
    }
    if ($s = $snap['flow-explorer-settings']) {
        if ($plugins -and $plugins.Contains($s.ExplorerPluginId)) {
            $entry = $plugins[$s.ExplorerPluginId]
            if ($s.ActionKeywordsExisted) { $entry['ActionKeywords'] = @($s.ActionKeywords) }
            elseif ($entry.Contains('ActionKeywords')) { $entry.Remove('ActionKeywords') }
        }
        $explorer = Read-FlowJson $p.Explorer
        if ($s.ExplorerFileExisted -and $explorer) {
            foreach ($k in $s.Fields.Keys) { & $put $explorer $k $s.Fields[$k] }
            $explorer | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $p.Explorer -Encoding UTF8
        }
    }
    if ($s = $snap['flow-querymode']) { & $put $settings 'LastQueryMode' $s.LastQueryMode }
    # Flow's own sign-in start: its two settings as they were. Flow makes its own task (or
    # Run value) again the next time it starts, if they were on.
    if ($s = $snap['flow-startup']) { foreach ($k in $s.Keys) { & $put $settings $k $s[$k] } }
    if ($s = $snap['flow-fonts']) { foreach ($k in $s.Keys) { & $put $settings $k $s[$k] } }
    if ($s = $snap['flow-fullscreen']) { & $put $settings 'IgnoreHotkeysOnFullscreen' $s.IgnoreHotkeysOnFullscreen }
    $settings | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $p.Settings -Encoding UTF8
    foreach ($l in $labels) { Remove-OriginalState -Label $l }
    $true
}
