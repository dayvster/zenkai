# Action menu icons

These SVGs are embedded into Zenkai at build time and rendered by the Ctrl+K
action menu at 24px (scaled for HiDPI). Replace any file with a downloaded SVG;
no code changes are needed as long as the file name stays the same.

The placeholders are empty `<svg>` documents, so the menu shows a blank icon
slot until a file is replaced.

| File | Used for |
| --- | --- |
| `document-open.svg` | Open the selected item |
| `preferences-system-windows.svg` | Switch to the selected window |
| `window-left-half.svg` | Left half |
| `window-right-half.svg` | Right half |
| `window-top-half.svg` | Top half |
| `window-bottom-half.svg` | Bottom half |
| `window-maximize.svg` | Maximize |
| `window-center.svg` | Center window |
| `window-next-display.svg` | Move to next display |
| `window-new.svg` | New browser window |
| `view-private.svg` | New private/incognito window |
| `edit-copy.svg` | Copy name/title |
| `edit-copy-command.svg` | Copy launch command |
| `dialog-information.svg` | Application info |
| `view-refresh.svg` | Refresh windows |
| `application-x-executable.svg` | Fallback for custom actions without an icon |

Use a `viewBox="0 0 24 24"` and keep important artwork inside the outer 2px so
icons line up with each other in the menu.

SVGs may use `fill="currentColor"` or `stroke="currentColor"` to follow the
active theme's text color; selected rows use the theme's highlighted text
color. `inherit` is also accepted as a theme-color token. Icons with hard-coded
colors are rendered exactly as supplied.
