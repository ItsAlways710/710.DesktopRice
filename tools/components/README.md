# Components

Every app with its own install step is one file here: `<id>.ps1`, returning one hashtable.
`tools\lib\components.ps1` loads them all (`Get-RiceComponents`). install, uninstall, doctor
and repair pick a new file up by themselves.

| Field | Needed | What it is |
|---|---|---|
| `Id` | yes | the file's own name (`flow` for `flow.ps1`): lower-case letters, digits and dashes. It is also the install step's name, so `710sRice install -Only flow` runs it |
| `Label` | yes | how output names it (`Flow Launcher`) |
| `After` | yes | the install step it runs right after: one of install's own steps (`710sRice install -?` lists them) or another component's `Id`. Two components after the same step run in `Id` order |
| `Install` | no | `{ param($Ctx) ... }`, the install step itself |
| `Uninstall` | no | `{ param($Ctx) ... }`, what uninstall puts back: restore from its snapshots, remove what it added. Uninstall runs these last-installed first, in its "Revert components" section, before the env vars and packages go |
| `Check` | no | `{ param($Ctx) ... }`, doctor's results for it (`New-DoctorResult`). A fixable `[XX]` carries `Step = '<Id>'`, so `710sRice doctor -repair` runs this component's install step |
| `Group` | no (`Integrations`) | the doctor group its results go under: `Repo and command`, `Packages and pins`, `Stack`, `Tasks and tiling mode`, `Generated configs`, `Integrations`, `Conflicts and leftovers` |
| `NamedOnly` | no (`$false`) | `$true`: a plain install skips it; only `-Only <Id>` runs it (like `upgrade` and `palette`) |
| `Functions` | no | `{ function ... }`, the component's own helper functions, dot-sourced before its `Install`, `Uninstall` or `Check` runs, so the three can share code |

There is no sign-in task field: until 2026-10-06 a component could have its own task
(`Autostart`), and Flow, the only one that did, broke because of it (see the rules below). The
loader stops on a file that still has one.

`$Ctx` has `Root` (the repo), `OnlyRun` (this is a `-Only` run), `FullTime` (the machine's
mode: the stack starts at sign-in), `IsAdmin`, and `DryRun` (uninstall `-DryRun`). The helpers
from `tools\lib\activation.ps1` and `tools\lib\packages.ps1` are in scope, and doctor's too
(`New-DoctorResult`, ...) for `Check`.

The loader checks every file when it reads it. A broken one throws and names the file: a
field it doesn't know (a typo'd `Instal` would otherwise vanish), a missing `Label` or `After`,
an `After` that names no step, `After`s that go round in a circle, `Id` not the file's name or
not lower-case letters / digits / dashes, an `Id` that is one of install's own steps, a `Group`
that isn't one of doctor's. Nothing is skipped quietly, because an install that silently lost a
step would be worse than one that stops: install and uninstall stop before their first change
(`[XX] <file and what's wrong> -- nothing was changed.`), and doctor reports it as its own `[XX]`
and runs every other check.

Once loaded, a component that fails is reported and the rest go on: an `Install` that throws is
its own `[XX]` line (the run finishes), an `Uninstall` that throws is reported and the other
components still revert, a `Check` that throws is "couldn't check".

## The five today

| File | Runs after | What it owns |
|---|---|---|
| `bluetooth.ps1` | `envvars` | The bar's Bluetooth icon: left out on a machine with no adapter (`DESKTOPRICE_NO_BLUETOOTH = _none`, for a YASB started outside 710sRice -- `scripts\Start-Yasb.ps1` sets it from the hardware at every bar start), doctor's line |
| `commands.ps1` | `envvars` (after `bluetooth`; before Flow's first start, so it indexes them) | The Start-menu commands: ten shortcuts in Start Menu\Programs\710sRice, each `config\ahk\send-command.ahk <name>` (710.ahk's `RiceCommands`); Flow's program cache cleared when it isn't running to see a change; doctor's line |
| `flow.ps1` | `wallust` (so `theme` themes a Flow set up in the same run) | Flow Launcher: its first start on a new machine, its settings, its own startup turned off (710.ahk starts it), doctor's Flow lines |
| `everything.ps1` | `flow` | Everything: its tray icon and update check off (`Everything.ini`), started (as you) when it isn't running, doctor's "running" line |
| `sharex.ps1` | `flow` | ShareX: its update check off (`ShowTray` stays on: ShareX's silent start at sign-in needs it), its own sign-in start off (the Startup-folder shortcut its installer makes), doctor's ShareX lines |

The worked example is `flow.ps1`: every field but `NamedOnly`, a first start through
`Start-AsUser`, snapshots, and a restart through 710.ahk. `everything.ps1` / `sharex.ps1` are the smaller
pattern: settings an app keeps in its own file, set once, with doctor's split between
`[XX] not set up by 710sRice yet` (no snapshot yet: the step has never run here, so `710sRice
update`'s repair runs it) and `[!!]` for a value you changed back yourself since (shown, never
overridden by repair).

## Adding one

1. Copy the smallest one that's like your app; rename it `<id>.ps1` and set `Id`,
   `Label` and `After`.
2. `710sRice install -?` lists its step where you expect it; `710sRice install -Only <id>` runs
   it; `710sRice doctor` shows its checks in their group; `710sRice uninstall -DryRun` lists its
   revert.
3. Nothing else changes: install, uninstall, doctor and repair find it.

## The rules

- **Never start an app elevated.** install, uninstall and repair run elevated. A component
  never `Start-Process`es an app from there.
- **An app you open programs from is started by 710.ahk, never by a task.** Whatever a
  Scheduled Task starts runs inside the task's job, and so does everything it opens: a program
  that starts its own programs apart from itself (Mod Organizer 2's tools) fails with Error 5.
  The bar, Flow and ShareX: `Start-AhkStartedApps` (`tools\lib\activation.ps1`) asks 710.ahk,
  which starts them as you (config\ahk\710.ahk, "The apps 710.ahk starts"). `Start-AsUser`
  (the same file) starts an app as you through a one-shot task -- so in that task's job: fine
  for a start that's stopped again seconds later (Flow's first start). Everything's start goes
  that way too; whether that touches what you open from Everything's own window is untested.
- **Snapshot before the first change.** Take a once-only snapshot of anything outside the repo
  it changes, before the change: `Save-OriginalState` with a label that starts with its `Id`
  (`flow-settings`). `Uninstall` restores from it, then removes its own labels.
- **A change existing installs need is a doctor check with its fix**, never a migration
  script: `Check` finds it, `Step = '<Id>'` fixes it.
