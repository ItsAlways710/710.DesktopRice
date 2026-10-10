# Under the hood

How 710.DesktopRice is put together, and why it's built that way. None of this is needed to use
it; it's here for when you want to know what's running on your machine, or why something works
the way it does. [Map: what lives where](map.md) goes a level deeper, file by file.

## What starts what

Only two things start through Scheduled Tasks, both in Task Scheduler's `\710.DesktopRice\`
folder: komorebi and AutoHotkey (`710.ahk`). On a full-time machine they start at sign-in; on an
on-demand machine the same tasks exist with no sign-in trigger, and `710sRice start` runs them.
Each task starts its program through `tools\lib\run-hidden.vbs`, so no console window flashes
up, and at normal priority (Task Scheduler's default would start the whole chain below normal).
komorebi's task runs elevated unless you opted out ([Admin windows](tiling.md#admin-windows));
AutoHotkey's runs as you.

`710.ahk` then starts the bar, Flow Launcher and ShareX itself. They used to have tasks of their
own, but whatever a Scheduled Task starts runs inside a job that won't let a program opened from
it start programs of its own: a Mod Organizer 2 opened from the bar couldn't start its tools
(Error 5). What `710.ahk` starts is free of that.

**The bar's watchdog:** `710.ahk` checks every 5 seconds that the bar is running. Two misses in a
row (with nothing else already bringing it back, such as an install or a reload) and it starts
the bar again. Three restarts inside 5 minutes means the bar is crashing on its own, so the
watchdog stops and a notification points at `710sRice doctor`, which reads the story back out of
`yasb-autostart.log`. Getting the bar up at sign-in is `scripts\Start-Yasb.ps1`'s job (it retries
for a minute); the watchdog is the net for afterwards.

**Screens:** a few seconds after any display change, `710.ahk` asks komorebi to look at the
screens again, since komorebi sometimes looks before Windows has finished rearranging them.

## AutoHotkey with UI Access

Your hotkeys work in windows running as administrator, but AutoHotkey doesn't run as
administrator. It runs the UI Access build, `AutoHotkey64_UIA.exe`, which Windows lets send keys
to admin windows without being elevated itself, so nothing it launches (a Terminal, Flow, a
browser) runs as admin by accident. That build only exists in a per-machine AutoHotkey install
in Program Files, where AutoHotkey's installer creates and signs it; a per-user AutoHotkey falls
back to the plain build, and admin windows then don't get your keys.

## Rules, compiled from four layers

komorebi reads one file, `config\komorebi\komorebi.json`. Nobody edits it: it isn't in git, and
`tools\compile-komorebi-rules.ps1` (SUPER+Shift+R runs it) rebuilds it from `base.json` and the
four rule layers in [App rules](tiling.md#app-rules), plus this machine's screen numbers.

- **Where a window goes** (ignore, manage, float): when two layers disagree about the same
  window, the higher layer wins outright.
- **How a window behaves** (layered, opaque and the others): every layer's rules are added
  together, which is why your file can add one but can't cancel a shipped one.
- **Only when it changed:** komorebi reloads the file a couple of seconds after any write, and
  that reload puts every workspace back to its starting layout. So the compiler only writes the
  file when the result is different.

## Pins

A pin is komorebi's `initial_workspace_rules`: komorebi moves a matching window to its
workspace once, when it first sees it. That's why a pinned window can be moved anywhere after it
opens. Pins name this machine's screens by the numbers 710sRice gave them
([Screens and workspaces](desktop.md#screens-and-workspaces)), which is why they live only in
your `rules.local.toml`.

## What uninstall puts back

Before install changes something that was already there (your wallpaper, lock screen, accent
color, Windows Terminal's settings, Flow Launcher's, ShareX's and Everything's settings, your
PowerShell profile, Defender exclusions), it saves how it was, once, to
`%LOCALAPPDATA%\710.DesktopRice\original-state\`. A second install, or a wallpaper change, never
overwrites that copy with what is by then 710sRice's own state. Going full-time saves your
taskbar and Windows settings the same way. Uninstall puts each one back from its copy and
deletes the copy, so a later install starts fresh. It doesn't track changes you make after
install: it puts back what was there before 710sRice, and leaves alone what 710sRice never
changed. Packages go by [versions.md](../versions.md)'s Pre-existing? column
([Uninstall](install.md#uninstall)).

## Why these tools

The core came from [Winarchy](https://github.com/guidonaselli/winarchy): komorebi for tiling,
YASB for the bar, AutoHotkey for the keys and Flow Launcher for search. 710.DesktopRice kept that
stack and built its own install, doctor and theming on top.

- **komorebi** tiles with layouts, stacks with tabs, up to four screens, and can run elevated, so
  admin windows tile too.
- **YASB** talks to komorebi directly (workspaces, layout) and takes its look from a stylesheet
  the theme can write.
- **AutoHotkey v2** carries every hotkey and the themed menus, and reaches admin windows through
  UI Access.
- **Flow Launcher with Everything** is the launcher and instant file search.
- **wallust** is a pywal alternative that runs on Windows: it reads the colors out of the
  wallpaper, and palette profiles decide what goes where.
- **No accounts:** nothing here needs an account or an API key, which is why the weather is
  Open-Meteo, and why tools that phone home or want a sign-in were left out.
- **Pinned:** komorebi, YASB, AutoHotkey, Flow Launcher and Everything stay at the versions
  710sRice was tested with, and `710sRice update` moves them when a new pin has been tested.

## Influences

- [Niri](https://github.com/YaLTeR/niri) gave workspace 1 its Scrolling layout: windows in
  columns two wide, scrolling sideways.
- [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) shaped the Default
  palette: its look led to wallust's `kmeans`.

---

[← The manual](README.md)
