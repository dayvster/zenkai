# Roadmap

Where zenkai is heading, roughly in order. Nothing here has a date, and the order can change.
Ideas and pull requests for anything on this list are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## v1.6 (released)

- [x] Settings window: appearance with a live preview, themes, plugins, opacity, corner radius
      and text sizes.
- [x] Ember theme.
- [x] Bottom bar with borderless shortcuts and line icons.
- [x] Developer toolbox plugin (`dev:`) and `api.now` for plugins.
- [x] Square app icon, used by the AUR packages.
- [x] Source-built `zenkai` package on the AUR, next to `zenkai-bin`.

## Up next

- [x] **Optional background service with a toggle command.** zenkai starts a new process on
      every launch, and that stays the default. Anyone who wants it can opt into a resident
      service (`zenkai --service`) that a hotkey shows and hides (`zenkai --toggle`): it opens
      without a startup and keeps the app list and plugins loaded. Linux first; macOS and
      Windows later. Clipboard history and per-command hotkeys build on it, so they only work
      with the service turned on.
- [x] **Clipboard history.** Search, pin and copy back past copies (`clip:`). Needs the
      optional background service to watch the clipboard (`wl-paste --watch` on Wayland).
      Pasting straight into the previous window comes later.
- [ ] **System commands.** Lock, sleep, log out, restart, shut down and empty trash in the main
      search, for every desktop. Today only the Hyprland plugin has lock and sleep.
- [x] **dmenu mode.** Read entries from stdin and print the chosen one, so scripts can use
      zenkai as a picker (`--dmenu`, `--prompt=TEXT`).

## Root search

- [ ] **Fallback commands**, such as "Search the web for ...", when nothing matches.
- [ ] **Aliases**: a short keyword that runs a specific command.
- [ ] **Favourites** pinned to the top of an empty search.
- [ ] **Ranking by use for plugin results**, not only for apps.
- [ ] **Global hotkeys per command** (needs the optional background service).

## Plugin API

- [ ] **Sub-views**: open a second list from a result, such as a repository's issues.
- [ ] **Detail views** with formatted text, for things like full JSON or a diff.
- [ ] **Forms and argument fields**: text inputs and dropdowns before a command runs.
- [ ] **Grid layout** for emoji, colours and images.
- [ ] **Toasts** for short confirmations and errors.
- [ ] **A plugin index** and an install command, so plugins can be found and updated without
      copying folders by hand.

## Later

- [ ] **Snippets that type themselves** into other apps when you type their keyword. On Wayland
      this needs a virtual keyboard tool such as `wtype` or `ydotool`.
- [ ] **Indexed file search**, instead of walking folders at query time.
- [ ] **Calculator history.**
- [ ] **Emoji skin tones.**
- [ ] **Window placement through layer-shell on Wayland**, so compositors like KWin stop placing
      the launcher in the top-left corner.
