<#
.SYNOPSIS
  `710sRice palette`, `palette use`, `palette edit` and `palette new`: the palette profiles listed,
  one used now, the editor opened. Dot-sourced by 710sRice.ps1's palette rows, and only there
  (the list's row loads tools\lib\palette.ps1 first; the editor's start loads it itself): they
  use the dispatcher's own Write-RiceError, Show-RiceCommandHelp, Step-Ok and $script:RiceExit.
  Only functions.
#>

# --- palette ---------------------------------------------------------------------------------------
function Show-RicePalettes {
    # Default and the profiles that exist, the one in use marked; a broken one says why.
    $active = Resolve-ActivePaletteProfile
    $chosen = Get-ActivePaletteProfileId
    $all = @(Get-PaletteProfiles)
    Write-Host ''
    Write-Host '  Palette profiles -- SUPER+Alt+Space > Palette profiles, or 710sRice palette use / edit / new'
    foreach ($p in $all | Where-Object Exists) {
        $mark = if ($p.Id -eq $active.Id) { '>' } else { ' ' }
        $what = if ($p.Error) { "can't be used: $($p.Error -replace '^[^:]+: ', '')" } else { $p.Summary }
        $line = '  {0} {1,-26} {2}' -f $mark, $p.Label, $what
        if ($p.Id -eq $active.Id) { Write-Host $line -ForegroundColor Green }
        elseif ($p.Error) { Write-Host $line -ForegroundColor Yellow }
        else { Write-Host $line }
    }
    if ($chosen -ne $active.Id) { Write-Host "  [!!] $($active.Warning)" -ForegroundColor Yellow }
    $free = @($all | Where-Object { $_.Id -ne 'default' -and -not $_.Exists }).Count
    Write-Host ''
    Write-Host "  $free of 10 slots free. palette use <profile> switches now (every wallpaper change uses it too); palette edit <profile> opens the editor."
    Write-Host ''
}

function Invoke-RicePaletteUse {
    if ($args.Count -ne 1 -or -not "$($args[0])".Trim()) {
        Write-RiceError 'palette use takes one profile: default, 0-9, or its name'
        Show-RiceCommandHelp 'palette use'
        $script:RiceExit = 1
        return
    }
    # In-process, like install's palette step; the pipeline prints what it themed.
    & (Join-Path $Root 'tools\apply-wallust-outputs.ps1') -ProfileId "$($args[0])"
    $script:RiceExit = $LASTEXITCODE
}

function Invoke-RicePaletteEditor {
    # Starts the editor hidden (only its own window shows) and waits until that window is up --
    # or the process ends: already open (it brought that one to the front) or it failed (the
    # last line of its log says why).
    param([string]$Mode, [Parameter(ValueFromRemainingArguments)]$Rest)
    $rest = @($Rest | Where-Object { "$_".Trim() })
    $usage = if ($Mode -eq 'new') { 'palette new' } else { 'palette edit' }
    if ($rest.Count -gt 1) {
        Write-RiceError "$usage takes at most one profile: default, 0-9, or its name (quote a name with spaces)"
        Show-RiceCommandHelp $usage
        $script:RiceExit = 1
        return
    }
    . (Join-Path $Root 'tools\lib\palette.ps1')
    $argLine = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$(Join-Path $Root 'tools\palette-editor.ps1')`""
    if ($rest.Count) {
        $want = "$($rest[0])".Trim()
        $id = ConvertTo-PaletteProfileId $want
        if (-not $id) {
            Write-RiceError "No palette profile '$want' -- default, 0-9, or a profile's name (710sRice palette lists them)"
            $script:RiceExit = 1
            return
        }
        if ($Mode -eq 'new') {
            if (-not (Test-Path -LiteralPath (Get-PaletteProfilePath -Id $id))) {
                Write-RiceError "$(Get-PaletteProfileLabel -Id $id) doesn't exist yet -- nothing to start from"
                $script:RiceExit = 1
                return
            }
            $argLine += " -New -From $id"
        } else { $argLine += " -ProfileId $id" }
    } elseif ($Mode -eq 'new') { $argLine += ' -New' }
    if ($Mode -eq 'new' -and -not (Get-FreePaletteProfileId)) {
        Write-RiceError 'All 10 profile slots are in use -- delete one first (710sRice palette edit <profile>, then Delete)'
        $script:RiceExit = 1
        return
    }
    $log = Join-Path $env:LOCALAPPDATA '710.DesktopRice\palette-editor.log'
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $until = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $until) {
        Start-Sleep -Milliseconds 200
        if ($p.HasExited) { break }
        $p.Refresh()
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
            Step-Ok 'The palette editor is open.'
            return
        }
    }
    if (-not $p.HasExited) { Step-Ok 'The palette editor is starting.'; return }
    if ($p.ExitCode -eq 0) { Step-Ok 'The palette editor was already open -- it''s in front now.'; return }
    $last = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log -Tail 1)[0] -replace '^\S+ \S+\s+', '' } else { '' }
    Write-RiceError "The palette editor didn't start$(if ($last) { ": $last" }) (log: %LOCALAPPDATA%\710.DesktopRice\palette-editor.log)"
    $script:RiceExit = 1
}
