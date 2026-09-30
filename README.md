# 710.DesktopRice

A keyboard-first tiling desktop for Windows 11, themed from your wallpaper.

| Piece | What it does here |
| --- | --- |
| [komorebi](https://github.com/LGUG2Z/komorebi) | Tiling window manager: workspaces, layouts, borders. Admin windows tile too |
| [YASB](https://github.com/amnweb/yasb) | The bar across the top: workspaces, weather, system info, wallpaper gallery |
| [AutoHotkey v2](https://www.autohotkey.com/) | Every hotkey, plus the themed, searchable menus (`config/ahk/710.ahk`) |
| [Flow Launcher](https://www.flowlauncher.com/) + [Everything](https://www.voidtools.com/) | App launcher and instant file search |
| [ShareX](https://getsharex.com/) | Screenshots, recordings, OCR, QR scanning |
| [Windows Terminal](https://github.com/microsoft/terminal) + PowerShell 7 | The terminal, with a [Starship](https://starship.rs/) prompt, fzf, zoxide, eza and bat |
| [wallust](https://codeberg.org/explosion-mental/wallust) | Pulls a color palette from the wallpaper; a [palette profile](#palette-profiles) decides which color goes where |

Throughout this README, **SUPER** means the Windows key.

## Credits

710.DesktopRice started life as a set of changes to
[winarchy](https://github.com/guidonaselli/winarchy) by Guido Naselli, an Omarchy-inspired
Windows desktop, and much of its behavior is ported from it. The bar's look is the
[Okinami](https://github.com/amnweb/yasb-themes/tree/main/themes/b51c153d-397c-4be0-b7ed-4f619c6de87f)
theme from [yasb-themes](https://github.com/amnweb/yasb-themes), and the app rules that keep
komorebi from tiling things it shouldn't come from the community
[komorebi-application-specific-configuration](https://github.com/LGUG2Z/komorebi-application-specific-configuration).
Their licenses and copyright notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

This repo is [MIT](LICENSE). The tools it installs keep their own licenses, and one of them
matters: **komorebi is free for personal use only**. Using it for work needs a commercial
license from its author. See [komorebi's licensing page](https://komorebi.lgug2z.com/about/licensing/).

## Before you start: the weather widget

The bar's weather widget needs a free API key from [weatherapi.com](https://www.weatherapi.com/)
(sign up, then copy the key from your dashboard). YASB's
[weather widget page](https://github.com/amnweb/yasb/wiki/(Widget)-Weather) has the details.

You don't have to set anything up ahead of time. The installer asks for two values:

- `YASB_WEATHER_API_KEY` — your weatherapi.com key
- `YASB_WEATHER_LOCATION` — a zip/postal code or city name

It only asks for the ones that aren't set yet, never prints what's stored, and Enter skips.
Skip them and the widget shows an error until they're set; run `710sRice install -Only weather`
or set them yourself:

```powershell
setx YASB_WEATHER_API_KEY "your-key"
setx YASB_WEATHER_LOCATION "your zip or city"
```

They're stored as your own Windows user variables, never in the repo, and uninstall leaves
them alone. If you set or change them after the bar is already running, restart the bar to
pick them up (a running program never sees a new `setx` value):

```powershell
710sRice reload bar
```

The widget shows **°F**. For °C, open `config/yasb/config.yaml`, find the `weather:` widget
and change `units: "imperial"` to `units: "metric"`.

## Requirements

- Windows 11
- winget (built into current Windows 11)
- **PowerShell 7, installed first.** The `710sRice` command and everything it runs need it,
  so install it before anything else:

  ```powershell
  winget install --id 9MZ1SNWT0N5D --source msstore
  ```

  That's the Microsoft Store build, the same package the installer checks for. It isn't
  tied to a version: it installs the current release and keeps itself updated, and
  nothing here cares which 7.x you have. If the Store is blocked on your machine,
  `winget install --id Microsoft.PowerShell --source winget` works too.
- Admin rights for install and uninstall (Defender exclusions and komorebi's elevated
  sign-in task need them). You don't open an admin window for that: both ask with a UAC
  prompt.

Clone the repo wherever you like. The installer records its location in
`DESKTOPRICE_HOME`, and everything else finds it from there.

```powershell
git clone https://github.com/ItsAlways710/710.DesktopRice.git
cd 710.DesktopRice
```

## Install

There are two ways to run it: **full-time**, where it's your desktop from the moment you sign
in, or **on demand**, where you start it when you want it and stop it when you don't.

The first install runs from a normal PowerShell 7 window in the repo folder, as
`.\710sRice.ps1`. It opens an admin window for the install itself (one UAC prompt) and waits
for it. After that, `710sRice` works in any PowerShell 7 window, the one you started from
included, and once the stack is running SUPER+Enter opens one.

### What install always does

Either way, the installer:

- Installs the packages with winget. komorebi, YASB, AutoHotkey, Flow Launcher and
  Everything are **pinned** to tested versions so a `winget upgrade --all` can't move them
  out from under the config; the rest take whatever is current. [versions.md](versions.md)
  lists every package, its version and where it comes from.
- Installs wallust (a checksum-verified release download; there's no winget package).
- Points komorebi and YASB at this repo's config folders.
- Adds Windows Defender exclusions for ShareX, Everything, komorebi's command-line tool
  (`komorebic.exe`), PowerShell 7 and this repo (without them, the first capture or hotkey
  of a session lags while Defender scans).
- Hooks `config/pwsh/profile.ps1` into your PowerShell profile.
- Sets Windows Terminal's default shell to PowerShell 7.
- Sets up Flow Launcher: `app` searches apps, `f` searches files through Everything, and it
  opens with an empty search box.
- Sets the default wallpaper and themes everything from it.
- Removes the desktop shortcuts the installers drop (Flow Launcher and ShareX add one; ones
  you already had are left alone).
- Sets komorebi up to run **elevated**, so windows running as administrator tile like
  everything else. See [Admin windows](#admin-windows), including how to opt out
  (`710sRice tiling normal`) and why you might.

Each of these is a step you can also run on its own; see [Install steps](#install-steps).

### Full-time: `-Activate`

From a PowerShell 7 window in the repo folder:

```powershell
.\710sRice.ps1 install -Activate
```

On top of the above, this:

- Starts komorebi, YASB, AutoHotkey and ShareX at every sign-in, through Scheduled Tasks.
  Only komorebi's runs elevated (unless you opted out); the rest run as you.
- Sets the Windows taskbar to auto-hide (the bar replaces it).
- Turns off, for your user only: Bing results and ad suggestions in Start search, the
  Copilot, Widgets and Task View taskbar buttons, Start menu recommendations and account
  nags, and Windows' "suggested content", tips and lock-screen ads. The exact registry
  values are listed in [Windows settings changed by -Activate](docs/activate-windows-settings.md).
- Removes Explorer's delay before startup apps launch
  (`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize\StartupDelayInMSec = 0`).
- Starts everything right away.

#### Windows settings changed by -Activate

All under `HKEY_CURRENT_USER`: your account only, no admin rights, and uninstall deletes
each value again, which hands the setting back to Windows' own default. The full list,
value by value: [docs/activate-windows-settings.md](docs/activate-windows-settings.md).

### On demand

Run the installer without `-Activate`, from a PowerShell 7 window in the repo folder:

```powershell
.\710sRice.ps1 install
```

Nothing starts at sign-in and none of the Windows changes above are made. Each part still
gets a Scheduled Task, just with no sign-in trigger, so `710sRice start` starts everything
the way sign-in would (komorebi elevated, with no UAC prompt). See
[Run on demand](#run-on-demand).

### Updating

```powershell
710sRice update
```

It pulls the newest version from GitHub, then runs `710sRice doctor -repair` from it (one UAC
prompt). Repair keeps your wallpaper and theme: it moves pinned packages up to a new pin in
[versions.md](versions.md) (closing each app first and starting it again afterwards), and
picks up changed rules, launchers, the profile hook, Flow's settings, the bar's config,
`710.ahk` and the theme templates. Update won't pull over your own edits to tracked files
(those belong in `user.ahk`, `rules.local.toml` or `user.ps1` -- see
[Make it yours](#make-it-yours)), and if your copy and GitHub have both moved, it tells you
what to run instead. Nothing new? It says so and runs a health check.

There's no separate update checker, by design: `710sRice doctor` tells you when GitHub has a
newer version, when you ask it.

From a copy older than the `update` command, or if you'd rather run git yourself,
`git pull` and then `710sRice doctor -repair` does the same thing by hand.

Re-running the installer (`710sRice install`) is always safe too. A plain re-run keeps
whatever you had: a full-time (`-Activate`) machine stays full-time, and your
elevated-tiling choice is remembered. It installs what's missing, re-registers the sign-in
tasks, and recompiles the rules. One thing to know: **every run applies the default
wallpaper and theme again**, so pick yours with SUPER+W afterwards. It never moves a package
that's already installed; `710sRice install -Only upgrade` does that for a new pin.

`710sRice install -SkipPackages` skips the winget step and redoes everything else (config,
theme, Flow setup), which is quicker when only the repo changed.

## The 710sRice command

Run it from any PowerShell 7 window. Commands marked *(admin)* ask for admin rights with a
UAC prompt and run in their own admin window; there's no need to open one yourself.

| Command | What it does |
| --- | --- |
| `710sRice` | The command list. `710sRice <command> -?` shows one command's options |
| `710sRice install` | Install (safe to run again); `-Activate` makes it full-time, `-SkipPackages` skips winget, `-Only <step>` runs just those [steps](#install-steps) *(admin)* |
| `710sRice uninstall` | Undo everything install did; `-DryRun` shows the plan first *(admin)* |
| `710sRice doctor` | Health check: what's wrong, and the command that fixes each thing. Changes nothing; also says when GitHub has a newer version |
| `710sRice doctor -repair` | Fix what doctor finds, then check again. Never touches your wallpaper, theme or choices *(admin)* |
| `710sRice update` | Get the newest version from GitHub, then repair from it. Keeps your wallpaper, theme and choices *(admin)* |
| `710sRice start` / `stop` | Start or stop the stack |
| `710sRice restart` | Stop the stack and start it again, same as SUPER+Ctrl+R (SUPER+Shift+R only restarts what it has to) |
| `710sRice reload` | Re-apply config and rules, restarting only what changed; same as SUPER+Shift+R |
| `710sRice reload bar` | Restart just the bar |
| `710sRice logs` | Open the logs folder and list what's in it |
| `710sRice palette` | List the [palette profiles](#palette-profiles), the one in use marked |
| `710sRice palette use <profile>` | Theme everything with that profile now: `default`, `0`–`9`, or its name |
| `710sRice palette edit [<profile>]` | Open the palette profile editor on the one in use (or that one) |
| `710sRice palette new [<from>]` | Create a palette profile in the editor, starting from the one in use (or `<from>`) |
| `710sRice tiling status` | Whether komorebi runs elevated: the saved choice, its task, and the running copy |
| `710sRice tiling elevated` / `normal` | Switch komorebi to elevated or not *(admin)* |

The scripts behind it (`install.ps1`, `uninstall.ps1`, `scripts\Start-All.ps1` and so on)
still exist and work on their own; the command just gives them one name.

### Install steps

The installer is a set of steps, always run in this order. A plain `710sRice install` runs
them all, except `upgrade` and `palette`, which only run when you name them (and `windows`
only runs with `-Activate`).

| Step | What it does |
| --- | --- |
| `packages` | Installs what's missing from [versions.md](versions.md), pinned ones at their pin |
| `upgrade` | Moves a pinned package that's older than its pin up to it |
| `envvars` | Points komorebi and YASB at this repo's config |
| `weather` | Asks for the weather key and location, if they aren't set |
| `path` | Puts the `710sRice` command on your PATH |
| `wallust` | Installs wallust at its pinned version |
| `theme` | Sets the default wallpaper and themes everything from it |
| `palette` | Re-themes everything from the wallpaper you have now, with the palette profile in use (no wallpaper change) |
| `monitors` | Records which monitor is which, for komorebi |
| `defender` | Adds the Windows Defender exclusions |
| `profile` | Hooks the PowerShell profile in |
| `terminal` | Makes PowerShell 7 Windows Terminal's default |
| `flow` | Sets up Flow Launcher |
| `compile` | Rebuilds `komorebi.json` from the rules |
| `tasks` | Registers the scheduled tasks, for whichever way this machine runs |
| `windows` | The Windows settings of a full-time install (taskbar, hardening, Startup delay) |

`-Only` runs just the steps you name, in that same order, and leaves the machine running the
way it already does (full-time or on demand). It doesn't take any other switch. For example:

```powershell
710sRice install -Only path       # put the 710sRice command back on PATH
710sRice install -Only upgrade    # after a pin bump in versions.md
710sRice install -Only palette    # the bar or Terminal lost their colours
```

`710sRice install -?` lists the steps too. `710sRice doctor -repair` runs them for whatever
doctor finds, never `theme`.

## Run on demand

From a PowerShell 7 window:

```powershell
710sRice start
```

Everything starts through its own Scheduled Task, so it doesn't matter which window you run
it from: komorebi starts elevated (unless you switched that off), and YASB, AutoHotkey and
ShareX start as you. It checks what came up and says so.

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

This is a real uninstall: it stops everything, removes the Scheduled Tasks, and puts back
what was there before. Your original wallpaper, lock screen, accent color, Windows Terminal
colors and default shell, Flow Launcher settings and theme, taskbar, Windows settings,
PowerShell profile and Defender exclusions are restored, not reset to defaults. The installer saves
each one the first time it changes it.

Packages: anything the installer added is removed, except rows marked **Pre-existing? yes**
in [versions.md](versions.md) (common tools you may well have had already, like Windows
Terminal and Everything).

- `-Keep <Install ID>` keeps a package that would otherwise be removed, e.g.
  `710sRice uninstall -Keep ShareX.ShareX`. Several at once:
  `-Keep ShareX.ShareX,Flow-Launcher.Flow-Launcher`.
- `-Force` removes the Pre-existing rows too.

It forgets your elevated-tiling choice and which palette profile is in use, so a later
install starts from the defaults again. Your palette profiles themselves stay in
`config/palettes` (it tells you how many).
It also takes the `710sRice` command off your PATH; `.\710sRice.ps1` in the repo folder still
works, for a reinstall.
It doesn't delete the repo folder, your weather variables, or your personal files
(`user.ahk`, `user.ps1`, `rules.local.toml`, `config/windows.toml`, your palette profiles and
scheme files). Delete the folder
yourself if you're done with it.

## Hotkeys

**SUPER+K** lists every hotkey, searchable. The ones to know first:

| Keys | What it does |
| --- | --- |
| SUPER+Enter | Windows Terminal (opens on the monitor under the mouse) |
| SUPER+Alt+Enter | Windows Terminal **as administrator** (UAC prompt; same monitor placement) |
| SUPER+Space | Flow Launcher |
| SUPER+Ctrl+Space | Flow, apps only |
| SUPER+S | Flow, file search |
| SUPER+Alt+Space | Main menu: apps, capture, tiling, palette profiles, game mode, reload, quit |
| SUPER+Esc | Power menu: lock, sleep, restart, shut down... |
| SUPER+K | This hotkey list |
| SUPER+X | Close the window |
| SUPER+W | Wallpaper gallery |
| SUPER+B / SUPER+E | Browser / File Explorer |
| SUPER+Shift+A | Claude desktop app |
| SUPER+Shift+R | Reload: re-applies config and rules, restarting only what changed |
| SUPER+Ctrl+R | Restart the whole stack (stop, then start everything); a toast before and after |
| SUPER+Arrows | Move focus |
| SUPER+Shift+Arrows | Move the window |
| SUPER+Alt+Arrows | Stack the window with its neighbor (tabs show on the stack); SUPER+Alt+, / SUPER+Alt+. switch tabs, SUPER+Alt+U unstacks |
| SUPER+1…9 | Go to workspace 1–9 |
| SUPER+Shift+1…9 | Move the window to workspace 1–9 |
| SUPER+F / SUPER+T | Monocle (fill the screen) / float or tile the window |
| SUPER+Ctrl+T / SUPER+P | Retile / pause tiling |
| SUPER+, / SUPER+. | Focus the previous / next monitor |

**Capture (ShareX):**

| Keys | What it does |
| --- | --- |
| SUPER+Shift+S | Region |
| SUPER+Shift+W | Active window |
| SUPER+Shift+P | Full screen |
| SUPER+Shift+V / SUPER+Ctrl+V | Start / stop recording |
| SUPER+Shift+G | Record as GIF |
| SUPER+Ctrl+O | Text from screen (OCR) |
| SUPER+Ctrl+Q | Scan a QR code |

The **Main Menu** entry at the top of the bar's home menu (the icon at the far left) opens
the same menu as SUPER+Alt+Space. Every menu is searchable: start typing, use the arrow
keys, Esc to go back.

## Make it yours

These files are yours alone. Git ignores them, so neither `710sRice update` nor `git pull` touches them:

- `config/ahk/user.ahk` — your own hotkeys. It's loaded after `710.ahk` if it exists, and
  SUPER+K lists its hotkeys too. Reload with SUPER+Shift+R.
- `config/pwsh/user.ps1` — your own PowerShell profile additions, loaded last by
  `config/pwsh/profile.ps1`. Open a new terminal to pick up changes.
- `config/komorebi/rules.local.toml` — your own app rules. Quick add rule writes it for you;
  see [App rules](#app-rules).
- `config/palettes/profile0.json` … `profile9.json` — your palette profiles (the editor
  writes them; see [Palette profiles](#palette-profiles)), and any scheme files you put in
  `config/palettes/schemes`.

## Wallpapers and theming

Change the wallpaper with **SUPER+W** (or the wallpaper button on the bar) and everything
recolors to match: the bar, komorebi's window borders and stack tabs, the Windows accent
color, Windows Terminal, the prompt, the menus, Flow Launcher and the lock screen. wallust
does the color picking; the [palette profile](#palette-profiles) in use decides how, and
which color goes where.

The lock screen takes the wallpaper itself, as your own lock-screen picture (the one
Settings > Personalization > Lock screen sets), so it's there before sign-in straight away,
even after a restart. A picture you pick in Settings stays until your next wallpaper change.

The gallery shows:

- `assets/wallpapers` in this repo, the wallpapers that ship with it.
- Up to ten folders of your own (subfolders included), one per variable:
  `YASB_WALLPAPER_PATH`, then `YASB_WALLPAPER_PATH_2` through `YASB_WALLPAPER_PATH_10`.
  None is set by default, and an unset one is simply skipped. To add a folder:

  ```powershell
  setx YASB_WALLPAPER_PATH "C:\Users\<you>\Pictures\Wallpapers"
  ```

  ```powershell
  setx YASB_WALLPAPER_PATH_2 "C:\Windows\Web\Wallpaper"
  ```

  (that second one is a good start: Windows' own wallpapers, on every Windows 11 machine),
  then restart the bar so it sees the change: `710sRice reload bar`. To drop one again:

  ```powershell
  [Environment]::SetEnvironmentVariable('YASB_WALLPAPER_PATH_2', $null, 'User')
  ```

  (then `710sRice reload bar` again). No need to edit `config/yasb/config.yaml`.

### Palette profiles

The wallpaper decides the colors; a palette profile decides how they're made and where each
one goes. **Default** is the theme described above, and it's in use until you pick another:
wallust's `kmeans` with a little more saturation for the bar, menus, Flow, borders and accent, while
Windows Terminal keeps fixed red, green, yellow, blue, purple and cyan, tinted by the wallpaper,
so text stays distinct and readable on any wallpaper. Up to ten profiles of your own sit beside
it, and the one in use applies to every wallpaper. The Default before 2026-09-28 (every Terminal
color straight from the wallpaper) is kept in `config/palettes/archive`, with how to use it
again.

**SUPER+Alt+Space > Palette profiles**:

- **Choose profile** re-themes everything with that profile at once, without changing the
  wallpaper, and every wallpaper change after that uses it too. It stays chosen through
  sign-out and `710sRice update`.
- **Create profile** and **Edit profile** open the editor.

The editor has:

- **Color source**: how the palette is made. From the wallpaper (wallust's `kmeans`,
  Default's, or `salience` or `ansi`; a dark or light palette; more saturation; 16 distinct
  colors), the built-in theme closest to each wallpaper, one built-in theme (about 600,
  searchable), a random built-in theme each time, or a color scheme file (pywal or
  terminal.sexy) that you put in `config/palettes/schemes`.
- **Palette**: the colors that source makes from the wallpaper you have now.
- **Roles**: eight named colors (Background, Panel, Accent, Hover, Subtext, Text, Bright text,
  Alert), each taken from the palette. Open a role to see every app color that follows it;
  any of them can have a color of its own instead. Built-in themes and scheme files come in
  terminal order, so the **Terminal order** button suits them better than Default's map.
- **Readable text** (colors too dim to read get lifted), **light or dark** Windows apps, and
  which apps the profile themes at all. An app that's switched off keeps its own colors.
- **Preview**: the bar, the menus, Flow Launcher, Terminal and the prompt, window borders,
  stack tabs and the Windows accent, in the profile's colors on your wallpaper. Click any
  color in it to change it.

Picking a color gives you a palette color, a role, or a fixed color (the same on every
wallpaper), as it is, lighter, darker, or mixed with another. **Save** keeps the profile;
**Save and use** also themes everything with it now. Default can't be changed, but you can
try anything on it and **Save as new**.

From a PowerShell 7 window, `710sRice palette` lists the profiles, `710sRice palette use 3`
(or its name) switches, and `710sRice palette edit` / `710sRice palette new` open the editor.

If wallust can't make a palette from a wallpaper, nothing is left half-themed: the last theme
stays and a notification says why. `710sRice doctor` checks that the colors on screen are the
ones the profile in use makes, and names the fix when they aren't.

Theming another app takes one small file; `tools/palette/targets/README.md` explains how,
with Flow Launcher as the example.

## App rules

Rules decide which windows komorebi tiles, floats or leaves alone. They come in four
layers, lowest to highest priority, and SUPER+Shift+R compiles them into komorebi's config:

1. The community rules in `vendor/asc` (a pinned copy, updated deliberately).
2. `games.toml`: game launchers and games, so they're never tiled. Game mode (in the main
   menu) shows when one is running.
3. `config/komorebi/rules.toml`: the rules this repo ships, tracked in git. Currently two:
   WinUI 3 apps (the new Photos app and others) stay opaque when unfocused, because
   komorebi's transparency stops them taking clicks (transparency is off by default;
   SUPER+Shift+D turns it on); and the Claude desktop app is tiled
   (see [Tips and known issues](#tips-and-known-issues)).
4. `config/komorebi/rules.local.toml`: **your** rules, for this machine only (git ignores
   it). They win over everything above. Want one on every machine? Move it into
   `rules.toml` and commit it.

One limit: for the "extra behavior" rule types (Layered, Opaque and a few others), every
layer's rules are added together, so your file can add them but can't cancel a shipped
one. Edit `rules.toml` for that.

### Adding a rule

**SUPER+Alt+Space → Tiling → Quick add rule...**, click the window, pick what to match on
(its program, window class or title), then what to do with it:

| Action | What it does | Takes effect |
| --- | --- | --- |
| Float (never tile) | komorebi manages it but never tiles it | Right away, on that window too |
| Ignore (hands off) | komorebi leaves it completely alone | Right away |
| Manage (force tile) | Tiles a window komorebi would normally skip | Right away |
| Layered (tile an app komorebi skips) | For apps whose windows komorebi turns away because of how they're drawn, like the Claude desktop app | New windows: **relaunch the app** |
| Opaque (never translucent) | Keeps it solid when unfocused, for apps that stop taking clicks when translucent. Only matters with transparency on (off by default; SUPER+Shift+D) | The next time you click it |

If the window you picked looks like a Layered case (komorebi isn't managing it and it has
the telltale window style), Layered moves to the top, marked **suggested**. Rules for
windows running as administrator work too.

### Removing and editing rules

- **Tiling → Remove a rule...** lists your rules; pick one and confirm. komorebi restarts to
  drop it. Windows that were already open keep the state komorebi remembered for them (a
  window you un-floated stays floating, for example) until you press **SUPER+T** on it or
  relaunch the app.
- **Tiling → Edit my rules...** opens `rules.local.toml` in whatever opens `.toml` files, or
  Notepad. Save, then SUPER+Shift+R to apply.

Only your own rules are listed and removable here; the shipped ones are edited in
`rules.toml` like any other config.

## Admin windows

By default komorebi runs **elevated** (as administrator), so windows running as
administrator tile, move and resize like everything else. Your hotkeys work in them too:
AutoHotkey runs with UI Access, which lets it send keys to admin windows **without** being
elevated itself, so nothing it launches runs as admin by accident.

- **SUPER+Alt+Enter** opens a Windows Terminal as administrator (after a UAC prompt), tiled
  on the monitor under the mouse.
- **Opting out:** `710sRice tiling normal` runs komorebi as you instead; admin windows then
  float and can't be tiled. `710sRice tiling elevated` switches back, and
  `710sRice tiling status` shows where things stand. The choice is remembered (a re-run of
  install keeps it), it doesn't touch your wallpaper or theme, and it takes effect the next
  time komorebi starts (sign out and in, or `710sRice restart`).
- **Admin commands without an admin window:** turn on Windows 11's `sudo` (Settings >
  System > For developers > Enable sudo, "Inline" mode) and run `sudo <command>` in a normal
  Terminal.

**The trade-off, plainly:** an elevated komorebi starts from files your normal account can
change (its startup script, its config folder, an environment variable). So any program
already running as you could use them to get admin rights without a UAC prompt. On a
personal machine where you're the only user that's a small step, since UAC isn't a
security boundary to begin with, but on a shared or work-connected machine use
`710sRice tiling normal`. komorebi's author also describes running it elevated as "not well
tested", so if something odd shows up around admin windows, that's the first thing to try.

## Tips and known issues

- **Extra title bars on an app after the bar restarts.** Apps tiled through a Layered rule
  may react badly when the bar restarts (the bar gives its screen strip back and takes it
  again, and Windows tells every window). The Claude desktop app is the real example, and
  it's one of the included rules, so expect it: each bar restart can add another title bar
  on top of Claude's own, and clicks land one row off. Quit it from its tray icon and
  relaunch to fix. SUPER+Shift+R only restarts the bar when it has to (its `config.yaml`
  changed, or komorebi restarted), so this is rare; `710sRice reload bar` and
  `710sRice restart` always do.
- **Widgets button still on the taskbar?** Windows won't let a script hide it. Turn it off
  in Settings > Personalization > Taskbar.
- **Changed a weather or wallpaper variable?** Restart the bar: `710sRice reload bar`.
- **Something not right?** `710sRice doctor` (or **Doctor** in the main menu, SUPER+Alt+Space)
  checks the install and names the fix for each problem it finds; `710sRice doctor -repair`
  runs those fixes for you. SUPER+Shift+R (or `710sRice reload`) reloads the whole stack and
  re-applies the config. `710sRice logs` opens the folder with every log.

## Future plans

- **More commands:** set the weather key and location, point the wallpaper gallery at a
  folder, add or remove a game for game mode, and turn taskbar auto-hide on or off.
- **A proper README pass:** screenshots and a short demo.
- **Pin an app to a workspace.** A Quick add action that makes an app open on the monitor
  and workspace you pick, using komorebi's own workspace rules -- no extra background
  process. By default you can still move it afterwards; optionally lock it there. Saved in
  your machine-local `rules.local.toml`.
- **Turn off a shipped rule locally,** without editing the tracked `rules.toml`.
