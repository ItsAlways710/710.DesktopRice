# Palette targets

Every app the palette themes is one file here: `<id>.ps1`, returning one hashtable, plus (for
apps that read a file) a template next to it. `tools\lib\palette.ps1` loads them all, in
`Order`; the pipeline (`tools\apply-wallust-outputs.ps1`), the editor, doctor and the theme
stamp pick a new file up by themselves.

| Field | Needed | What it is |
|---|---|---|
| `Id` | yes | the file's own name (`flow` for `flow.ps1`) |
| `Label` | yes | what the editor calls it |
| `Order` | no (50) | apply order; files first (10–50), live apps after (60+) |
| `About` | no | one line for the editor |
| `Properties` | yes | `[ordered]@{ name = @{ Label = '...'; Default = '<expression>' } }` — each property's colour when the profile doesn't override it. Expressions: a role (`accent`), a palette slot (`color3`, `background`), `#rrggbb`, `lighten(x, n)`, `darken(x, n)`, `mix(x, y, n)` |
| `Readable` | no | `@(@{ Fg = 'text'; Bg = 'background'; Min = 4.5 })` — pairs the "keep text readable" guard checks (`Bg` may be `othertarget.prop`); `Guard = 'terminal'` puts a pair under the Terminal setting instead of the UI one |
| `Template` | for files | a file next to this one; `{{property}}` placeholders, plus `{{_isDark}}` (`True`/`False`) and `{{_mode}}` (`dark`/`light`). Everything else is copied byte for byte |
| `Output` | for files | `{ <scriptblock returning the path> }` — written only when the bytes change; return nothing to skip writing (Flow before it has ever run) |
| `Validate` | no | `'xml'` or `'json'`: the rendered text is parsed first and a file that doesn't parse is never written (the target fails instead) |
| `Apply` | for live apps | `{ param($Values, $Theme, $Context) ... }` — runs after the file (if any) is written; returns `@{ Status = 'ok' \| 'skipped'; Message = '...' }`, throws on failure |
| `Hidden` | no | leave it out of the editor |

`$Values` is this target's resolved properties (`$Values.accent` → `'#696868'`); `$Theme`
has `Roles`, `Targets` (every target's values), `AppDark`; `$Context` has `Mode` (`full`,
`reapply`, `borders`), `IsAdmin`, `Changed` (the file target's output changed this run).
Helpers from `tools\lib\palette.ps1` are in scope (`ConvertTo-PaletteRgb`,
`Save-PaletteOriginalStateOnce`, `Write-PaletteFile`, ...).

A target that changes something outside the repo takes a once-only snapshot first
(`Save-PaletteOriginalStateOnce`) and gets a matching restore in uninstall
(`tools\lib\activation.ps1`, or the app's component); one whose state can drift gets a doctor check
(`tools\lib\doctor.ps1`). The worked example is `flow.ps1` — see
`claude/palette-profiles-plan.md`, "How to add a target".
