# ShareX (Group 1 W4): no update check of its own (it's version-managed here), and its tray icon
# hidden from the bar -- YASB's systray hide_icons: ["ShareX"] in config\yasb\config.yaml (YASB
# 2.0.7 matches an icon's exe name up to its first dot, case-insensitively). ShareX itself keeps
# ShowTray ON: ShareX 21.0.0 honours -silent (the sign-in task's "no main window") only while its
# tray icon is on (MainForm.cs:1270) -- winarchy turned it off once (2463825) and had to revert it
# (4945ea1). So this step turns AutoCheckUpdate off and makes sure ShowTray is on.
#
# ApplicationConfig.json lives in ShareX's personal folder, found the way ShareX 21.0.0 finds it
# (Program.cs UpdatePersonalPath): a "Portable" file next to ShareX.exe -> <ShareX folder>\ShareX;
# else HKLM, then HKCU, SOFTWARE\ShareX PersonalPath; else PersonalPath.cfg (next to ShareX.exe,
# else Documents\ShareX, else the old %LOCALAPPDATA%\ShareX one ShareX would migrate); else
# Documents\ShareX. Only those two values change, edited in the text itself -- every other byte of
# the file stays as ShareX wrote it (a JSON round trip here would rewrite its dates and layout).
# ShareX never run -> the file is created with just those two keys; ShareX fills in the rest.
#
# ShareX is force-stopped before the write (it saves its settings over the file on exit) and, when
# it was running, started again through its own task (\710.DesktopRice\sharex, as you), or
# Start-AsUser when there's none yet. Snapshot 'sharex-settings' (each key: existed + value);
# uninstall puts them back with ShareX stopped.
#
# ShareX's own sign-in start goes too. Its "Run ShareX when Windows starts" is a ShareX.lnk in your
# Startup folder, ShareX.exe -silent (ShareX's StartupManager: ShortcutHelpers on
# SpecialFolder.Startup; switched off in Task Manager's Startup apps = the StartupApproved\
# StartupFolder value ShareX.lnk starting with byte 3, ShareX's own test). Its installer makes it
# on a new install, ticked by default, so ShareX came up at every sign-in -- on an on-demand
# machine too, alone, which doctor read as a half-started stack, and repair started the rest
# around it (the Dell, 2026-10-03). One thing starts ShareX at sign-in: its task, on a full-time
# machine only -- the rule flow.ps1 applies to Flow's own startup. A shortcut you switched off in
# Task Manager is left alone (it starts nothing). Snapshot 'sharex-startup' (the shortcut as it
# was); uninstall makes it again while ShareX is installed.
@{
    Id    = 'sharex'
    Label = 'ShareX'
    After = 'flow'

    Functions = {
        function Get-ShareXConfigPath {
            # ApplicationConfig.json, wherever this ShareX keeps it (see the file's header).
            param([string]$Exe)
            $dir = Split-Path -Parent $Exe
            $expand = {
                param([string]$p)
                foreach ($sf in [Enum]::GetNames([Environment+SpecialFolder])) {
                    $p = $p -ireplace [regex]::Escape("%$sf%"), [Environment]::GetFolderPath($sf).Replace('$', '$$')
                }
                [Environment]::ExpandEnvironmentVariables($p)
            }
            $absolute = { param([string]$p) $p = & $expand $p; if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $dir $p }; [IO.Path]::GetFullPath($p) }
            $myDocs = [Environment]::GetFolderPath('MyDocuments')
            if (-not $myDocs) { throw "Windows didn't say where Documents is -- can't find ShareX's settings" }
            $docs = Join-Path $myDocs 'ShareX'
            $personal = $null
            if (Test-Path -LiteralPath (Join-Path $dir 'Portable')) { $personal = Join-Path $dir 'ShareX' }
            if (-not $personal) {
                foreach ($hive in 'HKLM:', 'HKCU:') {
                    $v = try { (Get-ItemProperty -Path "$hive\SOFTWARE\ShareX" -Name 'PersonalPath' -ErrorAction Stop).PersonalPath } catch { $null }
                    if ("$v") { $personal = & $expand "$v"; break }
                }
            }
            if (-not $personal) {
                $cfg = @((Join-Path $dir 'PersonalPath.cfg'), (Join-Path $docs 'PersonalPath.cfg'), (Join-Path $env:LOCALAPPDATA 'ShareX\PersonalPath.cfg')) |
                       Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if ($cfg) { $t = (Get-Content -LiteralPath $cfg -Raw -Encoding UTF8).Trim(); if ($t) { $personal = & $absolute $t } }
            }
            if (-not $personal) { $personal = $docs }
            Join-Path $personal 'ApplicationConfig.json'
        }

        function Read-ShareXValues {
            # {FileExisted; AutoCheckUpdate; ShowTray} -- $null for a key that isn't in the file.
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ FileExisted = $false; AutoCheckUpdate = $null; ShowTray = $null } }
            $j = try { [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable } catch { throw "$(ConvertTo-SafePath $Path) isn't readable JSON ($($_.Exception.Message))" }
            [pscustomobject]@{
                FileExisted     = $true
                AutoCheckUpdate = if ($j.Contains('AutoCheckUpdate')) { [bool]$j['AutoCheckUpdate'] } else { $null }
                ShowTray        = if ($j.Contains('ShowTray')) { [bool]$j['ShowTray'] } else { $null }
            }
        }

        function Set-ShareXJsonBool {
            # One top-level boolean in ShareX's JSON text, everything else byte for byte: the value
            # replaced where the key is, or the key added right after the opening brace in the file's
            # own style (its newline, two-space indent).
            param([string]$Text, [string]$Key, [bool]$Value)
            $v = if ($Value) { 'true' } else { 'false' }
            $rx = '("' + [regex]::Escape($Key) + '"\s*:\s*)(true|false)'
            $n = [regex]::Matches($Text, $rx).Count
            if ($n -gt 1) { throw "ApplicationConfig.json has $Key $n times -- not changed" }
            if ($n -eq 1) { return [regex]::Replace($Text, $rx, { param($m) $m.Groups[1].Value + $v }) }
            $nl = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
            $i = $Text.IndexOf('{')
            if ($i -lt 0) { throw 'ApplicationConfig.json has no opening brace -- not changed' }
            $rest = $Text.Substring($i + 1)
            $sep = if ($rest.Trim().StartsWith('}')) { '' } else { ',' }
            $Text.Substring(0, $i + 1) + "$nl  `"$Key`": $v$sep" + $rest
        }

        function Write-ShareXValues {
            # The two values set (a $null value = left out of a file we create).
            param([string]$Path, [System.Collections.IDictionary]$Values)
            if (Test-Path -LiteralPath $Path) {
                $text = [IO.File]::ReadAllText($Path)
                foreach ($k in $Values.Keys) { if ($null -ne $Values[$k]) { $text = Set-ShareXJsonBool $text $k $Values[$k] } }
                [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
                $pairs = @($Values.Keys | Where-Object { $null -ne $Values[$_] } | ForEach-Object { "  `"$_`": $(if ($Values[$_]) { 'true' } else { 'false' })" })
                [IO.File]::WriteAllText($Path, "{`r`n$($pairs -join ",`r`n")`r`n}", [Text.UTF8Encoding]::new($false))
            }
        }

        function Stop-ShareXApp {
            # ShareX in this session stopped; $true when it was running.
            $session = (Get-Process -Id $PID).SessionId
            $p = @(Get-Process -Name ShareX -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
            if (-not $p.Count) { return $false }
            $p | Stop-Process -Force -ErrorAction SilentlyContinue
            $p | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
            $true
        }

        function Start-ShareXAgain {
            # As you: its task, else Start-AsUser (tray only, -silent -- as at sign-in).
            param([string]$Exe)
            if (Test-Task -TaskName 'sharex') {
                $null = & schtasks.exe /Run /TN (Get-TaskFullName -TaskName 'sharex') 2>&1
                if ($LASTEXITCODE -eq 0) { return $true }
            }
            Start-AsUser -Exe $Exe -Arguments '-silent' -Process 'ShareX' -Name 'sharex'
        }

        function Get-ShareXStartupFolder { [Environment]::GetFolderPath('Startup') }

        function Get-ShareXOwnStartup {
            # ShareX's own sign-in start (the file's header): {Path; Shortcut (Read-RiceShortcut's
            # target, arguments, folder, icon, description); Enabled (Windows runs it at sign-in)},
            # or $null when your Startup folder has no ShareX.lnk pointing at a ShareX.exe.
            $dir = Get-ShareXStartupFolder
            if (-not $dir) { return $null }
            $path = Join-Path $dir 'ShareX.lnk'
            $lnk = Read-RiceShortcut $path
            if (-not $lnk -or -not "$($lnk.Target)" -or (Split-Path -Leaf "$($lnk.Target)") -ne 'ShareX.exe') { return $null }
            $item = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' -Name 'ShareX.lnk' -ErrorAction SilentlyContinue
            $state = if ($item) { @($item.'ShareX.lnk') } else { @() }
            [pscustomobject]@{ Path = $path; Shortcut = $lnk; Enabled = -not ($state.Count -and $state[0] -eq 3) }
        }
    }

    Install = {
        param($Ctx)
        $exe = Get-ShareXExe
        if (-not $exe) { Step-Warn "ShareX isn't installed -- skipped (the packages step installs it; then 710sRice install -Only sharex)."; return }
        $path = Get-ShareXConfigPath $exe
        $now = Read-ShareXValues $path
        if ($now.AutoCheckUpdate -eq $false -and $now.ShowTray -eq $true) {
            Save-OriginalState -Label 'sharex-settings' -Data @{ FileExisted = $true; AutoCheckUpdate = @{ Existed = $true; Value = $false }; ShowTray = @{ Existed = $true; Value = $true } }
            Step-Ok 'ShareX already set up (no update check, tray icon on so it starts hidden; the bar hides the icon)'
        } else {
            $wasUp = Stop-ShareXApp
            if ($wasUp) { Step-Info 'ShareX stopped to write its settings' }
            $now = Read-ShareXValues $path   # as the stopped ShareX left it
            Save-OriginalState -Label 'sharex-settings' -Data @{
                FileExisted     = $now.FileExisted
                AutoCheckUpdate = @{ Existed = $null -ne $now.AutoCheckUpdate; Value = $now.AutoCheckUpdate }
                ShowTray        = @{ Existed = $null -ne $now.ShowTray; Value = $now.ShowTray }
            }
            Write-ShareXValues $path ([ordered]@{ AutoCheckUpdate = $false; ShowTray = $true })
            $what = @(if ($now.AutoCheckUpdate -ne $false) { 'update check off' }; if ($now.ShowTray -ne $true) { 'tray icon on (it starts hidden only with it)' })
            Step-Ok "ShareX set up: $($what -join '; ')$(if (-not $now.FileExisted) { " (it hadn't run yet: $(ConvertTo-SafePath $path) created with just these)" })"
            if ($wasUp) {
                if (Start-ShareXAgain $exe) { Step-Ok 'ShareX started again (as you)' }
                else { Step-Warn "ShareX didn't start again -- 710sRice start brings it back" }
            }
        }

        # ShareX's own sign-in start off (the file's header says why). Only the shortcut: ShareX
        # keeps no setting of its own for it, so a running ShareX doesn't need stopping.
        $own = Get-ShareXOwnStartup
        if ($own -and $own.Enabled) {
            $s = $own.Shortcut
            Save-OriginalState -Label 'sharex-startup' -Data @{ Target = "$($s.Target)"; Arguments = "$($s.Arguments)"; WorkingDirectory = "$($s.WorkingDirectory)"; Icon = "$($s.Icon)"; Description = "$($s.Description)" }
            try {
                Remove-Item -LiteralPath $own.Path -Force -ErrorAction Stop
                Step-Ok "ShareX's own sign-in start turned off (its ""Run ShareX when Windows starts"" shortcut) -- $(if ($Ctx.FullTime) { 'its task starts it at sign-in' } else { 'on demand, nothing starts at sign-in' })"
            } catch { Step-Warn "Couldn't remove ShareX's own sign-in shortcut (ShareX.lnk in your Startup folder): $($_.Exception.Message)" }
        }
    }

    Uninstall = {
        param($Ctx)
        $exe = Get-ShareXExe
        $snap = Get-OriginalState -Label 'sharex-settings'
        if (-not $snap) { Step-Info 'install never changed ShareX''s settings on this machine -- nothing to restore.' }
        else {
            if ($exe) {
                $path = Get-ShareXConfigPath $exe
                [void](Stop-ShareXApp)
                if (Test-Path -LiteralPath $path) {
                    # A key that wasn't there goes back to ShareX's own default (true for both).
                    Write-ShareXValues $path ([ordered]@{
                        AutoCheckUpdate = if ($snap.AutoCheckUpdate.Existed) { [bool]$snap.AutoCheckUpdate.Value } else { $true }
                        ShowTray        = if ($snap.ShowTray.Existed) { [bool]$snap.ShowTray.Value } else { $true }
                    })
                }
                Step-Ok "ShareX's settings restored (its update check as it was)"
            }
            Remove-OriginalState -Label 'sharex-settings'
        }

        # ShareX's own sign-in start, as it was before install took it out: its shortcut made
        # again, while ShareX is still installed (one you made again since is left as it is).
        $start = Get-OriginalState -Label 'sharex-startup'
        if ($start) {
            $dir = Get-ShareXStartupFolder
            if ($exe -and $dir -and $start.Target -and (Test-Path -LiteralPath $start.Target)) {
                $lnk = Join-Path $dir 'ShareX.lnk'
                if (-not (Test-Path -LiteralPath $lnk)) {
                    Save-RiceShortcut -Path $lnk -Target $start.Target -Arguments $start.Arguments -WorkingDirectory $start.WorkingDirectory -Icon $start.Icon -Description $start.Description
                }
                Step-Ok "ShareX's own sign-in start put back (its ""Run ShareX when Windows starts"" shortcut)"
            }
            Remove-OriginalState -Label 'sharex-startup'
        }
    }

    Check = {
        # [XX] until this step has run here (no snapshot yet), or with ShowTray off (ShareX then
        # opens its window at every sign-in); [!!] for an update check turned back on since.
        # And its own line, [XX], while ShareX starts itself at sign-in.
        param($Ctx)
        $exe = Get-ShareXExe
        if (-not $exe) { return }   # the packages group says so
        $fix = @{ Fix = '710sRice install -Only sharex'; Step = 'sharex' }
        $own = Get-ShareXOwnStartup
        if ($own -and $own.Enabled) {
            New-DoctorResult -Id 'sharex-startup' -Status 'XX' -Text 'ShareX also starts itself at sign-in (its own "Run ShareX when Windows starts") -- 710sRice starts it, and only on a full-time machine' @fix
        }
        $now = Read-ShareXValues (Get-ShareXConfigPath $exe)
        if ($now.FileExisted -and $now.ShowTray -eq $false) {
            return New-DoctorResult -Id 'sharex' -Status 'XX' -Text "ShareX's tray icon is off -- it ignores -silent then, and opens its window at every sign-in (the bar hides the icon anyway)" @fix
        }
        if (-not (Get-OriginalState -Label 'sharex-settings')) {
            return New-DoctorResult -Id 'sharex' -Status 'XX' -Text 'ShareX: not set up by 710sRice yet (its update check)' @fix
        }
        if ($now.AutoCheckUpdate -ne $false) {
            return New-DoctorResult -Id 'sharex' -Status '!!' -Text 'ShareX checks for updates again (turned back on since 710sRice set it -- your call)' -Fix '710sRice install -Only sharex turns it off again'
        }
        New-DoctorResult -Id 'sharex' -Status 'OK' -Text 'ShareX set up (no update check; starts hidden; the bar hides its icon)'
    }
}
