<#
.SYNOPSIS
  install's envvars step: KOMOREBI_CONFIG_HOME, YASB_CONFIG_HOME and DESKTOPRICE_HOME (User scope)
  pointing at this clone, and the old weather widget's two variables gone; what uninstall puts
  back (section 4: the three, where they still point here -- the old weather ones go there too);
  doctor's envvars and weather lines. Loaded by tools\lib\activation.ps1. Only functions.
#>

# --- install's step -------------------------------------------------------------------------------
function Install-EnvVarsStep {
    # --- 2. Config env vars: repo is the source of truth --------------------------------
    Write-Host "`n-- Config environment variables --" -ForegroundColor Cyan
    $komorebiConfigHome = Join-Path $Root 'config\komorebi'
    $yasbConfigHome     = Join-Path $Root 'config\yasb'
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

# --- Uninstall's part (section 4) ---------------------------------------------------------------
function Undo-ConfigEnvVars {
    # uninstall, section 4: KOMOREBI_CONFIG_HOME, YASB_CONFIG_HOME and DESKTOPRICE_HOME taken off,
    # each only while it still points at this clone.
    $komorebiConfigHome = Join-Path $Root 'config\komorebi'
    $yasbConfigHome     = Join-Path $Root 'config\yasb'
    # Only clear a var if it's still pointing at THIS repo -- if something else (a
    # newer winarchy run, a manual edit) already moved it elsewhere, that's not this
    # script's to touch. Matches the "last write wins, don't clobber a later write"
    # posture install.ps1's own NOTES already accept for these shared vars.
    if ([Environment]::GetEnvironmentVariable('KOMOREBI_CONFIG_HOME', 'User') -eq $komorebiConfigHome) {
        [Environment]::SetEnvironmentVariable('KOMOREBI_CONFIG_HOME', $null, 'User')
    }
    if ([Environment]::GetEnvironmentVariable('YASB_CONFIG_HOME', 'User') -eq $yasbConfigHome) {
        [Environment]::SetEnvironmentVariable('YASB_CONFIG_HOME', $null, 'User')
    }
    if ([Environment]::GetEnvironmentVariable('DESKTOPRICE_HOME', 'User') -eq $Root) {
        [Environment]::SetEnvironmentVariable('DESKTOPRICE_HOME', $null, 'User')
    }
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
