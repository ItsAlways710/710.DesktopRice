# Install

## Requirements

- Windows 11
- winget (built into current Windows 11)
- PowerShell 7 and git. The [one-line install](#the-one-line-install) installs both when
  they're missing. Installing by hand, install PowerShell 7 first -- the `710sRice` command and
  everything it runs need it:

  ```powershell
  winget install --id 9MZ1SNWT0N5D --source msstore
  ```

  That's the Microsoft Store build, versions.md's row for it. It isn't
  tied to a version: it installs the current release and keeps itself updated, and
  nothing here cares which 7.x you have. If the Store is blocked on your machine,
  `winget install --id Microsoft.PowerShell --source winget` works too.
- Admin rights for install and uninstall (Defender exclusions and komorebi's elevated
  sign-in task need them). You don't open an admin window for that: both ask with a UAC
  prompt.

## Three ways to run it

- **On demand**: you start it when you want it and stop it when you don't.
- **Full-time**: it's your desktop from the moment you sign in.
- **Full-time with komorebi not elevated**: full-time, with komorebi running as you instead of
  as administrator, so windows running as administrator float instead of tiling (see
  [Admin windows](tiling.md#admin-windows) for why you might want that).

| Way | After the one-line install | By hand, from the repo folder |
| --- | --- | --- |
| On demand | nothing more: the one-liner always installs on demand | `.\710sRice.ps1 install` |
| Full-time | `710sRice activate` | `.\710sRice.ps1 install -Activate` |
| Full-time, komorebi not elevated | `710sRice tiling normal`, then `710sRice activate` | `.\710sRice.ps1 install -Activate -NoElevatedTiling` |

You can switch between on demand and full-time at any time with `710sRice activate` and
`710sRice deactivate` (see [Switching](#switching-activate--deactivate)). Whether komorebi runs
elevated is a choice of its own, remembered per machine, so it pairs with on demand too:
`710sRice tiling normal` or `710sRice tiling elevated`. A komorebi that's already running
changes at its next start (`710sRice restart`; the command says so).

One thing to do once the bar is up: click the weather widget and pick your city (see
[The bar](desktop.md#the-bar)). There's no account or key to set up.

## The one-line install

From a normal PowerShell window -- Windows PowerShell is fine, an admin one isn't:

```powershell
irm https://raw.githubusercontent.com/ItsAlways710/710.DesktopRice/master/boot.ps1 | iex
```

It installs git and PowerShell 7 if they're missing, clones this repo to `C:\710.DesktopRice`
and runs the installer, on demand: one UAC prompt, and the install itself runs in its own admin
window. To put the repo somewhere else, set `$env:DESKTOPRICE_HOME = 'D:\710.DesktopRice'` in
that window first. When it's done, open a new PowerShell 7 window: `710sRice start` starts it,
and `710sRice activate` makes it [full-time](#switching-activate--deactivate). Run the
one-liner again any time: it uses the clone that's there (`710sRice update` brings that up to
date).

## By hand

Clone the repo wherever you like. The installer records its location in
`DESKTOPRICE_HOME`, and everything else finds it from there.

```powershell
git clone https://github.com/ItsAlways710/710.DesktopRice.git
cd 710.DesktopRice
```

The first install runs from a normal PowerShell 7 window in the repo folder, as
`.\710sRice.ps1` (`install`, or `install -Activate` for full-time; both below). It opens an
admin window for the install itself (one UAC prompt) and waits for it. After that, `710sRice`
works in any PowerShell 7 window, the one you started from included, and once the stack is
running SUPER+Enter opens one.

## What install always does

Either way, the installer:

- Installs the packages with winget. komorebi, YASB, AutoHotkey, Flow Launcher and
  Everything are **pinned** to tested versions so a `winget upgrade --all` can't move them
  out from under the config; the rest take whatever is current. A pinned package that's
  older than its pin is moved up to it (never down). [versions.md](../versions.md) lists every
  package, its version and where it comes from. If a package doesn't install, the run still
  finishes every step, then lists what's missing and exits with an error;
  `710sRice doctor -repair` tries again.
- Installs wallust (a checksum-verified release download; there's no winget package).
- Points komorebi and YASB at this repo's config folders.
- Adds ten 710sRice commands to the Start menu (a 710sRice folder: Menu, Reload stack, Doctor,
  Game mode on / off, Screenshot region / window, Screen recording, Stop recording, Text from
  screen). Flow Launcher finds them: type `710sRice`. Each asks the running 710sRice to do it.
- Adds Windows Defender exclusions for ShareX, Everything, komorebi's command-line tool
  (`komorebic.exe`), PowerShell 7 and this repo (without them, the first capture or hotkey
  of a session lags while Defender scans).
- Hooks `config/pwsh/profile.ps1` into your PowerShell profile.
- Sets Windows Terminal's default shell to PowerShell 7, and its font to the JetBrainsMono
  Nerd Font for every profile (the prompt's icons need it), including profiles that set a
  font of their own.
- Sets up Flow Launcher: `app` searches apps, `f` searches files through Everything, it
  opens with an empty search box, its search box and results use the JetBrainsMono Nerd Font,
  and its hotkey does nothing while the window you're in is fullscreen (a game, a video) --
  click a window on another monitor and it opens there. On a machine where Flow has never run, install starts it
  once first (its Welcome window shows for a few seconds), then sets it up and themes it in
  the same run. Flow's own "start on system startup" setting is switched off: 710sRice starts
  Flow itself (below), and two starts would open its window. Flow installs for you only, so
  install runs its installer un-elevated, not from the admin window (a winget window shows
  briefly).
- Turns off ShareX's and Everything's own update checks (the pins and `710sRice update` bring
  updates) and keeps their icons out of the bar: Everything's tray icon is off, and ShareX's
  is hidden from the bar's tray (ShareX keeps it on: it needs it to start hidden at sign-in).
  ShareX's own "Run ShareX when Windows starts" is switched off: 710sRice starts ShareX
  itself on a full-time machine, and an on-demand one starts nothing at sign-in.
  If Everything isn't running, install starts it in the background (SUPER+S's file search
  needs it; Everything freshly installed by winget only starts at your next sign-in).
- Sets the default wallpaper and themes everything from it.
- Removes the desktop shortcuts the installers drop (Flow Launcher and ShareX add one; ones
  you already had are left alone).
- Sets komorebi up to run **elevated**, so windows running as administrator tile like
  everything else. See [Admin windows](tiling.md#admin-windows), including how to opt out
  (`710sRice tiling normal`) and why you might.

Each of these is a step you can also run on its own; see [Install steps](command.md#install-steps).

## Full-time: `-Activate`

From a PowerShell 7 window in the repo folder:

```powershell
.\710sRice.ps1 install -Activate
```

On top of the above, this:

- Saves your taskbar and Windows settings as they are, first, so `710sRice deactivate` and
  uninstall can put them back. If they can't be saved, nothing of the rest below is changed: the
  run installs on demand and ends with an error, and `710sRice activate` tries again.
- Starts komorebi and AutoHotkey at every sign-in, through Scheduled Tasks, and AutoHotkey
  starts the bar, ShareX and Flow Launcher. Only komorebi runs elevated (unless you opted out);
  the rest run as you. Flow starts hidden, and the first SUPER+Space after sign-in opens it.
- Sets the Windows taskbar to auto-hide (the bar replaces it).
- Turns off, for your user only: Bing results and ad suggestions in Start search, the
  Copilot, Widgets and Task View taskbar buttons, Start menu recommendations and account
  nags, and Windows' "suggested content", tips and lock-screen ads. The exact registry
  values are listed in [Windows settings changed by -Activate](activate-windows-settings.md).
- Removes Explorer's delay before startup apps launch
  (`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize\StartupDelayInMSec = 0`).
- Starts everything right away.

Already installed on demand? `710sRice activate` does the same without re-running the
installer (see [Switching](#switching-activate--deactivate)).

### Windows settings changed by -Activate

All under `HKEY_CURRENT_USER`: your account only, no admin rights. Each one is saved as it
was before it changes, and `710sRice deactivate` and uninstall put each back from that copy.
An install made full-time before 710sRice saved them has no copy: there, those values are
deleted instead, which hands each setting back to Windows' own default. The full list, value
by value: [docs/activate-windows-settings.md](activate-windows-settings.md).

## On demand

Run the installer without `-Activate`, from a PowerShell 7 window in the repo folder:

```powershell
.\710sRice.ps1 install
```

Nothing starts at sign-in and none of the Windows changes above are made. komorebi and
AutoHotkey still get their Scheduled Tasks, just with no sign-in trigger, so `710sRice start`
starts everything the way sign-in would (komorebi elevated, with no UAC prompt; AutoHotkey then
starts the bar, ShareX and Flow). See
[Run on demand](#run-on-demand). Already full-time? `710sRice deactivate` switches back.

## Switching: `activate` / `deactivate`

An installed machine can move between the two at any time, without re-running the installer
(which puts the default wallpaper back every time):

```powershell
710sRice activate      # on demand -> full-time
710sRice deactivate    # full-time -> on demand
```

- `activate` saves your taskbar and Windows settings as they are, then does what
  [Full-time](#full-time--activate) lists: the sign-in tasks, auto-hide, the Windows settings,
  the Startup delay, and it starts the stack.
- `deactivate` puts those settings back as they were before you activated, takes the sign-in
  start off every task, and leaves the stack stopped: `710sRice start` starts it when you want
  it.
- Neither changes a setting while the stack is running: each stops it first, and `activate`
  starts it again at the end. Explorer restarts once, as it does during the install.
- `-DryRun` shows what either would do, and changes nothing.
- In the mode it's already in, each says so and changes nothing else (it re-registers that
  mode's tasks, which mends one that lost its sign-in start).
- An install made full-time before these commands existed has no saved copy, so the first
  `deactivate` hands those settings back to Windows' own defaults instead, as uninstall always
  did.

The end of an install run, `710sRice doctor` and both commands say which mode the machine is
in, and the command that switches it.

## Updating

```powershell
710sRice update
```

It pulls the newest version from GitHub, then runs `710sRice doctor -repair` from it (one UAC
prompt). Repair keeps your wallpaper and theme: it moves pinned packages up to a new pin in
[versions.md](../versions.md) (closing each app first and starting it again afterwards), and
picks up changed rules, launchers, the profile hook, Flow's, ShareX's and Everything's
settings, the bar's config, `710.ahk` and the theme templates. Whatever install set that has been
changed since goes back too -- Windows Terminal's font and default shell, Flow's preferences, full
time's Windows settings, a sign-in task someone disabled: doctor marks each one `[XX]`. Update won't pull over your own edits to tracked files
(those belong in `user.ahk`, `rules.local.toml` or `user.ps1` -- see
[Make it yours](../README.md#make-it-yours)), and if your copy and GitHub have both moved, it tells you
what to run instead. Nothing new? It says so and runs a health check.

There's no separate update checker, by design: `710sRice doctor` tells you when GitHub has a
newer version, when you ask it. The apps' own update checks are off too (YASB's, ShareX's,
Everything's, Flow Launcher's): [versions.md](../versions.md) pins them, and `710sRice update`
moves them.

From a copy older than the `update` command, or if you'd rather run git yourself,
`git pull` and then `710sRice doctor -repair` does the same thing by hand.

Re-running the installer (`710sRice install`) is always safe too. A plain re-run keeps
whatever you had: a full-time (`-Activate`) machine stays full-time (switching is
`710sRice activate` / `deactivate`), and your elevated-tiling choice is remembered. It
installs what's missing, re-registers the sign-in tasks, and recompiles the rules. One thing to know: **every run applies the default
wallpaper and theme again**, so pick yours with SUPER+W afterwards. A pinned package that's
older than its pin is moved up to it (closing the app first and starting it again
afterwards); one that's newer than its pin, and every unpinned one, is left alone.

`710sRice install -SkipPackages` skips the winget step and redoes everything else (config,
theme, Flow setup), which is quicker when only the repo changed.

## Run on demand

From a PowerShell 7 window:

```powershell
710sRice start
```

komorebi and AutoHotkey start through their own Scheduled Tasks, and AutoHotkey starts the bar,
ShareX and Flow Launcher (if it isn't running already), so it doesn't matter which window you
run it from: komorebi starts elevated (unless you switched that off), everything else as you. It
checks what came up and says so.

To stop, use `710sRice stop` or **Quit 710sRice** in the tray icon's menu. Flow Launcher and
Everything keep running either way; they're ordinary apps you can use on their own.
`710sRice restart` stops everything and starts it again.

The taskbar is left to you. The stack is built around a hidden taskbar, so `710sRice start`
tells you how to turn auto-hide on if it's off, and `710sRice stop` reminds you to turn it
back off. Neither changes it.

## Uninstall

From a PowerShell 7 window:

```powershell
710sRice uninstall -DryRun    # show what it would do, change nothing
710sRice uninstall
```

This is a real uninstall: it stops everything, removes the Scheduled Tasks and the Start-menu
commands, and puts back what was there before. Your original wallpaper, lock screen, accent color, Windows Terminal
colors, font and default shell, Flow Launcher settings (its own startup setting and fonts included) and
theme, ShareX's and Everything's settings (their update checks and tray icons, ShareX's own startup), taskbar,
Windows settings, PowerShell profile and Defender exclusions are restored, not reset to
defaults. The installer saves each one the first time it changes it (the taskbar and Windows
settings when a machine goes full-time). The one exception: an install made full-time before
`710sRice activate` existed has no saved taskbar and Windows settings, so uninstall deletes
those values instead, which hands each back to Windows' own default. On an on-demand machine
uninstall leaves them alone: 710sRice never changed them there.

Packages: anything the installer added is removed, except two kinds of row in
[versions.md](../versions.md):

- **Pre-existing? yes**: common tools you may well have had already, like Everything and
  the Nerd Font. Kept, unless you pass `-Force`.
- **Pre-existing? system**: PowerShell 7 (the uninstall itself runs on it), Windows
  Terminal (part of Windows 11) and Git (`710sRice update` pulls with it; one you installed
  some other way is used as it is). Never removed, `-Force` included; uninstall says so, and
  you can remove them yourself in Settings > Apps > Installed apps.

Two switches change what goes:

- `-Keep <Install ID>` keeps a package that would otherwise be removed, e.g.
  `710sRice uninstall -Keep ShareX.ShareX`. Several at once:
  `-Keep ShareX.ShareX,Flow-Launcher.Flow-Launcher`. Keep Flow Launcher, and its own start at
  sign-in comes back too, if it had one before 710sRice.
- `-Force` removes the `yes` rows too. For the Nerd Font that's DEVCOM's package, which install
  only adds when Windows doesn't have the font: a copy you installed some other way stays, and
  Windows Terminal keeps using it. The Nerd Font goes without closing anything: Windows
  Terminal (this window included) usually still has it open, so its files are deleted at your next
  restart -- restart before you install 710sRice again.

It forgets your elevated-tiling choice and which palette profile is in use, so a later
install starts from the defaults again. Your palette profiles themselves stay in
`config/palettes` (it tells you how many).
It also takes the `710sRice` command off your PATH; `.\710sRice.ps1` in the repo folder still
works, for a reinstall.
It removes the weather variables an older install set (`YASB_WEATHER_API_KEY`,
`YASB_WEATHER_LOCATION`), if they're still there.
Last, it deletes its own folder, `%LOCALAPPDATA%\710.DesktopRice`: the logs (`710sRice logs`)
and the rest of what it kept there.
It doesn't delete the repo folder or your personal files (`user.ahk`, `user.ps1`,
`rules.local.toml` with your rules, games and pins, your palette profiles and scheme files).
Delete the folder yourself if you're done with it.
