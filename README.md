# 710.DesktopRice

A keyboard-first tiling desktop for Windows 11, themed from your wallpaper.

| Piece | What it does here |
| --- | --- |
| [komorebi](https://github.com/LGUG2Z/komorebi) | Tiling window manager: workspaces, layouts, borders |
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

You don't have to set anything up ahead of time. `install.ps1` asks for two values:

- `YASB_WEATHER_API_KEY` — your weatherapi.com key
- `YASB_WEATHER_LOCATION` — a zip/postal code or city name

It only asks for the ones that aren't set yet, never prints what's stored, and Enter skips.
Skip them and the widget shows an error until they're set; re-run the installer or set them
yourself:

```powershell
setx YASB_WEATHER_API_KEY "your-key"
setx YASB_WEATHER_LOCATION "your zip or city"
```

They're stored as your own Windows user variables, never in the repo, and uninstall leaves
them alone.

The widget shows **°F**. For °C, open `config/yasb/config.yaml`, find the `weather:` widget
and change `units: "imperial"` to `units: "metric"`.

## Requirements

- Windows 11
- winget (built into current Windows 11)
- **PowerShell 7, installed first.** Every script here needs it, including the installer,
  so install it before anything else:

  ```powershell
  winget install --id 9MZ1SNWT0N5D --source msstore
  ```

  That's the Microsoft Store build, the same package `install.ps1` checks for. It isn't
  tied to a version: it installs the current release and keeps itself updated, and
  nothing here cares which 7.x you have. If the Store is blocked on your machine,
  `winget install --id Microsoft.PowerShell --source winget` works too.
- An **admin** PowerShell 7 window for `install.ps1` and `uninstall.ps1` (Defender
  exclusions and the lock-screen image need it).

Clone the repo wherever you like. The installer records its location in
`DESKTOPRICE_HOME`, and everything else finds it from there.

```powershell
git clone https://github.com/ItsAlways710/710.DesktopRice.git
cd 710.DesktopRice
```

## Install

There are two ways to run it: **full-time**, where it's your desktop from the moment you sign
in, or **on demand**, where you start it when you want it and stop it when you don't.

### What install always does

Either way, `install.ps1`:

- Installs the packages with winget. komorebi, YASB, AutoHotkey, Flow Launcher and
  Everything are **pinned** to tested versions so a `winget upgrade --all` can't move them
  out from under the config; the rest take whatever is current. [versions.md](versions.md)
  lists every package, its version and where it comes from.
- Installs wallust (a checksum-verified release download; there's no winget package).
- Points komorebi and YASB at this repo's config folders.
- Adds Windows Defender exclusions for ShareX, Everything, komorebi, PowerShell 7 and this
  repo (without them, the first capture or hotkey of a session lags while Defender scans).
- Hooks `config/pwsh/profile.ps1` into your PowerShell profile.
- Sets Windows Terminal's default shell to PowerShell 7.
- Sets up Flow Launcher: `app` searches apps, `f` searches files through Everything, and it
  opens with an empty search box.
- Sets the default wallpaper and themes everything from it.
- Removes the desktop shortcuts the installers drop (Flow Launcher and ShareX add one; ones
  you already had are left alone).

### Full-time: `-Activate`

From an admin PowerShell 7 window in the repo folder:

```powershell
.\install.ps1 -Activate
```

On top of the above, this:

- Starts komorebi, YASB, AutoHotkey and ShareX at every sign-in, through Scheduled Tasks
  that never run elevated.
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
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarDa` | 0 | Widgets button (Windows may refuse this one; see [Tips](#tips-and-troubleshooting)) |
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

Run the installer without `-Activate`:

```powershell
.\install.ps1
```

Nothing starts at sign-in and none of the Windows changes above are made. See
[Run on demand](#run-on-demand).

### Updating

```powershell
git pull
.\install.ps1          # add -Activate if that's how you run it
```

Re-running the installer is always safe; it only changes what's missing or out of date.
There's no separate update checker, by design.

`.\install.ps1 -SkipPackages` skips the winget step and redoes everything else (config,
theme, Flow setup), which is quicker when only the repo changed.

## Run on demand

From a **normal** (not admin) PowerShell 7 window in the repo folder:

```powershell
.\scripts\Start-All.ps1
```

It never starts anything elevated (an admin AutoHotkey would open admin Terminals that
komorebi can't tile), so run it from a normal window. It checks what came up and says so.

To stop, use `.\scripts\Stop-All.ps1` or **Quit 710sRice** in the tray icon's menu. Flow
Launcher and Everything keep running either way; they're ordinary apps you can use on
their own.

The taskbar is left to you. The stack is built around a hidden taskbar, so `Start-All`
tells you how to turn auto-hide on if it's off, and `Stop-All` reminds you to turn it back
off. Neither changes it.

## Uninstall

From an admin PowerShell 7 window in the repo folder:

```powershell
.\uninstall.ps1 -DryRun    # show what it would do, change nothing
.\uninstall.ps1
```

This is a real uninstall: it stops everything, removes the sign-in tasks, and puts back
what was there before. Your original wallpaper, lock screen, accent color, Windows Terminal
colors and default shell, Flow Launcher settings, taskbar, Windows settings, PowerShell
profile and Defender exclusions are restored, not reset to defaults. The installer saves
each one the first time it changes it.

Packages: anything the installer added is removed, except rows marked **Pre-existing? yes**
in [versions.md](versions.md) (common tools you may well have had already, like Windows
Terminal and Everything).

- `-Keep <Install ID>` keeps a package that would otherwise be removed, e.g.
  `.\uninstall.ps1 -Keep ShareX.ShareX`.
- `-Force` removes the Pre-existing rows too.

It doesn't delete the repo folder, your weather variables, or your personal files
(`user.ahk`, `user.ps1`, `config/windows.toml`). Delete the folder yourself if you're done
with it.

## Hotkeys

**SUPER+K** lists every hotkey, searchable. The ones to know first:

| Keys | What it does |
| --- | --- |
| SUPER+Enter | Windows Terminal (opens on the monitor under the mouse) |
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
| SUPER+1…9 | Go to workspace 1–9 |
| SUPER+Shift+1…9 | Move the window to workspace 1–9 |
| SUPER+F / SUPER+T | Monocle (fill the screen) / float or tile the window |
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

Two optional files are yours alone. Git ignores them, so `git pull` never touches them:

- `config/ahk/user.ahk` — your own hotkeys. It's loaded after `710.ahk` if it exists, and
  SUPER+K lists its hotkeys too. Reload with SUPER+Shift+R.
- `config/pwsh/user.ps1` — your own PowerShell profile additions, loaded last by
  `config/pwsh/profile.ps1`. Open a new terminal to pick up changes.

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

  then press SUPER+Shift+R to restart the bar.

For more folders, add lines to `image_path` under the `wallpapers:` widget in
`config/yasb/config.yaml`:

```yaml
      image_path:
        - "$env:DESKTOPRICE_HOME\\assets\\wallpapers"
        - "$env:YASB_WALLPAPER_PATH"
        - "D:\\Art\\Backgrounds"
```

## App rules

Rules decide which windows komorebi tiles, floats or leaves alone. They come from three
layers, lowest to highest priority, and SUPER+Shift+R compiles them into komorebi's config:

1. The community rules in `vendor/asc` (a pinned copy, updated deliberately).
2. `games.toml`: game launchers and games, so they're never tiled. Game mode (in the main
   menu) shows when one is running.
3. `config/komorebi/rules.toml`: your own overrides. It's tracked in git, so your rules
   follow you to every machine. It ships with one: WinUI 3 apps (the new Photos app and
   others) stay opaque when unfocused, because komorebi's transparency stops them taking
   clicks.

The easy way to add a rule: **SUPER+Alt+Space → Tiling → Quick add rule...**, click the
window, then pick what to match on (its program, window class or title) and whether to
float, ignore or force-tile it. It's written to `rules.toml` and applied right away.

Windows running as administrator always float. komorebi (running as you) isn't allowed to
move them, and it keeps admin windows out of the way of your hotkeys.

## Tips and troubleshooting

- **Hotkeys do nothing?** If an admin window has focus (for example, the one you just ran
  the installer in), Windows won't let the hotkeys through. Click any normal window.
- **Widgets button still on the taskbar?** Windows won't let a script hide it. Turn it off
  in Settings > Personalization > Taskbar.
- **Admin commands in a normal, tiled Terminal:** turn on Windows 11's `sudo` (Settings >
  System > For developers > Enable sudo, "Inline" mode) and run `sudo <command>`.
- **Something not right?** SUPER+Shift+R reloads the whole stack and re-applies the
  config. Logs are in `%LOCALAPPDATA%\710.DesktopRice\`.

## Future plans

- **Update this README.**
- **Window slots.** Pin an app to the monitor, workspace and tile position you choose, and
  it goes back there every time it opens. Move a pinned app yourself and it learns the new
  spot.
