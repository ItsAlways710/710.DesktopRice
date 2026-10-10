# Make it yours

These files are yours alone. Git ignores them, so neither `710sRice update` nor `git pull` touches them:

- `config/ahk/user.ahk` — your own hotkeys. It's loaded after `710.ahk` if it exists, and
  SUPER+K lists its hotkeys too. Reload with SUPER+Shift+R. A key `710.ahk` already has can't
  be defined again with `::` — AutoHotkey then won't load `710.ahk` at all (and so no bar,
  Flow Launcher or ShareX either); `710sRice doctor` names the key and the line. To give one
  of 710's keys a job of your own, use `Hotkey()` in `user.ahk` instead:
  `Hotkey("#q", (*) => MsgBox("my SUPER+Q"))` replaces what SUPER+Q does.
- `config/pwsh/user.ps1` — your own PowerShell profile additions, loaded last by
  `config/pwsh/profile.ps1`. Open a new terminal to pick up changes.
- `config/komorebi/rules.local.toml` — your own app rules, games and pins. Quick add rule
  writes it for you; see [App rules](tiling.md#app-rules).
- `config/palettes/profile0.json` … `profile9.json` — your palette profiles (the editor
  writes them; see [Palette profiles](theming.md#palette-profiles)), and any scheme files you put in
  `config/palettes/schemes`.

## Forking it, or changing what it installs

- **What it installs, and at which version:** [versions.md](../versions.md) is the one list.
  install, uninstall and doctor all read it, and its header says what each column means,
  including what uninstall may remove. A pin means "tested and accepted": moving one is a
  one-line change to its row, then `710sRice update` on each machine (or
  `710sRice install -Only upgrade` on this one). Pins only move up; a copy newer than its pin is
  left alone.
- **Your fork's updates:** `710sRice update` pulls `master` from the clone's own `origin`, and
  doctor's version line asks the same place, so a clone of your fork follows your fork. The
  one-liner is the exception: `boot.ps1` clones this repo, so a fork's one-liner needs its own
  `boot.ps1` and its own raw URL.
- **Rules every machine gets:** shipped rules go in `config/komorebi/rules.toml` and shipped
  games in `games.toml`, both tracked; your file wins over them on your machine
  ([App rules](tiling.md#app-rules)).
- **Theming another app:** one small file; `tools/palette/targets/README.md` explains how.
- **A new install step:** a file in `tools/components/` becomes one, with its uninstall and
  doctor parts ([its README](../tools/components/README.md)).
- **What lives where:** [Map: what lives where](map.md) says which file owns each piece, and
  the rules for changing the code.

---

[← The manual](README.md) · Next: [Troubleshooting](troubleshooting.md)
