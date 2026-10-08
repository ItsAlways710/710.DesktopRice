# Flow Launcher (Group 1 #4 + W3): started by 710.ahk, set up on the very first install, and its
# settings kept the way 710.ahk's three Flow hotkeys need them.
#
# Start: 710.ahk runs Flow's stable root Flow.Launcher.exe (the Squirrel stub; it starts
# app-<version>\Flow.Launcher.exe) as you, as it loads -- so at sign-in on a full-time machine,
# with `710sRice start` on an on-demand one -- and whenever Flow has to come back
# (config\ahk\710.ahk, "The apps 710.ahk starts"). That replaces Flow's own "start on system
# startup" task, which has traps of its own: Flow creates it with RunLevel Highest whenever the
# Flow creating it runs elevated and never lowers it again, points it at the versioned exe Flow's
# updater deletes, and only creates it the next time Flow starts -- and a task's job keeps what
# you open from Flow from starting programs of its own (Mod Organizer 2's tools: Error 5).
# \710.DesktopRice\flow, our own task until 2026-10-06, had that last trap; the tasks step
# retires it. Exactly one thing may start Flow at sign-in -- a second start shows Flow's window
# (App.xaml.cs OnSecondAppStarted) -- so this step switches Flow's own off.
#
# Why Flow must already be running before the first SUPER+Space (read in Flow 2.1.3's source):
# it starts hidden (HideOnStartup) and registers its hotkey only at the end of its startup
# (App.xaml.cs:237, after a plugin-manifest download at :221). 710.ahk's cold start (Flow not
# running) waits for that and then shows Flow through its own second-instance signal.
#
# Settings (Settings.json and the Explorer plugin's Settings.json), all additive -- Flow's "*"
# global search is untouched:
#   - "app" on the built-in Program plugin: SUPER+Ctrl+Space types "app " (installed programs).
#   - "f" on the built-in Explorer plugin as its FILE search keyword, on the Everything index:
#     SUPER+S types "f ". Two places have to agree (Flow 2.1.3's source): Flow's core routes a
#     typed "f ..." to whichever plugin lists "f" in its ActionKeywords (Settings.json), and the
#     Explorer plugin decides what "f" MEANS from its own file (FileSearchActionKeyword +
#     FileSearchKeywordEnabled; IndexSearchEngine 1 = Everything, 0 = Windows Search).
#   - Identity: HideNotifyIcon (710.ahk hosts the one tray icon), AutoUpdates / AutoUpdatePlugins
#     off and DontPromptUpdateMsg on (Flow is version-pinned).
#   - LastQueryMode = Empty: Flow always opens blank (its default reopened with 'f ' / 'app '
#     still in the box after a scoped search).
#   - Fonts (winarchy's Set-WinarchyFlowTheme, ported 2026-10-01): QueryBoxFont, ResultFont and
#     ResultSubFont = the JetBrainsMono Nerd Font (Get-NerdFontFace -- "JetBrainsMono NF", or the v2
#     name); not installed = left as they are, said so. Style / weight / stretch are left alone.
#   - IgnoreHotkeysOnFullscreen = true (winarchy's too): Flow ignores its hotkey -- so SUPER+Space,
#     SUPER+S and SUPER+Ctrl+Space, which send it -- while the FOCUSED window is fullscreen (Flow
#     2.1.3 MainViewModel.ShouldIgnoreHotkeys: the foreground window exactly covers its monitor).
#     Focus a window on another screen and Flow opens there.
#   - StartFlowLauncherOnSystemStartup / UseLogonTaskForStartup off, and \Flow.Launcher Startup
#     (or the HKCU Run value Flow.Launcher it uses instead) deleted: 710.ahk's start replaces them.
#   - The legacy standalone Everything plugin (ID D2D2C23B...) this repo once installed is
#     removed: archived upstream, broken on Flow 2.x, replaced by the Explorer plugin on the
#     Everything engine (winarchy a4dd1f7 reached the same conclusion).
#
# Flow is stopped before anything is written -- a running Flow keeps its settings in memory and
# saves them back over the files, and holds its plugin DLLs locked -- and the files are read again
# as the stopped Flow left them. It is started again by 710.ahk (asked -- this step runs in
# install's admin window, and only 710.ahk starts Flow) when it was running before; a Flow found
# running as admin is restarted that way too. Never started from here directly. No 710.ahk
# running: Flow stays closed until `710sRice start` (starting 710.ahk from here would start the
# bar and ShareX too).
#
# The first start (W3; winarchy 57fad9e's Initialize-WinarchyFlow, reshaped): Flow creates its
# settings files only when it first runs. Installed but never run -> started once through
# Start-AsUser (a one-shot task -- fine for a Flow that's stopped again seconds later), both files
# waited for (up to 30 s), Flow stopped, then set up -- so a first install
# sets Flow up in one run, and the theme step right after this one (After = 'wallust') themes it.
# Its Welcome window shows for those seconds, once (Flow saves FirstLaunch = false before opening it).
#
# Snapshots (uninstall puts back exactly what was there), each taken once, before the first change
# it covers: flow-settings (Program keywords + identity), flow-explorer-settings (Explorer keywords
# + its three file-search fields), flow-querymode (LastQueryMode), flow-startup (Flow's two
# startup settings), flow-fonts (the three fonts), flow-fullscreen (IgnoreHotkeysOnFullscreen).
# The first three kept their names from tools\setup-flow-launcher.ps1, whose body this is, so
# snapshots an existing install already has stay valid; an existing install takes the two new ones
# the next time the step changes something (each label is saved once, on its own).
# Doctor: the fonts and the fullscreen setting never set by 710sRice here (no snapshot), or changed
# since, = [XX] (like Terminal's font): repair and update set them again, as the step does every
# other setting.
#
# Flow's files, its own sign-in start and the snapshots' code are tools\lib\flow.ps1; what the
# step changes (Get-FlowSetup) is here.
@{
    Id    = 'flow'
    Label = 'Flow Launcher'
    After = 'wallust'
    Group = 'Integrations'

    Functions = {
        function Get-FlowSetup {
            <# What's off in Flow's settings, and the settings with it put right -- in memory; the
               caller writes. Findings: Item + Kind -- 'functional' (the search keywords, the
               engine, the old plugin, Flow updating itself), 'startup' (Flow starting itself at
               sign-in), 'preference' (the query box, the tray icon, the update prompt). #>
            param($Paths)
            $settings = Read-FlowJson $Paths.Settings
            $explorer = Read-FlowJson $Paths.Explorer
            $r = [pscustomobject]@{
                Settings = $settings; Explorer = $explorer; SettingsChanged = $false; ExplorerChanged = $false
                LegacyDirs = @(); OwnTask = $false; OwnRunValue = $false; Face = $null; FontsWrong = @(); FullscreenOff = $false; Notes = [System.Collections.Generic.List[string]]::new()
                Findings = [System.Collections.Generic.List[object]]::new(); Todo = [System.Collections.Generic.List[string]]::new()
            }
            $find = { param([string]$Item, [string]$Kind = 'functional') $r.Findings.Add([pscustomobject]@{ Item = $Item; Kind = $Kind }) }
            $plugins = if ($settings['PluginSettings']) { $settings['PluginSettings']['Plugins'] }
            $programId  = '791FC278BA414111B8D1886DFE447410'   # built-in Program
            $explorerId = '572be03c74c642baae319fc283e561a8'   # built-in Explorer
            $legacyId   = 'D2D2C23B084D411DB66FE0C79D6C2A6E'   # standalone Everything plugin (archived)

            # Keywords, additive. The outer @(...) is load-bearing: a one-element list (just "*")
            # would otherwise collapse to a string and `+ 'app'` make "*app" (8a55240; winarchy a4dd1f7).
            foreach ($k in @(@{ Id = $programId; Keyword = 'app'; Label = 'Program' }, @{ Id = $explorerId; Keyword = 'f'; Label = 'Explorer' })) {
                if (-not $plugins -or -not $plugins.Contains($k.Id)) { & $find "$($k.Label) plugin settings not found"; continue }
                $keywords = @(if ($null -ne $plugins[$k.Id]['ActionKeywords']) { @($plugins[$k.Id]['ActionKeywords']) })
                if ($keywords -contains $k.Keyword) { continue }
                & $find "'$($k.Keyword)' keyword missing"
                $plugins[$k.Id]['ActionKeywords'] = @($keywords) + $k.Keyword
                $r.SettingsChanged = $true
                $r.Todo.Add("$($k.Label) keyword '$($k.Keyword)'")
            }

            # Explorer: file search on 'f', on the Everything index (when Everything is installed).
            if (-not $explorer) {
                & $find 'Explorer plugin settings not found'
            } else {
                $everything = @("$env:ProgramFiles\Everything\Everything.exe", "${env:ProgramFiles(x86)}\Everything\Everything.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                $desired = [ordered]@{ FileSearchActionKeyword = 'f'; FileSearchKeywordEnabled = $true }
                if ($everything) { $desired['IndexSearchEngine'] = 1 }   # 1 = Everything (0 = Windows Search)
                $what = @{ FileSearchActionKeyword = "file search keyword isn't 'f'"; FileSearchKeywordEnabled = 'file search keyword is off'; IndexSearchEngine = "file search isn't on Everything" }
                foreach ($k in $desired.Keys) {
                    if ($explorer[$k] -ne $desired[$k]) { $explorer[$k] = $desired[$k]; $r.ExplorerChanged = $true; & $find $what[$k] }
                }
                if ($r.ExplorerChanged) { $r.Todo.Add("Explorer file search ('f', engine $(if ($everything) { 'Everything' } else { 'unchanged -- Everything isn''t installed' }))") }
            }

            # The legacy Everything plugin: its settings entry and its folder.
            if ($plugins -and $plugins.Contains($legacyId)) {
                & $find 'old Everything plugin still in its settings'
                $plugins.Remove($legacyId)
                $r.SettingsChanged = $true
                $r.Todo.Add('legacy Everything plugin settings entry removed')
            }
            $r.LegacyDirs = @(if (Test-Path -LiteralPath $Paths.Plugins) {
                Get-ChildItem -LiteralPath $Paths.Plugins -Directory -ErrorAction SilentlyContinue | Where-Object {
                    $manifest = Join-Path $_.FullName 'plugin.json'
                    (Test-Path -LiteralPath $manifest) -and ((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).ID -eq $legacyId)
                }
            })
            if ($r.LegacyDirs.Count) { & $find 'old Everything plugin still installed' }

            # Identity: one tray icon (710.ahk's), no self-updates, no update prompt.
            $identity = [ordered]@{ HideNotifyIcon = $true; AutoUpdates = $false; AutoUpdatePlugins = $false; DontPromptUpdateMsg = $true }
            $identityWhat = @{
                HideNotifyIcon      = @('tray icon shown', 'preference')
                AutoUpdates         = @('Flow updates itself', 'functional')
                AutoUpdatePlugins   = @('plugins update themselves', 'functional')
                DontPromptUpdateMsg = @('update prompt on', 'preference')
            }
            foreach ($k in $identity.Keys) {
                if (-not $settings.Contains($k) -or $settings[$k] -ne $identity[$k]) {
                    & $find $identityWhat[$k][0] $identityWhat[$k][1]
                    $settings[$k] = $identity[$k]
                    if (-not $r.Todo.Contains('identity toggles')) { $r.Todo.Add('identity toggles') }
                    $r.SettingsChanged = $true
                }
            }

            # The query box opens empty.
            if ($settings['LastQueryMode'] -ne 'Empty') {
                & $find 'the query box keeps the last search' 'preference'
                $settings['LastQueryMode'] = 'Empty'
                $r.SettingsChanged = $true
                $r.Todo.Add('query box opens empty')
            }

            # Fonts: the query box, results and result details in the Nerd Font.
            $r.Face = Get-NerdFontFace
            if ($r.Face) {
                $r.FontsWrong = @('QueryBoxFont', 'ResultFont', 'ResultSubFont' | Where-Object { "$($settings[$_])" -cne $r.Face })
                if ($r.FontsWrong.Count) {
                    & $find "fonts aren't the Nerd Font ($($r.FontsWrong -join ', '))" 'font'
                    foreach ($k in $r.FontsWrong) { $settings[$k] = $r.Face }
                    $r.SettingsChanged = $true
                    $r.Todo.Add("fonts $($r.Face)")
                }
            } else {
                $r.Notes.Add("the JetBrainsMono Nerd Font isn't installed -- Flow's fonts left as they are")
            }

            # Its hotkey is ignored while the focused window is fullscreen.
            if ($settings['IgnoreHotkeysOnFullscreen'] -ne $true) {
                $r.FullscreenOff = $true
                & $find 'opens over fullscreen windows' 'fullscreen'
                $settings['IgnoreHotkeysOnFullscreen'] = $true
                $r.SettingsChanged = $true
                $r.Todo.Add('its hotkey ignored over fullscreen windows')
            }

            # Flow's own sign-in start: off -- 710.ahk starts it (#4).
            $startup = $false
            foreach ($k in 'StartFlowLauncherOnSystemStartup', 'UseLogonTaskForStartup') {
                if ($settings[$k] -eq $true) { $settings[$k] = $false; $r.SettingsChanged = $true; $startup = $true }
            }
            $r.OwnTask = Test-FlowOwnTask
            $r.OwnRunValue = Test-FlowRunValue
            if ($startup -or $r.OwnTask -or $r.OwnRunValue) {
                & $find 'Flow also starts itself at sign-in (its own setting) -- two starts open its window' 'startup'
                $r.Todo.Add("its own sign-in start off (710.ahk starts it)")
            }
            $r
        }
    }

    Install = {
        param($Ctx)
        $p = Get-FlowPaths
        if (-not (Test-Path -LiteralPath $p.Exe)) {
            Step-Warn "Flow Launcher isn't installed -- skipped (the packages step installs it; then 710sRice install -Only flow)."
            return
        }
        $running  = @(Get-Process -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)
        $wasUp    = [bool]$running.Count
        $asAdmin  = $wasUp -and @($running | Where-Object { (Get-ProcessElevation -Id $_.Id) -eq 'elevated' }).Count

        # The first start (W3): Flow creates its settings files only when it first runs.
        if (-not (Test-FlowProfile $p)) {
            if (-not $wasUp) {
                Step-Info 'Flow Launcher has never run -- starting it once, as you, so it creates its settings (its Welcome window shows for a few seconds) ...'
                if (-not (Start-AsUser -Exe $p.Exe -Process 'Flow.Launcher' -Name 'flow-first-start' -TimeoutSeconds 15)) {
                    Write-Host "  [XX] Flow Launcher didn't start -- open it once (SUPER+Space), then 710sRice install -Only flow." -ForegroundColor Red
                    return
                }
            }
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Test-FlowProfile $p -Readable) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            Start-Sleep -Seconds 2   # let it finish what it's writing (winarchy's pause)
            [void](Stop-FlowLauncher)
            $wasUp = $false; $asAdmin = $false   # it only ran for this -- not started again below
            if (-not (Test-FlowProfile $p -Readable)) {
                Write-Host "  [XX] Flow Launcher didn't create its settings within 30 s -- open it once (SUPER+Space), then 710sRice install -Only flow." -ForegroundColor Red
                return
            }
            Step-Ok "Flow Launcher's settings created (its first start)"
        }

        $setup = Get-FlowSetup $p
        foreach ($n in $setup.Notes) { Step-Warn "Flow Launcher: $n (the packages step installs it; then 710sRice install -Only flow)" }
        $change = $setup.SettingsChanged -or $setup.ExplorerChanged -or $setup.LegacyDirs.Count -or $setup.OwnTask -or $setup.OwnRunValue
        if ($change -or $asAdmin) {
            if (Stop-FlowLauncher) { Step-Info "Flow Launcher stopped to $(if ($change) { 'write its settings' } else { 'start it again as you (it was running as admin)' })" }
        }
        if ($change) {
            # As the stopped Flow left them: the same changes on a fresh read, snapshots first.
            $setup = Get-FlowSetup $p
            Save-FlowSnapshots $p $setup
            if ($setup.SettingsChanged) {
                Copy-Item -LiteralPath $p.Settings -Destination "$($p.Settings).bak" -Force   # a quick previous copy; the snapshots are what uninstall restores
                $setup.Settings | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $p.Settings -Encoding UTF8
            }
            if ($setup.ExplorerChanged) {
                Copy-Item -LiteralPath $p.Explorer -Destination "$($p.Explorer).bak" -Force
                $setup.Explorer | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $p.Explorer -Encoding UTF8
            }
            foreach ($d in $setup.LegacyDirs) {
                try { Remove-Item -LiteralPath $d.FullName -Recurse -Force; $setup.Todo.Add("legacy Everything plugin folder removed ($($d.Name))") }
                catch { Step-Warn "Couldn't remove the legacy Everything plugin folder $(ConvertTo-SafePath $d.FullName): $($_.Exception.Message)" }
            }
            if ($setup.OwnTask) {
                $null = & schtasks.exe /Delete /TN '\Flow.Launcher Startup' /F 2>&1
                if ($LASTEXITCODE -ne 0) { Write-Host "  [XX] Couldn't delete Flow's own sign-in task (\Flow.Launcher Startup, schtasks exit $LASTEXITCODE) -- run 710sRice install -Only flow again" -ForegroundColor Red }
            }
            if ($setup.OwnRunValue) {
                try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Flow.Launcher' -ErrorAction Stop }
                catch { Step-Warn "Couldn't remove Flow's own Run value (Flow.Launcher): $($_.Exception.Message)" }
            }
            Step-Ok "Flow Launcher configured: $($setup.Todo -join '; ')"
        } else {
            Step-Ok 'Flow Launcher already set up'
        }

        # Started again as it was -- by 710.ahk, as you, never from this admin window (see the
        # header).
        if (($wasUp -or $asAdmin) -and -not (Get-Process -Name 'Flow.Launcher' -ErrorAction SilentlyContinue)) {
            $r = Start-AhkStartedApps -Keys 'flow' -NoAhkStart -WaitSeconds 15
            if ($r.Up.Count) { Step-Ok 'Flow Launcher started again (by 710.ahk, as you)' }
            elseif ($r.NoAhk) { Step-Warn "Flow Launcher stays closed for now: only 710.ahk starts it, and 710.ahk isn't running -- 710sRice start starts both" }
            else { Step-Warn "710.ahk was asked to start Flow Launcher again, but it isn't up after 15 s -- SUPER+Space starts it" }
        }
    }

    Uninstall = {
        param($Ctx)
        # Was Flow starting itself at sign-in before install? Read before the restore takes the
        # snapshot away.
        $ownStart = Get-OriginalState -Label 'flow-startup'
        if (Restore-FlowLauncherSettings) { Step-Ok 'Flow Launcher settings restored (keywords, identity, Explorer file search, the query box, its own sign-in start, fonts, fullscreen hotkey) and any legacy Everything plugin removed' }
        else { Step-Info 'install never changed Flow Launcher''s settings on this machine -- nothing to restore.' }
        # You keep Flow (-Keep; versions.md doesn't mark it Pre-existing?, so -Keep is how it stays):
        # its own sign-in start back too, if it had one (review item 7).
        if ($Ctx.Keep -contains 'Flow-Launcher.Flow-Launcher' -and $ownStart -and $ownStart.StartFlowLauncherOnSystemStartup.Value) { Restore-FlowOwnStart }
    }

    Check = {
        # The same comparison the install step makes, nothing written: anything not as the flow
        # step set it is [XX] -- functional items, Flow starting itself at sign-in, the preferences.
        param($Ctx)
        $p = Get-FlowPaths
        if (-not (Test-Path -LiteralPath $p.Exe)) { return }   # the packages group says so
        $fix = @{ Fix = '710sRice install -Only flow'; Step = 'flow' }
        if (-not (Test-FlowProfile $p)) {
            return New-DoctorResult -Id 'flow' -Status 'XX' -Text "Flow Launcher has never run -- its first start sets it up" @fix
        }
        $setup = Get-FlowSetup $p
        $functional = @($setup.Findings | Where-Object { $_.Kind -eq 'functional' } | ForEach-Object Item)
        $preference = @($setup.Findings | Where-Object { $_.Kind -eq 'preference' } | ForEach-Object Item)
        if ($functional.Count) { New-DoctorResult -Id 'flow' -Status 'XX' -Text "Flow Launcher setup: $($functional -join '; ')" @fix }
        else { New-DoctorResult -Id 'flow' -Status 'OK' -Text 'Flow Launcher set up (file search on Everything with f, apps with app, old plugin gone, auto-updates off)' }
        if (@($setup.Findings | Where-Object { $_.Kind -eq 'startup' }).Count) {
            New-DoctorResult -Id 'flow-startup' -Status 'XX' -Text 'Flow Launcher also starts itself at sign-in (its own setting) -- two starts open its window' @fix
        }
        if ($preference.Count) { New-DoctorResult -Id 'flow-prefs' -Status 'XX' -Text "Flow Launcher preferences: $($preference -join '; ')" @fix }
        else { New-DoctorResult -Id 'flow-prefs' -Status 'OK' -Text 'Flow Launcher preferences (opens empty, tray icon hidden, no update prompt)' }
        # The fonts and the fullscreen setting: [XX] when not as the flow step sets them -- never set
        # by 710sRice here (no snapshot), or changed since.
        if ($setup.Face) {
            $which = $setup.FontsWrong -join ', '
            if (-not $setup.FontsWrong.Count) { New-DoctorResult -Id 'flow-font' -Status 'OK' -Text "Flow Launcher uses the Nerd Font ($($setup.Face))" }
            elseif (-not (Get-OriginalState -Label 'flow-fonts')) { New-DoctorResult -Id 'flow-font' -Status 'XX' -Text "Flow Launcher doesn't use the Nerd Font ($which)" @fix }
            else { New-DoctorResult -Id 'flow-font' -Status 'XX' -Text "Flow Launcher's font changed since 710sRice set $($setup.Face) ($which)" @fix }
        }
        if (-not $setup.FullscreenOff) { New-DoctorResult -Id 'flow-fullscreen' -Status 'OK' -Text "Flow Launcher stays shut over fullscreen windows" }
        elseif (-not (Get-OriginalState -Label 'flow-fullscreen')) { New-DoctorResult -Id 'flow-fullscreen' -Status 'XX' -Text 'Flow Launcher opens over fullscreen windows (its "Ignore hotkeys in fullscreen" is off)' @fix }
        else { New-DoctorResult -Id 'flow-fullscreen' -Status 'XX' -Text 'Flow Launcher''s "Ignore hotkeys in fullscreen" switched off since 710sRice set it' @fix }
    }
}
