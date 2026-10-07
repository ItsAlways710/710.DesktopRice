<#
.SYNOPSIS
  Is this window an admin one, and is a process (komorebi, 710.ahk) running elevated. Loaded by
  tools\lib\activation.ps1. Only functions.
#>

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-ProcessTokenNative {
    if (-not ('Win710.ProcessToken' -as [type])) {
        Add-Type -Namespace Win710 -Name ProcessToken -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out IntPtr token);
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool GetTokenInformation(IntPtr token, int infoClass, out int info, int length, out int returnLength);
[DllImport("kernel32.dll")]
public static extern bool CloseHandle(IntPtr handle);
'@
    }
}

function Get-ProcessElevation {
    <# 'elevated', 'normal', 'not running' or 'unknown', for the first process called -Name
       (`710sRice tiling status` asks about komorebi) or the process -Id (doctor asks about
       710.ahk's). Reads the process token's
       TokenElevation. From a NORMAL window Windows won't hand over an elevated process's
       token at all -- while a same-user normal process's token always opens -- so that
       refusal is itself the answer. From an admin window the token opens either way. #>
    [CmdletBinding(DefaultParameterSetName = 'Name')]
    param([Parameter(Mandatory, ParameterSetName = 'Name', Position = 0)][string]$Name,
          [Parameter(Mandatory, ParameterSetName = 'Id')][int]$Id)
    $p = if ($PSCmdlet.ParameterSetName -eq 'Id') { Get-Process -Id $Id -ErrorAction SilentlyContinue }
         else { Get-Process -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $p) { return 'not running' }
    try { Initialize-ProcessTokenNative } catch { return 'unknown' }
    # PROCESS_QUERY_LIMITED_INFORMATION (0x1000): allowed across elevation levels.
    $h = [Win710.ProcessToken]::OpenProcess(0x1000, $false, $p.Id)
    if ($h -eq [IntPtr]::Zero) { return 'unknown' }
    try {
        $token = [IntPtr]::Zero
        if (-not [Win710.ProcessToken]::OpenProcessToken($h, 0x0008, [ref]$token)) {   # TOKEN_QUERY
            if (Test-IsAdmin) { return 'unknown' }
            return 'elevated'
        }
        try {
            $elevated = 0; $len = 0
            # 20 = TokenElevation: one DWORD, non-zero when the token is elevated.
            if (-not [Win710.ProcessToken]::GetTokenInformation($token, 20, [ref]$elevated, 4, [ref]$len)) { return 'unknown' }
            if ($elevated -ne 0) { 'elevated' } else { 'normal' }
        } finally { [void][Win710.ProcessToken]::CloseHandle($token) }
    } finally { [void][Win710.ProcessToken]::CloseHandle($h) }
}
