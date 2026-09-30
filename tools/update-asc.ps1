#Requires -Version 7.0
<#
.SYNOPSIS
  Maintainer tool: re-pin vendor\asc\applications.json (the community komorebi app rules)
  to upstream's newest commit. Dry run by default; -Apply writes it.

.DESCRIPTION
  vendor\asc\applications.json is a pinned copy of applications.json from
  LGUG2Z/komorebi-application-specific-configuration, recorded in vendor\asc\pin.toml (repo,
  commit, date, sha256). Re-pinning is deliberate, never automatic: this shows what a re-pin
  would bring in, and writes it only when asked.

  Dry run (the default):
    - asks GitHub for the newest upstream commit that touched applications.json. The same
      commit as the pin -> "already at the newest", and that's all;
    - otherwise lists upstream's commits to the file since the pin (hash, date, subject --
      the why), then the per-app diff against the pinned copy: + added, ~ changed,
      - removed. An app you've turned off with [[disable]] asc = "..." in rules.toml or
      rules.local.toml is flagged, so you know that change won't reach you anyway.
  -Apply: writes applications.json as it is AT that commit (not whatever master serves by
  the time the download happens), then pin.toml's commit, date and sha256. The sha256 is
  taken the way doctor's ASC check takes it (CRLF -> LF, Get-DoctorLfSha256), so doctor
  agrees straight away.

  Never commits and never reloads: try the new rules with SUPER+Shift+R (it compiles them
  into komorebi.json), then commit the two files if they behave. Not a 710sRice command and
  not in the README -- this is repo maintenance (plan doc item 44, 2026-09-26). Modelled on
  winarchy's `winarchy rules sync [--apply]` (Sync-WinarchyAsc, read 2026-09-30); ours pins
  the exact upstream commit (winarchy's re-pin leaves its old commit id behind) and shows
  upstream's commit messages.

  GitHub's API without a token (60 requests an hour; a run uses up to three). Output names
  repo-relative paths only.

  Exit codes: 0 = already at the newest, or -Apply wrote it; 3 = a newer commit exists (dry
  run, nothing written); 1 = something failed (GitHub unreachable, bad JSON, ...), nothing
  written.
#>
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$Root       = Split-Path -Parent $PSScriptRoot
$AscPath    = Join-Path $Root 'vendor\asc\applications.json'
$PinPath    = Join-Path $Root 'vendor\asc\pin.toml'
$FileInRepo = 'applications.json'
$Headers    = @{ 'User-Agent' = '710.DesktopRice-update-asc'; 'Accept' = 'application/vnd.github+json' }

function Get-LfSha256 {
    # doctor's Get-DoctorLfSha256, from bytes: CRLF -> LF, then sha256 of the UTF-8.
    param([byte[]]$Bytes)
    $text = [Text.Encoding]::UTF8.GetString($Bytes) -replace "`r`n", "`n"
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
}

function Get-PinValue {
    param([string]$Text, [string]$Key)
    if ($Text -match "(?m)^$Key\s*=\s*`"([^`"]*)`"") { $Matches[1] }
}

function Get-UtcDay {
    # A commit date from the API as yyyy-MM-dd, UTC. ConvertFrom-Json may already have made
    # it a [datetime]; otherwise it's the ISO string.
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-dd') }
    ([datetimeoffset]"$Value").UtcDateTime.ToString('yyyy-MM-dd')
}

function Get-DisabledAscApps {
    # [[disable]] asc = "..." in rules.toml / rules.local.toml, lower-cased -- the grammar
    # compile-komorebi-rules.ps1 reads: key = "value" lines under a [[section]] header.
    foreach ($name in 'rules.toml', 'rules.local.toml') {
        $path = Join-Path $Root "config\komorebi\$name"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $section = $null
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            $l = $line.Trim()
            if ($l -match '^\[\[(\w+)\]\]$') { $section = $Matches[1]; continue }
            if ($section -eq 'disable' -and $l -match '^asc\s*=\s*"([^"]*)"') { $Matches[1].ToLowerInvariant() }
        }
    }
}

$tmp = $null
try {
    $pinText = [IO.File]::ReadAllText($PinPath)
    $repo    = Get-PinValue $pinText 'repo'
    $pinned  = Get-PinValue $pinText 'commit'
    if (-not $repo -or -not $pinned) { throw 'vendor\asc\pin.toml has no repo or commit' }

    Write-Host "Checking $repo on GitHub..."
    # Invoke-RestMethod hands a JSON array back as ONE object; the pipe unrolls it into commits.
    $history = @(Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/repos/$repo/commits?path=$FileInRepo&per_page=100" |
        ForEach-Object { $_ })
    if (-not $history.Count) { throw "GitHub listed no commits to $FileInRepo" }
    $newest  = $history[0]
    $newSha  = $newest.sha
    $newDate = Get-UtcDay $newest.commit.committer.date

    if ($newSha -eq $pinned) {
        Write-Host "[OK] Already at the newest: $($pinned.Substring(0, 7)) ($(Get-PinValue $pinText 'date')) -- nothing to do." -ForegroundColor Green
        exit 0
    }

    # Upstream's commits to the file since the pin, newest first (the list stops at the pin).
    $since = [System.Collections.Generic.List[object]]::new()
    $foundPin = $false
    foreach ($c in $history) {
        if ($c.sha -eq $pinned) { $foundPin = $true; break }
        $since.Add($c)
    }

    # The file AT that commit -- not master, which could move between the two requests.
    $tmp = [IO.Path]::GetTempFileName()
    Invoke-WebRequest -Headers @{ 'User-Agent' = $Headers['User-Agent'] } -OutFile $tmp `
        -Uri "https://raw.githubusercontent.com/$repo/$newSha/$FileInRepo" | Out-Null
    $bytes = [IO.File]::ReadAllBytes($tmp)
    try { $incoming = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable }
    catch { throw "upstream's $FileInRepo at $($newSha.Substring(0, 7)) isn't valid JSON: $($_.Exception.Message)" }
    try { $current = [IO.File]::ReadAllText($AscPath) | ConvertFrom-Json -AsHashtable }
    catch { throw "vendor\asc\applications.json isn't valid JSON: $($_.Exception.Message)" }

    $disabled = @(Get-DisabledAscApps)
    $names = @(@($current.Keys) + @($incoming.Keys) | Where-Object { -not $_.StartsWith('$') } | Sort-Object -Unique)
    $added = @(); $changed = @(); $removed = @()
    foreach ($n in $names) {
        $a = if ($current.Contains($n))  { $current[$n]  | ConvertTo-Json -Depth 20 -Compress } else { $null }
        $b = if ($incoming.Contains($n)) { $incoming[$n] | ConvertTo-Json -Depth 20 -Compress } else { $null }
        if ($a -eq $b) { continue }
        if ($null -eq $a) { $added += $n } elseif ($null -eq $b) { $removed += $n } else { $changed += $n }
    }

    Write-Host ''
    Write-Host "Newer upstream: $($pinned.Substring(0, 7)) -> $($newSha.Substring(0, 7)) ($newDate)" -ForegroundColor Yellow
    Write-Host "  Upstream's commits to $FileInRepo since the pin, newest first:"
    foreach ($c in $since) {
        $subject = ("$($c.commit.message)" -split "`n")[0].Trim()
        Write-Host ('    {0} {1} {2}' -f $c.sha.Substring(0, 7), (Get-UtcDay $c.commit.committer.date), $subject)
    }
    if (-not $foundPin) { Write-Host "    ... more than GitHub's last 100 -- the pin $($pinned.Substring(0, 7)) wasn't among them." }
    Write-Host ''
    Write-Host "  Apps: +$($added.Count) added, ~$($changed.Count) changed, -$($removed.Count) removed"
    foreach ($set in @(@{ Mark = '+'; Items = $added }, @{ Mark = '~'; Items = $changed }, @{ Mark = '-'; Items = $removed })) {
        foreach ($n in $set.Items) {
            $flag = if ($n.ToLowerInvariant() -in $disabled) { '   (you disabled this app in your rules)' } else { '' }
            Write-Host "    $($set.Mark) $n$flag"
        }
    }
    Write-Host ''

    if (-not $Apply) {
        Write-Host '[..] Dry run -- nothing written. Run it again with -Apply to vendor this commit.'
        exit 3
    }

    $sha256 = Get-LfSha256 $bytes
    $newPin = $pinText -replace '(?m)^(commit\s*=\s*")[0-9a-f]*(")', "`${1}$newSha`${2}" `
                       -replace '(?m)^(date\s*=\s*")[^"]*(")', "`${1}$newDate`${2}" `
                       -replace '(?m)^(sha256\s*=\s*")[0-9a-f]*(")', "`${1}$sha256`${2}"
    [IO.File]::WriteAllBytes($AscPath, $bytes)
    [IO.File]::WriteAllText($PinPath, $newPin, [Text.UTF8Encoding]::new($false))
    Write-Host "[OK] Vendored $($newSha.Substring(0, 7)) ($newDate): vendor\asc\applications.json and vendor\asc\pin.toml." -ForegroundColor Green
    Write-Host '     Next: SUPER+Shift+R compiles the new rules -- try them, then commit both files.'
    exit 0
}
catch {
    Write-Host "[XX] $($_.Exception.Message) -- nothing written." -ForegroundColor Red
    exit 1
}
finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
