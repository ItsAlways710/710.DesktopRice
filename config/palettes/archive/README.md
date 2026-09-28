# Archived palette profiles

Known-good configurations kept in case they're needed again. Nothing reads this folder: a file
here isn't a profile until it's copied where profiles live.

| File | What it is |
|---|---|
| `classic-default.json` | The Default profile until 2026-09-28: the wallpaper through wallust's kmeans method, every colour straight from the palette, Windows Terminal in wallust 4.1's own slot order. Exactly the theme 710sRice had before Palette Profiles. Only its name and note changed when it was archived. |

## Using one again

- **As a profile you can pick:** copy it to `config/palettes/` as `profile0.json` … `profile9.json`
  (any number that isn't taken). It shows up as "Profile N · Classic Default" in
  SUPER+Alt+Space > Palette profiles > Choose profile, and the editor can open it like any other.
- **As the Default again:** copy it over `config/palettes/default.json`. The next theme run uses it
  (`710sRice doctor` names the fix until one happens). `git pull` / `710sRice update` would then see
  a changed tracked file, so do this on a clone you don't update, or put it back before updating.
