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
| `Autostart` | no | its own task, `\710.DesktopRice\<Id>`: `@{ Exe = { <path, or nothing when it isn't installed> }; Arguments = '...'; Delay = 'PT2S'; Process = '<process name>' }`. A full-time machine starts it at sign-in; an on-demand one when you run `710sRice start`. `Exe` is a GUI exe, started directly. Only a console host goes through `tools\lib\run-hidden.vbs`, and none of those is a component. `Process` is the process name that means "already running" |

`$Ctx` has `Root` (the repo), `OnlyRun` (this is a `-Only` run), `FullTime` (the machine's
mode: the stack starts at sign-in), `IsAdmin`, and `DryRun` (uninstall `-DryRun`). The helpers
from `tools\lib\activation.ps1` and `tools\lib\packages.ps1` are in scope, and doctor's too
(`New-DoctorResult`, ...) for `Check`.

The loader checks every file when it reads it. A broken one throws and names the file: a
field it doesn't know, a missing `Label` or `After`, an `After` that names no step, `Id` not
the file's name. Nothing is skipped quietly, because an install that silently lost a step
would be worse than one that stops.

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
