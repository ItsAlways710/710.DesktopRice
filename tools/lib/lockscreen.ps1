# The lock screen follows the wallpaper as YOUR lock-screen picture (Windows' per-user one), set
# by scripts\Set-LockScreen.ps1 -- which has to run in Windows PowerShell 5.1 (PowerShell 7 can't
# call WinRT). Everything of the lock screen's but that script lives here: running it and its
# record (the wallpaper pipeline, tools\apply-wallust-outputs.ps1, dot-sources this file for those
# -- they have no dependencies, so the pipeline stays free of activation.ps1); install's and
# uninstall's parts and the restores; doctor's check. Those last three use the shared helpers
# tools\lib\activation.ps1 loads (it dot-sources this file too) and only ever run there.
# Why a per-user picture and not the old machine policy: scripts\Set-LockScreen.ps1's header.

function Get-LockScreenRecordPath { Join-Path $env:LOCALAPPDATA '710.DesktopRice\lockscreen.json' }

function Read-LockScreenRecord {
    <# The last set's outcome (Set-LockScreen.ps1 writes it; so does Invoke-LockScreenSetter when
       the script never got to): time, image (a file name, never a folder), ok, policy (a machine
       policy shows its own picture over yours), reason. $null when there's none. #>
    $f = Get-LockScreenRecordPath
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { [IO.File]::ReadAllText($f) | ConvertFrom-Json -AsHashtable } catch { $null }
}

function Write-LockScreenRecord {
    param([bool]$Ok, [string]$Image, [string]$Reason)
    try {
        $o = [ordered]@{ time = (Get-Date -Format 's'); image = $(if ($Image) { Split-Path -Leaf $Image } else { '' }); ok = $Ok; policy = $false; reason = $Reason }
        $f = Get-LockScreenRecordPath
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f)
        [IO.File]::WriteAllText($f, ($o | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    } catch { }
}

function Invoke-LockScreenSetter {
    <# Runs scripts\Set-LockScreen.ps1 in Windows PowerShell 5.1 with no window at all
       (CreateNoWindow: no console is ever made -- the way Start-Komorebi runs komorebic), and
       waits for it: the caller gets the result, and quick wallpaper changes stay in order (the
       pipeline holds its lock meanwhile). The timeout is only for a WinRT call that never
       answers. As the caller -- the user on a wallpaper change; install / uninstall run
       elevated, as the same user.
       -KeepMode: leave Windows' Picture / Spotlight / Slideshow choice alone (uninstall's put-back
       of your original picture); otherwise the script also chooses Picture, or the picture never
       shows while Spotlight is on.
       -> ExitCode (the script's: 0 set, 1 no picture file, 2 set but a policy overrides it,
       3 Windows refused; ours: 4 timed out, 5 couldn't start powershell.exe) and Message (what
       happened, in words -- the script's last line). #>
    param([Parameter(Mandatory)][string]$Root, [string]$Image, [int]$TimeoutSec = 30, [switch]$KeepMode)
    $ps = if ($env:WINDIR) { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
    if (-not $ps -or -not (Test-Path -LiteralPath $ps)) {
        $why = "Windows PowerShell (powershell.exe) wasn't found"
        Write-LockScreenRecord -Ok $false -Image $Image -Reason $why
        return [pscustomobject]@{ ExitCode = 5; Message = $why }
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new($ps)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'scripts\Set-LockScreen.ps1'))) {
        $psi.ArgumentList.Add($a)
    }
    if ($Image) { $psi.ArgumentList.Add('-Image'); $psi.ArgumentList.Add($Image) }
    if ($KeepMode) { $psi.ArgumentList.Add('-KeepMode') }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch {
        $why = "couldn't start Windows PowerShell ($($_.Exception.Message))"
        Write-LockScreenRecord -Ok $false -Image $Image -Reason $why
        return [pscustomobject]@{ ExitCode = 5; Message = $why }
    }
    try {
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { }
            $why = "Windows didn't answer within $TimeoutSec s"
            Write-LockScreenRecord -Ok $false -Image $Image -Reason $why
            return [pscustomobject]@{ ExitCode = 4; Message = $why }
        }
        $p.WaitForExit()   # and let the readers finish
        $said = @("$($out.Result)" -split "`r?`n" | Where-Object { $_.Trim() })
        $errs = @("$($err.Result)" -split "`r?`n" | Where-Object { $_.Trim() })
        $msg = if ($said.Count) { $said[-1].Trim() } elseif ($errs.Count) { $errs[0].Trim() } else { '' }
        [pscustomobject]@{ ExitCode = $p.ExitCode; Message = $msg }
    } finally { $p.Dispose() }
}

# --- Install and uninstall: the old sync retired, your picture set and put back ------------
# Since 2026-09-28 the lock screen follows the wallpaper as YOUR lock-screen picture (Windows'
# per-user one), set on every wallpaper change by the pipeline -- scripts\Set-LockScreen.ps1
# through Invoke-LockScreenSetter above, on every install, with no task and no admin. Before that
# (2026-09-22 .. 09-28) -Activate registered an elevated on-demand task that wrote a machine
# policy (HKLM PersonalizationCSP) pointing at the wallpaper file, and the screen before sign-in
# stayed black after a wallpaper change until the next Win+L (plan doc items 46 and 48). What's
# left of that: retiring it on a machine that still has it. And uninstall's put-back of yours.

function Restore-LockScreenPolicy {
    <# Puts the machine policy the old sync wrote (HKLM PersonalizationCSP) back the way it was,
       from the 'lockscreen-personalizationcsp' snapshot install took when it registered the old
       task. On the usual machine nothing was there before, so the whole key goes (and Settings'
       own lock-screen picker works again); otherwise its three values are restored. A key with
       no snapshot of ours is never touched (a company's policy, say), and a key that's already
       gone is fine. Needs admin (HKLM): warns and skips without it. $true when the snapshot was
       used. #>
    $snap = Get-OriginalState -Label 'lockscreen-personalizationcsp'
    if (-not $snap) { return $false }
    if (-not (Test-IsAdmin)) {
        Step-Warn "The old lock-screen policy key needs an admin window to remove -- run this again from one."
        return $false
    }
    $cspPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    $anyExistedBefore = $snap.LockScreenImageStatus.Existed -or $snap.LockScreenImagePath.Existed -or $snap.LockScreenImageUrl.Existed
    if (-not $anyExistedBefore) {
        Remove-Item -Path $cspPath -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Set-RegValueFromSnapshot -Path $cspPath -Name 'LockScreenImageStatus' -Snapshot $snap.LockScreenImageStatus
        Set-RegValueFromSnapshot -Path $cspPath -Name 'LockScreenImagePath' -Snapshot $snap.LockScreenImagePath
        Set-RegValueFromSnapshot -Path $cspPath -Name 'LockScreenImageUrl' -Snapshot $snap.LockScreenImageUrl
    }
    Remove-OriginalState -Label 'lockscreen-personalizationcsp'
    $true
}

function Remove-RetiredLockScreenSync {
    <# Retires the old lock-screen sync on a machine that still has it: the elevated
       'lock-screen-sync' task, its launch file (launch-lock-screen-sync.txt), and the policy it
       wrote (Restore-LockScreenPolicy). Called by install's tasks step (so -Activate, a plain
       re-run and `710sRice install -Only tasks` -- repair's fix, and so update's) and by
       uninstall. A no-op on a machine that never had it. $true when it removed something:
       install then sets your picture once, since nothing else would before the next wallpaper
       change. #>
    $removed = $false
    if (Test-Task -TaskName 'lock-screen-sync') {
        $null = & schtasks.exe /Delete /TN (Get-TaskFullName -TaskName 'lock-screen-sync') /F 2>&1
        if (Test-Task -TaskName 'lock-screen-sync') {
            Step-Warn "Couldn't remove the retired lock-screen sync task -- run this again from an admin window."
        } else {
            Step-Info 'Removed the retired lock-screen sync task (the lock screen is your own picture now, set on every wallpaper change).'
            $removed = $true
        }
    }
    Remove-Item (Join-Path $env:LOCALAPPDATA '710.DesktopRice\launch-lock-screen-sync.txt') -Force -ErrorAction SilentlyContinue
    if (Restore-LockScreenPolicy) {
        Step-Info "Removed the old lock-screen policy key (put back the way it was before 710sRice) -- it hid your own picture."
        $removed = $true
    }
    $removed
}

function Set-LockScreenToWallpaper {
    <# Your lock-screen picture = the wallpaper that's up now, once, outside a wallpaper change:
       install's tasks step, right after retiring the old sync, or when nothing has set it yet.
       One line either way. #>
    $r = Invoke-LockScreenSetter -Root $Root -Image (Get-CurrentWallpaper)
    $text = ConvertTo-SafeText $r.Message
    switch ($r.ExitCode) {
        0       { Step-Ok "Lock screen $text" }
        2       { Step-Warn "Lock screen $text" }
        default { Step-Warn "Lock screen: $text -- it follows the next wallpaper change (SUPER+W)." }
    }
}

function Get-WindowsLockScreenDefault {
    # Windows' own default lock-screen picture, for when your original is gone: img100.jpg in
    # %WINDIR%\Web\Screen, or the first picture there. $null when there's none.
    $dir = Join-Path $env:WINDIR 'Web\Screen'
    $first = Join-Path $dir 'img100.jpg'
    if (Test-Path -LiteralPath $first -PathType Leaf) { return $first }
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.jpg', '.jpeg', '.png' } | Sort-Object Name |
        Select-Object -First 1 -ExpandProperty FullName
}

function Restore-LockScreenPicture {
    <# Uninstall: your lock screen as it was before 710sRice first set it, from the
       'lockscreen-picture' snapshot scripts\Set-LockScreen.ps1 takes before its first set. The
       picture first -- the original file (Windows reports the original, not a copy), or Windows'
       own default picture when that file is gone -- THEN the Spotlight / Slideshow settings, so it
       doesn't matter whether setting a picture switched them off. If -Activate had already
       switched Spotlight off when the snapshot was taken (Hardened), those two values were its,
       not the original: full time's own way back (Restore-FullTimeWindowsSettings) puts them
       back, so they're left alone here. Run after that. Last, Windows' own copy of the choice
       for the screens before sign-in, from the 'lockscreen-signin' snapshot the setter takes
       before it first changes that copy (no snapshot = it never did: left alone). -> 'restored',
       'default' (the original was gone), 'failed', or $null (nothing ever set here -- nothing to
       do). #>
    $snap = Get-OriginalState -Label 'lockscreen-picture'
    if (-not $snap) { return $null }
    $img = "$($snap.Image)"
    $result = 'restored'
    if (-not $img -or -not (Test-Path -LiteralPath $img -PathType Leaf)) { $img = Get-WindowsLockScreenDefault; $result = 'default' }
    if ($img) {
        # -KeepMode: Windows' Picture / Spotlight / Slideshow choice comes back from the snapshot
        # just below, not from the setter (which otherwise chooses Picture).
        $r = Invoke-LockScreenSetter -Root $Root -Image $img -KeepMode
        if ($r.ExitCode -notin 0, 2) { Step-Warn "Lock-screen picture not put back: $(ConvertTo-SafeText $r.Message)"; $result = 'failed' }
    } else { $result = 'failed' }
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    if (-not $snap.Hardened) {
        foreach ($name in 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled') {
            if ($snap[$name]) { Set-RegValueFromSnapshot -Path $cdm -Name $name -Snapshot $snap[$name] }
        }
    }
    if ($snap.SlideshowEnabled) {
        Set-RegValueFromSnapshot -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen' -Name 'SlideshowEnabled' -Snapshot $snap.SlideshowEnabled
    }
    $signIn = Get-OriginalState -Label 'lockscreen-signin'
    if ($signIn) {
        $signInKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Creative\' +
            [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($name in 'RotatingLockScreenEnabled', 'LockImageFlags') {
            if ($signIn[$name]) { Set-RegValueFromSnapshot -Path $signInKey -Name $name -Snapshot $signIn[$name] }
        }
        Remove-OriginalState -Label 'lockscreen-signin'
    }
    Remove-OriginalState -Label 'lockscreen-picture'
    Remove-Item -LiteralPath (Get-LockScreenRecordPath) -Force -ErrorAction SilentlyContinue
    $result
}

function Install-LockScreen {
    <# install's tasks step (so -Activate, a plain re-run and `710sRice install -Only tasks` --
       repair's fix for the old sync, and so update's). Every install sets the lock screen as
       your own picture (the theme step, then every wallpaper change). A machine from before
       2026-09-28 may still have the old elevated 'lock-screen-sync' task and the policy key it
       wrote, which hides your picture: they go here, and the picture is set once, since nothing
       else would before the next wallpaper change. Also set once when nothing has set it yet
       (no record: an install from before, on a machine that never had the old task). Silent
       when there's nothing to do. #>
    $oldSync = (Test-Task -TaskName 'lock-screen-sync') -or [bool](Get-OriginalState -Label 'lockscreen-personalizationcsp')
    if ($oldSync -or -not (Test-Path -LiteralPath (Get-LockScreenRecordPath))) {
        Write-Host "`n-- Lock screen --" -ForegroundColor Cyan
        $null = Remove-RetiredLockScreenSync
        Set-LockScreenToWallpaper
    }
}

function Undo-LockScreenSync {
    # uninstall, section 2: the retired sync's task and policy key, wherever they're still here.
    # Only a machine from before 2026-09-28 has them; your lock-screen picture itself is put
    # back in section 3, after the hardening revert (Undo-LockScreenPicture).
    if (-not (Remove-RetiredLockScreenSync)) { Step-Info 'No old lock-screen sync task or policy key on this machine.' }
}

function Undo-LockScreenPicture {
    # uninstall, section 3: your lock screen as it was before 710sRice (Restore-LockScreenPicture),
    # and a line saying how that went.
    switch (Restore-LockScreenPicture) {
        'restored' { Step-Ok 'Lock-screen picture restored to what it was before this repo ever set it' }
        'default'  { Step-Ok "Lock screen set to Windows' own default picture -- the one you had before is gone" }
        'failed'   { Step-Warn 'Lock-screen picture not put back -- pick one in Settings > Personalization > Lock screen.' }
        default    { Step-Info 'This repo never set the lock screen on this machine -- nothing to restore.' }
    }
}

# --- Doctor's check: the lock screen's lines in the Generated configs group ---------------------
function Get-DoctorLockScreenChoice {
    # Windows' lock-screen choice when it isn't Picture: 'Slideshow' (SlideshowEnabled 1) or
    # 'Windows spotlight' (RotatingLockScreenEnabled not 0, absent included: Spotlight is Windows'
    # default). $null = Picture. The hardening's Spotlight-off policy (DisableWindowsSpotlightFeatures)
    # doesn't count: Windows only honours it on Enterprise / Education, not Pro or Home.
    $slide = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen' -Name 'SlideshowEnabled' -ErrorAction SilentlyContinue
    if ($slide -and $slide.SlideshowEnabled -eq 1) { return 'Slideshow' }
    $rot = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenEnabled' -ErrorAction SilentlyContinue
    if (-not $rot -or $rot.RotatingLockScreenEnabled -ne 0) { return 'Windows spotlight' }
    $null
}

function Get-DoctorSignInScreenChoice {
    # The screens before sign-in read Windows' own copy of the choice, per account
    # (scripts\Set-LockScreen.ps1's header): 'Windows spotlight' when that copy says so
    # (RotatingLockScreenEnabled not 0). No copy at all has nothing to disagree with: $null,
    # same as Picture. Readable without admin.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Creative\' +
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rot = Get-ItemProperty -LiteralPath $key -Name 'RotatingLockScreenEnabled' -ErrorAction SilentlyContinue
    if ($rot -and $rot.RotatingLockScreenEnabled -ne 0) { return 'Windows spotlight' }
    $null
}

function Test-DoctorLockScreen {
    # Your lock-screen picture (plan doc item 48; tools\lib\lockscreen.ps1), four kinds of line:
    #   - The old sync still here, on a machine from before 2026-09-28: its elevated task, or the
    #     policy key it wrote (install's snapshot of that key says it's ours). [XX]: `-Only tasks`
    #     retires both, so repair -- and update -- does.
    #   - A lock-screen policy that isn't ours (no snapshot: a company's, say) shows its own
    #     picture over yours. [!!]: explained, nothing to run -- it isn't ours to delete.
    #   - The last set, from the record scripts\Set-LockScreen.ps1 writes: [OK]; [!!] with
    #     Windows' reason (never [XX]: a managed PC may refuse every time, and repair couldn't
    #     change that); [..] nothing has set it yet.
    #   - Windows' own lock-screen choice, when 710sRice has set your picture: it only shows with
    #     Picture chosen. Spotlight (RotatingLockScreenEnabled not 0 -- absent is Spotlight, Windows'
    #     default) or a slideshow hides it: Win+L and the boot screen showed Windows' default image
    #     on the Dell (2026-10-03). Every set since then chooses Picture; an on-demand machine set
    #     before then can still be on Spotlight, and so can one where Spotlight was picked in
    #     Settings since. [XX]: the palette step sets the picture again, choosing Picture, so
    #     repair -- and update -- does. Not under a lock-screen policy (that shows its own picture
    #     either way, the line above).
    #   - With Picture chosen, Windows' own copy of the choice for the screens before sign-in
    #     (the clock and password screens at boot): still on Spotlight, those two showed Windows'
    #     picture while Win+L showed yours (Godzilla, 2026-10-04). [XX]: the palette step's set
    #     writes that copy (your account may write its own), so repair -- and update -- does.
    # Doctor never asks Windows what the lock screen shows: that would be a Windows PowerShell
    # start in every report (the choice above is two registry values), and a picture you pick in
    # Settings is yours until the next wallpaper change.
    $ours   = [bool](Get-OriginalState -Label 'lockscreen-personalizationcsp')
    $csp    = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -ErrorAction SilentlyContinue
    $gpo    = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -ErrorAction SilentlyContinue
    $cspSet = [bool]($csp -and ($csp.LockScreenImagePath -or $csp.LockScreenImageUrl))
    $gpoSet = [bool]($gpo -and $gpo.LockScreenImage)
    $task   = Test-Task -TaskName 'lock-screen-sync'
    if ($task -or ($ours -and $cspSet)) {
        $what = @(if ($task) { 'its task' }; if ($ours -and $cspSet) { 'the policy key it wrote, which hides your own picture' }) -join ' and '
        New-DoctorResult -Id 'lock-screen:old' -Status 'XX' -Text "The retired lock-screen sync is still here: $what" -Fix '710sRice install -Only tasks' -Step 'tasks'
    }
    if (($cspSet -and -not $ours) -or $gpoSet) {
        New-DoctorResult -Id 'lock-screen:policy' -Status '!!' -Text "A lock-screen policy on this machine shows its own picture over yours -- not 710sRice's (a company policy?)"
    }
    $rec = Read-LockScreenRecord
    if (-not $rec) {
        return New-DoctorResult -Id 'lock-screen' -Status '..' -Text 'Lock screen: not set by 710sRice yet -- it follows the next wallpaper change'
    }
    $when = try { $t = [datetime]::Parse("$($rec.time)"); if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') } else { $t.ToString('yyyy-MM-dd HH:mm') } } catch { "$($rec.time)" }
    $name = "$($rec.image)"
    if ($rec.ok) {
        $choice = if (-not $cspSet -and -not $gpoSet) { Get-DoctorLockScreenChoice } else { $null }
        if ($choice) {
            return New-DoctorResult -Id 'lock-screen' -Status 'XX' -Text "Lock screen: Windows is set to $choice, so your picture doesn't show there" `
                -Detail @("Settings > Personalization > Lock screen says $choice; your picture needs Picture", "last set with the wallpaper: $(if ($name) { "$name, " })$when") `
                -Fix '710sRice install -Only palette' -Step 'palette'
        }
        $signIn = if (-not $cspSet -and -not $gpoSet) { Get-DoctorSignInScreenChoice } else { $null }
        if ($signIn) {
            return New-DoctorResult -Id 'lock-screen' -Status 'XX' -Text "Lock screen: the screens before sign-in still show $signIn, not your picture" `
                -Detail @("Win+L shows your picture; the clock and password screens at boot read Windows' own copy of the choice", "last set with the wallpaper: $(if ($name) { "$name, " })$when") `
                -Fix '710sRice install -Only palette' -Step 'palette'
        }
        return New-DoctorResult -Id 'lock-screen' -Status 'OK' -Text "Lock screen: set with the wallpaper ($(if ($name) { "$name, " })$when)"
    }
    New-DoctorResult -Id 'lock-screen' -Status '!!' -Text "Lock screen: the last set ($when) didn't take -- it shows an older picture" `
        -Detail @($(if ($name) { "wallpaper: $name" }), (ConvertTo-SafeText "$($rec.reason)")) -Fix '710sRice install -Only palette'
}
