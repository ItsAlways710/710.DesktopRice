# window-slots (not wired in)

Keeps chosen apps on the monitor, workspace and tile position you gave them. Ported from
winarchy. **Not part of the running stack:** it was unwired on 2026-09-24 because no app
was ever pinned, so the daemon sat idle at every sign-in. The code is kept here as a
possible future feature.

## What's here

| File | What it does |
| --- | --- |
| `window-slots.ps1` | The library: reads/writes `config\windows.toml`, works out where windows are, moves them back. |
| `Start-WindowSlots.ps1` | The daemon: subscribes to komorebi's events over a named pipe (`\\.\pipe\710-window-slots`), puts pinned windows back when they appear, and learns a new slot when you move one yourself. |
| `save-window-layout.ps1` | Captures where your windows are right now into `config\windows.toml` (gitignored, machine-local). |
| `windows.toml.example` | The file format. Add `pin = true` to an entry to have the daemon keep it in place. |

All of it needs PowerShell 7.

## Trying it by hand

1. Arrange your windows, then run `.\extras\window-slots\save-window-layout.ps1`.
2. Edit `config\windows.toml` and add `pin = true` to the apps you want kept in place.
3. Start the daemon from a normal (not admin) PowerShell window:
   `pwsh -NoProfile -File .\extras\window-slots\Start-WindowSlots.ps1`
   Its log is `%LOCALAPPDATA%\710.DesktopRice\window-slots.log`.

## Wiring it back in

It used to be an autostart component. To bring it back:

- `tools\lib\activation.ps1`: add it back to `Get-AutostartComponents` (a hidden
  powershell.exe host that starts pwsh on `Start-WindowSlots.ps1`, 10s delay so komorebi
  starts first), and take `window-slots` out of `Remove-RetiredAutostart`'s list.
  `Stop-RetiredWindowSlots` already stops it on uninstall.
- `scripts\Start-All.ps1`: add a check for it (the pipe above exists while it's running).
- `tools\reload-stack.ps1`: optionally restart it if it's down.
- `config\ahk\710.ahk`: `QuitStack()` should stop it too, to match `Stop-All.ps1`.

The git history before the unwiring commit has the exact code for each of these.
