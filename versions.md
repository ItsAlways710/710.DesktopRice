# 710.DesktopRice — component versions

The one list of what this repo installs and at which version, and what `uninstall.ps1` is
(and isn't) allowed to remove. `install.ps1` (its `packages` and `wallust` steps),
`tools/install-wallust.ps1` and `uninstall.ps1` all read this table — nothing keeps a second
copy — and `710sRice doctor` compares it with the machine. A pin bump is a one-line
change here, and a pin still means "tested on the Dell and accepted".

**Table format is load-bearing**, not just documentation: `tools/lib/packages.ps1`
(`Get-VersionsTable`) parses this exact table (by column position, between the header
separator row and the next blank line) — for what install installs and pins, and what
uninstall is allowed to remove. If you add or reorder columns, update that parser to match.

Columns:
- **Component** — human name.
- **Version** — the pin: `install.ps1` installs exactly that version and (for winget rows)
  winget-pins it, and an installed copy that's older than its pin is moved up to it by a plain
  install too (never down: a newer one is left alone, and doctor says so). `latest` = installed
  unpinned, and it takes its own updates. A row that doesn't install fails the run: install
  finishes every step, lists what's missing and exits 1 — the same rows doctor calls `[XX]`.
- **Source** — `winget`, `msstore` (winget, from the Microsoft Store source), `psgallery`, or
  `github-release`. Every winget call names its source (`--source winget` / `--source
  msstore`), so a broken Microsoft Store source can't fail the `winget` rows.
- **Install ID** — the winget package ID / PSGallery module name / GitHub-or-Codeberg repo
  slug `install.ps1` actually uses. This is the identity `uninstall.ps1` matches against.
- **Pre-existing?** — exactly one of three values (see the note below):
  - `no` — removed by a plain `710sRice uninstall`, unless you pass `-Keep <Install ID>`;
  - `yes` — kept by a plain uninstall, removed by `710sRice uninstall -Force`;
  - `system` — installed if missing, **never removed by uninstall, `-Force` included**
    (PowerShell 7, which uninstall itself runs on and a fresh install needs first, and Windows
    Terminal, part of Windows 11). Remove one by hand if you want it gone (Settings > Apps).

  Any other value stops install, doctor and uninstall with an error naming the row — a typo
  can never be read as "remove it".
- **Last touched** — date this row was last verified against the real machine (not just
  edited in this file).

## `Pre-existing?` — a judgment call, reviewed and confirmed by the user 2026-09-22

This column is *not* "was this literally installed before `install.ps1` existed" — on
Dell, that's true of everything below, since `install.ps1` has never actually run yet
(winarchy installed most of this stack originally). The distinction that actually matters
for a safe uninstall is: **is this a general-purpose tool you'd want to keep regardless of
whether 710.DesktopRice is installed, or is it a dedicated piece of this specific
tiling-WM stack that's useless without it?**

Marked `no` (dedicated to this stack, safe for a plain `.\uninstall.ps1` to remove):
komorebi, YASB, AutoHotkey, Flow Launcher, wallust, ShareX, DisplayConfig.

Marked `yes` (general-purpose, protected by default — `uninstall.ps1` requires `-Force` to
touch these): the Nerd Font, Starship, fzf, zoxide, eza, bat, Everything, PSFzf.

Marked `system` (never removed, `-Force` included — user, 2026-09-30, Group 1 W9: "Keep both,
always, ps7 will have to be a manual remove, and that's fine"): PowerShell 7 and Windows
Terminal. Until then both were `yes` rows, so `-Force` removed them too — PowerShell 7 included,
the shell the uninstall itself runs on.

The history of the review, as it stood before `system` existed: Windows Terminal and PowerShell 7
were `yes` rows too. **Reviewed and confirmed by the user 2026-09-22** — originally flagged
`?` as Claude's own conservative guess with no real evidence either way (defaulted to
protecting rather than silently deciding); the user reviewed the full list, confirmed these
stay protected, and moved ShareX from protected to removable-by-default. PowerShell 7 was
added the same session, at the user's explicit request, as a new pinned `-Force`-protected
row (not part of the original review — decided directly, not guessed). **Unpinned
2026-09-23** at the user's request ("I want to be able to update my PS7"): still required
(every script `#Requires -Version 7.0`), still `-Force`-protected, but `latest` — see the
PowerShell 7 note below.

| Component | Version | Source | Install ID | Pre-existing? | Last touched |
|---|---|---|---|---|---|
| komorebi | 0.1.41 | winget | LGUG2Z.komorebi | no | 2026-09-21 |
| YASB | 2.0.7 | winget | AmN.yasb | no | 2026-09-21 |
| AutoHotkey | 2.0.28 | winget | AutoHotkey.AutoHotkey | no | 2026-09-23 |
| Flow Launcher | 2.1.3 | winget | Flow-Launcher.Flow-Launcher | no | 2026-09-21 |
| wallust | 4.1.0-alpha | github-release | explosion-mental/wallust | no | 2026-09-21 |
| ShareX | latest | winget | ShareX.ShareX | no | 2026-09-21 |
| Windows Terminal | latest | winget | Microsoft.WindowsTerminal | system | 2026-09-21 |
| PowerShell 7 | latest | msstore | 9MZ1SNWT0N5D | system | 2026-09-23 |
| JetBrainsMono Nerd Font | latest | winget | DEVCOM.JetBrainsMonoNerdFont | yes | 2026-09-21 |
| Starship | latest | winget | Starship.Starship | yes | 2026-09-21 |
| fzf | latest | winget | junegunn.fzf | yes | 2026-09-21 |
| zoxide | latest | winget | ajeetdsouza.zoxide | yes | 2026-09-21 |
| eza | latest | winget | eza-community.eza | yes | 2026-09-21 |
| bat | latest | winget | sharkdp.bat | yes | 2026-09-21 |
| Everything | 1.4.1.1032 | winget | voidtools.Everything | yes | 2026-09-23 |
| PSFzf | latest | psgallery | PSFzf | yes | 2026-09-21 |
| DisplayConfig | latest | psgallery | DisplayConfig | no | 2026-10-05 |

## Notes on specific rows

**DisplayConfig** -- added 2026-10-05 for the Screens menu (the bar's monitor button and
SUPER+Alt+Space > Screens): it reads every connected screen, on or off, through Windows' own
display APIs (MartinGC94/DisplayConfig, MIT). `no`: nothing outside this stack uses it. Unpinned,
like every psgallery row (the packages step installs them with `Install-Module`, always latest).

**Everything** — **pinned 2026-09-23 at `1.4.1.1032`** (confirmed installed on Dell via a
real `winget list`, and the same version winarchy pins): it's the engine behind Flow's file
search now (SUPER+S), so it's pinned alongside Flow — updating either is a deliberate,
tested step. Still `Pre-existing? = yes` (a general-purpose tool you'd keep; uninstall
removes the pin, not the app, without `-Force`). Older note, kept for history: filesystem
evidence gathered this session (browsing Dell's real
`AppData` tree) suggests this is already installed, which would contradict an earlier
session's note in the plan doc that it "isn't installed yet." Not independently confirmed
against a real `winget list` run (the device bridge that reaches Dell's filesystem can't
invoke Windows executables — see plan doc). `install.ps1`'s own idempotent winget-list
check will tell the real story the first time it actually runs.

**AutoHotkey / Flow Launcher versions** — Flow confirmed via real directory evidence on Dell
(`AppData\Local\FlowLauncher\app-2.1.3`), not guessed. AutoHotkey is installed machine-wide
(`C:\Program Files\AutoHotkey`); autostart launches the version-independent
`v2\AutoHotkey64_UIA.exe` (`Get-AhkExe`), so a version bump doesn't touch the launch path.
That's the UI Access build (hotkeys work over admin windows, plan doc Open item 36); the
installer only creates and signs it in a Program Files install, so a per-user install falls
back to plain `AutoHotkey64.exe`. (An
earlier version of this note placed it under a per-user `...\Programs\AutoHotkey\v2.0.26`
folder, which doesn't exist on Dell.) Bumped 2.0.26 → 2.0.28 on 2026-09-23 after checking both
releases' notes (GitHub releases): 2.0.27 = six bug fixes (debugger `=>` breakpoints,
`Send "{Click X Y Count}"`, a `ComObjQuery` interface leak, getter/setter ordering, ListView
header `ContextMenu`, self-subclassing classes); 2.0.28 = `Gui.Move` no longer DPI-scales X/Y.
None of those APIs are used in `config\ahk` (grepped). Winarchy moved to 2.0.28 in `90fbdfe`.

**YASB version** — winarchy's own `versions.lock.toml` pins `2.0.6`; this repo pins `2.0.7`
deliberately, matching a version this project confirmed live via `yasbc update` in an
earlier session. A real, intentional deviation from winarchy's pin, not a typo.

**wallust** — no winget/scoop package exists; installed via `tools/install-wallust.ps1`
from its pinned Codeberg release, SHA256-verified. See that script and the Palette section
of the plan doc.

**PowerShell 7** — **unpinned since 2026-09-23** (was pinned at `7.6.6`; winget's catalog
reported it as `7.6.6.0`). No scheduled task names a pwsh path — they all start Windows
PowerShell (`powershell.exe`), whose path never moves, and whatever needs PS7 looks it up
when it runs — so Store updates can't strand them (the lock-screen task was the last one
that did, through the WindowsApps alias, until 2026-09-27); the one versioned path left is the
Defender exclusion, which matches the real image path — re-run `install.ps1` elevated after
a PowerShell update to refresh it. Original notes follow. Dell's existing install is the
Microsoft Store/MSIX build
(`AppData\Local\Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe`), not
the traditional MSI package, confirmed via Windows Terminal's dynamic-profile `commandline`
field (that path itself can't be browsed directly — `AppData\...\WindowsApps` is a
protected/inaccessible location, even via the device bridge running as the machine's own
user). `9MZ1SNWT0N5D` is the Microsoft Store product ID (confirmed via the Store listing at
`apps.microsoft.com/detail/9mz1snwt0n5d`), not `Microsoft.PowerShell` (that's the separate
traditional MSI package — pinning that one instead would risk installing a redundant second
copy alongside the Store build already here). Its Source is `msstore`, so `install.ps1` and
`uninstall.ps1` pass `--source msstore` for it (winget's default community source doesn't
carry it; before 2026-09-26 both scripts kept their own `$PackageSources` copy of this). Version `7.6.6` is what
the user reported live (`$PSVersionTable.PSVersion` on Dell, 2026-09-22) — not independently
verified against a real `winget list --source msstore` run (the device bridge can't invoke
winget), so if the exact-version pin match ever misbehaves the first time `install.ps1`
actually runs, check whether winget's own catalog reports a 4-part MSIX-style version (e.g.
`7.6.6.0`) instead of this 3-part one.

**Unpinned rows (`latest`)**: `install.ps1` never passes `--version` for them and never
pins them — no config of ours depends on an exact build, so they take their own updates
(a normal `winget upgrade --all` moves them). Everything used to be in this group; it's
pinned since 2026-09-23 (see its note).
