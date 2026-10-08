# Map: what lives where

Read this before changing anything in the install / uninstall / doctor / repair / update side or in
710.ahk. It says which file owns each piece of 710sRice: its install step, what uninstall puts back,
doctor's checks for it, what repair and `710sRice update` do for it. Any change that moves code,
adds a module or adds a check updates this file in the same commit.

## Rules for changing the code

- **The big files only get smaller.** `config\ahk\710.ahk`, `tools\lib\activation.ps1`,
  `tools\lib\doctor.ps1`, `710sRice.ps1`, `install.ps1`, `uninstall.ps1`,
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
| `710sRice.ps1` (`bin\710sRice.cmd` runs it) | The `710sRice` command: the verb table, help, the admin hand-off; each verb runs a script or a library function | `tools\lib\steps.ps1` and `console.ps1` always; per verb: `activation.ps1`, `doctor.ps1`, `repair.ps1`, `update.ps1`, `palette.ps1`, `switch.ps1`, `stack-commands.ps1`, `palette-commands.ps1`, `logs.ps1` |
| `boot.ps1` | The one-line install (`irm ... \| iex`, Windows PowerShell 5.1): git and PowerShell 7 if missing, the clone (`C:\710.DesktopRice` or `DESKTOPRICE_HOME`; one already there is used as it is), then `710sRice.ps1 install` | — |
| `install.ps1` | Install: its switches, the step order, the closing lines; each fixed step's body is in its module (`tools\steps\<step>.ps1`) | `steps.ps1` (and with it `components.ps1`), `activation.ps1` |
| `uninstall.ps1` | Uninstall: stop, revert, remove, in a fixed order | `activation.ps1` |
| `scripts\Start-All.ps1` / `Stop-All.ps1` | `710sRice start` / `stop` (and SUPER+Ctrl+R through 710.ahk) | `activation.ps1` |
| `scripts\Start-Komorebi.ps1`, `Start-Ahk.ps1`, `Start-Yasb.ps1` | What komorebi's and 710.ahk's tasks run (through `tools\lib\run-hidden.vbs`); `Start-Yasb.ps1` is what 710.ahk runs for the bar | `Start-Ahk.ps1`: `tools\lib\ahk-load.ps1` (it checks 710.ahk loads first); `Start-Yasb.ps1`: `tools\lib\bluetooth.ps1` |
| `scripts\Set-LockScreen.ps1` | Sets your lock-screen picture (Windows PowerShell 5.1: WinRT) | — |
| `tools\reload-stack.ps1` | SUPER+Shift+R (710.ahk's ReloadStack) and `reload bar` | — |
| `tools\apply-wallust-outputs.ps1` | The wallpaper pipeline: wallust, then every palette target | `tools\lib\lockscreen.ps1`, `tools\lib\palette.ps1` |
| `config\ahk\710.ahk` | The hotkeys, menus, and the apps it starts | its parts, `config\ahk\710\*.ahk` (see 710.ahk below), then `config\ahk\user.ahk` (last, optional) |

`tools\lib\activation.ps1` is what every install-side script loads: it loads the shared libraries
(below), `tools\lib\lockscreen.ps1`, `tools\lib\components.ps1` and the fixed steps' modules
(`tools\steps\`); it has no code of its own. Callers define `Step-Ok`, `Step-Info` and `Step-Warn`
before loading it.

## Install steps

In install's order (`710sRice install -?` lists them). Fixed steps are listed in `tools\lib\steps.ps1`
and run from `install.ps1`'s `$Steps` table; a fixed step's module, `tools\steps\<step>.ps1`, holds
its install part, the parts of uninstall that put it back, and doctor's checks for it (uninstall and
doctor keep the order: uninstall's sections, doctor's groups). Components are
`tools\components\<id>.ps1`, spliced in after their `After` step. Doctor's check Ids are what its
report lines carry; repair runs the step named on an `[XX]` line (`Step`) or the action named
(`Repair`).

| Step | Install | Uninstall puts back | Doctor (check Ids) | Repair / update |
|---|---|---|---|---|
| packages | `tools\steps\packages.ps1` (`Install-PackagesStep`); versions.md's table in `tools\lib\versions.ps1`, winget in `winget.ps1`, the probes in `probes.ps1`, the move to a pin in `topin.ps1` | `uninstall.ps1` decides what goes (versions.md's Pre-existing?, -Keep, -Force); section 5 (pins: `Remove-WingetPins`) and 6 (packages: `Uninstall-WingetPackage` -- the Nerd Font through `Invoke-MsiUninstall`, `tools\lib\msi.ps1`, after `Clear-TerminalNerdFontFaces`) in `tools\steps\packages.ps1`; 8 (PSGallery modules) in `uninstall.ps1` | `pkg:*`, `pins`, `pkg:shell-tools` (`tools\steps\packages.ps1`) | `Step=packages` |
| upgrade (named only) | `tools\steps\packages.ps1` (`Install-UpgradeStep`); `Invoke-MoveToPin` in `tools\lib\topin.ps1` | — | `pkg:*` "older than its pin" | `Step=upgrade` |
| envvars | `tools\steps\envvars.ps1` (`Install-EnvVarsStep`; also removes the old weather variables) | same file (`Undo-ConfigEnvVars`, uninstall's section 4, which removes any old weather variables itself) | `envvars`, `weather-vars`, `weather` (same file) | `Step=envvars` |
| bluetooth | `tools\components\bluetooth.ps1` (+ `tools\lib\bluetooth.ps1`) | same file | `bluetooth` | `Step=bluetooth` |
| commands | `tools\components\commands.ps1` | same file | `commands` | `Step=commands` |
| path | `tools\steps\path.ps1` (`Install-PathStep`); PATH helpers in `tools\lib\userenv.ps1` | same file (`Undo-RiceCommandPath`, uninstall's section 4) | `path` (same file) | `Step=path` |
| wallust | `tools\steps\wallust.ps1` (`Install-WallustStep`; `Get-WallustExe`); `tools\install-wallust.ps1`, `tools\write-wallust-config.ps1` | `uninstall.ps1` sections 7 (binary), 9 (`wallust.toml`) | `wallust`, `wallust-toml` (`tools\steps\wallust.ps1`) | `Step=wallust` |
| flow | `tools\components\flow.ps1` (what the step changes: `Get-FlowSetup`); Flow's files, its own sign-in start and the snapshots in `tools\lib\flow.ps1` | same file (`Restore-FlowLauncherSettings`, `tools\lib\flow.ps1`; you keep Flow: `Restore-FlowOwnStart`, its own sign-in start back) | `flow`, `flow-startup`, `flow-prefs`, `flow-font`, `flow-fullscreen` | `Step=flow` |
| everything | `tools\components\everything.ps1` | same file | `everything`, `everything-settings` | `Step=everything` |
| sharex | `tools\components\sharex.ps1` | same file | `sharex`, `sharex-startup` | `Step=sharex` |
| theme | `tools\steps\theme.ps1` (`Install-ThemeStep`); the pipeline `tools\apply-wallust-outputs.ps1`; the wallpaper and its snapshot in `tools\lib\wallpaper.ps1` | same file, from uninstall's section 3 (`Undo-Wallpaper`, `Undo-WindowsAccent`, `Undo-FlowTheme`; `Restore-WindowsAccent`, `Restore-FlowTheme`); section 9 (generated palette files); Terminal's colours: the terminal component | (see palette) | never run by repair |
| palette (named only) | `tools\steps\theme.ps1` (`Install-PaletteStep`: the pipeline on the current wallpaper) | — | `palette-profile`, `theme-files`, `theme-inputs`, `palette-last`, `flow-theme` (`tools\steps\theme.ps1`); the terminal component's `terminal`; `lock-screen` (`tools\lib\lockscreen.ps1`) | `Step=palette` |
| monitors | `tools\steps\monitors.ps1` (`Install-MonitorsStep`); `tools\write-display-index.ps1`, `tools\lib\monitors.ps1` | `uninstall.ps1` section 9 (`display-index.local.json`) | `display-index`, `display-index-more` (`tools\steps\monitors.ps1`) | `Step=monitors`, `Repair=reload` |
| defender | `tools\components\defender.ps1` | same file | `defender` | `Step=defender` |
| profile | `tools\steps\profile.ps1` (`Install-ProfileStep`: the `$PROFILE` hook) | same file (`Remove-ShellProfile`, uninstall's section 3) | `profile` (same file) | `Step=profile` |
| terminal | `tools\components\terminal.ps1` (default shell, font; font helpers in `tools\lib\terminal.ps1`) | same file (`Restore-WindowsTerminalSettings`: default shell, font, the palette's colour scheme) | `terminal`, `terminal-default`, `terminal-font` | `Step=terminal` (`terminal`: `Step=palette`) |
| compile | `tools\steps\compile.ps1` (`Install-CompileStep`) → `tools\compile-komorebi-rules.ps1` | `uninstall.ps1` section 9 (`komorebi.json`) | `komorebi-json`, `komorebi-json-warnings`, `asc` (`tools\steps\compile.ps1`) | `Step=compile`, `Repair=reload` |
| tasks | `tools\steps\tasks.ps1` (`Install-TasksStep`: the tiling mode -- `tools\lib\tiling.ps1` --, the tasks -- `Register-Autostart` / `Register-OnDemandTasks` --, then the lock screen's part, `Install-LockScreen` in `tools\lib\lockscreen.ps1`); task plumbing in `tools\lib\tasks.ps1` | `uninstall.ps1` section 2 (`Unregister-Autostart`, `tools\steps\tasks.ps1`; `Undo-LockScreenSync`), section 9 (`tiling-mode.txt`) | `mode`, `task:*`, `task:retired` (`tools\steps\tasks.ps1`), `tiling` (`tools\lib\tiling.ps1`); `lock-screen:old` (`lockscreen.ps1`) | `Step=tasks`, `Repair=tiling:<mode>` |
| windows (-Activate) | `install.ps1` → `Install-FullTimeWindowsSettings` in `tools\lib\fulltime.ps1` | `uninstall.ps1` section 2 → `Restore-FullTimeWindowsSettings` (`fulltime.ps1`) | `windows` (`fulltime.ps1`) | `Step=windows` |

## Pieces without a step of their own

| Piece | Where |
|---|---|
| The full-time switch | `710sRice activate` / `deactivate`: `tools\lib\switch.ps1` (`Invoke-RiceSwitch`, `Invoke-Rice(De)Activate`; loaded by their rows in `710sRice.ps1`); full time's Windows settings -- saved, applied, put back (`Save-FullTimeSettings`, `Set-` / `Restore-FullTimeWindowsSettings`), install -Activate's save (`Save-FullTimeSettingsOnActivate`, before any step: no copy, no switch) and its windows step (`Install-FullTimeWindowsSettings`), doctor's `windows`: `tools\lib\fulltime.ps1`; the mode is read from the tasks (`Test-FullTimeMachine`, `tools\steps\tasks.ps1`) |
| The stack: start, stop, restart, reload | `scripts\Start-All.ps1`, `Stop-All.ps1`; `restart` / `reload` / `reload bar` in `tools\lib\stack-commands.ps1` (`Invoke-RiceRestart`, `Invoke-RiceReload`, `Invoke-RiceReloadBar`; repair runs them too); in `tools\lib\stack.ps1`: `Start-StackFromTasks`, `Stop-RunningComponents`, `Get-RunningStackNames`, `Start-AhkFromTask`, `Restart-AhkFromTask`, `Get-AhkStartedApps` / `Start-AhkStartedApps` (asks 710.ahk), the retired start tasks (`Remove-RetiredStartTasks`, `Request-RetiredAppsRestart`), doctor's `stack:*`, `stack`, `paused` (`Test-DoctorStack`, `Test-DoctorPaused`); repair's starts (`Start-RepairComponents`, `tools\lib\repair.ps1`) |
| The lock screen | `scripts\Set-LockScreen.ps1` (sets it, takes its snapshots); everything else in `tools\lib\lockscreen.ps1`: running the setter and its record (the pipeline's), install's part (`Install-LockScreen`, from the tasks step), uninstall's (`Undo-LockScreenSync` in section 2, `Undo-LockScreenPicture` in section 3), the restores (`Restore-LockScreenPolicy`, `Restore-LockScreenPicture`), `Set-LockScreenToWallpaper`, doctor's `lock-screen*` lines (`Test-DoctorLockScreen`); `deactivate` sets it again (`Set-RiceSwitchLockScreen`, `tools\lib\switch.ps1`) |
| Tiling mode (elevated komorebi) | `tools\lib\tiling.ps1`: `Get-TilingMode`, `Resolve-TilingMode`, `Get-KomorebiRunLevel`, doctor's `tiling` (`Test-DoctorTilingMode`); `710sRice tiling` (`Show-RiceTilingStatus`, `Set-RiceTilingMode`; repair's `tiling <mode>` too) |
| Palette profiles and the theme | `tools\lib\palette.ps1`, `palette-files.ps1`, `palette-edit.ps1`, `tools\palette-editor.ps1` / `.xaml`, `tools\palette\targets\*` (one file per themed app; README there), `tools\apply-wallust-outputs.ps1`; `710sRice palette ...` in `tools\lib\palette-commands.ps1` |
| Tiling rules | `tools\compile-komorebi-rules.ps1` (`config\komorebi\base.json`, `rules.toml`, `rules.local.toml`, `games.toml`, `vendor\asc`), `tools\add-rule.ps1`, `tools\remove-rule.ps1`, `tools\update-asc.ps1` |
| Screens | `tools\screens.ps1`, `tools\lib\monitors.ps1`, `tools\write-display-index.ps1` |
| doctor / repair / update | `tools\lib\doctor.ps1` (the groups, the checks that belong to no step, the shared helpers, the repair plan, the report; each step's checks are in its module), `tools\lib\repair.ps1` (the rounds, starting what's down), `tools\lib\update.ps1` (the pull, then repair from the new files) |

## Shared libraries

| File | What's in it |
|---|---|
| `tools\lib\activation.ps1` | The loader: the libraries below and the fixed steps' modules (`tools\steps\`); no code of its own |
| `tools\lib\text.ps1` | Printing paths and names safely: `ConvertTo-SafePath`, `ConvertTo-SafeText` (never a user name), `Join-RiceNameList` |
| `tools\lib\snapshots.ps1` | The original-state snapshots uninstall puts back (`Save-` / `Get-` / `Remove-OriginalState`), one registry value as a snapshot (`Get-RegValueSnapshot`, `Set-RegValueFromSnapshot`), `Backup-RegistryKey` (reg.exe export to `backups\`) |
| `tools\lib\userenv.ps1` | User environment variables (`Get-` / `Set-` / `Remove-UserEnvVar`), the user PATH read and written raw (`Add-` / `Remove-UserPathEntry`, `Get-UserPathRaw`, `Test-SamePathEntry`), `Send-SettingChangeBroadcast` |
| `tools\lib\wallpaper.ps1` | `Set-DesktopWallpaper`, `Get-CurrentWallpaper`, and the wallpaper's own snapshot (`Save-` / `Restore-OriginalWallpaper`) |
| `tools\lib\apps.ps1` | Where the stack's apps are: `Get-KomorebiExe`, `Get-KomorebicExe`, `Get-YasbcExe`, `Get-AhkExe` (UI Access first), `Get-ShareXExe` |
| `tools\lib\tasks.ps1` | The task folder (`$script:TaskFolder`), `Get-TaskFullName`, `Test-Task`, `New-TaskXml`, `ConvertTo-HiddenLaunch` (run-hidden.vbs and its launch file), `Get-ComponentTaskInfo`, `Start-AsUser` |
| `tools\lib\elevation.ps1` | `Test-IsAdmin`, `Get-ProcessElevation` |
| `tools\lib\ahk.ps1` | Talking to the running 710.ahk: `Find-AhkWindow`, `Send-AhkMessage`, `Send-AhkQuit`, `Get-AhkWindowProcessId` |
| `tools\lib\ahk-load.ps1` | Will 710.ahk load? AutoHotkey's own check (`/Validate`): `Test-AhkScriptLoads`, `Format-AhkLoadError`, `Get-AhkLoadFix`; doctor's 710.ahk line when it won't load (`Get-DoctorAhkWontLoad`). Also dot-sourced by `scripts\Start-Ahk.ps1` (Windows PowerShell 5.1) |
| `tools\lib\shortcuts.ps1` | `Save-RiceShortcut`, `Read-RiceShortcut`, `Get-StartMenuProgramsDir` |
| `tools\lib\explorer.ps1` | Explorer's one restart (`Restart-Explorer`, `Wait-ExplorerRunning`, `Test-ExplorerShell`) and the tray icons kept around it (`Backup-` / `Restore-TrayIconPromotions`) |
| `tools\lib\fonts.ps1` | `Get-NerdFontFace`: the JetBrainsMono Nerd Font's face name, as Windows has it registered |
| `tools\lib\fulltime.ps1` | Full time's Windows settings (taskbar auto-hide, the hardening, the Startup delay): saved, applied, put back; install -Activate's save and windows step; doctor's `windows` line |
| `tools\lib\stack.ps1` | The stack's starts and stops (see Pieces) and doctor's Stack group |
| `tools\lib\tiling.ps1` | The tiling mode -- elevated komorebi or not (see Pieces) --, doctor's `tiling` line and `710sRice tiling` |
| `tools\lib\switch.ps1` | `710sRice activate` / `deactivate` (dispatcher-only: loaded by their rows) |
| `tools\lib\stack-commands.ps1` | `710sRice restart`, `reload`, `reload bar` (dispatcher-only: loaded by their rows and by `doctor -repair`'s, which runs them) |
| `tools\lib\palette-commands.ps1` | `710sRice palette`, `palette use`, `palette edit`, `palette new` (dispatcher-only: loaded by their rows) |
| `tools\lib\logs.ps1` | `710sRice logs` (dispatcher-only: loaded by its row) |
| `tools\lib\console.ps1` | 710sRice's "Press Enter to close": only in a window opened for the command alone (`Test-RiceOwnConsole`, `Wait-RiceClose`; dispatcher-only) |
| `tools\lib\flow.ps1` | Flow Launcher's files (`Get-FlowPaths`, `Read-FlowJson`, `Get-FlowField`), its own sign-in start (`Test-FlowOwnTask`, `Test-FlowRunValue`), `Stop-FlowLauncher`, the flow component's snapshots (`Save-FlowSnapshots`, `Restore-FlowLauncherSettings`), `Restore-FlowOwnStart` (uninstall, when you keep Flow) |
| `tools\lib\terminal.ps1` | Windows Terminal's font faces (`Get-TerminalFontFaces`, `Set-TerminalFontFace`) and `Clear-TerminalNerdFontFaces` (uninstall, before the Nerd Font goes) |
| `tools\lib\versions.ps1` | `versions.md`'s table (`Get-VersionsTable`), `Test-WingetRow`, `Test-PinnedRow` |
| `tools\lib\winget.ps1` | winget's sources (`Get-WingetSourceArgs`) and exit codes (`Get-WingetOutcome`, `Format-WingetCode`), the version `winget list` shows, the per-user packages, `Invoke-WingetAsUser` |
| `tools\lib\msi.ps1` | Removing an MSI package without closing anything (`Get-MsiProductCode`, `Invoke-MsiUninstall`: the Nerd Font) |
| `tools\lib\probes.ps1` | What's installed, read locally (`Get-PackageVersion` and its probes), `Compare-PinVersion` |
| `tools\lib\topin.ps1` | Moving a pinned package up to its pin (`Invoke-MoveToPin`: stop the app, upgrade, start it again) |
| `tools\lib\components.ps1` | The component loader and the step order (`Get-RiceComponents`, `Get-RiceStepOrder`, `Invoke-RiceComponentPart`, `New-RiceComponentContext`) |
| `tools\lib\steps.ps1` | install's fixed steps and the named-only ones |
| `tools\lib\lockscreen.ps1` | The lock screen, but for its setter script (see Pieces): `Invoke-LockScreenSetter` and its record (the pipeline's, no dependencies), install's and uninstall's parts, the restores, doctor's check |
| `tools\lib\monitors.ps1` | The screen-number map (`display-index.local.json`) |
| `tools\lib\bluetooth.ps1` | Does this machine have a Bluetooth adapter |
| `tools\lib\palette.ps1`, `palette-edit.ps1` | Palette profiles, targets, the theme stamp |
| `tools\lib\palette-files.ps1` | Rendering a target's template and writing the palette's files (`Write-PaletteFile`); `palette.ps1` loads it, and the theme stamp covers it |
| `tools\lib\run-hidden.vbs` | Starts a task's program with no console window |

## Doctor's report

Groups in report order, each check's function in `tools\lib\doctor.ps1` unless named otherwise.
Component checks come at the end of their group, in install's order.

| Group | Checks |
|---|---|
| (header) | `update` (`Get-DoctorUpdateResult`), `local-changes` |
| Repo and command | `path` (`tools\steps\path.ps1`), `envvars`, `weather` (`tools\steps\envvars.ps1`) |
| Packages and pins | `pkg:*` (`Test-DoctorPinnedPackages`), `pins`, other packages (`Test-DoctorOtherPackages`) -- `tools\steps\packages.ps1`; `wallust` (`tools\steps\wallust.ps1`) |
| Stack | `stack` / `stack:*` (`Test-DoctorStack`), `paused` (`Test-DoctorPaused`) -- both in `tools\lib\stack.ps1`; `stack:ahk` says when 710.ahk won't load (`tools\lib\ahk-load.ps1`) |
| Tasks and tiling mode | `mode`, `task:*`, `task:retired` (`Test-DoctorTasks`, `tools\steps\tasks.ps1`), `tiling` (`tools\lib\tiling.ps1`) |
| Generated configs | `komorebi-json`, `asc` (`tools\steps\compile.ps1`), `display-index` (`tools\steps\monitors.ps1`), `wallust-toml` (`tools\steps\wallust.ps1`), `palette-profile`, `theme-files`, `theme-inputs`, `palette-last` (`tools\steps\theme.ps1`), `lock-screen` (`Test-DoctorLockScreen`, `tools\lib\lockscreen.ps1`) |
| Integrations | `flow-theme` (`tools\steps\theme.ps1`), `profile` (`tools\steps\profile.ps1`), `windows` (`Test-DoctorWindowsSettings`, `fulltime.ps1`); then bluetooth, commands, flow, everything, sharex, defender, terminal (`terminal`, `terminal-default`, `terminal-font`) (components) |
| Conflicts and leftovers | `conflicts`, `komorebi-scripts` |

## 710.ahk

`config\ahk\710.ahk` keeps the directives, the environment it cleans, the paths and state folder,
then `#Include`s its parts from `config\ahk\710\` in this order -- AutoHotkey reads them as though
they were pasted in there, global code and all, so the order matters -- and `user.ahk` last. Each
part starts with a line saying what's in it; SUPER+K lists the hotkeys under the section titles
inside them (`; ====` banners), reading the parts in place (`ReadScriptText`, `keymap.ahk`).

| Part (`config\ahk\710\`) | What's in it |
|---|---|
| `komorebi.ahk` | `Komorebic`, `QueryKomorebic`, `ToggleScrolling`, `LaunchOnCursorMonitor`, `CloseWindow`, `RedrawApp`, `EndGpuHelpers` |
| `komorebi-keys.ahk` | The window, focus, move, stack, resize, workspace and monitor hotkeys |
| `sharex.ahk` | `Sharex()` and the capture hotkeys |
| `apps.ahk` | App launchers: browser, Explorer, web apps, Obsidian, Claude |
| `palette.ahk` | `PalOpen` and the themed popup every menu uses |
| `keymap.ahk` | SUPER+K: `ReadScriptText`, `ParseKeymap` (710.ahk with its parts, and user.ahk), `ToggleKeyOverlay` |
| `system-menu.ahk` | SUPER+Esc, the power / system menu |
| `terminal.ahk` | SUPER+Return |
| `flow.ahk` | `ToggleFlow`, `ToggleFlowScoped`; SUPER+Space, SUPER+S |
| `stay-awake.ahk` | Stay awake |
| `game-mode.ahk` | `games.toml`, `GameWatch` |
| `started-apps.ahk` | The apps 710.ahk starts: `StartApps` (the bar, Flow, ShareX), `RestartRetired`, the start at load |
| `yasb-watchdog.ahk` | The bar's watchdog |
| `monitor-watcher.ahk` | komorebi's monitor watcher: display-change nudges |
| `screens.ahk` | The Screens menu, `RunThen` |
| `quick-rule.ahk` | Quick add rule (click-to-pick); Remove a rule / Edit my rules |
| `menus.ahk` | The menus' items (Capture, Tiling) and their state text |
| `palette-profiles.ahk` | Choosing, creating and editing palette profiles from the menu |
| `main-menu.ahk` | `MainMenuItems`, `RunDoctor`, `OpenMainMenu`; the messages 710sRice posts (`OnMessage`), `RiceCommands`; the tray |
| `stack-control.ahk` | `ReloadStack` (SUPER+Shift+R), `QuitStack`, `RestartStack` (SUPER+Ctrl+R) and its toast |
| (`710.ahk`, last) | `#Include *i %A_ScriptDir%\user.ahk` -- always the last line |

Doctor's "710.ahk changed since it started" compares `710.ahk`, its parts and `user.ahk` with 710.ahk's
start time (`Get-DoctorStaleText`). When 710.ahk isn't running, or has changed since, doctor asks
AutoHotkey whether it loads (`tools\lib\ahk-load.ps1`): a key `user.ahk` defines again with `::`, or
any other mistake, is a needs-you `[XX]` naming the line -- repair leaves 710.ahk alone, and
`scripts\Start-Ahk.ps1` makes the same check before it starts it (why goes in `ahk-autostart.log`). `scripts\Start-Ahk.ps1` and every `Find-AhkWindow` find 710.ahk by
its window title (the script's full path).
