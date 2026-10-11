<#
.SYNOPSIS
  install's envvars step: KOMOREBI_CONFIG_HOME, YASB_CONFIG_HOME and DESKTOPRICE_HOME (User scope)
  pointing at this clone -- the first two copied once beforehand, as you had them -- and the old
  weather widget's two variables gone; what uninstall puts back (section 4: the first two from
  that copy, DESKTOPRICE_HOME off, each only where it still points here -- the old weather ones
  go there too); doctor's envvars and weather lines. Loaded by tools\lib\activation.ps1. Only
  functions.
#>

# --- install's step -------------------------------------------------------------------------------
function Install-EnvVarsStep {
    # --- 2. Config env vars: repo is the source of truth --------------------------------
    Write-Host "`n-- Config environment variables --" -ForegroundColor Cyan
    $komorebiConfigHome = Join-Path $Root 'config\komorebi'
    $yasbConfigHome     = Join-Path $Root 'config\yasb'
    Save-ConfigEnvVarsOriginal          # yours, before they first point here: uninstall puts them back
    [Environment]::SetEnvironmentVariable('KOMOREBI_CONFIG_HOME', $komorebiConfigHome, 'User')
    [Environment]::SetEnvironmentVariable('YASB_CONFIG_HOME', $yasbConfigHome, 'User')
    # The repo root. config\yasb\config.yaml builds every path it needs from this through
    # YASB's own $env: expansion (the wallpaper folder, the wallust/apply-outputs commands, the
    # home menu entry) instead of hard-coding C:\710.DesktopRice -- clone the repo anywhere.
    [Environment]::SetEnvironmentVariable('DESKTOPRICE_HOME', $Root, 'User')
    $env:KOMOREBI_CONFIG_HOME = $komorebiConfigHome
    $env:YASB_CONFIG_HOME     = $yasbConfigHome
    $env:DESKTOPRICE_HOME     = $Root
    # Shown as %USERPROFILE%\... when the clone lives under the user's folders (ConvertTo-SafePath).
    Step-Ok "KOMOREBI_CONFIG_HOME = $(ConvertTo-SafePath $komorebiConfigHome)"
    Step-Ok "YASB_CONFIG_HOME     = $(ConvertTo-SafePath $yasbConfigHome)"
    Step-Ok "DESKTOPRICE_HOME     = $(ConvertTo-SafePath $Root)"
    # The old weather widget's two variables (weatherapi.com's key and a location), unused since
    # the bar's weather moved to Open-Meteo (Group 1 #1: no account, no key -- the location is
    # picked in the widget). A key shouldn't sit in the environment, so they go. Names only.
    foreach ($name in 'YASB_WEATHER_API_KEY', 'YASB_WEATHER_LOCATION') {
        if (Get-UserEnvVar $name) {
            Remove-UserEnvVar $name
            Step-Ok "$name removed (the weather widget doesn't use it any more)"
        }
    }
}

# --- The copy uninstall puts back ---------------------------------------------------------------
# KOMOREBI_CONFIG_HOME and YASB_CONFIG_HOME are komorebi's and YASB's own variables: you may have
# pointed them at configs of your own before 710sRice. Install copies them, once, before it first
# points them here (original-state\config-envvars.json; Save-OriginalState never overwrites a copy
# it has), and uninstall puts them back from it. One already pointing at this clone isn't copied:
# that's an install's own value, not yours. So an install from before the copy existed has none,
# and its uninstall takes the two off, as uninstall always did.
function Get-ConfigEnvVarHomes {
    [ordered]@{ KOMOREBI_CONFIG_HOME = Join-Path $Root 'config\komorebi'; YASB_CONFIG_HOME = Join-Path $Root 'config\yasb' }
}

function Get-UserEnvVarAsStored {
    # One user variable exactly as registered: %VARS% unexpanded, and its type (String or
    # ExpandString), the way the user PATH is read (tools\lib\userenv.ps1). $null when it isn't
    # set -- empty counts as not set, as it does for doctor.
    param([Parameter(Mandatory)][string]$Name)
    $key = Get-Item -LiteralPath 'HKCU:\Environment' -ErrorAction SilentlyContinue
    if (-not $key -or -not "$($key.GetValue($Name))") { return $null }
    [ordered]@{ Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames'); Kind = "$($key.GetValueKind($Name))" }
}

function Save-ConfigEnvVarsOriginal {
    # install's envvars step, before it points the two here. A variable that wasn't set is copied
    # as that (Existed = false): uninstall then takes it off.
    if (Get-OriginalState -Label 'config-envvars') { return }       # copied once already
    $copy = [ordered]@{}
    foreach ($e in (Get-ConfigEnvVarHomes).GetEnumerator()) {
        $now = Get-UserEnvVarAsStored $e.Key
        if (-not $now) { $copy[$e.Key] = [ordered]@{ Existed = $false }; continue }
        if (Test-SamePathEntry $now.Value $e.Value) { continue }     # already here: not yours
        $copy[$e.Key] = [ordered]@{ Existed = $true; Value = $now.Value; Kind = $now.Kind }
        Step-Info "$($e.Key) was $(ConvertTo-SafePath $now.Value) -- uninstall puts it back"
    }
    if ($copy.Count) { Save-OriginalState -Label 'config-envvars' -Data $copy }
}

# --- Uninstall's part (section 4) ---------------------------------------------------------------
function Undo-ConfigEnvVars {
    # uninstall, section 4; -DryRun only says what it would do. Each config variable still pointing
    # at this clone goes back to install's copy, or comes off: it wasn't set before install, or this
    # install is older than the copy. One that points somewhere else now isn't 710sRice's to touch
    # (a newer winarchy run, a manual edit moved it) and is left alone. DESKTOPRICE_HOME is
    # 710sRice's own: it comes off while it still points here. The copy goes once used, so a later
    # install copies afresh.
    param([switch]$DryRun)
    $copy = Get-OriginalState -Label 'config-envvars'
    $said = 0; $putBack = 0
    foreach ($e in (Get-ConfigEnvVarHomes).GetEnumerator()) {
        $name = $e.Key
        $now = Get-UserEnvVar $name
        if (-not $now) { continue }
        $said++
        if (-not (Test-SamePathEntry $now $e.Value)) {
            if ($DryRun) { Write-Host "  [ ] Leave $name alone: it points somewhere else now" }
            else { Step-Info "$name left alone: it points somewhere else now" }
            continue
        }
        $was = if ($copy) { $copy[$name] } else { $null }
        if ($was -and $was.Existed) {
            $shown = ConvertTo-SafePath $was.Value
            if ($DryRun) { Write-Host "  [ ] Put $name back: $shown"; continue }
            $kind = if ($was.Kind -eq 'ExpandString') { 'ExpandString' } else { 'String' }
            Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name $name -Value $was.Value -Type $kind
            Step-Ok "$name put back: $shown"; $putBack++
            continue
        }
        $why = if ($was) { "it wasn't set before install" } else { 'installed before 710sRice kept a copy of it' }
        if ($DryRun) { Write-Host "  [ ] Take $name off ($why)"; continue }
        Remove-UserEnvVar $name
        Step-Ok "$name taken off ($why)"
    }
    if ([Environment]::GetEnvironmentVariable('DESKTOPRICE_HOME', 'User') -eq $Root) {
        $said++
        if ($DryRun) { Write-Host '  [ ] Take DESKTOPRICE_HOME off' }
        else { Remove-UserEnvVar 'DESKTOPRICE_HOME'; Step-Ok 'DESKTOPRICE_HOME taken off' }
    }
    if (-not $said) { Step-Info 'No config variable points at this clone: nothing to put back' }
    if ($DryRun) { return }
    Remove-OriginalState -Label 'config-envvars'
    if ($putBack) { Send-SettingChangeBroadcast -Area 'Environment' }   # Set-ItemProperty sends none
}

# --- Doctor's checks: the envvars and weather lines in Repo and command ---------------------------
function Get-DoctorUserEnv {
    # A variable as registered for the user (what a new window gets) -- not doctor's own
    # process, which only knows what was set when its window opened.
    param([Parameter(Mandatory)][string]$Name)
    Get-UserEnvVar $Name
}

function Test-DoctorEnvVars {
    # The three config variables install registers, each pointing into this clone. One line
    # when all three are right; otherwise one detail line per wrong one.
    $want = [ordered]@{
        KOMOREBI_CONFIG_HOME = Join-Path $Root 'config\komorebi'
        YASB_CONFIG_HOME     = Join-Path $Root 'config\yasb'
        DESKTOPRICE_HOME     = $Root
    }
    $wrong = foreach ($name in $want.Keys) {
        $v = Get-DoctorUserEnv $name
        if (-not $v) { "$name isn't set" }
        elseif (-not (Test-SamePathEntry $v $want[$name])) { "$name = $(ConvertTo-SafePath $v)" }
    }
    if (-not @($wrong).Count) {
        return New-DoctorResult -Id 'envvars' -Status 'OK' -Text "Config env vars point at this clone ($($want.Keys -join ', '))"
    }
    New-DoctorResult -Id 'envvars' -Status 'XX' -Text "Config env vars don't all point at this clone" `
        -Detail @($wrong) -Fix '710sRice install -Only envvars' -Step 'envvars'
}

function Test-DoctorWeather {
    # The bar's weather is YASB's Open-Meteo widget (Group 1 #1): no key, no account -- you pick the
    # location in the widget, and YASB keeps it in %LOCALAPPDATA%\YASB\weather.json under the
    # widget's name ('weather'), shared by every bar. Whether one is picked is a plain fact (never
    # counted); the city is never printed. The old weather widget's two variables are an [XX]
    # until the envvars step removes them -- how update's repair cleans an existing install.
    $old = @('YASB_WEATHER_API_KEY', 'YASB_WEATHER_LOCATION' | Where-Object { Get-DoctorUserEnv $_ })
    if ($old.Count) {
        New-DoctorResult -Id 'weather-vars' -Status 'XX' -Text "Old weather variables still set ($($old -join ', ')) -- no longer used" `
            -Fix '710sRice install -Only envvars' -Step 'envvars'
    }
    $file = Join-Path $env:LOCALAPPDATA 'YASB\weather.json'
    $picked = $false
    if (Test-Path -LiteralPath $file) {
        $entry = try { ([IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable)['weather'] } catch { $null }
        $picked = $entry -and $null -ne $entry['latitude'] -and $null -ne $entry['longitude']
    }
    if ($picked) { New-DoctorResult -Id 'weather' -Status '..' -Text 'Weather: location picked' }
    else { New-DoctorResult -Id 'weather' -Status '..' -Text 'Weather: no location yet -- click the weather widget in the bar and pick your city' }
}
