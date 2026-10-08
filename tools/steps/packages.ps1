<#
.SYNOPSIS
  install's packages and upgrade steps: everything versions.md lists, installed (pinned rows at
  their pin and winget-pinned; one below its pin moved up to it), and -- the upgrade step, named
  only -- a pinned package older than its pin moved up to it from what the probes read; what
  uninstall does with them (section 5: the pins off; section 6: each package that goes, the way
  it has to go -- uninstall.ps1 itself decides which go); doctor's Packages and pins lines. The
  libraries they use: versions.md's table (tools\lib\versions.ps1), winget (winget.ps1), the
  probes (probes.ps1), the move to a pin (topin.ps1), removing an MSI (msi.ps1). Loaded by
  tools\lib\activation.ps1. Only functions.
#>

# --- install's steps ------------------------------------------------------------------------------
function Install-PackagesStep {
    # install's packages step. What didn't install goes on install's list (-NotInstalled): the
    # run finishes every step, then says so and exits 1.
    param([bool]$SkipPackages, $NotInstalled)
    # --- 1. Packages (winget) -----------------------------------------------------------
    # versions.md is the one list of what's installed and at which version (read through
    # tools\lib\versions.ps1; nothing here keeps a copy). A row with a version number is a
    # pin: installed at exactly that version and winget-pinned, so a general
    # `winget upgrade --all` elsewhere on the machine can't move it out from under this
    # repo's tested config. A `latest` row is installed unpinned and takes its own updates
    # (PowerShell 7 among them -- every script here only needs >= 7.0, and no scheduled task
    # names a pwsh path: they start Windows PowerShell, whose path never moves, and whatever
    # needs PS7 looks it up when it runs). Source `msstore`
    # = winget from the Store source (PowerShell 7's Store/MSIX build -- see versions.md).
    # The github-release row (wallust) is the wallust step's; psgallery rows are below.
    $versionRows = @(Get-VersionsTable -Path (Join-Path $Root 'versions.md'))
    $wingetRows  = @($versionRows | Where-Object { Test-WingetRow $_ })

    if (-not $SkipPackages) {
        Write-Host "`n-- Packages (winget) --" -ForegroundColor Cyan
        if ($wingetRows.Count -eq 0) {
            # Never guess what to install -- uninstall refuses the same way.
            Write-Host "  [XX] versions.md has no package table -- nothing installed" -ForegroundColor Red
            $NotInstalled.Add("every package (versions.md has no package table)")
        }

        # Some installers drop a Desktop shortcut (Flow Launcher and ShareX -- seen on the
        # 2026-09-24 reinstall test; Flow's installer has no option to skip it). Note which
        # shortcuts are on the Desktop (yours and the shared Public one) before installing,
        # and afterwards remove only the ones that appeared in between -- any you already had,
        # even for these same apps, are left alone. Uninstall needs nothing: both
        # uninstallers remove their own shortcut.
        $desktopDirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        function Get-DesktopShortcuts {
            foreach ($dir in $desktopDirs) {
                Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object FullName
            }
        }
        $shortcutsBefore = @(Get-DesktopShortcuts)

        foreach ($row in $wingetRows) {
            $id = $row.InstallId
            $pinVersion = if (Test-PinnedRow $row) { $row.Version } else { $null }
            # Every call names its source (Get-WingetSourceArgs): winget's own for winget rows,
            # the Store for PowerShell 7's msstore row -- never both (W1).
            $sourceArgs = @(Get-WingetSourceArgs $row)
            # Three rows are found without asking winget, the way doctor finds them. PowerShell 7: this
            # install runs on it (#Requires -Version 7.0) -- the Store's build or winget's, the README's
            # way where the Store is blocked, which the Store source would call "not installed"
            # (review item 4). Git: on your PATH, whoever installed it. The Nerd Font: by its name in
            # Windows' fonts -- yours or every user's, either face (Get-NerdFontFace) -- so a copy
            # that's already there, installed by hand or by winget, never gets DEVCOM's installer laid
            # over it (Godzilla, 2026-10-03).
            if ($id -eq '9MZ1SNWT0N5D') {
                $here = Get-PackageVersion $row
                if ($here.Installed) { Step-Ok "$id already installed (this install runs on it: PowerShell $($here.Version))"; continue }
            }
            if ($id -eq 'Git.Git') {
                $here = Get-PackageVersion $row
                if ($here.Installed) { Step-Ok "$id already installed (git is on your PATH$(if ($here.Version) { ": $($here.Version)" }))"; continue }
            }
            if ($id -like '*NerdFont*') {
                $face = Get-NerdFontFace
                if ($face) { Step-Ok "$id already installed (Windows has the font: $face)"; continue }
            }
            $listArgs = @('list', '--id', $id, '--exact', '--accept-source-agreements') + $sourceArgs
            $listed = @(winget @listArgs 2>$null)
            $alreadyInstalled = ($listed | Out-String) -match [regex]::Escape($id)
            if ($alreadyInstalled) {
                # A pinned package below its pin goes up to it (W7; user, 2026-09-30: "install
                # should always update pinned packages to pin, that's what the pin is for") --
                # never down: newer than the pin is left alone (doctor's [!!] says how to go back). The
                # version is the one this same `winget list` shows (the token after the ID), so
                # an AutoHotkey 1.1 that winget lists is moved to 2.0.28 instead of pinned at 1.1.
                $have = Get-WingetListedVersion -Lines $listed -Id $id
                $cmp  = if ($pinVersion -and $have) { Compare-PinVersion $have $pinVersion } else { $null }
                if ($cmp -eq -1) {
                    if (-not (Invoke-MoveToPin -Row $row -From $have)) { $NotInstalled.Add("$($row.Component) (still $have, not its pin $pinVersion)") }
                } elseif ($cmp -eq 1) {
                    Step-Ok "$id already installed ($have -- newer than its pin $pinVersion, left alone)"
                } else {
                    Step-Ok "$id already installed"
                }
            } else {
                $wingetArgs = @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
                if ($pinVersion) { $wingetArgs += @('--version', $pinVersion) }
                $wingetArgs += $sourceArgs
                $how = ''
                if ($PerUserPackages -contains $id -and (Test-IsAdmin)) {
                    # Installed for you only (Flow, into %LOCALAPPDATA%), so installed un-elevated --
                    # the one-shot task uninstall and the upgrade step already use for it. Run from
                    # this admin window, its own setup first re-launches itself un-elevated through
                    # Explorer, and on the Dell that hand-off crashed (final test T7, 2026-10-01:
                    # Flow-Launcher-Setup.exe c0000005, 0.6 s in, after two Explorer restarts --
                    # Squirrel's Setup uses Explorer's shell-windows object without checking it got one).
                    Step-Info "Installing $id (installed for you only -- un-elevated; a winget window shows briefly) ..."
                    $how = ' (un-elevated)'
                    try { $code = Invoke-WingetAsUser -Arguments ($wingetArgs + '--disable-interactivity') -TimeoutSeconds 600 }
                    catch {
                        Step-Warn "$($_.Exception.Message) -- installing it from this window instead"
                        $how = ''
                        winget @wingetArgs
                        $code = $LASTEXITCODE
                    }
                } else {
                    Step-Info "Installing $id ..."
                    winget @wingetArgs
                    $code = $LASTEXITCODE
                }
                # Restart-required and already-there are installed too (W2, winarchy c5053b9);
                # anything else is a package that didn't install -- the run finishes every step
                # and then says so and exits 1.
                switch (Get-WingetOutcome $code) {
                    'ok'      { Step-Ok "$id installed$how" }
                    'restart' { Step-Warn "$id installed$how -- restart Windows to finish its setup" }
                    'timeout' {
                        Write-Host "  [XX] $($id): the un-elevated install was still running after 10 minutes -- 'winget list --id $id' once it's done; 710sRice doctor -repair tries again" -ForegroundColor Red
                        $NotInstalled.Add($row.Component)
                    }
                    default {
                        $where = if ($how) { "winget ran in its own window -- 'winget install --id $id' from a normal PowerShell window shows why" } else { 'check the output above' }
                        Write-Host "  [XX] $($id): winget install exited $(Format-WingetCode $code)$how -- $where" -ForegroundColor Red
                        $NotInstalled.Add($row.Component)
                    }
                }
            }
            if ($pinVersion) {
                $pinArgs = @('pin', 'add', '--id', $id, '--exact') + $sourceArgs
                winget @pinArgs 2>$null | Out-Null
            }
        }

        $newShortcuts = @(Get-DesktopShortcuts | Where-Object { $shortcutsBefore -notcontains $_ })
        $removed = @(foreach ($lnk in $newShortcuts) {
            try { Remove-Item -LiteralPath $lnk -Force; Split-Path $lnk -Leaf }
            catch { Step-Warn "Couldn't remove the desktop shortcut $(ConvertTo-SafePath $lnk): $($_.Exception.Message)" }
        })
        if ($removed.Count -gt 0) { Step-Ok "Removed the desktop shortcut(s) the installers added: $($removed -join ', ')" }

        # Re-read PATH from the registry into this process. Without this, a component that
        # was just installed for the first time above (e.g. komorebi) won't be found by
        # Get-Command until a new terminal is opened -- see NOTES.
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')

        # PowerShell modules (PSGallery rows -- PSFzf: the PowerShell-side fzf
        # keybindings/integration, separate from the junegunn.fzf winget package above,
        # which is just the fzf binary; DisplayConfig: the Screens menu's, tools\screens.ps1).
        # No pin, always latest, matching this project's own
        # decided practice (winarchy never pinned it either).
        foreach ($row in @($versionRows | Where-Object { $_.Source -eq 'psgallery' })) {
            $module = $row.InstallId
            Write-Host "`n-- $module (PowerShell module) --" -ForegroundColor Cyan
            if (Get-Module -ListAvailable $module) {
                Step-Ok "$module already installed"
            } else {
                Step-Info "Installing $module (PSGallery) ..."
                try {
                    Install-Module $module -Scope CurrentUser -Force -ErrorAction Stop
                    Step-Ok "$module installed"
                } catch {
                    Write-Host "  [XX] Could not install $($module): $($_.Exception.Message)" -ForegroundColor Red
                    $NotInstalled.Add($row.Component)
                }
            }
        }
    } else {
        Step-Info "Skipping package installation (-SkipPackages)"
    }
}

function Install-UpgradeStep {
    # install's upgrade step (named only: doctor's fix for "older than its pin").
    param($NotInstalled)
    # --- upgrade: pinned packages older than their pin, to the pin (named-only) ----------
    # Pinned winget rows only (a version number in versions.md): `latest` rows are unpinned
    # so a normal `winget upgrade --all` moves them; wallust is the wallust step's job.
    # Installed versions come from the local probes in tools\lib\probes.ps1 (doctor reads
    # the same ones). Newer than the pin = left alone (no downgrades -- e.g. a hand upgrade being
    # tried before versions.md is bumped); older = stop the app, pin remove -> winget
    # upgrade --version <pin> -> pin add, check, start it again if it was running -- komorebi
    # and 710.ahk through their tasks, the bar and Flow by asking 710.ahk (Invoke-MoveToPin).
    Write-Host "`n-- Upgrade pinned packages --" -ForegroundColor Cyan
    $pinnedRows = @(@(Get-VersionsTable -Path (Join-Path $Root 'versions.md')) | Where-Object { (Test-WingetRow $_) -and (Test-PinnedRow $_) })
    if ($pinnedRows.Count -eq 0) {
        Write-Host "  [XX] versions.md has no pinned packages -- nothing to upgrade to" -ForegroundColor Red
    }
    foreach ($row in $pinnedRows) {
        $name   = $row.Component
        $before = Get-PackageVersion $row
        if (-not $before.Probe) { Step-Warn "$($name): no version probe for $($row.InstallId) yet -- left alone"; continue }
        if (-not $before.Installed) { Step-Info "$name isn't installed -- the packages step installs it (at its pin)"; continue }
        $cmp = Compare-PinVersion $before.Version $row.Version
        if ($null -eq $cmp) { Step-Warn "$($name): couldn't read its version ('$($before.Version)') -- left alone"; continue }
        if ($cmp -eq 0) { Step-Ok "$name $($before.Version) -- at its pin"; continue }
        if ($cmp -gt 0) { Step-Warn "$name $($before.Version) is newer than its pin $($row.Version) -- left alone"; continue }
        # The same routine the packages step runs for one below its pin (tools\lib\topin.ps1).
        if (-not (Invoke-MoveToPin -Row $row -From $before.Version)) { $NotInstalled.Add("$name (not at its pin $($row.Version))") }
    }
}

# --- Uninstall's parts (sections 5 and 6) --------------------------------------------------------
function Remove-WingetPins {
    # uninstall, section 5: the winget pins of versions.md's pinned rows taken off. Throws, naming
    # them, when winget couldn't remove one.
    param($WingetRows)
    # Every exit code checked: this step used to discard winget's output AND its exit
    # code, so it said "removed" no matter what. "No pin for that package" counts as
    # done -- the goal is no pin, however we got there.
    $failed = @()
    foreach ($row in ($wingetRows | Where-Object { Test-PinnedRow $_ })) {
        $pinArgs = @('pin', 'remove', '--id', $row.InstallId, '--exact') + @(Get-WingetSourceArgs $row)
        winget @pinArgs 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $WingetNoPin) {
            $failed += "$($row.InstallId) ($(Format-WingetCode $LASTEXITCODE))"
        }
    }
    if ($failed) { throw "winget couldn't remove the pin for: $($failed -join ', ') -- 'winget pin list' shows what's left" }
}

function Uninstall-WingetPackage {
    # uninstall, section 6: one package uninstall.ps1 has decided goes (its keep rules -- system,
    # -Keep, Pre-existing? -- are uninstall.ps1's), and the line saying how that went; -DryRun: the
    # line saying what would happen.
    param([Parameter(Mandatory)]$Row, [switch]$DryRun)
    $id = $Row.InstallId
    $msi = $null
    if ($id -like '*NerdFont*') {
        # The font goes: no Windows Terminal profile may still name it (Clear-TerminalNerdFontFaces,
        # tools\lib\terminal.ps1), and it goes through Windows Installer told to close nothing
        # (Invoke-MsiUninstall, tools\lib\msi.ps1) -- winget's silent uninstall had Restart
        # Manager shut down the Terminal running this very uninstall (B2 and T5, 2026-10-01).
        # Only when it IS going -- DEVCOM's Windows Installer entry is there, or winget lists it: a
        # copy you installed yourself stays, and Terminal keeps it (his call, 2026-10-07).
        try { $msi = Get-MsiProductCode -DisplayName '^JetBrainsMono Nerd Font' } catch { }
        $going = [bool]$msi
        if (-not $going) {
            $listArgs = @('list', '--id', $id, '--exact', '--accept-source-agreements') + @(Get-WingetSourceArgs $Row)
            $going = (@(winget @listArgs 2>$null) | Out-String) -match [regex]::Escape($id)
        }
        if ($going -and $DryRun) { Write-Host "  [ ] Point any Windows Terminal profile still on the Nerd Font back to Terminal's own font" }
        elseif ($going) {
            try {
                $moved = @(Clear-TerminalNerdFontFaces)
                if ($moved.Count) {
                    Step-Ok "Windows Terminal: $($moved -join ', ') still used the JetBrainsMono Nerd Font -- back to Terminal's own font before it's removed"
                    Start-Sleep -Seconds 2   # Terminal re-reads its settings by itself; let it, before the font goes
                }
            } catch { Step-Warn "Windows Terminal's font couldn't be checked before removing the Nerd Font: $($_.Exception.Message)" }
        }
    }
    if ($DryRun) { Write-Host "  [ ] Uninstall $id"; return }
    if ($id -like '*NerdFont*') {
        if ($msi) {
            try {
                $code = Invoke-MsiUninstall -ProductCode $msi
                if ($code -eq 0)        { Step-Ok "$id uninstalled (Windows Installer, closing nothing)" }
                elseif ($code -eq 3010) { Step-Ok "$id uninstalled (Windows Installer, closing nothing) -- a program still had the font open (this Windows Terminal, likely), so its files go at your next restart: restart before installing 710sRice again" }
                elseif ($code -eq 1605) { Step-Info "$id -- not installed, nothing to remove" }
                else                    { Step-Warn "$id -- Windows Installer couldn't remove it (exit $code); 'winget uninstall --id $id' by hand shows why (it may close Windows Terminal)" }
            } catch { Step-Warn "Uninstall $($id): $($_.Exception.Message)" }
            return
        }
        # No Windows Installer entry for it (installed some other way, or not at all): winget, below.
    }
    # Not Invoke-Step: the result line depends on winget's exit code (this used to discard
    # it and print "uninstalled" regardless -- Flow Launcher was never actually removed).
    try {
        $uninstallArgs = @('uninstall', '--id', $id, '--exact', '--silent', '--disable-interactivity') + @(Get-WingetSourceArgs $row)
        winget @uninstallArgs 2>$null | Out-Null
        $code = $LASTEXITCODE
        $how  = ''
        if ($code -eq $WingetAdminProhibited) {
            # Installed for this user only -- winget won't remove it from an elevated shell.
            Step-Info "$id is installed for this user only -- removing it un-elevated ..."
            $code = Invoke-WingetAsUser -Arguments $uninstallArgs
            $how  = ' (un-elevated)'
        }
        if ($null -eq $code)                  { Step-Warn "$id -- the un-elevated uninstall was still running after 3 minutes; check 'winget list --id $id' once it's done" }
        elseif ($code -eq 0)                  { Step-Ok "$id uninstalled$how" }
        elseif ($code -eq $WingetNotInstalled) { Step-Info "$id -- not installed, nothing to remove" }
        else                                  { Step-Warn "$id -- winget uninstall failed$how (exit $(Format-WingetCode $code)); 'winget uninstall --id $id' by hand shows why" }
    }
    catch { Step-Warn "Uninstall $($id): $($_.Exception.Message)" }
}

# --- Doctor's checks: the Packages and pins group ---------------------------------------------------
# versions.md's rows against the machine: the local probes in tools\lib\probes.ps1 (the ones
# install's upgrade step goes by, so a check and its fix can't disagree) and ONE `winget pin
# list`, started in the background at the top of the run -- a `winget list` per package would
# be 20-30 s. Pinned rows get their version against the pin; the rest just need to be there.

function Get-DoctorShellToolIds { @('Starship.Starship', 'junegunn.fzf', 'ajeetdsouza.zoxide', 'eza-community.eza', 'sharkdp.bat') }

function Get-DoctorVersionRows {
    $rows = @(Get-VersionsTable -Path (Join-Path $Root 'versions.md'))
    if (-not $rows.Count) { throw "versions.md has no package table" }
    $rows
}

function Test-DoctorPinnedWingetRow { param($Row) (Test-WingetRow $Row) -and (Test-PinnedRow $Row) }

function Get-DoctorPackageName {
    # "PowerShell 7" at 7.6.6 reads "PowerShell 7.6.6", not "PowerShell 7 7.6.6".
    param([string]$Component, [string]$Version)
    if (-not $Version) { return $Component }
    if ($Component -match '^(.*\S)\s+(\d+)$' -and $Version.StartsWith("$($Matches[2]).")) { return "$($Matches[1]) $Version" }
    "$Component $Version"
}

function Get-DoctorPackageResult {
    # One versions.md row: installed at all, and -- when it's pinned -- at its pin.
    param($Row)
    $id   = "pkg:$($Row.InstallId)"
    $name = $Row.Component
    $v    = Get-PackageVersion $Row
    if (-not $v.Probe)     { return New-DoctorResult -Id $id -Status '!!' -Text "$name -- doctor doesn't know how to check it" }
    if (-not $v.Installed) { return New-DoctorResult -Id $id -Status 'XX' -Text "$name isn't installed" -Fix '710sRice install -Only packages' -Step 'packages' }
    $shown = Get-DoctorPackageName $name $v.Version
    if (-not (Test-PinnedRow $Row)) { return New-DoctorResult -Id $id -Status 'OK' -Text $shown }
    $pin = $Row.Version
    switch (Compare-PinVersion $v.Version $pin) {
        0  { return New-DoctorResult -Id $id -Status 'OK' -Text "$shown -- at its pin" }
        -1 { return New-DoctorResult -Id $id -Status 'XX' -Text "$shown -- older than its pin $pin" -Fix '710sRice install -Only upgrade' -Step 'upgrade' }
        1  {
            # Newer than what this rice was tested with: a fact, which repair never changes (no
            # downgrades) -- with the way back, should the app misbehave: winget's own uninstall, then
            # repair, which installs it at its pin and pins it (the packages step).
            return New-DoctorResult -Id $id -Status '!!' -Text "$shown -- newer than its pin $pin" `
                -Detail "its pin is the version this rice was tested with -- if something about it isn't working, going back is worth a try" `
                -Fix "winget uninstall --id $($Row.InstallId) --exact (from a normal window), then 710sRice doctor -repair: it installs $pin and pins it"
        }
    }
    $what = if ($v.Version) { "its version '$($v.Version)' can't be compared with its pin $pin" } else { "installed, but its version couldn't be read" }
    New-DoctorResult -Id $id -Status '!!' -Text "$name -- $what"
}

function Test-DoctorPinnedPackages {
    # The pinned winget rows, in versions.md's order, one line each.
    foreach ($row in @(Get-DoctorVersionRows | Where-Object { Test-DoctorPinnedWingetRow $_ })) { Get-DoctorPackageResult $row }
}

function Start-DoctorWingetJob {
    # `winget pin list --source winget`, in the background (3.2 s on the Dell). Reason says why
    # there's no job. The source named, like every winget call here (Get-WingetSourceArgs): with
    # none, winget also opens the Store source, and a broken one fails the call (Group 1 W1) --
    # every pinned row is a winget row.
    $winget = (Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $winget) { return [pscustomobject]@{ Reason = "winget isn't installed"; Job = $null } }
    [pscustomobject]@{ Reason = $null; Job = (Start-DoctorProcess -Exe $winget -Arguments @('pin', 'list', '--source', 'winget')) }
}

function Test-DoctorPins {
    # Every installed pinned package still winget-pinned -- without the pin, a general `winget
    # upgrade --all` moves it off the version this repo was tested with. One line for all of
    # them. Each Id is matched as a whole word in `winget pin list`'s output (its Name column
    # has spaces, so it isn't split into columns). A package that isn't installed is already
    # its own [XX] above, and the packages step pins what it installs.
    param($Context)
    $rows = @(Get-DoctorVersionRows | Where-Object { (Test-DoctorPinnedWingetRow $_) -and (Get-PackageVersion $_).Installed })
    if (-not $rows.Count) { return }
    $w = $Context.Winget
    if ($w.Reason) { return New-DoctorResult -Id 'pins' -Status '!!' -Text "winget pins -- couldn't check ($($w.Reason))" }
    $r = Wait-DoctorProcess -Job $w.Job -TimeoutSeconds 20
    if ($r.TimedOut)       { return New-DoctorResult -Id 'pins' -Status '!!' -Text "winget pins -- couldn't check (winget didn't answer in 20 s)" }
    if ($r.ExitCode -ne 0) { return New-DoctorResult -Id 'pins' -Status '!!' -Text "winget pins -- couldn't check (winget exited $(Format-WingetCode $r.ExitCode))" }
    $missing = @($rows | Where-Object { $r.Out -notmatch "(?<![\w.-])$([regex]::Escape($_.InstallId))(?![\w.-])" } | ForEach-Object Component)
    if ($missing.Count) {
        return New-DoctorResult -Id 'pins' -Status 'XX' -Text "winget pins missing: $($missing -join ', ')" -Fix '710sRice install -Only packages' -Step 'packages'
    }
    if ($rows.Count -eq 1) { return New-DoctorResult -Id 'pins' -Status 'OK' -Text "winget pin in place ($($rows[0].Component))" }
    New-DoctorResult -Id 'pins' -Status 'OK' -Text "winget pins: all $($rows.Count) in place"
}

function Get-DoctorShellToolsResult {
    # The five shell tools on one line: what's there (starship with its version), and what isn't.
    param([object[]]$Rows)
    $have = @(); $missing = @()
    foreach ($row in $Rows) {
        $v = Get-PackageVersion $row
        if (-not $v.Probe) { Get-DoctorPackageResult $row; continue }   # its own "doesn't know" line
        if ($v.Installed) { $have += Get-DoctorPackageName $row.Component $v.Version } else { $missing += $row.Component }
    }
    if (-not $missing.Count) { return New-DoctorResult -Id 'pkg:shell-tools' -Status 'OK' -Text "Shell tools: $($have -join ', ')" }
    $verb = if ($missing.Count -eq 1) { "isn't" } else { "aren't" }
    $text = if ($have.Count) { "Shell tools: $($have -join ', ') -- $($missing -join ', ') $verb installed" }
            else { "Shell tools: $($missing -join ', ') $verb installed" }
    New-DoctorResult -Id 'pkg:shell-tools' -Status 'XX' -Text $text -Fix '710sRice install -Only packages' -Step 'packages'
}

function Test-DoctorOtherPackages {
    # Everything that isn't a pinned winget row or wallust, in versions.md's order -- the shell
    # tools folded into one line where the first of them sits.
    $rows  = @(Get-DoctorVersionRows | Where-Object { -not (Test-DoctorPinnedWingetRow $_) -and $_.InstallId -notlike '*wallust*' })
    $tools = @(Get-DoctorShellToolIds)
    $toolsShown = $false
    foreach ($row in $rows) {
        if ($tools -contains $row.InstallId) {
            if (-not $toolsShown) {
                $toolsShown = $true
                Get-DoctorShellToolsResult @($rows | Where-Object { $tools -contains $_.InstallId })
            }
            continue
        }
        Get-DoctorPackageResult $row
    }
}
