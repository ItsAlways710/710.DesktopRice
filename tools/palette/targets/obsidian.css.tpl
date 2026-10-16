/* 710.DesktopRice: this machine's palette in Obsidian, made from the wallpaper ({{_mode}}).
   The wallpaper pipeline writes this file on every theme run (tools\palette\targets\obsidian.ps1
   in the 710.DesktopRice repo), so edits here don't last: change the colours in the palette
   editor instead. Obsidian's own theme (light, dark or "adapt to system") can stay as it is; this
   sets both. Keep this file and .obsidian/appearance.json out of any sync between machines --
   each machine has its own wallpaper, and would overwrite the others' colours. */
body.theme-dark,
body.theme-light {
  color-scheme: {{_mode}};

  /* Obsidian's grey ramp, from the background to the text in the default theme's steps:
     borders, form fields and the like follow it. */
  --color-base-00: {{background}};
  --color-base-05: color-mix(in srgb, {{text}} 3%, {{background}});
  --color-base-10: color-mix(in srgb, {{text}} 4%, {{background}});
  --color-base-20: color-mix(in srgb, {{text}} 6%, {{background}});
  --color-base-25: color-mix(in srgb, {{text}} 9%, {{background}});
  --color-base-30: color-mix(in srgb, {{text}} 12%, {{background}});
  --color-base-35: color-mix(in srgb, {{text}} 18%, {{background}});
  --color-base-40: color-mix(in srgb, {{text}} 30%, {{background}});
  --color-base-50: color-mix(in srgb, {{text}} 39%, {{background}});
  --color-base-60: color-mix(in srgb, {{text}} 66%, {{background}});
  --color-base-70: color-mix(in srgb, {{text}} 80%, {{background}});
  --color-base-100: {{text}};
  --mono-0: {{background}};
  --mono-100: {{text}};

  /* The accent ({{accent}}), in Obsidian's own slot for it: Obsidian makes links, tags, buttons,
     checkboxes and the selection from it, in its own shades. Only the default: an accent picked
     in Settings > Appearance > Accent color goes on the page itself, over this one, and stays
     through every wallpaper change; that setting's restore-default arrow brings this one back. */
  --accent-h: {{accentH}};
  --accent-s: {{accentS}}%;
  --accent-l: {{accentL}}%;
  /* Text on the accent: black on a light accent, white on a dark one -- whichever accent is
     showing, by Obsidian's own test for a picked one (YIQ brightness 150 or more is light). */
  --text-on-accent: rgb(from hsl(var(--accent-h) var(--accent-s) var(--accent-l))
    clamp(0, (150 - (0.299 * r + 0.587 * g + 0.114 * b)) * 100000, 255)
    clamp(0, (150 - (0.299 * r + 0.587 * g + 0.114 * b)) * 100000, 255)
    clamp(0, (150 - (0.299 * r + 0.587 * g + 0.114 * b)) * 100000, 255));

  /* The palette's colours where Obsidian uses them. */
  --background-primary: {{background}};
  --background-primary-alt: color-mix(in srgb, {{panel}} 50%, {{background}});
  --background-secondary: {{panel}};
  --background-secondary-alt: color-mix(in srgb, {{hover}} 50%, {{panel}});
  --background-modifier-hover: color-mix(in srgb, {{hover}} 60%, transparent);
  --background-modifier-error: {{error}};
  --background-modifier-error-hover: {{error}};
  --interactive-normal: {{panel}};
  --interactive-hover: {{hover}};
  --text-normal: {{text}};
  --text-muted: {{muted}};
  --text-faint: color-mix(in srgb, {{muted}} 65%, {{background}});
  --text-error: {{error}};
}
