# Everything (voidtools; Group 1 W4): no tray icon and no update check of its own (it's pinned here)
# -- show_tray_icon=0 and check_for_updates_on_startup=0 in the [Everything] section of
# %APPDATA%\Everything\Everything.ini, merged line by line: every other line stays byte for byte
# (CRLF and all), a missing key is added at the end of the section, a missing file is created with
# just the section and these two.
#
# voidtools' docs: Everything writes its settings back over Everything.ini when it exits, so the
# Everything running in your session is closed first (Everything.exe -exit -- its service keeps
# indexing) and, when it was running, started again in the background (-startup) as you, through
# Start-AsUser: nothing here ever runs Everything from the admin window. SUPER+S (Flow's file
# search on the Everything engine) needs that session process -- the service indexes but doesn't
# answer searches -- hence doctor's "running" line, moved here from doctor.ps1.
#
# And it leaves Everything running: when it isn't (a fresh winget install never starts it -- its
# installer's own sign-in entry, `Everything.exe -startup` in HKLM's Run key on the Dell, only
# runs at the NEXT sign-in), it's started the same way, as you, in the background. Found in the
# Dell's final test (T3, 2026-10-01): install and doctor both exit 0, SUPER+S says "Everything
# isn't running" until you sign out and in.
#
# Snapshot 'everything-settings' (each key: existed + value); uninstall puts them back with
# Everything closed and starts it again as you if it was running, so its icon is back at once.
@{
    Id    = 'everything'
    Label = 'Everything'
    After = 'flow'

    Functions = {
        function Get-EverythingExe {
            @("$env:ProgramFiles\Everything\Everything.exe", "${env:ProgramFiles(x86)}\Everything\Everything.exe") |
                Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        }

        function Get-EverythingIniPath { Join-Path $env:APPDATA 'Everything\Everything.ini' }

        function Read-EverythingValues {
            # The two keys' values in [Everything] ($null = not there) + FileExisted.
            param([string]$Path)
            $keys = 'show_tray_icon', 'check_for_updates_on_startup'
            $r = [ordered]@{ FileExisted = (Test-Path -LiteralPath $Path) }
            foreach ($k in $keys) { $r[$k] = $null }
            if ($r.FileExisted) {
                $in = $false
                foreach ($line in [IO.File]::ReadAllLines($Path)) {
                    if ($line -match '^\s*\[(.+)\]\s*$') { $in = $Matches[1] -eq 'Everything'; continue }
                    if ($in -and $line -match '^([^=;]+)=(.*)$' -and $Matches[1].Trim() -in $keys) { $r[$Matches[1].Trim()] = $Matches[2].Trim() }
                }
            }
            [pscustomobject]$r
        }

        function Set-EverythingValues {
            # Merges key=value pairs into [Everything] ($null = the key removed); nothing else moves.
            param([string]$Path, [System.Collections.IDictionary]$Values)
            $nl = "`r`n"
            if (-not (Test-Path -LiteralPath $Path)) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
                $body = @('[Everything]') + @($Values.Keys | Where-Object { $null -ne $Values[$_] } | ForEach-Object { "$_=$($Values[$_])" })
                [IO.File]::WriteAllText($Path, ($body -join $nl) + $nl, [Text.UTF8Encoding]::new($false))
                return
            }
            $bytes = [IO.File]::ReadAllBytes($Path)
            $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            $text = [IO.File]::ReadAllText($Path)
            if ($text -notmatch "`r`n") { $nl = "`n" }
            $lines = [System.Collections.Generic.List[string]]::new([string[]]($text -split "`r?`n"))
            $trailing = $lines.Count -and $lines[$lines.Count - 1] -eq ''
            if ($trailing) { $lines.RemoveAt($lines.Count - 1) }
            $start = -1; $end = $lines.Count
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*\[(.+)\]\s*$') {
                    if ($start -ge 0) { $end = $i; break }
                    if ($Matches[1] -eq 'Everything') { $start = $i }
                }
            }
            if ($start -lt 0) { $lines.Add('[Everything]'); $start = $lines.Count - 1; $end = $lines.Count }
            foreach ($k in $Values.Keys) {
                $at = -1
                for ($i = $start + 1; $i -lt $end; $i++) { if ($lines[$i] -match '^([^=;]+)=' -and $Matches[1].Trim() -eq $k) { $at = $i; break } }
                if ($null -eq $Values[$k]) {
                    if ($at -ge 0) { $lines.RemoveAt($at); $end-- }
                } elseif ($at -ge 0) {
                    $lines[$at] = "$k=$($Values[$k])"
                } else {
                    # At the end of the section, before any blank lines that close it.
                    $ins = $end
                    while ($ins - 1 -gt $start -and $lines[$ins - 1].Trim() -eq '') { $ins-- }
                    $lines.Insert($ins, "$k=$($Values[$k])"); $end++
                }
            }
            [IO.File]::WriteAllText($Path, ($lines -join $nl) + $(if ($trailing) { $nl } else { '' }), [Text.UTF8Encoding]::new($bom))
        }

        function Get-EverythingSessionProcess {
            # Everything in this session -- never the service's (session 0).
            $session = (Get-Process -Id $PID).SessionId
            @(Get-Process -Name Everything -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
        }

        function Stop-EverythingApp {
            # Closed the way voidtools says (-exit, sent as you), killed if it's still there 5 s
            # later; $true when it was running.
            param([string]$Exe)
            $p = Get-EverythingSessionProcess
            if (-not $p.Count) { return $false }
            [void](Start-AsUser -Exe $Exe -Arguments '-exit' -Name 'everything-exit')
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-EverythingSessionProcess).Count -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            Get-EverythingSessionProcess | Stop-Process -Force -ErrorAction SilentlyContinue
            $true
        }
    }

    Install = {
        param($Ctx)
        $exe = Get-EverythingExe
        if (-not $exe) { Step-Warn "Everything isn't installed -- skipped (the packages step installs it; then 710sRice install -Only everything)."; return }
        $ini = Get-EverythingIniPath
        $now = Read-EverythingValues $ini
        $done = { param($v) $v.show_tray_icon -eq '0' -and $v.check_for_updates_on_startup -eq '0' }
        $wasUp = $false
        if (& $done $now) {
            Save-OriginalState -Label 'everything-settings' -Data @{ FileExisted = $true; show_tray_icon = @{ Existed = $true; Value = '0' }; check_for_updates_on_startup = @{ Existed = $true; Value = '0' } }
            Step-Ok 'Everything already set up (no tray icon, no update check)'
        } else {
            $wasUp = Stop-EverythingApp $exe
            if ($wasUp) { Step-Info 'Everything closed to write its settings (its service keeps indexing)' }
            $now = Read-EverythingValues $ini   # as the closed Everything left it
            $snap = @{ FileExisted = $now.FileExisted }
            foreach ($k in 'show_tray_icon', 'check_for_updates_on_startup') { $snap[$k] = @{ Existed = $null -ne $now.$k; Value = $now.$k } }
            Save-OriginalState -Label 'everything-settings' -Data $snap
            Set-EverythingValues $ini ([ordered]@{ show_tray_icon = '0'; check_for_updates_on_startup = '0' })
            $what = @(if ($now.show_tray_icon -ne '0') { 'tray icon off' }; if ($now.check_for_updates_on_startup -ne '0') { 'update check off' })
            Step-Ok "Everything set up: $($what -join '; ')$(if (-not $now.FileExisted) { ' (it had no settings file yet: created with just these)' })"
        }
        # Running before = started again; not running (a fresh install, or you'd quit it) = started
        # now. Either way the one SUPER+S talks to, in your session, never from this admin window.
        if (-not (Get-EverythingSessionProcess).Count) {
            if (Start-AsUser -Exe $exe -Arguments '-startup' -Process 'Everything' -Name 'everything') {
                Step-Ok $(if ($wasUp) { 'Everything started again in the background (as you)' } else { "Everything started in the background (as you) -- SUPER+S's file search needs it" })
            } else { Step-Warn "Everything didn't start -- start it from the Start menu (SUPER+S needs it)" }
        }
    }

    Uninstall = {
        param($Ctx)
        $snap = Get-OriginalState -Label 'everything-settings'
        if (-not $snap) { Step-Info 'install never changed Everything''s settings on this machine -- nothing to restore.'; return }
        $exe = Get-EverythingExe
        $ini = Get-EverythingIniPath
        $wasUp = $exe -and (Stop-EverythingApp $exe)
        if (Test-Path -LiteralPath $ini) {
            $back = [ordered]@{}
            foreach ($k in 'show_tray_icon', 'check_for_updates_on_startup') { $back[$k] = if ($snap[$k].Existed) { "$($snap[$k].Value)" } else { $null } }
            Set-EverythingValues $ini $back
        }
        Remove-OriginalState -Label 'everything-settings'
        Step-Ok "Everything's settings restored (its tray icon and update check as they were)"
        if ($wasUp) {
            if (Start-AsUser -Exe $exe -Arguments '-startup' -Process 'Everything' -Name 'everything') { Step-Ok 'Everything started again (as you) -- its icon is back' }
            else { Step-Warn "Everything didn't start again -- start it from the Start menu" }
        }
    }

    Check = {
        # Running (SUPER+S needs it; this step starts it, as you), then the settings: [XX] until this
        # step has run here (no snapshot yet), and for a value turned back on since.
        param($Ctx)
        $exe = Get-EverythingExe
        if (-not $exe) { return }   # the packages group says so
        $fix = @{ Fix = '710sRice install -Only everything'; Step = 'everything' }
        if ((Get-EverythingSessionProcess).Count) { New-DoctorResult -Id 'everything' -Status 'OK' -Text 'Everything running' }
        else { New-DoctorResult -Id 'everything' -Status 'XX' -Text "Everything isn't running -- SUPER+S (Flow's file search) needs it" @fix }
        if (-not (Get-OriginalState -Label 'everything-settings')) {
            return New-DoctorResult -Id 'everything-settings' -Status 'XX' -Text 'Everything: not set up by 710sRice yet (its tray icon, its update check)' @fix
        }
        $now = Read-EverythingValues (Get-EverythingIniPath)
        $back = @(if ($now.show_tray_icon -ne '0') { 'its tray icon is on' }; if ($now.check_for_updates_on_startup -ne '0') { 'it checks for updates' })
        if ($back.Count) {
            return New-DoctorResult -Id 'everything-settings' -Status 'XX' -Text "Everything: $($back -join ', ') again (changed since 710sRice set it)" @fix
        }
        New-DoctorResult -Id 'everything-settings' -Status 'OK' -Text 'Everything set up (no tray icon, no update check)'
    }
}
