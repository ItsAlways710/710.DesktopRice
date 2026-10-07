# Map: what lives where

Read this before changing anything in the install / uninstall / doctor / repair / update side or in
710.ahk. It says which file owns each piece of 710sRice: its install step, what uninstall puts back,
doctor's checks for it, what repair and `710sRice update` do for it. Any change that moves code,
adds a module or adds a check updates this file in the same commit.

## Rules for changing the code

- **The big files only get smaller.** `config\ahk\710.ahk`, `tools\lib\activation.ps1`,
  `tools\lib\doctor.ps1`, `710sRice.ps1`, `install.ps1`, `tools\lib\packages.ps1`, `uninstall.ps1`,
  and, when they're touched, `tools\palette-editor.ps1`, `tools\lib\palette.ps1`,
  `tools\components\flow.ps1`, `tools\compile-komorebi-rules.ps1` and `tools\reload-stack.ps1`. A
  big file grows only by the line that calls a new module, a comment fix, or a module call that got
  longer.
- **Touching code in a big file that belongs in a module moves it out, whole:** the piece's install
  part with its uninstall, doctor, repair and update parts. A comment-only fix can stay.
- **New work is born as a module**, with the doctor check (and its fix) that doctor and update need.
- **A module is the simplest thing that fits:** a component (`tools\components\<id>.ps1`, see its
  README) when the piece is an install step with an uninstall part and checks; a plain
  single-purpose script otherwise.
- **A change existing installs need ships as a doctor check with its fix**, never a migration
  script: repair, and so `710sRice update`, applies it.

## How it runs

| Entry point | What it is | Loads |
|---|---|---|
| `710sRice.ps1` (`bin\710sRice.cmd` runs it) | The `710sRice` command: the verb table, help, the admin hand-off; each verb runs a script or a library function | `tools\lib\steps.ps1` always; per verb: `activation.ps1`, `packages.ps1`, `doctor.ps1`, `repair.ps1`, `update.ps1`, `palette.ps1`, `switch.ps1` |
| `install.ps1` | Install: its switches, the step order, every fixed step's body, the closing lines | `steps.ps1` (and with it `components.ps1`), `activation.ps1`, `packages.ps1` |
| `uninstall.ps1` | Uninstall: stop, revert, remove, in a fixed order | `activation.ps1`, `packages.ps1` |
| `scripts\Start-All.ps1` / `Stop-All.ps1` | `710sRice start` / `stop` (and SUPER+Ctrl+R through 710.ahk) | `activation.ps1` |
| `scripts\Start-Komorebi.ps1`, `Start-Ahk.ps1`, `Start-Yasb.ps1` | What komorebi's and 710.ahk's tasks run (through `tools\lib\run-hidden.vbs`); `Start-Yasb.ps1` is what 710.ahk runs for the bar | `Start-Yasb.ps1`: `tools\lib\bluetooth.ps1` |
| `scripts\Set-LockScreen.ps1` | Sets your lock-screen picture (Windows PowerShell 5.1: WinRT) | — |
| `tools\reload-stack.ps1` | SUPER+Shift+R (710.ahk's ReloadStack) and `reload bar` | — |
| `tools\apply-wallust-outputs.ps1` | The wallpaper pipeline: wallust, then every palette target | `tools\lib\lockscreen.ps1`, `tools\lib\palette.ps1` |
| `config\ahk\710.ahk` | The hotkeys, menus, and the apps it starts | `config\ahk\user.ahk` (last, optional) |

`tools\lib\activation.ps1` is what every install-side script loads: it loads the shared libraries
(below), `tools\lib\lockscreen.ps1` and `tools\lib\components.ps1`, and holds the pieces that haven't
moved into modules yet. Callers define `Step-Ok`, `Step-Info` and `Step-Warn` before loading it.

## Install steps

In install's order (`710sRice install -?` lists them). Fixed steps live in `install.ps1`'s `$Steps`
table and in `tools\lib\steps.ps1`'s list; components are `tools\components\<id>.ps1`, spliced in
after their `After` step. Doctor's check Ids are what its report lines carry; repair runs the step
named on an `[XX]` line (`Step`) or the action named (`Repair`).

| Step | Install | Uninstall puts back | Doctor (check Ids) | Repair / update |
|---|---|---|---|---|
| packages | `install.ps1`; winget helpers, probes, move-to-pin in `tools\lib\packages.ps1` | `uninstall.ps1` sections 5 (pins), 6 (packages; the Nerd Font through `Invoke-MsiUninstall` after `Clear-TerminalNerdFontFaces`), 8 (PSGallery modules) | `doctor.ps1` group b: `pkg:*`, `pins`, `pkg:shell-tools` | `Step=packages` |
| upgrade (named only) | `install.ps1`; `Invoke-MoveToPin` in `packages.ps1` | — | `pkg:*` "older than its pin" | `Step=upgrade` |
| envvars | `install.ps1` (also removes the old weather variables) | `uninstall.ps1` section 4 | `doctor.ps1` `envvars`, `weather-vars`, `weather` | `Step=envvars` |
| bluetooth | `tools\components\bluetooth.ps1` (+ `tools\lib\bluetooth.ps1`) | same file | `bluetooth` | `Step=bluetooth` |
| commands | `tools\components\commands.ps1` | same file | `commands` | `Step=commands` |
| path | `install.ps1`; PATH helpers in `tools\lib\userenv.ps1` | `uninstall.ps1` section 4 | `doctor.ps1` `path` | `Step=path` |
| wallust | `install.ps1`; `tools\install-wallust.ps1`, `tools\write-wallust-config.ps1` | `uninstall.ps1` sections 7 (binary), 9 (`wallust.toml`) | `doctor.ps1` `wallust`, `wallust-toml` | `Step=wallust` |
| flow | `tools\components\flow.ps1` | same file | `flow`, `flow-startup`, `flow-prefs`, `flow-font`, `flow-fullscreen` | `Step=flow` |
| everything | `tools\components\everything.ps1` | same file | `everything`, `everything-settings` | `Step=everything` |
| sharex | `tools\components\sharex.ps1` | same file | `sharex`, `sharex-startup` | `Step=sharex` |
| theme | `install.ps1`; the pipeline `tools\apply-wallust-outputs.ps1`; the wallpaper and its snapshot in `tools\lib\wallpaper.ps1` | `uninstall.ps1` section 3 (wallpaper: `Restore-OriginalWallpaper`; accent, Flow theme: restore functions in `activation.ps1`), section 9 (generated palette files); Terminal's colours: the terminal component | (see palette) | never run by repair |
| palette (named only) | `install.ps1` (the pipeline on the current wallpaper) | — | `doctor.ps1` `palette-profile`, `theme-files`, `theme-inputs`, `palette-last`, `flow-theme`; the terminal component's `terminal`; `lock-screen` (`tools\lib\lockscreen.ps1`) | `Step=palette` |
| monitors | `install.ps1`; `tools\write-display-index.ps1`, `tools\lib\monitors.ps1` | `uninstall.ps1` section 9 (`display-index.local.json`) | `doctor.ps1` `display-index`, `display-index-more` | `Step=monitors`, `Repair=reload` |
| defender | `tools\components\defender.ps1` | same file | `defender` | `Step=defender` |
| profile | `install.ps1` → `Install-ShellProfile` in `activation.ps1` | `uninstall.ps1` section 3 → `Remove-ShellProfile` | `doctor.ps1` `profile` | `Step=profile` |
| terminal | `tools\components\terminal.ps1` (default shell, font; font helpers in `tools\lib\terminal.ps1`) | same file (`Restore-WindowsTerminalSettings`: default shell, font, the palette's colour scheme) | `terminal`, `terminal-default`, `terminal-font` | `Step=terminal` (`terminal`: `Step=palette`) |
| compile | `install.ps1` → `tools\compile-komorebi-rules.ps1` | `uninstall.ps1` section 9 (`komorebi.json`) | `doctor.ps1` `komorebi-json`, `komorebi-json-warnings`, `asc` | `Step=compile`, `Repair=reload` |
| tasks | `install.ps1` (tiling mode, the tasks; then the lock screen's part, `Install-LockScreen` in `tools\lib\lockscreen.ps1`); registering them in `activation.ps1`, task plumbing in `tools\lib\tasks.ps1` | `uninstall.ps1` section 2 (`Unregister-Autostart`; `Undo-LockScreenSync`), section 9 (`tiling-mode.txt`) | `doctor.ps1` `mode`, `task:*`, `task:retired`, `tiling`; `lock-screen:old` (`lockscreen.ps1`) | `Step=tasks`, `Repair=tiling:<mode>` |
| windows (-Activate) | `install.ps1` → `Install-FullTimeWindowsSettings` in `tools\lib\fulltime.ps1` | `uninstall.ps1` section 2 → `Restore-FullTimeWindowsSettings` (`fulltime.ps1`) | `windows` (`fulltime.ps1`) | `Step=windows` |

## Pieces without a step of their own

| Piece | Where |
|---|---|
| The full-time switch | `710sRice activate` / `deactivate`: `tools\lib\switch.ps1` (`Invoke-RiceSwitch`, `Invoke-Rice(De)Activate`; loaded by their rows in `710sRice.ps1`); full time's Windows settings -- saved, applied, put back (`Save-FullTimeSettings`, `Set-` / `Restore-FullTimeWindowsSettings`), install -Activate's save (`Save-FullTimeSettingsOnActivate`, from the tasks step) and its windows step (`Install-FullTimeWindowsSettings`), doctor's `windows`: `tools\lib\fulltime.ps1`; the mode is read from the tasks (`Test-FullTimeMachine`, `activation.ps1`) |
| The stack: start, stop, restart, reload | `scripts\Start-All.ps1`, `Stop-All.ps1`; `restart` / `reload` / `reload bar` in `710sRice.ps1`; in `activation.ps1`: `Start-StackFromTasks`, `Stop-RunningComponents`, `Get-RunningStackNames`, `Start-AhkFromTask`, `Restart-AhkFromTask`, `Start-AhkStartedApps` (asks 710.ahk), the retired start tasks (`Remove-RetiredStartTasks`, `Request-RetiredAppsRestart`); doctor's `stack:*`, `stack`, `paused`; repair's starts (`Start-RepairComponents`, `tools\lib\repair.ps1`) |
| The lock screen | `scripts\Set-LockScreen.ps1` (sets it, takes its snapshots); everything else in `tools\lib\lockscreen.ps1`: running the setter and its record (the pipeline's), install's part (`Install-LockScreen`, from the tasks step), uninstall's (`Undo-LockScreenSync` in section 2, `Undo-LockScreenPicture` in section 3), the restores (`Restore-LockScreenPolicy`, `Restore-LockScreenPicture`), `Set-LockScreenToWallpaper`, doctor's `lock-screen*` lines (`Test-DoctorLockScreen`); `deactivate` sets it again (`Set-RiceSwitchLockScreen`, `710sRice.ps1`) |
| Tiling mode (elevated komorebi) | `Get-TilingMode`, `Resolve-TilingMode`, `Get-KomorebiRunLevel` (`activation.ps1`); `710sRice tiling` (`710sRice.ps1`); doctor's `tiling` |
| Palette profiles and the theme | `tools\lib\palette.ps1`, `palette-edit.ps1`, `tools\palette-editor.ps1` / `.xaml`, `tools\palette\targets\*` (one file per themed app; README there), `tools\apply-wallust-outputs.ps1`; `710sRice palette ...` in `710sRice.ps1` |
| Tiling rules | `tools\compile-komorebi-rules.ps1` (`config\komorebi\base.json`, `rules.toml`, `rules.local.toml`, `games.toml`, `vendor\asc`), `tools\add-rule.ps1`, `tools\remove-rule.ps1`, `tools\update-asc.ps1` |
| Screens | `tools\screens.ps1`, `tools\lib\monitors.ps1`, `tools\write-display-index.ps1` |
| doctor / repair / update | `tools\lib\doctor.ps1` (the checks, the groups, the repair plan, the report), `tools\lib\repair.ps1` (the rounds, starting what's down), `tools\lib\update.ps1` (the pull, then repair from the new files) |

## Shared libraries

| File | What's in it |
|---|---|
| `tools\lib\activation.ps1` | Loads the libraries below. Still holds, until each moves into its module: registering the tasks and reading the mode (`Register-Autostart`, `Register-OnDemandTasks`, `Unregister-Autostart`, `Test-FullTimeMachine`); the tiling mode; the stack's starts and stops (`Start-StackFromTasks`, `Stop-RunningComponents`, `Start-AhkStartedApps`, the retired start tasks); the shell profile hook; the accent and Flow-theme restores |
| `tools\lib\text.ps1` | Printing paths and names safely: `ConvertTo-SafePath`, `ConvertTo-SafeText` (never a user name), `Join-RiceNameList` |
| `tools\lib\snapshots.ps1` | The original-state snapshots uninstall puts back (`Save-` / `Get-` / `Remove-OriginalState`), one registry value as a snapshot (`Get-RegValueSnapshot`, `Set-RegValueFromSnapshot`), `Backup-RegistryKey` (reg.exe export to `backups\`) |
| `tools\lib\userenv.ps1` | User environment variables (`Get-` / `Set-` / `Remove-UserEnvVar`), the user PATH read and written raw (`Add-` / `Remove-UserPathEntry`, `Get-UserPathRaw`, `Test-SamePathEntry`), `Send-SettingChangeBroadcast` |
| `tools\lib\wallpaper.ps1` | `Set-DesktopWallpaper`, `Get-CurrentWallpaper`, and the wallpaper's own snapshot (`Save-` / `Restore-OriginalWallpaper`) |
| `tools\lib\apps.ps1` | Where the stack's apps are: `Get-KomorebiExe`, `Get-KomorebicExe`, `Get-YasbcExe`, `Get-AhkExe` (UI Access first), `Get-ShareXExe` |
| `tools\lib\tasks.ps1` | The task folder (`$script:TaskFolder`), `Get-TaskFullName`, `Test-Task`, `New-TaskXml`, `ConvertTo-HiddenLaunch` (run-hidden.vbs and its launch file), `Get-ComponentTaskInfo`, `Start-AsUser` |
| `tools\lib\elevation.ps1` | `Test-IsAdmin`, `Get-ProcessElevation` |
| `tools\lib\ahk.ps1` | Talking to the running 710.ahk: `Find-AhkWindow`, `Send-AhkMessage`, `Send-AhkQuit`, `Get-AhkWindowProcessId` |
| `tools\lib\shortcuts.ps1` | `Save-RiceShortcut`, `Read-RiceShortcut`, `Get-StartMenuProgramsDir` |
| `tools\lib\explorer.ps1` | Explorer's one restart (`Restart-Explorer`, `Wait-ExplorerRunning`, `Test-ExplorerShell`) and the tray icons kept around it (`Backup-` / `Restore-TrayIconPromotions`) |
| `tools\lib\fonts.ps1` | `Get-NerdFontFace`: the JetBrainsMono Nerd Font's face name, as Windows has it registered |
| `tools\lib\fulltime.ps1` | Full time's Windows settings (taskbar auto-hide, the hardening, the Startup delay): saved, applied, put back; install -Activate's save and windows step; doctor's `windows` line |
| `tools\lib\switch.ps1` | `710sRice activate` / `deactivate` (dispatcher-only: loaded by their rows) |
| `tools\lib\terminal.ps1` | Windows Terminal's font faces (`Get-TerminalFontFaces`, `Set-TerminalFontFace`) and `Clear-TerminalNerdFontFaces` (uninstall, before the Nerd Font goes) |
| `tools\lib\packages.ps1` | `versions.md`'s table, winget's sources and exit codes, `Invoke-WingetAsUser`, the MSI uninstall, the installed-version probes, `Compare-PinVersion`, moving a package to its pin |
| `tools\lib\components.ps1` | The component loader and the step order (`Get-RiceComponents`, `Get-RiceStepOrder`, `Invoke-RiceComponentPart`, `New-RiceComponentContext`) |
| `tools\lib\steps.ps1` | install's fixed steps and the named-only ones |
| `tools\lib\lockscreen.ps1` | The lock screen, but for its setter script (see Pieces): `Invoke-LockScreenSetter` and its record (the pipeline's, no dependencies), install's and uninstall's parts, the restores, doctor's check |
| `tools\lib\monitors.ps1` | The screen-number map (`display-index.local.json`) |
| `tools\lib\bluetooth.ps1` | Does this machine have a Bluetooth adapter |
| `tools\lib\palette.ps1`, `palette-edit.ps1` | Palette profiles, targets, the theme stamp |
| `tools\lib\run-hidden.vbs` | Starts a task's program with no console window |

## Doctor's report

Groups in report order, each check's function in `tools\lib\doctor.ps1` unless named otherwise.
Component checks come at the end of their group, in install's order.

| Group | Checks |
|---|---|
| (header) | `update` (`Get-DoctorUpdateResult`), `local-changes` |
| Repo and command | `path`, `envvars`, `weather` |
| Packages and pins | `pkg:*` (`Test-DoctorPinnedPackages`), `pins`, `wallust`, other packages (`Test-DoctorOtherPackages`) |
| Stack | `stack` / `stack:*` (`Test-DoctorStack`), `paused` |
| Tasks and tiling mode | `mode`, `task:*`, `task:retired` (`Test-DoctorTasks`), `tiling` |
| Generated configs | `komorebi-json`, `asc`, `display-index`, `wallust-toml`, `palette-profile`, `theme-files`, `theme-inputs`, `palette-last`, `lock-screen` (`Test-DoctorLockScreen`, `tools\lib\lockscreen.ps1`) |
| Integrations | `flow-theme`, `profile`, `windows` (`Test-DoctorWindowsSettings`, `fulltime.ps1`); then bluetooth, commands, flow, everything, sharex, defender, terminal (`terminal`, `terminal-default`, `terminal-font`) (components) |
| Conflicts and leftovers | `conflicts`, `komorebi-scripts` |

## 710.ahk

One file, in this order (each section starts with a `; ====` banner; SUPER+K lists the hotkeys
under these titles):

| Section | What's in it |
|---|---|
| (top) | Directives, the environment it cleans, the paths and state folder |
| komorebi | `Komorebic`, `QueryKomorebic`, `ToggleScrolling`, `LaunchOnCursorMonitor`, `CloseWindow`, `RedrawApp`, `EndGpuHelpers`; the window, focus, move, stack, resize, workspace and monitor hotkeys |
| ShareX | `Sharex()` and the capture hotkeys |
| App launchers | browser, Explorer, web apps, Obsidian, Claude |
| Palette | `PalOpen` and the themed popup every menu uses |
| Key overlay | SUPER+K: `ParseKeymap` (reads 710.ahk and user.ahk), `ToggleKeyOverlay` |
| Power / system menu | SUPER+Esc |
| Terminal | SUPER+Return |
| Flow Launcher | `ToggleFlow`, `ToggleFlowScoped`; SUPER+Space, SUPER+S |
| Stay awake | |
| Game mode | `games.toml`, `GameWatch` |
| The apps 710.ahk starts | `StartApps` (the bar, Flow, ShareX), `RestartRetired`, the start at load |
| YASB watchdog | |
| komorebi's monitor watcher | display-change nudges |
| Screens | the Screens menu, `RunThen` |
| Quick add rule | click-to-pick rules; Remove a rule / Edit my rules |
| Tray + main menu | the menus' items, the messages 710sRice posts (`OnMessage`), `RiceCommands`, the tray, `ReloadStack`, `RestartStack` |
| Palette profiles | choosing, creating and editing profiles from the menu |
| User overrides | `#Include *i %A_ScriptDir%\user.ahk` -- always the last line |

Doctor's "710.ahk changed since it started" compares `710.ahk` and `user.ahk` with 710.ahk's start
time (`Get-DoctorStaleText`). `scripts\Start-Ahk.ps1` and every `Find-AhkWindow` find 710.ahk by its
window title (the script's full path).
