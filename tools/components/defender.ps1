# Windows Defender exclusions: the paths whose first-touch scans lag the stack -- ShareX's and
# Everything's frequent I/O, komorebic.exe (every hotkey runs it), pwsh.exe and this repo's own
# scripts. install adds them, uninstall removes them, doctor checks them. Unconditional -- not
# gated behind -Activate, matching winarchy's own install.ps1 exactly (Set-WinarchyDefender-
# Exclusions runs unconditionally there too). Needs an admin window: without one it warns and
# skips, never failing the install or the uninstall. Only exclusions of ours are ever touched:
# exactly the paths install would add now, plus old ones of ours (an earlier pwsh.exe, komorebi.exe
# from before komorebic.exe) -- one you added yourself stays.
# (A fixed install step until 2026-10-07, its code in install.ps1, uninstall.ps1 and
# tools\lib\activation.ps1 / doctor.ps1.)
@{
    Id    = 'defender'
    Label = 'Windows Defender exclusions'
    After = 'monitors'

    Functions = {
        function Get-DefenderExclusionPaths {
            <# Ported from winarchy's Get-WinarchyDefenderExclusionPaths. Covers the same two lag
               sources: frequent I/O from ShareX/Everything, and Defender scanning komorebic.exe /
               pwsh.exe / this repo's own .ps1 files the first time they're touched per session
               (the "only the first time" lag seen on capture/window-close). Only returns paths
               that actually exist on this machine, plus pwsh.exe (see Get-PwshImagePath).
               komorebic.exe -- the command every hotkey runs; until 2026-10-05 this took komorebi.exe
               (Get-KomorebiExe) instead, found on Godzilla, so that one is now an old exclusion of
               ours (Get-StaleDefenderExclusions). #>
            $komorebic = Get-KomorebicExe
            @(
                (Get-ShareXExe),
                "$env:USERPROFILE\Documents\ShareX",
                "$env:ProgramFiles\Everything\Everything.exe",
                "${env:ProgramFiles(x86)}\Everything\Everything.exe",
                $komorebic,
                $Root
            ) | Where-Object { $_ -and (Test-Path $_) }
            Get-PwshImagePath
        }

        function Get-PwshImagePath {
            <# The pwsh.exe Defender should exclude: the real image this very process runs from
               ($PSHOME) -- install/uninstall always run under PowerShell 7. Defender matches the
               real image path, which for the Store build is the versioned package folder
               (...\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe\pwsh.exe).
               winarchy (and our port) used `Get-Command pwsh.exe`, which depends on PATH order:
               after install.ps1 re-reads PATH from the registry it finds the per-user App
               Execution Alias instead (%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe) -- seen
               on the 2026-09-24 third install, where that alias is what got excluded, which
               doesn't cover the real binary. No Test-Path: it's the running process's own
               binary, and Test-Path inside Program Files\WindowsApps isn't reliable. #>
            Join-Path $PSHOME 'pwsh.exe'
        }

        function Get-StalePwshExclusions {
            <# Existing Defender exclusions that are an earlier pwsh.exe of ours, not the current
               one: the per-user alias (what the old Get-Command lookup could add) and any other
               Store-build version folder (left behind when PowerShell updates itself -- its
               folder name carries the version). Only exact pwsh.exe paths in those two places,
               so nothing the person excluded themselves is touched. #>
            param([string[]]$Current)
            $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
            $real  = Get-PwshImagePath
            @($Current | Where-Object {
                $_ -and $_ -ne $real -and (
                    $_ -eq $alias -or
                    $_ -like "$env:ProgramFiles\WindowsApps\Microsoft.PowerShell_*\pwsh.exe")
            })
        }

        function Get-StaleDefenderExclusions {
            <# Existing Defender exclusions of ours that install no longer wants: an earlier pwsh.exe
               (Get-StalePwshExclusions), and komorebi.exe itself -- excluded by mistake until
               2026-10-05 in place of komorebic.exe (Get-DefenderExclusionPaths). Only those exact
               paths, so nothing the person excluded themselves elsewhere is touched. #>
            param([string[]]$Current)
            @(Get-StalePwshExclusions -Current $Current)
            $komorebi = Get-KomorebiExe
            if ($komorebi -and $Current -contains $komorebi) { $komorebi }
        }

        function Set-DefenderExclusions {
            <# Requires an elevated shell; same not-elevated fallback as the rest of this file:
               warn and skip, never fail the install. Ported from Set-WinarchyDefenderExclusions. #>
            if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                Step-Warn 'Defender exclusions need an elevated shell -- re-run install.ps1 from an admin PowerShell to apply them.'
                return
            }
            $paths = @(Get-DefenderExclusionPaths)
            if ($paths.Count -eq 0) {
                Step-Info 'No ShareX/Everything/komorebi paths found yet to exclude.'
                return
            }
            $current = @((Get-MpPreference).ExclusionPath)
            # An old exclusion of ours (an earlier pwsh.exe -- the alias, or a PowerShell version
            # since updated away -- or komorebi.exe from before komorebic.exe) is removed rather than
            # left to pile up.
            $stale = @(Get-StaleDefenderExclusions -Current $current)
            if ($stale.Count -gt 0) {
                try {
                    Remove-MpPreference -ExclusionPath $stale
                    Step-Ok "Old Defender exclusion(s) removed: $(@($stale | ForEach-Object { ConvertTo-SafePath $_ }) -join ', ')"
                } catch {
                    Step-Warn "Could not remove old Defender exclusion(s): $($_.Exception.Message)"
                }
            }
            $missing = @($paths | Where-Object { $current -notcontains $_ })
            if ($missing.Count -eq 0) {
                Step-Ok 'Defender exclusions already applied'
                return
            }
            try {
                Add-MpPreference -ExclusionPath $missing
                Step-Ok "Defender exclusions added: $(@($missing | ForEach-Object { ConvertTo-SafePath $_ }) -join ', ')"
            } catch {
                Step-Warn "Could not add Defender exclusions: $($_.Exception.Message)"
            }
        }

        function Remove-DefenderExclusions {
            <# Reverts Set-DefenderExclusions -- called from uninstall.ps1. winarchy's own
               uninstall.ps1 never removes these at all (see plan doc); we go further. Removes
               exactly the paths Get-DefenderExclusionPaths would add (recomputed live, same as
               install time), never the caller's whole ExclusionPath list, so an exclusion the
               person added themselves outside this repo is left alone. Same elevation requirement
               and not-elevated fallback as Set-DefenderExclusions -- warns and skips rather than
               failing the uninstall. #>
            if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                Step-Warn 'Defender exclusions need an elevated shell to remove -- re-run uninstall.ps1 from an admin PowerShell to revert them.'
                return
            }
            $paths = @(Get-DefenderExclusionPaths)
            if ($paths.Count -eq 0) {
                Step-Info 'No Defender exclusion paths to remove (nothing currently found to have excluded).'
                return
            }
            $current = @((Get-MpPreference).ExclusionPath)
            # Plus any old exclusion of ours (see Get-StaleDefenderExclusions).
            $toRemove = @(@($paths | Where-Object { $current -contains $_ }) + @(Get-StaleDefenderExclusions -Current $current))
            if ($toRemove.Count -eq 0) {
                Step-Info 'Defender exclusions already absent.'
                return
            }
            try {
                Remove-MpPreference -ExclusionPath $toRemove
                Step-Ok "Defender exclusions removed: $(@($toRemove | ForEach-Object { ConvertTo-SafePath $_ }) -join ', ')"
            } catch {
                Step-Warn "Could not remove Defender exclusions: $($_.Exception.Message)"
            }
        }

        function Test-DoctorDefender {
            # Every path install excludes, and no old exclusion of ours left behind (an earlier
            # pwsh.exe, or komorebi.exe from before komorebic.exe) -- the same two lists install's
            # defender step works from. Windows only shows the exclusions to an admin.
            if (-not (Test-IsAdmin)) { return New-DoctorResult -Id 'defender' -Status '..' -Text 'Defender exclusions: Windows only shows them to an admin -- 710sRice doctor -repair checks them' }
            try { $pref = Get-MpPreference -ErrorAction Stop }
            catch { return New-DoctorResult -Id 'defender' -Status '..' -Text "Defender isn't in use here (another antivirus?) -- nothing to check" }
            $current = @($pref.ExclusionPath)
            $want    = @(Get-DefenderExclusionPaths)
            $missing = @($want | Where-Object { $current -notcontains $_ })
            $stale   = @(Get-StaleDefenderExclusions -Current $current)
            if (-not $missing.Count -and -not $stale.Count) {
                return New-DoctorResult -Id 'defender' -Status 'OK' -Text "Defender exclusions: all $($want.Count) in place"
            }
            $parts  = @(if ($missing.Count) { "$($missing.Count) missing" }; if ($stale.Count) { "$(Get-DoctorPlural $stale.Count 'old one' 'old ones') left" })
            $detail = @($missing | ForEach-Object { "missing: $(ConvertTo-SafePath $_)" }) + @($stale | ForEach-Object { "old: $(ConvertTo-SafePath $_)" })
            New-DoctorResult -Id 'defender' -Status 'XX' -Text "Defender exclusions: $($parts -join ', ')" -Detail $detail -Fix '710sRice install -Only defender' -Step 'defender'
        }
    }

    Install = {
        param($Ctx)
        Set-DefenderExclusions
    }

    Uninstall = {
        param($Ctx)
        Remove-DefenderExclusions
    }

    Check = {
        param($Ctx)
        Test-DoctorDefender
    }
}
