# Bluetooth in the bar (winarchy port audit, 2026-10-01; the user's call: "hidden only on a machine
# with no adapter -- with one it's always there, and shows off when it's off").
#
# config\yasb\config.yaml's network group lists "bluetooth$env:DESKTOPRICE_NO_BLUETOOTH": nothing in
# the variable = 'bluetooth', YASB's icon; '_none' = 'bluetooth_none', an empty widget. Every bar
# start through 710sRice sets the value from the hardware itself (scripts\Start-Yasb.ps1, with
# tools\lib\bluetooth.ps1); this step registers the same value for you, so a YASB started any other
# way (its Start-menu shortcut) gets it too:
#   - an adapter: no variable at all (the default IS the icon) -- a machine with Bluetooth gets
#     nothing written, and a stale '_none' from an adapter added since is removed;
#   - no adapter: DESKTOPRICE_NO_BLUETOOTH = _none (User scope).
# Uninstall removes the variable. Nothing to snapshot: the name is 710sRice's own.
# Doctor: the variable against the hardware -- [XX] (fix: this step) when it doesn't match.
@{
    Id    = 'bluetooth'
    Label = 'Bluetooth in the bar'
    After = 'envvars'
    Group = 'Integrations'

    Functions = {
        . (Join-Path (Get-RiceComponentsRoot) 'tools\lib\bluetooth.ps1')
        function Get-BluetoothVarName { 'DESKTOPRICE_NO_BLUETOOTH' }
    }

    Install = {
        param($Ctx)
        $name = Get-BluetoothVarName
        $now = "$(Get-UserEnvVar $name)"
        if (Test-BluetoothAdapter) {
            if ($now) {
                Remove-UserEnvVar $name
                Step-Ok "Bluetooth: this machine has an adapter now -- the bar shows its icon again ($name removed; at the bar's next start)"
            } else {
                Step-Ok "Bluetooth: this machine has an adapter -- the bar shows its icon (dimmed while it's off)"
            }
        } elseif ($now -ceq '_none') {
            Step-Ok 'Bluetooth: no adapter on this machine -- the bar already leaves its icon out'
        } else {
            Set-UserEnvVar $name '_none'
            Step-Ok "Bluetooth: no adapter on this machine -- the bar leaves its icon out ($name = _none)"
        }
    }

    Uninstall = {
        param($Ctx)
        $name = Get-BluetoothVarName
        if (Get-UserEnvVar $name) {
            Remove-UserEnvVar $name
            Step-Ok "$name removed (the bar's Bluetooth setting)"
        } else {
            Step-Info "install never set $name on this machine (it has Bluetooth) -- nothing to remove."
        }
    }

    Check = {
        param($Ctx)
        $name = Get-BluetoothVarName
        $now = "$(Get-UserEnvVar $name)"
        $fix = @{ Fix = '710sRice install -Only bluetooth'; Step = 'bluetooth' }
        $adapter = Test-BluetoothAdapter
        if ($now -and $now -cne '_none') {
            return New-DoctorResult -Id 'bluetooth' -Status 'XX' -Text "$name is '$now' -- a YASB started outside 710sRice would stop with an error (only empty or _none mean anything)" @fix
        }
        if ($adapter) {
            if ($now) { return New-DoctorResult -Id 'bluetooth' -Status 'XX' -Text "Bluetooth: this machine has an adapter now, but $name still says it hasn't" @fix }
            return New-DoctorResult -Id 'bluetooth' -Status 'OK' -Text 'Bluetooth in the bar (this machine has an adapter; dimmed while it''s off)'
        }
        if (-not $now) { return New-DoctorResult -Id 'bluetooth' -Status 'XX' -Text "Bluetooth: no adapter on this machine, and $name isn't set -- a YASB started outside 710sRice would show an icon for it" @fix }
        New-DoctorResult -Id 'bluetooth' -Status 'OK' -Text 'Bluetooth left out of the bar (no adapter on this machine)'
    }
}
