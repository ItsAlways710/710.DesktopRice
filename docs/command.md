# The 710sRice command

Run it from any PowerShell 7 window. Commands marked *(admin)* ask for admin rights with a
UAC prompt and run in their own admin window; there's no need to open one yourself.

| Command | What it does |
| --- | --- |
| `710sRice` | The command list. `710sRice <command> -?` shows one command's options |
| `710sRice install` | Install (safe to run again); `-Activate` makes it full-time, `-SkipPackages` skips winget, `-Only <step>` runs just those [steps](#install-steps) *(admin)* |
| `710sRice uninstall` | Undo everything install did; `-DryRun` shows the plan first *(admin)* |
| `710sRice activate` / `deactivate` | [Switch](install.md#switching-activate--deactivate) to full-time / back to on demand; `-DryRun` shows what it would do *(admin)* |
| `710sRice doctor` | Health check: what's wrong, and the command that fixes each thing. Changes nothing; also says when GitHub has a newer version |
| `710sRice doctor -repair` | Fix what doctor finds, then check again. Never touches your wallpaper, theme or the choices 710sRice gives you: full-time or on demand, the tiling mode, your palette profiles and the one in use, the screen numbers, your own files *(admin)* |
| `710sRice update` | Get the newest version from GitHub, then repair from it. Keeps your wallpaper, theme and those choices *(admin)* |
| `710sRice start` / `stop` | Start or stop the stack |
| `710sRice restart` | Stop the stack and start it again, same as SUPER+Ctrl+R (SUPER+Shift+R only restarts what it has to) |
| `710sRice reload` | Re-apply config and rules, restarting only what changed; same as SUPER+Shift+R |
| `710sRice reload bar` | Restart just the bar |
| `710sRice logs` | Open the logs folder and list what's in it |
| `710sRice palette` | List the [palette profiles](theming.md#palette-profiles), the one in use marked |
| `710sRice palette use <profile>` | Theme everything with that profile now: `default`, `0`–`9`, or its name |
| `710sRice palette edit [<profile>]` | Open the palette profile editor on the one in use (or that one) |
| `710sRice palette new [<from>]` | Create a palette profile in the editor, starting from the one in use (or `<from>`) |
| `710sRice tiling status` | Whether komorebi runs elevated: the saved choice, its task, and the running copy |
| `710sRice tiling elevated` / `normal` | Switch komorebi to elevated or not *(admin)* |

The scripts behind it (`install.ps1`, `uninstall.ps1`, `scripts\Start-All.ps1` and so on)
still exist and work on their own; the command just gives them one name.

## Install steps

The installer is a set of steps, always run in this order. A plain `710sRice install` runs
them all, except `upgrade` and `palette`, which only run when you name them (and `windows`
only runs with `-Activate`).

| Step | What it does |
| --- | --- |
| `packages` | Installs what's missing from [versions.md](../versions.md), pinned ones at their pin, and moves a pinned one that's older than its pin up to it |
| `upgrade` | Moves a pinned package that's older than its pin up to it (and nothing else) |
| `envvars` | Points komorebi and YASB at this repo's config (and removes the old weather variables, if a past install set them) |
| `bluetooth` | Tells the bar whether this machine has a Bluetooth adapter (no adapter: no Bluetooth icon) |
| `commands` | Adds the 710sRice commands to the Start menu, for Flow Launcher |
| `path` | Puts the `710sRice` command on your PATH |
| `wallust` | Installs wallust at its pinned version |
| `flow` | Sets up Flow Launcher (its first start, on a machine where it never ran): keywords, fonts, fullscreen; switches its own startup off (AutoHotkey starts it) |
| `everything` | Turns Everything's tray icon and update check off, and starts it if it isn't running |
| `sharex` | Turns ShareX's update check and its own startup off (and its tray icon on, which its hidden start needs) |
| `theme` | Sets the default wallpaper and themes everything from it |
| `palette` | Re-themes everything from the wallpaper you have now, with the palette profile in use (no wallpaper change) |
| `monitors` | Gives each screen its number, for komorebi (a number once given is kept; see [Screens and workspaces](desktop.md#screens-and-workspaces)) |
| `defender` | Adds the Windows Defender exclusions |
| `profile` | Hooks the PowerShell profile in |
| `terminal` | Makes PowerShell 7 Windows Terminal's default and sets its font, for every profile, to the Nerd Font |
| `compile` | Rebuilds `komorebi.json` from the rules |
| `tasks` | Registers komorebi's and AutoHotkey's scheduled tasks, for whichever way this machine runs (and removes the old ones the bar, Flow and ShareX had) |
| `windows` | The Windows settings of a full-time install (taskbar, hardening, Startup delay) |

`bluetooth`, `commands`, `flow`, `everything`, `sharex`, `defender` and `terminal` are components: each one's install, uninstall and doctor
code lives in one file in `tools/components/`, and a new file there becomes a step of its own
([its README](../tools/components/README.md) explains how).

`-Only` runs just the steps you name, in that same order, and leaves the machine running the
way it already does (full-time or on demand). It doesn't take any other switch. For example:

```powershell
710sRice install -Only path       # put the 710sRice command back on PATH
710sRice install -Only upgrade    # after a pin bump in versions.md
710sRice install -Only palette    # the bar or Terminal lost their colors
```

`710sRice install -?` lists the steps too. `710sRice doctor -repair` runs them for whatever
doctor finds, never `theme`.
