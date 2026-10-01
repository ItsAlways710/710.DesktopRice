# Components

Every app with its own install step is one file here: `<id>.ps1`, returning one hashtable.
`tools\lib\components.ps1` loads them all (`Get-RiceComponents`). install, uninstall, doctor,
repair and the sign-in tasks pick a new file up by themselves.

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
| `Functions` | no | `{ function ... }`, the component's own helper functions, dot-sourced before its `Install`, `Uninstall` or `Check` runs, so the three can share code. `Autostart.Exe` runs without them |
| `Autostart` | no | its own task, `\710.DesktopRice\<Id>`: `@{ Exe = { <path, or nothing when it isn't installed> }; Arguments = '...'; Delay = 'PT2S'; Process = '<process name>' }`. A full-time machine starts it at sign-in; an on-demand one when you run `710sRice start`. `Exe` is a GUI exe, started directly. Only a console host goes through `tools\lib\run-hidden.vbs`, and none of those is a component. `Process` is the process name that means "already running" |

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

## The four today

| File | Runs after | What it owns |
|---|---|---|
| `bluetooth.ps1` | `envvars` | The bar's Bluetooth icon: left out on a machine with no adapter (`DESKTOPRICE_NO_BLUETOOTH = _none`, for a YASB started outside 710sRice -- `scripts\Start-Yasb.ps1` sets it from the hardware at every bar start), doctor's line |
| `flow.ps1` | `wallust` (so `theme` themes a Flow set up in the same run) | Flow Launcher: its first start on a new machine, its settings, its own startup turned off, its sign-in task, doctor's Flow lines |
| `everything.ps1` | `flow` | Everything: its tray icon and update check off (`Everything.ini`), doctor's "running" line |
| `sharex.ps1` | `flow` | ShareX: its update check off (`ShowTray` stays on: ShareX's silent start at sign-in needs it), doctor's ShareX lines |

The worked example is `flow.ps1`: every field but `NamedOnly`, a first start through
`Start-AsUser`, snapshots, and its own task. `everything.ps1` / `sharex.ps1` are the smaller
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
3. Nothing else changes: install, uninstall, doctor, repair and the sign-in tasks find it.

## The rules

- **Never start an app elevated.** install, uninstall and repair run elevated. A component
  never `Start-Process`es an app from there. `Start-AsUser` (`tools\lib\activation.ps1`)
  starts it as you through a one-shot task, or its own `Autostart` task does
  (`schtasks /Run`).
- **Snapshot before the first change.** Take a once-only snapshot of anything outside the repo
  it changes, before the change: `Save-OriginalState` with a label that starts with its `Id`
  (`flow-settings`). `Uninstall` restores from it, then removes its own labels.
- **A change existing installs need is a doctor check with its fix**, never a migration
  script: `Check` finds it, `Step = '<Id>'` fixes it.
