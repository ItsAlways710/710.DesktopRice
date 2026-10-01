# The Start-menu commands (winarchy's command palette, ported 2026-10-01): ten shortcuts in Start
# Menu\Programs\710sRice -- "710sRice Menu", "710sRice Doctor", ... -- so Flow Launcher (and the Start
# menu's own search) finds them by name. Each runs config\ahk\send-command.ahk <name> with plain
# AutoHotkey, which asks the running 710.ahk to do it (710.ahk's RiceCommands: the same functions as
# its hotkeys and menus). winarchy's ran its CLI in a hidden PowerShell; ours start nothing heavier
# than AutoHotkey, and never a console. The 710sRice icon on each.
#
# Runs right after envvars, so on a first install the shortcuts are there before Flow's first start
# indexes the Start menu. Flow notices shortcuts added or removed while it runs (its Program plugin
# watches the Start menu); while it isn't running, a change here also deletes its program cache
# (%APPDATA%\FlowLauncher\Cache\Plugins\Flow.Launcher.Plugin.Program\Win32.cache -- only a cache, it
# rebuilds it), or its next start would keep the old list for up to 30 hours.
#
# Uninstall removes the folder. Nothing to snapshot: the folder and its shortcuts are 710sRice's own.
# Doctor: [XX] when one is missing, points elsewhere (a moved clone, AutoHotkey moved), or the folder
# has one that isn't ours any more -- fix: this step.
@{
    Id    = 'commands'
    Label = 'Start-menu commands'
    After = 'envvars'
    Group = 'Integrations'

    Functions = {
        function Get-RiceCommandList {
            # Display name -> 710.ahk's command name (config\ahk\710.ahk RiceCommands; keep the two in step).
            [ordered]@{
                'Menu'              = 'menu'
                'Reload stack'      = 'reload-stack'
                'Doctor'            = 'doctor'
                'Game mode on'      = 'game-mode-on'
                'Game mode off'     = 'game-mode-off'
                'Screenshot region' = 'screenshot-region'
                'Screenshot window' = 'screenshot-window'
                'Screen recording'  = 'screen-recording'
                'Stop recording'    = 'stop-recording'
                'Text from screen'  = 'text-from-screen'
            }
        }

        function Get-RiceCommandsDir { Join-Path (Get-StartMenuProgramsDir) '710sRice' }

        function Get-PlainAhkExe {
            # Plain AutoHotkey v2 -- the sender is an ordinary process (710.ahk opens its door to it).
            $found = @("$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe", "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe") |
                Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
            if (-not $found) { $found = (Get-Command AutoHotkey64.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
            $found
        }

        function Get-RiceCommandShortcuts {
            # What each shortcut should be: file, target, arguments, working folder, icon, description.
            param([string]$Root, [string]$Ahk)
            $dir = Get-RiceCommandsDir
            $ahkDir = Join-Path $Root 'config\ahk'
            $list = Get-RiceCommandList
            foreach ($name in $list.Keys) {
                [pscustomobject]@{
                    Name = $name; File = Join-Path $dir "710sRice $name.lnk"; Target = $Ahk
                    Arguments = "`"$(Join-Path $ahkDir 'send-command.ahk')`" $($list[$name])"
                    WorkingDirectory = $ahkDir; Icon = "$(Join-Path $Root 'assets\logo\710rice.ico'),0"
                    Description = "710sRice: $name"
                }
            }
        }

        function Test-RiceShortcutCurrent {
            param($Want)
            $have = Read-RiceShortcut $Want.File
            $have -and $have.Target -eq $Want.Target -and $have.Arguments -ceq $Want.Arguments -and
                $have.WorkingDirectory -eq $Want.WorkingDirectory -and $have.Icon -eq $Want.Icon
        }

        function Get-RiceCommandsState {
            # Missing / out of date / not ours (an old name) -- names only.
            param([string]$Root, [string]$Ahk)
            $want = @(Get-RiceCommandShortcuts $Root $Ahk)
            $dir = Get-RiceCommandsDir
            $r = [pscustomobject]@{ Want = $want; Missing = @(); Stale = @(); Extra = @() }
            $r.Missing = @($want | Where-Object { -not (Test-Path -LiteralPath $_.File) } | ForEach-Object Name)
            $r.Stale = @($want | Where-Object { (Test-Path -LiteralPath $_.File) -and -not (Test-RiceShortcutCurrent $_) } | ForEach-Object Name)
            if (Test-Path -LiteralPath $dir) {
                $names = @($want | ForEach-Object { Split-Path -Leaf $_.File })
                $r.Extra = @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $names } | ForEach-Object Name)
            }
            $r
        }

        function Reset-FlowProgramCache {
            # Flow not running: its next start re-reads the Start menu. $true when a cache was deleted.
            if (Get-Process -Name Flow.Launcher -ErrorAction SilentlyContinue) { return $false }
            $cache = Join-Path $env:APPDATA 'FlowLauncher\Cache\Plugins\Flow.Launcher.Plugin.Program\Win32.cache'
            if (-not (Test-Path -LiteralPath $cache)) { return $false }
            Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
            -not (Test-Path -LiteralPath $cache)
        }
    }

    Install = {
        param($Ctx)
        $ahk = Get-PlainAhkExe
        if (-not $ahk) { Step-Warn "AutoHotkey isn't installed -- the Start-menu commands skipped (the packages step installs it; then 710sRice install -Only commands)."; return }
        $s = Get-RiceCommandsState $Ctx.Root $ahk
        $dir = Get-RiceCommandsDir
        if (-not ($s.Missing.Count + $s.Stale.Count + $s.Extra.Count)) {
            Step-Ok "Start-menu commands already there ($($s.Want.Count) -- type 710sRice in Flow Launcher)"
            return
        }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($w in $s.Want) {
            if ($w.Name -notin $s.Missing -and $w.Name -notin $s.Stale) { continue }
            # Rewritten as a new file, so a running Flow's watcher (created / deleted only) sees it.
            Remove-Item -LiteralPath $w.File -Force -ErrorAction SilentlyContinue
            Save-RiceShortcut -Path $w.File -Target $w.Target -Arguments $w.Arguments -WorkingDirectory $w.WorkingDirectory -Icon $w.Icon -Description $w.Description
        }
        foreach ($x in $s.Extra) { Remove-Item -LiteralPath (Join-Path $dir $x) -Force -ErrorAction SilentlyContinue }
        $what = @(
            if ($s.Missing.Count) { "$($s.Missing.Count) added" }
            if ($s.Stale.Count) { "$($s.Stale.Count) updated ($($s.Stale -join ', '))" }
            if ($s.Extra.Count) { "$($s.Extra.Count) old one$(if ($s.Extra.Count -gt 1) { 's' }) removed ($($s.Extra -join ', '))" })
        Step-Ok "Start-menu commands: $($what -join '; ') -- $($s.Want.Count) in Start Menu\Programs\710sRice (type 710sRice in Flow Launcher)"
        if (Reset-FlowProgramCache) { Step-Info "Flow Launcher's program list cleared -- it reads the Start menu again at its next start" }
    }

    Uninstall = {
        param($Ctx)
        $dir = Get-RiceCommandsDir
        if (-not (Test-Path -LiteralPath $dir)) { Step-Info 'no Start-menu commands on this machine -- nothing to remove.'; return }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dir) { Step-Warn "couldn't remove Start Menu\Programs\710sRice -- delete it yourself"; return }
        Step-Ok 'Start-menu commands removed (Start Menu\Programs\710sRice)'
        [void](Reset-FlowProgramCache)
    }

    Check = {
        param($Ctx)
        $ahk = Get-PlainAhkExe
        if (-not $ahk) { return }   # the packages group says so
        $s = Get-RiceCommandsState $Ctx.Root $ahk
        $fix = @{ Fix = '710sRice install -Only commands'; Step = 'commands' }
        $bad = @(
            if ($s.Missing.Count -eq $s.Want.Count) { 'none there yet' }
            elseif ($s.Missing.Count) { "missing: $($s.Missing -join ', ')" }
            if ($s.Stale.Count) { "pointing at an old place: $($s.Stale -join ', ')" }
            if ($s.Extra.Count) { "not one of ours any more: $($s.Extra -join ', ')" })
        if ($bad.Count) { return New-DoctorResult -Id 'commands' -Status 'XX' -Text "Start-menu commands (Flow Launcher's 710sRice ones): $($bad -join '; ')" @fix }
        New-DoctorResult -Id 'commands' -Status 'OK' -Text "Start-menu commands ($($s.Want.Count), in Start Menu\Programs\710sRice -- type 710sRice in Flow Launcher)"
    }
}
