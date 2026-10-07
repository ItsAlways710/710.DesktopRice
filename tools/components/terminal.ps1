# Windows Terminal: PowerShell 7 as its default profile, and the JetBrainsMono Nerd Font as every
# profile's font -- install sets both, saving each as it was before its first change; uninstall
# puts Terminal's settings back as they were (those two, and the colour scheme the palette's
# Terminal target sets on every wallpaper change -- tools\palette\targets\terminal.ps1); doctor
# checks all three. Its font helpers, which uninstall's Nerd Font removal shares, are in
# tools\lib\terminal.ps1. (A fixed install step until 2026-10-07, its code in install.ps1,
# uninstall.ps1 and tools\lib\activation.ps1 / doctor.ps1.)
@{
    Id    = 'terminal'
    Label = 'Windows Terminal'
    After = 'profile'

    Functions = {
        function Test-TerminalUsesScheme {
            # Does any profile draw with colour scheme $Name -- profiles.defaults or one in profiles.list,
            # named directly or as either half of a { light, dark } pair?
            param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name)
            $p = $Settings['profiles']
            if ($p -isnot [System.Collections.IDictionary]) { return $false }
            foreach ($x in @($p['defaults']) + @($p['list'])) {
                if ($x -isnot [System.Collections.IDictionary] -or -not $x.Contains('colorScheme')) { continue }
                $cs = $x['colorScheme']
                if ($cs -is [System.Collections.IDictionary]) { if ("$($cs['light'])" -eq $Name -or "$($cs['dark'])" -eq $Name) { return $true } }
                elseif ("$cs" -eq $Name) { return $true }
            }
            $false
        }

        function Restore-WindowsTerminalSettings {
            <# Reverts both Terminal changes back to their own independent snapshots: 'terminal-
               colorscheme' (profiles.defaults.colorScheme/theme/the "wallust" themes[] entry --
               taken by the palette's Terminal target, tools\palette\targets\terminal.ps1, through
               palette.ps1's own copy of Save-OriginalState) and 'terminal-defaultprofile' (taken by
               this component's Install). Two separate labels, not one, because they're written by two
               different scripts that don't run in a fixed relative order relative to each other over
               the life of an install (install's theme step runs the pipeline before this step ever
               runs on a first install, but apply-wallust-outputs.ps1 also fires independently on
               every later real wallpaper change) -- combining them into one label would let
               whichever runs first "win" the snapshot and silently drop the other's fields.
               Applies whichever of the two snapshots exist (each is independently optional) to
               the CURRENT settings.json in a single read-modify-write, so anything else the person
               changed in Terminal in between (a new profile, a font tweak) survives. #>
            # (And 'terminal-font' -- the font faces install's terminal step set since 2026-10-01: the
            # defaults' and each profile's own -- applied the same way.)
            $colorSnap = Get-OriginalState -Label 'terminal-colorscheme'
            $profileSnap = Get-OriginalState -Label 'terminal-defaultprofile'
            $fontSnap = Get-OriginalState -Label 'terminal-font'
            if (-not $colorSnap -and -not $profileSnap -and -not $fontSnap) { return $false }

            $wtSettingsCandidates = @(
                "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
                "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
            )
            $wtSettingsPath = $wtSettingsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $wtSettingsPath) {
                Step-Info 'Windows Terminal settings.json not found -- nothing to restore (already gone, or Terminal was never launched).'
                Remove-OriginalState -Label 'terminal-colorscheme'
                Remove-OriginalState -Label 'terminal-defaultprofile'
                Remove-OriginalState -Label 'terminal-font'
                return $true
            }
            $wt = Get-Content $wtSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

            if ($colorSnap) {
                if ($colorSnap.ColorSchemeExisted -and $wt['profiles'] -and $wt['profiles']['defaults'] -is [hashtable]) {
                    $wt['profiles']['defaults']['colorScheme'] = $colorSnap.ColorScheme
                } elseif ($wt['profiles'] -and $wt['profiles']['defaults'] -is [hashtable]) {
                    $wt['profiles']['defaults'].Remove('colorScheme')
                }
                if ($colorSnap.ThemeKeyExisted) { $wt['theme'] = $colorSnap.Theme }
                elseif ($wt.ContainsKey('theme')) { $wt.Remove('theme') }
                if (-not $colorSnap.WallustThemeEntryExisted -and $wt['themes'] -is [array]) {
                    $wt['themes'] = @($wt['themes'] | Where-Object { $_['name'] -ne 'wallust' })
                }
                # The "wallust" colour scheme itself (the palette's Terminal target adds it to schemes[]). A
                # snapshot from 2026-10-07 on says whether one was there before ours (review item 3): that
                # one is put back in place of ours. Otherwise ours goes once nothing uses it -- the defaults
                # or a profile of its own, as a name or as a light / dark pair; it used to stay in
                # Terminal's scheme list forever (found 2026-10-01). Still used = kept: removing it would
                # leave that profile without its colours (your own pick since, or an older snapshot's
                # "before" that already said wallust -- the Dell's).
                $others = @($wt['schemes'] | Where-Object { -not ($_ -is [System.Collections.IDictionary] -and $_['name'] -eq 'wallust') })
                if ($colorSnap.WallustSchemeExisted -and $colorSnap.WallustScheme) {
                    $wt['schemes'] = @($others) + @($colorSnap.WallustScheme)
                } elseif ($wt['schemes'] -is [array] -and -not (Test-TerminalUsesScheme -Settings $wt -Name 'wallust')) {
                    $wt['schemes'] = $others
                }
                Remove-OriginalState -Label 'terminal-colorscheme'
            }
            if ($profileSnap) {
                if ($profileSnap.Existed) { $wt['defaultProfile'] = $profileSnap.Value }
                elseif ($wt.ContainsKey('defaultProfile')) { $wt.Remove('defaultProfile') }
                Remove-OriginalState -Label 'terminal-defaultprofile'
            }
            if ($fontSnap) {
                # Each face install changed, back as it was (the defaults' and each profile's own; a profile
                # that's gone since is skipped). Faces you set after install on other profiles stay.
                foreach ($f in @($fontSnap.Faces)) { Set-TerminalFontFace -Settings $wt -Key "$($f.Key)" -Face $f.Face }
                Remove-OriginalState -Label 'terminal-font'
            }

            $wt | ConvertTo-Json -Depth 50 | Set-Content -Path $wtSettingsPath -Encoding UTF8
            return $true
        }

        function Get-DoctorTerminalSettings {
            # Windows Terminal's settings.json, from the same two places install and the palette look.
            $path = @("$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
                      "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json") |
                    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
        }

        function Test-DoctorTerminal {
            # Themed: the palette step sets profiles.defaults.colorScheme to wallust's own scheme.
            # Default shell: the terminal step points defaultProfile at the PowerShell 7 profile.
            $wt = Get-DoctorTerminalSettings
            if (-not $wt) {
                if (Test-Path -LiteralPath "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe") {
                    return New-DoctorResult -Id 'terminal' -Status '..' -Text "Windows Terminal hasn't been opened yet -- no settings to check"
                }
                return   # not installed: group b says so
            }
            $active = Resolve-ActivePaletteProfile
            if ('terminal' -in $active.Profile.off) {
                New-DoctorResult -Id 'terminal' -Status '..' -Text "Windows Terminal's colours: off in $(Get-PaletteProfileLabel -Id $active.Id -Name $active.Profile.name)"
            }
            $scheme  = if ($wt['profiles'] -is [hashtable] -and $wt['profiles']['defaults'] -is [hashtable]) { $wt['profiles']['defaults']['colorScheme'] }
            $hasOurs = [bool](@($wt['schemes']) | Where-Object { $_ -is [hashtable] -and $_['name'] -eq 'wallust' })
            if ('terminal' -in $active.Profile.off) { }
            elseif ($scheme -eq 'wallust' -and $hasOurs) { New-DoctorResult -Id 'terminal' -Status 'OK' -Text 'Windows Terminal themed (wallust)' }
            else {
                $why = if ($scheme -ne 'wallust') { "colorScheme isn't wallust" } else { 'no wallust scheme' }
                New-DoctorResult -Id 'terminal' -Status 'XX' -Text "Windows Terminal isn't themed ($why)" -Fix '710sRice install -Only palette' -Step 'palette'
            }
            $pwsh = @(if ($wt['profiles'] -is [hashtable]) { $wt['profiles']['list'] }) | Where-Object { $_ -is [hashtable] -and $_['source'] -eq 'Windows.Terminal.PowershellCore' } | Select-Object -First 1
            if (-not $pwsh -or -not $pwsh['guid']) {
                New-DoctorResult -Id 'terminal-default' -Status '!!' -Text 'Windows Terminal has no PowerShell 7 profile yet' -Fix 'open Terminal once, then 710sRice install -Only terminal'
            } elseif ($wt['defaultProfile'] -eq $pwsh['guid']) {
                New-DoctorResult -Id 'terminal-default' -Status 'OK' -Text 'Windows Terminal opens PowerShell 7'
            } else {
                New-DoctorResult -Id 'terminal-default' -Status '!!' -Text 'Windows Terminal opens something other than PowerShell 7' -Fix '710sRice install -Only terminal' -Step 'terminal'
            }
            # The font (every profile's, profiles.defaults.font.face): the Nerd Font, for the prompt's
            # icons. Never set by 710sRice here yet (no 'terminal-font' snapshot) = [XX], so repair and
            # update bring existing installs along; set, then changed by you since = [!!], left alone.
            $face = Get-NerdFontFace
            if ($face) {
                # The defaults, and every profile that sets its own face (a profile's own wins).
                $wrong = @(Get-TerminalFontFaces -Settings $wt | Where-Object { $_.Face -cne $face })
                $which = ($wrong | ForEach-Object { "$($_.Name): $(if ($_.Face) { $_.Face } else { "Terminal's default" })" }) -join '; '
                if (-not $wrong.Count) {
                    New-DoctorResult -Id 'terminal-font' -Status 'OK' -Text "Windows Terminal uses the Nerd Font ($face)"
                } elseif (-not (Get-OriginalState -Label 'terminal-font')) {
                    New-DoctorResult -Id 'terminal-font' -Status 'XX' -Text "Windows Terminal doesn't use the Nerd Font -- the prompt's icons show as boxes" -Detail $which -Fix '710sRice install -Only terminal' -Step 'terminal'
                } else {
                    New-DoctorResult -Id 'terminal-font' -Status '!!' -Text "Windows Terminal's font changed since 710sRice set $face -- your call; the prompt's icons need $face" -Detail $which -Fix '710sRice install -Only terminal'
                }
            }
        }
    }

    Install = {
        param($Ctx)
        # Default shell (PowerShell 7) and font (the Nerd Font).
        # One-time preference, not a per-wallpaper concern -- deliberately NOT folded into
        # tools/apply-wallust-outputs.ps1 (which re-runs on every wallpaper change and would
        # silently re-clobber a manual change back to this every time). Looked up by `source`
        # rather than a hardcoded GUID: Windows Terminal auto-generates the PowerShellCore dynamic
        # profile once it detects pwsh.exe, and while its GUID is deterministic/stable across
        # machines in practice, matching on `source` here means this doesn't silently break if
        # that assumption is ever wrong on a machine (Godzilla, eventually) this hasn't been
        # verified against yet.
        $wtSettingsCandidates = @(
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
            "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
        )
        $wtSettingsPath = $wtSettingsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($wtSettingsPath) {
            $wt = Get-Content $wtSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $pwshProfile = @($wt['profiles']['list']) | Where-Object { $_['source'] -eq 'Windows.Terminal.PowershellCore' } | Select-Object -First 1
            if ($pwshProfile -and $pwshProfile['guid']) {
                if ($wt['defaultProfile'] -ne $pwshProfile['guid']) {
                    # One-time snapshot of whatever the default profile was before -- separate
                    # label from apply-wallust-outputs.ps1's own 'terminal-colorscheme' snapshot
                    # (see Restore-WindowsTerminalSettings, in Functions above, for why two
                    # labels, not one) since this is the only place that ever touches this field.
                    Save-OriginalState -Label 'terminal-defaultprofile' -Data @{
                        Existed = $wt.ContainsKey('defaultProfile')
                        Value   = $wt['defaultProfile']
                    }
                    $wt['defaultProfile'] = $pwshProfile['guid']
                    $wt | ConvertTo-Json -Depth 50 | Set-Content -Path $wtSettingsPath -Encoding UTF8
                    Step-Ok "Windows Terminal default profile set to PowerShell 7 ($($pwshProfile['guid']))"
                } else {
                    Step-Ok 'Windows Terminal default profile already PowerShell 7'
                }
            } else {
                Step-Warn "No PowerShell 7 profile found in Windows Terminal's settings.json yet -- open Terminal once (it generates this profile the first time it sees pwsh.exe on PATH), then run ``710sRice install -Only terminal``."
            }
            # The font, for every profile (profiles.defaults.font.face): the Nerd Font the packages
            # step installs -- Starship's prompt, eza's icons and the rest need its glyphs. winarchy's
            # Merge-WinarchyTerminalScheme set it next to the colour scheme; the 09-23 port carried
            # the colours only, so until 2026-10-01 a fresh machine got the font installed and never
            # used (the Dell only looked right because winarchy had set it there). Set on every run,
            # like the default shell; doctor flags a font you picked yourself since, and repair
            # leaves it. Only the face: a size or weight you set stays.
            $face = Get-NerdFontFace
            if (-not $face) {
                Step-Warn "The JetBrainsMono Nerd Font isn't installed -- Windows Terminal's font left as it is (``710sRice install -Only packages``, then ``-Only terminal``)."
            } else {
                $wt = Get-Content $wtSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                # The defaults, and every profile that sets its own face (a profile's own wins).
                $faces = @(Get-TerminalFontFaces -Settings $wt)
                # Once, before the first change (and on a machine that already had it all -- the
                # mark doctor reads as "the terminal step has set the font here"): every face as it is.
                Save-OriginalState -Label 'terminal-font' -Data @{ Faces = @($faces | ForEach-Object { @{ Key = $_.Key; Name = $_.Name; Face = $_.Face } }) }
                $wrong = @($faces | Where-Object { $_.Face -cne $face })
                if (-not $faces.Count) {
                    Step-Warn "Windows Terminal's settings.json has an old layout (no profiles.defaults) -- its font left as it is; set $face in Terminal's settings by hand."
                } elseif (-not $wrong.Count) {
                    Step-Ok "Windows Terminal font already $face (every profile)"
                } else {
                    foreach ($f in $wrong) { Set-TerminalFontFace -Settings $wt -Key $f.Key -Face $face }
                    $wt | ConvertTo-Json -Depth 50 | Set-Content -Path $wtSettingsPath -Encoding UTF8
                    $own = @($wrong | Where-Object Key -ne 'defaults')
                    $was = @($wrong | Where-Object Face | ForEach-Object Face | Select-Object -Unique)
                    Step-Ok ("Windows Terminal font set to $face (every profile" + $(if ($own.Count) { "; $($own.Count) that set their own font too: $(($own | ForEach-Object Name) -join ', ')" }) + ')' + $(if ($was.Count) { " -- was $($was -join ', ')" }))
                    Step-Info "A Terminal window that's open keeps its font list -- if one says $face is missing, close every Terminal window and open one again."
                }
            }
        } else {
            Step-Warn 'Windows Terminal settings.json not found -- default shell and font not set (install/launch Windows Terminal first).'
        }
    }

    Uninstall = {
        param($Ctx)
        if (Restore-WindowsTerminalSettings) { Step-Ok 'Windows Terminal settings restored' }
        else { Step-Info 'Windows Terminal was never actually themed or had its default shell changed on this machine -- nothing to restore.' }
    }

    Check = {
        param($Ctx)
        Test-DoctorTerminal
    }
}
