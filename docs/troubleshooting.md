# Troubleshooting

## Tips and known issues

- **Extra title bar on an app after the bar restarts.** When the bar restarts it gives its
  screen strip back and takes it again, and Windows tells every window. Chromium-based apps
  (Chrome and the Claude desktop app so far; Edge never has) can come back drawing a row
  low: an extra title bar on top, the bottom pushed off screen, clicks landing a row off.
  Focus that app and press **SUPER+Ctrl+C**: its drawing helper restarts and the app redraws
  in place without closing (relaunching it works too). Chromium switches an app to slower
  software drawing after three of these close together (it forgives one every 5 minutes),
  so keep it a now-and-then key. SUPER+Shift+R only restarts the bar when it has to (its
  `config.yaml` changed, or komorebi restarted), so this is rare; `710sRice reload bar` and
  `710sRice restart` always do.
- **Widgets button still on the taskbar?** Windows won't let a script hide it. Turn it off
  in Settings > Personalization > Taskbar.
- **Changed a wallpaper variable?** Restart the bar: `710sRice reload bar`.
- **Mod Organizer 2 can't start its tools (Error 5) when it was opened from the bar, Flow or
  a ShareX action?** Those three have to be started by AutoHotkey (710.ahk), which is how the
  rice starts them: whatever a Scheduled Task starts runs inside a job that won't let a program
  opened from it start programs of its own. An install from before October 2026 started them
  through tasks of their own; `710sRice doctor` says when one of those is still there, and
  `710sRice doctor -repair` removes it and has AutoHotkey restart any of the three that's running.
- **Terminal says JetBrainsMono NF is missing right after an install?** Terminal reads the
  font list when it starts: close every Terminal window and open one again.
- **Something not right?** `710sRice doctor` (or **Doctor** in the main menu, SUPER+Alt+Space)
  checks the install and names the fix for each problem it finds; `710sRice doctor -repair`
  runs those fixes for you. An `[XX]` is a problem: repair fixes it, unless doctor says it needs
  you (a key `user.ahk` defines twice, say). A `[!!]` is worth a look, and repair leaves it
  alone: your own edits, a package newer than its pin, warnings from your own rules.
  SUPER+Shift+R (or `710sRice reload`) reloads the whole stack and re-applies the config.
  `710sRice logs` opens the folder with every log.
- **An app newer than its pin?** `710sRice doctor` marks it `[!!]`, and repair leaves it alone:
  the pin is the version 710sRice was tested with, and nothing here moves an app down. If
  something about that app isn't working, going back is worth a try: from a normal window,
  `winget uninstall --id <its Install ID> --exact` (the IDs are in `versions.md`), then
  `710sRice doctor -repair`, which installs the pinned version and pins it.
- **The rice's own settings in a mess?** Uninstall, then install: every 710sRice choice goes
  back to its default (a plain re-install keeps the tiling mode, the palette profile in use and
  the screen numbers, so it isn't enough). Your own files stay -- `user.ahk`, `user.ps1`,
  `rules.local.toml`, your palette profiles: if the trouble is in one of them, move it to another
  folder, `710sRice restart`, and see.
