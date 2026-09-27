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
| [wallust](https://codeberg.org/explosion-mental/wallust) | Pulls a color palette from the wallpaper and recolors everything else |

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
- Admin rights for install and uninstall (Defender exclusions, the lock-screen image and
  komorebi's elevated sign-in task need them). You don't open an admin window for that:
  both ask with a UAC prompt.

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
  values are listed under [Windows settings changed by -Activate](#windows-settings-changed-by--activate).
- Removes Explorer's delay before startup apps launch
  (`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize\StartupDelayInMSec = 0`).
- Keeps the lock-screen image in sync with your wallpaper.
- Starts everything right away.

#### Windows settings changed by -Activate

All of these are under `HKEY_CURRENT_USER`, so they affect only your account and need no
admin rights. Uninstall deletes each value again, which hands the setting back to
Windows' own default.

| Key (under `HKCU\`) | Value | Set to | Turns off |
| --- | --- | --- | --- |
| `Software\Microsoft\Windows\CurrentVersion\Search` | `BingSearchEnabled` | 0 | Bing web results in Start search |
| `Software\Microsoft\Windows\CurrentVersion\Search` | `SearchboxTaskbarMode` | 0 | Taskbar search box |
| `Software\Microsoft\Windows\CurrentVersion\Search` | `CortanaConsent` | 0 | Cortana in search |
| `Software\Microsoft\Windows\CurrentVersion\SearchSettings` | `IsDynamicSearchBoxEnabled` | 0 | Search highlights |
| `Software\Microsoft\Windows\CurrentVersion\SearchSettings` | `IsAADCloudSearchEnabled` | 0 | Work/school cloud results in search |
| `Software\Microsoft\Windows\CurrentVersion\SearchSettings` | `IsMSACloudSearchEnabled` | 0 | Microsoft account cloud results in search |
| `Software\Policies\Microsoft\Windows\Explorer` | `DisableSearchBoxSuggestions` | 1 | Web suggestions in the search box |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarDa` | 0 | Widgets button (Windows may refuse this one; see [Tips](#tips-and-known-issues)) |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarMn` | 0 | Chat/Teams button |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowTaskViewButton` | 0 | Task View button |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowCopilotButton` | 0 | Copilot button |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Start_IrisRecommendations` | 0 | Start menu recommendations |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Start_AccountNotifications` | 0 | Account notifications in Start |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowSyncProviderNotifications` | 0 | OneDrive/sync ads in File Explorer |
| `Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo` | `Enabled` | 0 | Advertising ID |
| `Software\Microsoft\Windows\CurrentVersion\Privacy` | `TailoredExperiencesWithDiagnosticDataEnabled` | 0 | Tailored experiences |
| `Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement` | `ScoobeSystemSettingEnabled` | 0 | "Finish setting up your device" prompts |
| `Control Panel\International\User Profile` | `HttpAcceptLanguageOptOut` | 1 | Websites reading your language list |
| `Software\Policies\Microsoft\Windows\CloudContent` | `DisableWindowsSpotlightFeatures` | 1 | Windows Spotlight |

Also set to `0` under `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager`
(Windows' suggested content, preinstalled and silently installed apps, tips, and
lock-screen ads):

`ContentDeliveryAllowed`, `FeatureManagementEnabled`, `OemPreInstalledAppsEnabled`,
`PreInstalledAppsEnabled`, `PreInstalledAppsEverEnabled`, `SilentInstalledAppsEnabled`,
`SoftLandingEnabled`, `SystemPaneSuggestionsEnabled`, `RotatingLockScreenEnabled`,
`RotatingLockScreenOverlayEnabled`, `SubscribedContent-310093Enabled`,
`SubscribedContent-338387Enabled`, `SubscribedContent-338388Enabled`,
`SubscribedContent-338389Enabled`, `SubscribedContent-338393Enabled`,
`SubscribedContent-353694Enabled`, `SubscribedContent-353696Enabled`,
`SubscribedContent-353698Enabled`, `SubscribedContent-88000326Enabled`

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
| `710sRice restart` | Stop the stack and start it again (SUPER+Shift+R only restarts what it has to) |
| `710sRice reload` | Reload the whole stack, same as SUPER+Shift+R |
| `710sRice reload bar` | Restart just the bar |
| `710sRice logs` | Open the logs folder and list what's in it |
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
| `palette` | Re-themes everything from the wallpaper you have now (no wallpaper change) |
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
colors and default shell, Flow Launcher settings, taskbar, Windows settings, PowerShell
profile and Defender exclusions are restored, not reset to defaults. The installer saves
each one the first time it changes it.

Packages: anything the installer added is removed, except rows marked **Pre-existing? yes**
in [versions.md](versions.md) (common tools you may well have had already, like Windows
Terminal and Everything).

- `-Keep <Install ID>` keeps a package that would otherwise be removed, e.g.
  `710sRice uninstall -Keep ShareX.ShareX`. Several at once:
  `-Keep ShareX.ShareX,Flow-Launcher.Flow-Launcher`.
- `-Force` removes the Pre-existing rows too.

It forgets your elevated-tiling choice, so a later install starts from the default again.
It also takes the `710sRice` command off your PATH; `.\710sRice.ps1` in the repo folder still
works, for a reinstall.
It doesn't delete the repo folder, your weather variables, or your personal files
(`user.ahk`, `user.ps1`, `rules.local.toml`, `config/windows.toml`). Delete the folder
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
| SUPER+Alt+Space | Main menu: apps, capture, tiling, game mode, reload, quit |
| SUPER+Esc | Power menu: lock, sleep, restart, shut down... |
| SUPER+K | This hotkey list |
| SUPER+X | Close the window |
| SUPER+W | Wallpaper gallery |
| SUPER+B / SUPER+E | Browser / File Explorer |
| SUPER+Shift+A | Claude desktop app |
| SUPER+Shift+R | Reload the whole stack (re-applies config and rules) |
| SUPER+Arrows | Move focus |
| SUPER+Shift+Arrows | Move the window |
| SUPER+Alt+Arrows | Stack the window with its neighbor (tabs show on the stack); SUPER+Alt+, / SUPER+Alt+. switch tabs, SUPER+Alt+U unstacks |
| SUPER+1…9 | Go to workspace 1–9 |
| SUPER+Shift+1…9 | Move the window to workspace 1–9 |
| SUPER+F / SUPER+T | Monocle (fill the screen) / float or tile the window |
| SUPER+R / SUPER+P | Retile / pause tiling |
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

Three optional files are yours alone. Git ignores them, so neither `710sRice update` nor `git pull` touches them:

- `config/ahk/user.ahk` — your own hotkeys. It's loaded after `710.ahk` if it exists, and
  SUPER+K lists its hotkeys too. Reload with SUPER+Shift+R.
- `config/pwsh/user.ps1` — your own PowerShell profile additions, loaded last by
  `config/pwsh/profile.ps1`. Open a new terminal to pick up changes.
- `config/komorebi/rules.local.toml` — your own app rules. Quick add rule writes it for you;
  see [App rules](#app-rules).

## Wallpapers and theming

Change the wallpaper with **SUPER+W** (or the wallpaper button on the bar) and everything
recolors to match: the bar, komorebi's window borders, the Windows accent color, Windows
Terminal, the prompt, the menus and the lock screen. wallust does the color picking.

The gallery shows two folders:

- `assets/wallpapers` in this repo, the wallpapers that ship with it.
- Your own folder, from the `YASB_WALLPAPER_PATH` variable (subfolders included). It isn't
  set by default. To use one:

  ```powershell
  setx YASB_WALLPAPER_PATH "C:\Users\<you>\Pictures\Wallpapers"
  ```

  then restart the bar so it sees the new variable: `710sRice reload bar`.

For more folders, add lines to `image_path` under the `wallpapers:` widget in
`config/yasb/config.yaml`:

```yaml
      image_path:
        - "$env:DESKTOPRICE_HOME\\assets\\wallpapers"
        - "$env:YASB_WALLPAPER_PATH"
        - "D:\\Art\\Backgrounds"
```

## App rules

Rules decide which windows komorebi tiles, floats or leaves alone. They come in four
layers, lowest to highest priority, and SUPER+Shift+R compiles them into komorebi's config:

1. The community rules in `vendor/asc` (a pinned copy, updated deliberately).
2. `games.toml`: game launchers and games, so they're never tiled. Game mode (in the main
   menu) shows when one is running.
3. `config/komorebi/rules.toml`: the rules this repo ships, tracked in git. Currently two:
   WinUI 3 apps (the new Photos app and others) stay opaque when unfocused, because
   komorebi's transparency stops them taking clicks; and the Claude desktop app is tiled
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
| Opaque (never translucent) | Keeps it solid when unfocused, for apps that stop taking clicks when translucent | The next time you click it |

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
