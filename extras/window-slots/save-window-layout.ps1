#Requires -Version 7.0
<#
.SYNOPSIS
  Captures the current window arrangement into config/windows.toml.

.DESCRIPTION
  Run this after arranging your windows the way you want them. It records where each
  managed window is right now (monitor, workspace, slot) -- games/launchers, explorer,
  Windows Terminal and WezTerm are skipped, since reordering a shell window is more
  annoying than useful. Merge is additive: running this with only half your usual apps
  open won't delete preferences for the ones that weren't running.

  By itself this only RECORDS a placement; nothing enforces it. To have the daemon
  (Start-WindowSlots.ps1, next to this file) actively keep a window in its saved slot,
  open config\windows.toml afterwards and set `pin = true` on that [[windows]] entry.

  NOT WIRED IN (unwired 2026-09-24) -- see README.md in this folder.

  This is a standalone replacement for winarchy's `winarchy layout save` -- this repo has
  no CLI dispatcher, so this script IS the command. winarchy's `layout apply` / `layout
  list` / `layout forget` verbs are not ported; see claude/winarchy-decoupling-plan.md.

.EXAMPLE
  .\extras\window-slots\save-window-layout.ps1                    # capture every managed window
  .\extras\window-slots\save-window-layout.ps1 -WhatIf             # preview without writing
  .\extras\window-slots\save-window-layout.ps1 -Exe firefox.exe    # capture just one app
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # extras\window-slots\.. \.. = repo root

function Step-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Step-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Step-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }

. (Join-Path $PSScriptRoot 'window-slots.ps1')

Save-WindowLayout -Exe $Exe -WhatIf:$WhatIf
