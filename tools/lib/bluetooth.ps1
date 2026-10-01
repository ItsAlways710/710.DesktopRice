<#
  tools\lib\bluetooth.ps1 -- "does this machine have a Bluetooth adapter?", for the bar (winarchy
  port audit, 2026-10-01). config\yasb\config.yaml's network group lists the widget
  "bluetooth$env:DESKTOPRICE_NO_BLUETOOTH": unset or empty = 'bluetooth', YASB's own icon (shown
  "off" while the radio is off); '_none' = 'bluetooth_none', an empty widget, on a machine with no
  adapter. YASB 2.0.7's widget can't tell those two apart itself (both are its bt-off state), and
  a name in a widget list that isn't defined pops an error dialog -- hence a value that is always
  one of the two.

  Dot-sourced by scripts\Start-Yasb.ps1 (every bar start sets the value from this, so the bar
  always matches the hardware) and tools\components\bluetooth.ps1 (the user variable, for a YASB
  started some other way; doctor; uninstall). Windows PowerShell 5.1 safe: Start-Yasb.ps1 can run
  under it.
#>

function Get-BluetoothServiceDeviceCount {
    <# How many devices a driver service is running for right now: its Enum key's Count. Windows
       rebuilds a service's Enum key at every start and lists only present devices -- an adapter
       taken out, or disabled in Device Manager, drops out of it. 0 when the key isn't there;
       throws when the registry can't be read. Under 1 ms through .NET (the Dell's probe:
       Test-Path alone took 70-90 ms for a missing key; Get-PnpDevice over a second). #>
    param([Parameter(Mandatory)][string]$Service)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$Service\Enum")
    if (-not $key) { return 0 }
    try { [int]$key.GetValue('Count', 0) } finally { $key.Dispose() }
}

function Test-BluetoothAdapter {
    <# $true when a Bluetooth radio is here, switched on or off. The radio's own drivers stay
       loaded while it's switched off: BTHUSB (a USB radio, most laptops), ibtusb (Intel's driver),
       BTHMINI (UART / SDIO radios). The Microsoft Bluetooth Enumerators (BthEnum, BthLEEnum) run
       only while it's on, so they're a second yes, never the only test. The Dell, 2026-10-01
       (state\g2-probe2*.json): BTHUSB 1 and ibtusb 1 with the radio on and off; BthEnum 2 and
       BthLEEnum 1 on, 0 and 0 off. A read that fails counts as "here": an icon that shows "off"
       is better than one that's missing. #>
    $unsure = $false
    foreach ($service in 'BTHUSB', 'ibtusb', 'BTHMINI', 'BthEnum', 'BthLEEnum') {
        try { if ((Get-BluetoothServiceDeviceCount $service) -gt 0) { return $true } }
        catch { $unsure = $true }
    }
    $unsure
}

function Get-BluetoothBarValue {
    # DESKTOPRICE_NO_BLUETOOTH for this machine: '' with an adapter, '_none' without.
    if (Test-BluetoothAdapter) { '' } else { '_none' }
}
