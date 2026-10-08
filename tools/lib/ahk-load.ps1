<#
.SYNOPSIS
  Will 710.ahk load? AutoHotkey's own answer: its /Validate switch loads the script -- 710.ahk with
  its parts, and user.ahk when there is one -- and exits without running any of it. A key user.ahk
  defines again with `::` ("Duplicate hotkey"), or any other mistake there, stops 710.ahk loading
  at all, and with it the bar, Flow Launcher and ShareX, which only 710.ahk starts. Used by
  doctor's 710.ahk line (Test-DoctorStack, tools\lib\stack.ps1) and by scripts\Start-Ahk.ps1,
  which checks before it starts 710.ahk. Loaded by tools\lib\activation.ps1, and by Start-Ahk.ps1
  itself -- Windows PowerShell 5.1: nothing PowerShell 7-only here. Only functions.
#>

function Test-AhkScriptLoads {
    <# AutoHotkey v2's docs (Scripts): /Validate "loads the script and then exits instead of running
       it", exit code 0 when it loaded; /ErrorStdOut sends the reason to stderr instead of an error
       box. It exits before #SingleInstance, so a running 710.ahk is left alone (tested 2026-10-07).
       The plain AutoHotkey64.exe runs the check: the UI Access build only starts through the
       shell, which can't hand back stderr. -> Loaded: $true, $false, or $null when it couldn't
       check (Why). Not loaded: File (as AutoHotkey names it), Line, Message, What (its
       "Specifically:" line); ExitCode. #>
    param([Parameter(Mandatory)][string]$AhkExe, [Parameter(Mandatory)][string]$ScriptPath, [int]$TimeoutSeconds = 10)
    $exe = $AhkExe
    if ((Split-Path -Leaf $exe) -eq 'AutoHotkey64_UIA.exe') {
        $plain = Join-Path (Split-Path -Parent $exe) 'AutoHotkey64.exe'
        if (Test-Path -LiteralPath $plain) { $exe = $plain }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = "/Validate /ErrorStdOut=UTF-8 `"$ScriptPath`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ Loaded = $null; Why = "AutoHotkey wouldn't start: $($_.Exception.Message)" } }
    $err = $p.StandardError.ReadToEndAsync()
    $null = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Loaded = $null; Why = "AutoHotkey took over $TimeoutSeconds s" }
    }
    $p.WaitForExit()   # the no-argument wait also lets the output readers finish
    if ($p.ExitCode -eq 0) { return [pscustomobject]@{ Loaded = $true } }
    # "<file> (<line>) : ==> <message>", then "     Specifically: <what>".
    $out = [pscustomobject]@{ Loaded = $false; File = $null; Line = $null; Message = $null; What = $null; ExitCode = $p.ExitCode }
    foreach ($l in @("$($err.Result)" -split "`r?`n")) {
        if (-not $out.Message -and $l -match '^(?<file>.+?) \((?<line>\d+)\) : ==> (?<msg>.+)$') {
            $out.File = $Matches['file']; $out.Line = [int]$Matches['line']; $out.Message = $Matches['msg'].Trim().TrimEnd('.')
        } elseif ($out.Message -and -not $out.What -and $l -match '^\s+Specifically: (?<what>.+)$') {
            $out.What = $Matches['what'].Trim()
        }
    }
    $out
}

function Format-AhkLoadError {
    <# A Test-AhkScriptLoads failure as one line -- "Duplicate hotkey: #q (user.ahk, line 3)" -- the
       file named from config\ahk (else by its name alone): a full path can carry the Windows user
       name, and this lands in logs and doctor's report. #>
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$RepoRoot)
    if (-not $Result.Message) { return "AutoHotkey's check exited $($Result.ExitCode) -- run config\ahk\710.ahk by hand to see why" }
    $file = "$($Result.File)"
    $ahkDir = (Join-Path $RepoRoot 'config\ahk') + '\'
    $where = if ($file.StartsWith($ahkDir, [StringComparison]::OrdinalIgnoreCase)) { $file.Substring($ahkDir.Length) } else { Split-Path -Leaf $file }
    $what = if ($Result.What) { ": $($Result.What)" } else { '' }
    "$($Result.Message)$what ($where, line $($Result.Line))"
}

function Get-AhkLoadFix {
    <# What to do about it -- yours to do: user.ahk is yours, and 710.ahk's own files are as git
       has them unless you edited them. #>
    param([Parameter(Mandatory)]$Result)
    $inUser = "$($Result.File)" -match '(^|\\)user\.ahk$'
    if ($inUser -and $Result.Message -like 'Duplicate hotkey*') {
        return "a key can be defined once with :: -- take it out of user.ahk; to give one of 710.ahk's keys a job of your own, use Hotkey(""$($Result.What)"", YourFunction) there instead (README: Make it yours)"
    }
    if ($inUser) { return "fix that line of user.ahk (or move user.ahk out of config\ahk: 710.ahk loads without it)" }
    'git diff shows what changed in that file (git checkout puts it back)'
}

function Get-DoctorAhkWontLoad {
    <# Doctor's 710.ahk line when it won't load -- $Text, then why; the fix, then $Then -- or $null
       when it loads (or the check couldn't run: the usual line then). Needs you: repair would only
       start or reload it into the same error. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Then,
          [Parameter(Mandatory)][string]$AhkExe, [Parameter(Mandatory)][string]$ScriptPath)
    $r = Test-AhkScriptLoads -AhkExe $AhkExe -ScriptPath $ScriptPath
    if ($r.Loaded -ne $false) { return $null }
    New-DoctorResult -Id $Id -Status 'XX' -Text "$Text -- $(Format-AhkLoadError $r $Root)" -Fix "$(Get-AhkLoadFix $r); then $Then" -NeedsYou
}
