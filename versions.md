# 710.DesktopRice — component versions

Tracks what `install.ps1` installs and pins, and what `uninstall.ps1` is (and isn't)
allowed to remove. Hand-maintained today; a `doctor` command that diffs this file against
the machine's real, live state is planned as a natural extension once this file and
`install.ps1`/`uninstall.ps1` have some real mileage on them (see
`claude/winarchy-decoupling-plan.md`).

**Table format is load-bearing**, not just documentation: `uninstall.ps1` parses this exact
table (by column position, between the header separator row and the next blank line) to
decide what it's allowed to remove. If you add or reorder columns, update the parser in
`uninstall.ps1` (`Get-VersionsTable`) to match.

Columns:
- **Component** — human name.
- **Version** — the pin `install.ps1` installs/enforces, or `latest` if unpinned.
- **Source** — `winget`, `psgallery`, or `github-release`.
- **Install ID** — the winget package ID / PSGallery module name / GitHub-or-Codeberg repo
  slug `install.ps1` actually uses. This is the identity `uninstall.ps1` matches against.
- **Pre-existing?** — see the note below. `uninstall.ps1` never removes a `yes` row without
  `-Force`; a `no` row is removed by a plain `.\uninstall.ps1` (no flags) unless you pass
  `-Keep <Install ID>`.
- **Last touched** — date this row was last verified against the real machine (not just
  edited in this file).

## `Pre-existing?` — a judgment call, not a fact, and it needs your review

This column is *not* "was this literally installed before `install.ps1` existed" — on
Dell, that's true of everything below, since `install.ps1` has never actually run yet
(winarchy installed most of this stack originally). The distinction that actually matters
for a safe uninstall is: **is this a general-purpose tool you'd want to keep regardless of
whether 710.DesktopRice is installed, or is it a dedicated piece of this specific
tiling-WM stack that's useless without it?**

Marked `no` (dedicated to this stack, safe for a plain `.\uninstall.ps1` to remove):
komorebi, YASB, AutoHotkey, Flow Launcher, wallust.

Marked `yes` (general-purpose, protected by default — `uninstall.ps1` requires `-Force` to
touch these), **because getting this wrong in the removal direction is the more expensive
mistake**: ShareX, Windows Terminal, the Nerd Font, Starship, fzf, zoxide, eza, bat,
Everything, PSFzf. Several of these are a real guess on my part (flagged `?` below) — I have
no actual evidence one way or the other for whether you'd want to keep them without this
repo; I defaulted to protecting them rather than silently deciding for you. **Please review
the `?` rows and flip them to `no` if you'd actually want a full uninstall to remove them.**

| Component | Version | Source | Install ID | Pre-existing? | Last touched |
|---|---|---|---|---|---|
| komorebi | 0.1.41 | winget | LGUG2Z.komorebi | no | 2026-09-21 |
| YASB | 2.0.7 | winget | AmN.yasb | no | 2026-09-21 |
| AutoHotkey | 2.0.26 | winget | AutoHotkey.AutoHotkey | no | 2026-09-21 |
| Flow Launcher | 2.1.3 | winget | Flow-Launcher.Flow-Launcher | no | 2026-09-21 |
| wallust | 4.1.0-alpha | github-release | explosion-mental/wallust | no | 2026-09-21 |
| ShareX | latest | winget | ShareX.ShareX | yes ? | 2026-09-21 |
| Windows Terminal | latest | winget | Microsoft.WindowsTerminal | yes | 2026-09-21 |
| JetBrainsMono Nerd Font | latest | winget | DEVCOM.JetBrainsMonoNerdFont | yes ? | 2026-09-21 |
| Starship | latest | winget | Starship.Starship | yes ? | 2026-09-21 |
| fzf | latest | winget | junegunn.fzf | yes ? | 2026-09-21 |
| zoxide | latest | winget | ajeetdsouza.zoxide | yes ? | 2026-09-21 |
| eza | latest | winget | eza-community.eza | yes ? | 2026-09-21 |
| bat | latest | winget | sharkdp.bat | yes ? | 2026-09-21 |
| Everything | latest | winget | voidtools.Everything | yes ? | 2026-09-21 |
| PSFzf | latest | psgallery | PSFzf | yes ? | 2026-09-21 |

## Notes on specific rows

**Everything** — filesystem evidence gathered this session (browsing Dell's real
`AppData` tree) suggests this is already installed, which would contradict an earlier
session's note in the plan doc that it "isn't installed yet." Not independently confirmed
against a real `winget list` run (the device bridge that reaches Dell's filesystem can't
invoke Windows executables — see plan doc). `install.ps1`'s own idempotent winget-list
check will tell the real story the first time it actually runs.

**AutoHotkey / Flow Launcher versions** — confirmed via real directory evidence on Dell
(`AppData\Local\Programs\AutoHotkey\v2.0.26`, `AppData\Local\FlowLauncher\app-2.1.3`), not
guessed.

**YASB version** — winarchy's own `versions.lock.toml` pins `2.0.6`; this repo pins `2.0.7`
deliberately, matching a version this project confirmed live via `yasbc update` in an
earlier session. A real, intentional deviation from winarchy's pin, not a typo.

**wallust** — no winget/scoop package exists; installed via `tools/install-wallust.ps1`
from its pinned Codeberg release, SHA256-verified. See that script and the Palette section
of the plan doc.

**Not tracked here**: Windows Terminal, ShareX and Everything ship with no meaningful
"pin" concept in this project's own usage (no config of ours depends on an exact build),
so `install.ps1` never passes `--version` for them regardless of this table's `latest`.
