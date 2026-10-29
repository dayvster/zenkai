<p align="center">
  <img src="assets/logo.png" alt="zenkai logo" />
</p>

# zenkai


A fast app launcher for Linux and Windows. Written in Zig with Qt6.

Scans your .desktop files from the usual places, shows you everything in a searchable list, and lets you filter through it as you type with fuzzy matching. Built because apparently 50 other launchers weren't enough.

On Windows, Zenkai scans per-user and shared Start Menu folders for `.lnk` and `.url` shortcuts and opens them with the Windows shell. Configuration is stored under `%APPDATA%\zenkai`.

Thanks to [rcalixte](https://github.com/rcalixte) for [libqt6zig](https://github.com/rcalixte/libqt6zig), the Zig bindings this project is built on.

## Preview
<p align="center">
<img width="450"  alt="image" src="https://github.com/user-attachments/assets/3297778a-7a09-4b76-9f77-9d401f7d048a" />
</p>

- [Requirements](#requirements)
- [Building](#building)
- [Using](#using)
- [Examples](#examples)
- [Plugins](#plugins)

## Requirements

- **Zig 0.17.0** - the compiler and build system. Download from [ziglang.org/download](https://ziglang.org/download/) or use your distro's package manager if it has a recent enough version.
- **Qt 6.8.2 development libraries** (Core, Gui, Widgets, Svg) - the GUI toolkit. Install `qt6-base-dev` and `libqt6svg6-dev` or equivalent for your distro.
- **GCC or Clang** - used by Zig to link C++ code (Qt is written in C++).
- **libstdc++ or libc++** - the C++ standard library, comes with your compiler.
- **pkg-config** - helps the build system find Qt headers and libraries.

Windows builds also require Zig 0.17.0 and a Qt 6.8.2 development installation for the Windows target. Use the deployment build step to bundle the Qt and LLVM MinGW runtimes plus the platform plugin beside the executable:

```powershell
zig build deploy-windows -Dtarget=x86_64-windows-gnu
```

The output is `zig-out/bin/zenkai.exe`; it can be launched without setting `PATH` or `QT_PLUGIN_PATH`. If Qt is installed outside `C:/Qt/6.8.3/llvm-mingw_64`, pass its installation root with `-Dqt-win-root=<path>`.

Zig fetches the following automatically when you run `zig build`:

- [libqt6zig](https://github.com/rcalixte/libqt6zig) - Zig bindings for Qt6
- [ziglua](https://github.com/masterQ32/ziglua) - Zig bindings for Lua

## Building

```sh
zig build
```

Binary at `zig-out/bin/zenkai`.

### Installing dependencies

#### Zig

Download the tarball for your architecture from [ziglang.org/download](https://ziglang.org/download/), extract it, and put the `zig` binary somewhere in your `PATH`. Most distro repositories lag behind and 0.17.0 is required.

#### FreeBSD

```sh
sudo pkg install qt6-base
```

#### Debian / Ubuntu / Mint

```sh
sudo apt install gcc libstdc++-14-dev-$(dpkg --print-architecture)-cross qt6-base-dev
```

#### Fedora

```sh
sudo dnf install gcc libstdc++-devel qt6-qtbase-devel
```

#### Arch

```sh
sudo pacman -S gcc qt6-base
```

#### openSUSE

```sh
sudo zypper install qt6-base-devel
```

## Using

Kick it off:

```sh
./zig-out/bin/zenkai
```

Type to filter through your apps. Enter to launch. That's it.

Up and Down cycle through results. Ctrl+L selects the search text so you can
start a new query. Home and End move within the query; Ctrl+Home and Ctrl+End
jump to the first and last results. Escape closes the launcher.

### `--theme=<theme>`

Use `native` to follow system light/dark appearance and accent color. It selects a macOS-style surface on macOS and a Windows-style surface on Windows. Windows defaults to `native`; an explicit config or `--theme` selection overrides it.

```sh
./zig-out/bin/zenkai --theme=dracula
./zig-out/bin/zenkai --theme=./my-custom-theme.qss
```

Name one of the 65 built-in themes or point at a `.qss` file. See [screenshots](screenshots/) to save yourself the trouble of running each individually.

Uses an icon grid with a pill-shaped search bar:

<p align="center">
<img width="450" alt="launchpad" src="screenshots/launchpad-cropped.png" />
</p>

### `--fullscreen`

Opens the launcher in fullscreen mode on the selected monitor (or the cursor's monitor). Uses `ShowFullScreen()` internally. On Wayland, this auto-switches to XWayland when combined with `--monitor=N` since Wayland compositors ignore output assignment requests.

```sh
./zig-out/bin/zenkai --theme=launchpad --fullscreen
./zig-out/bin/zenkai --theme=launchpad --fullscreen --monitor=1
```

### `--monitor=N`

Select monitor by index (0-based). Defaults to the monitor the cursor is on. Use `--list-monitors` to see available indices.

```sh
./zig-out/bin/zenkai --monitor=0
./zig-out/bin/zenkai --fullscreen --monitor=1
```

### `--list-monitors`

Prints all available monitors with their index, name, geometry, and whether each is the primary display.

```sh
./zig-out/bin/zenkai --list-monitors
```

### `--list-themes`

Dumps every theme name and description to the terminal and exits.

### `--size=<pixels>`

Icon size. Default 32.

### `--width=<pixels>`

Window width. Default 600.

### `--height=<pixels>`

Window height. Default 500.

### `--menu=<name>|<cmd>|<icon>`

```sh
./zig-out/bin/zenkai --menu="Terminal|alacritty|terminal"
```

Adds a custom entry. Pipe separates name, command, icon. Pass it more than once for more entries. Skips .desktop file scanning entirely.

### `--no-dapps`

Skips `.desktop` file scanning. Use this when you only want plugins or `--menu` entries.

### `--no-plugins`

Skips loading plugins.

### `--window-switcher`

Starts as a dedicated window switcher. Open windows are listed immediately, and typing filters them without the `win:` prefix. Desktop application scanning is skipped.

```sh
./zig-out/bin/zenkai --window-switcher
```

### `--run`

Opens Zenkai in Windows Run mode. Type a command or URL and press Enter to open it with the Windows shell, without a `run:` prefix.

```powershell
zenkai.exe --run
```

### `--plugin=<name>`

```sh
./zig-out/bin/zenkai --plugin=calculator
./zig-out/bin/zenkai --plugin=calculator --plugin=notes
```

Only loads plugins with a matching directory name. Repeatable.

### `--no-icons`

Hides icons in the list.

### `--no-bottom-bar`

Hides the bottom bar.

### `--show-actions`

Parses `[Desktop Action ...]` entries from .desktop files (e.g. "New Window", "New Private Window").

### `--actions-bottombar`

Shows desktop actions in the bottom bar instead of the list.

### `--close-on-focus-out`

Closes the launcher when it loses focus.

### `--no-close-on-focus-out`

Keeps the launcher open when it loses focus.

### `--show-backdrop`

Shows a transparent fullscreen layer behind the launcher. Clicking it closes the launcher.

### `--clipboard=<cmd>`

Pipes content into a command instead of opening it. Hook this up with `api.open_url()` in plugins.

```sh
./zig-out/bin/zenkai --clipboard="xclip -selection c"
./zig-out/bin/zenkai --clipboard="wl-copy"
```

No more `xdg-open` launching a browser when you just want a URL in your clipboard.

### `--url-handler=<cmd>`

Tells plugins what to run when they want to open a URL. Defaults to `xdg-open`.

```sh
./zig-out/bin/zenkai --url-handler="firefox --new-tab"
```

### `--verbose`, `-v`

Makes it talk more.

### `--debug`

Makes it talk more and prints how long everything took to start up.

### `--benchmark-all`

Prints timing for every stage of startup.

### `--theme-reloader`

Watches `.qss` files and applies changes on the fly. Needs `--debug`.

### `--help`, `-h`

Prints everything you can pass and bails out.

## Examples

```sh
# Everyday launch
./zig-out/bin/zenkai

# Dracula theme, bigger icons, wider window
./zig-out/bin/zenkai --theme=dracula --size=48 --width=800

# Launch with a custom menu, skip .desktop scanning
./zig-out/bin/zenkai --menu="Firefox|firefox|firefox" --menu="Terminal|alacritty|terminal"

# Minimal look, no icons, no bottom bar
./zig-out/bin/zenkai --no-icons --no-bottom-bar

# Copy URLs to clipboard instead of opening them
./zig-out/bin/zenkai --clipboard="wl-copy"

# Quit when clicking outside the launcher
./zig-out/bin/zenkai --close-on-focus-out

# See how fast it starts
./zig-out/bin/zenkai --debug

# Hot-reload a theme you are working on
./zig-out/bin/zenkai --debug --theme-reloader --theme=./my-theme.qss

# Low memory mode (Nvidia or otherwise)
./zenkai.sh

# Plugin-only mode, no desktop apps
./zig-out/bin/zenkai --no-dapps --plugin=calculator

# Calculator with a theme, no icons
./zig-out/bin/zenkai --no-dapps --plugin=calculator --theme=dracula --no-icons
```

### Lower memory usage

On Nvidia or if you just want a lighter footprint, the included `zenkai.sh` wrapper sets some environment variables that bring RAM down to 20-50MB.

### Plugins

Drop a directory into `external/plugins/` with a `manifest.json` and a `main.lua` and the launcher picks it up automatically. No flags needed.

Plugin discovery and ordinary plugin initialization are queued after the list's first paint. If a query arrives first, initialization happens before that query is dispatched so its results are not lost. Plugins run on the GUI thread; this defers their cost rather than moving it to a worker thread.

Plugins used only for specific queries can opt into lazy loading with an optional manifest field:

```json
"activation_prefixes": ["run:"]
```

The manifest is discovered after the first paint, but the Lua script and its configuration are not loaded until a query starts with one of these prefixes (ASCII case-insensitive). Prefix matching is literal: `run:` matches `RUN: echo hello`, but not `run`. Once activated, the plugin keeps its Lua state until the launcher exits. Its `on_startup` hook runs once, before its first query. Other hooks only begin participating after activation; a plugin that needs lifecycle events from startup should omit this field. Empty lists or lists containing an empty prefix fall back to ordinary initialization. Plugins that never activate do not receive close/shutdown hooks. The bundled run, Hyprland, and macOS palettes opt in; the calculator initializes after the first paint because its queries have no dedicated prefix.

`--plugin=NAME` still restricts discovery to the named directories, and `--no-plugins` skips plugin work entirely.

Application icons are resolved and cached when a row is actually painted. Layout uses a transparent placeholder of the configured icon size, so measuring offscreen rows does not load their icons. Scrolling resolves newly visible icons on demand; there is no eager pass over the remaining list. Application refresh invalidates the cache, and new plugin results discard their previous icons.

#### manifest.json

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "main": "main.lua",
  "description": "What it does",
  "author": "you"
}
```

Hooks are detected automatically from your Lua functions. The available hooks:

- `on_query(query)` - called when the user types, add results with `api.add_result()`
- `on_open(id)` - called when a result is selected, `id` matches what `add_result` returned

#### API

```lua
-- Add a result to the list
-- Returns an id that gets passed to on_open()
api.add_result(title, subtitle, icon_name, result_type)

-- Open a URL when the result is selected
api.open_url("https://example.com")

-- Print to the debug log
api.log("something happened")
```

`result_type` is optional. Use `"NoReturn"` to keep the launcher open after selecting the result (like a calculator showing an answer). The default `"ExecCmd"` closes the launcher and fires `on_open`.

#### Example

```lua
function on_query(query)
  if query == "ping" then
    api.add_result("Pong!", "it works", "face-smile", "NoReturn")
  end
end
```

See `external/plugins/calculator/` for a full working example.

### Productivity plugins

These use the same Lua hooks and plugin configuration as the other bundled
plugins. `--no-plugins` disables them; `--plugin=NAME` can select them individually.

| Query | Action |
| --- | --- |
| `2 + 3 * 4` | Show the calculator answer; Enter copies it and keeps the launcher open. |
| `link: zig allocator` | Search Google or GitHub for the query. Enter opens the selected result. |
| `link: docs` | Find a saved link by its title. |
| `snip: greeting` | Find a saved snippet by title or description. Enter copies its full text. |
| `www.google.com` | Suggest opening `https://www.google.com` in the system default browser. |
| `win: editor` | Find an open window by title or application name; Enter switches to it. |

Quicklinks and snippets load only when their prefixes are used. Prefixes are
case-insensitive. Snippets copy text; they do not type it into another app.

Copy the plugin's `config.example.json` to
`<config directory>/<plugin name>.json`, then edit it. On Windows,
the config directory is `%APPDATA%/zenkai`; on Linux it is
`${XDG_CONFIG_HOME:-~/.config}/zenkai`. Restart the launcher after changing it.
A `config.json` beside the plugin's `main.lua` is also supported as a fallback.

Quicklinks use `commands` entries with a `title` and an HTTP(S) `url`. A
`{query}` placeholder is replaced with URL-encoded search text. Set `"replace":
true` to omit the bundled Google and GitHub searches. Snippets use `title`,
optional `subtitle`, and `text`; JSON `\n` escapes preserve line breaks.

```lua
-- Copy text through the launcher's native clipboard.
-- Returns true when a clipboard handler is available.
api.copy_text("Text to copy")
```

`on_open(id)` runs for both result types. `"NoReturn"` keeps the launcher open
after the hook, so plugins can copy a value without closing the search.

The bottom bar is visible by default, including when the search has no results.
Only `--no-bottom-bar` omits it. **Ctrl+K** toggles the searchable Actions pane
for the selected result, including when the footer is hidden. It occupies the
same right-hand panel as file previews, restoring the preview when dismissed.
Type to filter, scroll with the mouse wheel or scrollbar, use Up/Down or
Page Up/Page Down to navigate, Enter to run, and Escape to dismiss. Application actions
loaded with `--actions-bottombar` and plugin actions keep Ctrl+1…Ctrl+0 shortcuts
for their first ten entries; the menu displays all actions.

### Files and folders

The bundled `files` Lua plugin browses explicit paths and searches filenames:

| Query | Behavior |
| --- | --- |
| `/home/dayvster/workspace` | Browse the directory on Linux. |
| `~/Documents` | Browse a home directory path on Linux or macOS. |
| `C:\Users\dayvi\Workspace` or `C:/Users/dayvi/Workspace` | Browse a Windows directory. |
| `~\Workspace` | Browse a Windows home directory path. |
| `~/Documents/repo` | Show an exact path, or filter its parent by the partial filename. |
| `file: report` | Search filenames recursively under the configured roots (home by default). |
| `file:` | Browse home. |

Enter browses folders inside Zenkai and opens files with their default app.
The `..` row navigates up. Directories show folders first and page in groups of
128. Explicit browsing includes hidden entries. File and folder icons come from
Qt's native file icon provider on Windows, macOS, and Linux; `--no-icons` still
hides them. Linux opening requires `xdg-open`.

Search is incremental, not indexed: select **Continue searching** to scan the
next folders. Each step scans up to four directory pages and returns up to 100
matches. Matches use case-insensitive ASCII substring matching. Search skips
symlink directories and common dependency/cache directories; unavailable folders
are reported. Individual directories larger than 100,000 entries are rejected.
Network and large directories can still take time to enumerate.

Copy `external/plugins/files/config.example.json` to the config directory as
`files.json` and customize it. Windows uses `%APPDATA%\zenkai\files.json`;
Linux and macOS use `${XDG_CONFIG_HOME:-~/.config}/zenkai/files.json`.
Use forward slashes or escaped backslashes in JSON Windows paths:

```json
{
  "roots": ["~/Workspace", "~/Documents"],
  "exclude": [".git", "node_modules", ".cache", ".zig-cache", "zig-pkg", "Library", "AppData"],
  "include_hidden": false
}
```

Restart after changing configuration. Explicit paths work outside the search
roots. Use `--plugin=files` to load only this plugin or `--no-plugins` to disable it.

### Result actions

The Actions menu includes common actions such as Copy Name and Copy Launch
Command, plus actions supplied by the selected result:

- Files: Open with Default App, Copy Path, Browse Containing Folder, Refresh.
- Folders: Open in File Manager, Copy Path, Browse Folder, Refresh.
- Windows: Switch to Window, Copy Window Title, Refresh Windows.
- URLs and quicklinks: Copy URL.
- Snippets: Copy Snippet.
- Calculator: Copy Result and Copy Expression.
- Browser applications: New Window and New Private Window (InPrivate for Edge).

Browser actions are detected when opening the menu, without adding startup work.
Supported executables include Chrome, Chromium, Brave, Vivaldi, Edge, Firefox,
and LibreWolf, including recognized Flatpak/Snap application IDs. Windows resolves
ordinary named browser shortcuts to their executable; shortcut-specific arguments
are not inherited. Direct launch commands retain profile/package arguments.
macOS invokes the browser's bundle executable so a running browser receives the
window request. Safari, opaque shell wrappers, and recognized web-app/kiosk entries
do not receive these actions. These actions apply to application results.

Launch options follow the browsers' implementations:
[Chromium switches](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/chrome_switches.cc),
[Brave flags](https://support.brave.com/hc/en-us/articles/360044860011-How-Do-I-Use-Command-Line-Flags-in-Brave),
and [Firefox parameters](https://firefox-source-docs.mozilla.org/browser/CommandLineParameters.html).

Lua plugins register actions during `on_query` and handle them separately:

```lua
local id = api.add_result("Example", "Description", "edit-copy", "NoReturn")
api.add_action(id, "Copy Value", 1, "edit-copy")

function on_action(result_id, action_id)
    if action_id == 1 then api.copy_text("Value") end
end
```

Up to 64 actions may be attached to each result. Actions keep the launcher open
unless the hook calls `api.close()`. `api.set_query(text)` from `on_open` or
`on_action` changes the query after the hook returns, so plugins can navigate
without rebuilding results during a Lua callback. Calls from `on_query` are
ignored.

Filesystem primitives are available to plugins; traversal policy stays in Lua:

```lua
local entry, err = api.path_info("~/Documents")
-- entry: path, name, parent, is_dir, is_link, icon
local page, err = api.read_dir("~/Documents", 0, "report")
-- page: path, parent, entries, more; offset and filename filter are optional
local ok, err = api.open_path("~/Documents/report.pdf")
```

Paths are passed as native paths/arguments, not shell commands. Missing paths
and filesystem errors return `nil, message`.

### File actions

Select a files-plugin result and press **Ctrl+K** for:

- **Reveal in File Manager**: select the item in Explorer or Finder. Linux uses
  `org.freedesktop.FileManager1.ShowItems` via `dbus-send`; if unavailable, it opens
  the containing folder with `xdg-open`.
- **New File… / New Folder…**: enter a name to create an empty file or folder
  inside the selected folder, or beside a selected file. Empty-folder results
  also provide these actions.
- **Rename…**: change the selected item's name in its existing directory.
- **Move to Trash…**: confirm the specific path before moving it to the OS trash
  or recycle bin. Cancel is the default button. There is no permanent-delete
  fallback.

Create and rename never replace existing destinations. Names must be a single
component, not a path. Filesystem roots cannot be renamed or trashed. Errors keep
the launcher open and appear in the results; successful changes refresh navigation.
Dialog cancellation leaves the query and filesystem unchanged.

Trash uses [Qt's native trash support](https://doc.qt.io/qt-6.8/qfile.html#moveToTrash):
Windows/macOS APIs and the freedesktop trash specification on Linux. Some mounts
cannot provide trash support; those return an error. Symlinks are trashed as links.
Restore trashed items using your OS file manager.

The Lua plugin chooses the actions and navigation. `api.file_action(operation, path)`
is available only during `on_action`; operations are `reveal`, `new_file`,
`new_folder`, `rename`, and `trash`. Native code provides dialogs and filesystem
operations without shell interpolation. It returns the resulting path, or
`nil, message` (`"cancelled"` when a dialog is dismissed).

### File previews

Enable the preview pane with `--file-previews`, or set `file_previews = true`
in `zenkai.conf`. It is off by default. `--no-file-previews` overrides the config;
if both flags are supplied, the last one wins.

Press **Ctrl+P** (**Command+P** on macOS) to toggle previews for the current
session, including when they were disabled at launch. This does not change the
config file. The pane appears when a file result is selected.

Code previews highlight comments, strings, numbers, and common keywords for
Zig, Lua, C/C++, Rust, Go, JavaScript/TypeScript, Python, shell scripts, JSON,
and other common code/config extensions. Colors adapt to the editor palette.
This is lightweight lexical highlighting, not a full language parser; advanced
constructs such as embedded languages and multiline string literals may be plain
or imperfectly colored. Unknown extensions retain plain text previews.

Select a result from `file:` search or explicit path browsing to preview it.
The pane shows UTF-8 text up to 128 KiB, supported raster images up to 16 MiB
and 16 megapixels, or the first 64 entries in a directory. Images keep their
aspect ratio; animated images show a single frame. Binary files, unsupported
encodings, and oversized images show metadata or an explanation instead.
HTML is displayed as plain text. No document scripts or external viewers run.

Previews use the same Qt implementation on Windows, macOS, and Linux. They also
work with `--no-bottom-bar` and `--no-icons`. The pane uses part of the configured
window width; `--width=900` provides more room. Other result types hide the pane.
Rapid selection changes cancel the pending preview. Reading begins after a
120 ms delay; slow network or removable filesystems can still delay the UI.

Lua plugins can attach an absolute file path to a result during `on_query`:

```lua
api.set_preview(result_id, absolute_path)
```

The UI reads that path only when previews are enabled and the result is selected.

### Scientific calculator and conversions

The bundled `calculator` Lua plugin accepts expressions directly in the search bar:

| Example | Result |
| --- | --- |
| `sqrt(144) + max(2, 3)` | `15` |
| `sin(pi / 2)` | `1` (trigonometry uses radians) |
| `1e3 / 4` | `250` |
| `15% of 80` | `12` |
| `100 cm to m` | `1 m` |
| `32 f to c` | `0 c` |
| `2 GiB to MiB` | `2048 MiB` |
| `100 USD to EUR` | Latest available reference rate, with its date |

Functions include `sqrt`, `abs`, `floor`, `ceil`, `round`, `min`, `max`,
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `ln`, `log` (base 10), `exp`,
`rad`, and `deg`; constants are `pi`, `tau`, and `e`. Conversions support
length, mass, time, volume, speed, temperature, angles, and data sizes.
Data units distinguish bits (`Mb`) from bytes (`MB`) and decimal from binary (`MiB`).
Enter copies the result; Ctrl+K also offers Copy Expression.

Currency requests and parsing are implemented in Lua using the asynchronous native
`api.http_get` bridge. [Frankfurter](https://frankfurter.dev/) supplies daily
reference rates without an API key; these are not intraday trading quotes.
Only currency codes are sent, never the amount. The dated rate is cached for the
launcher session. Offline failures show an unavailable result; restart to retry.
Normal calculations and unit conversions work offline.

For plugin authors, `api.http_get(https_url)` returns `nil, "pending"` while
fetching, then `body, "ok"`, or `nil, error_message`. Completion dispatches
`on_idle`, where the plugin can request a query refresh with `api.set_query`.
Responses are cached until exit, capped at 64 KiB each and 32 distinct URLs per
session, with a five-second transfer inactivity timeout. TLS certificates are
validated by Qt. No external interpreter or command-line HTTP tool is required.

### Window switcher

Window switching is built into the Zig core. Type `win:` to list open windows,
filter by title or application name, and focus the selected window. It omits
Zenkai itself. It is enabled by default, works with `--no-plugins`, and can be
disabled independently with `--no-window-switcher`. Pass `--window-switcher` to
start directly in this mode with the window list already populated and the
`win:` prefix optional. Run mode does not use it.
Clear back to `win:` (or clear the search in window-switcher mode) to refresh
the window list; typing a filter searches the snapshot without repeatedly
starting desktop tools. Failed focus keeps the launcher open and displays the
error; changing the query refreshes the list.

Select a window result and press **Ctrl+K** for Left/Right/Top/Bottom Half,
Maximize, Center Window, and Move to Next Display. Layouts use monitor work
areas, including negative monitor coordinates and desktop scaling. Center and
Next Display preserve the window size when it fits. Applications may enforce a
minimum size. On macOS, Maximize fills the desktop rather than creating a new
fullscreen Space. Hyprland and Sway actions make tiled windows floating; leave
Hyprland fullscreen mode before arranging a window.

Window results display the owning application's icon: executable icons on
Windows, application bundle icons on macOS, and desktop entry `Icon` values on
Linux (matched by app ID or `StartupWMClass`). Missing metadata falls back to
the usual launcher icon. Linux searches the XDG data directories, including
user-installed desktop entries.

| Platform | Backend and requirements |
| --- | --- |
| Windows | Native Win32 enumeration and focus; minimized windows are restored. No helper installation. |
| macOS | Native AppKit and Accessibility APIs called from Zig. Allow Zenkai Accessibility access in System Settings → Privacy & Security. |
| Linux / X11 | Install `wmctrl` and `xrandr` for window layouts; the window manager must support EWMH. |
| Linux / Hyprland | `hyprctl` in PATH and the compositor's session environment. |
| Linux / Sway | `swaymsg` in PATH and the compositor's session environment. |

Other Wayland compositors, including GNOME and KDE Wayland, currently show an
unsupported-session message. They require their own compositor integration;
XWayland alone cannot enumerate their native Wayland windows. macOS retains the
exact native window reference until the list is refreshed. The macOS and Linux
backends have not been tested on a live desktop
from this Windows development environment.

### Automatic URL suggestions

URL suggestions display the system default browser's icon, separately for HTTP
and HTTPS. Windows uses protocol associations, macOS uses NSWorkspace, and Linux
uses `xdg-mime` plus the handler's desktop entry. The URL plugin caches those
descriptors for its lifetime; restart Zenkai after changing your default browser.
Native icons are loaded through Qt only when their result row is painted, and
`--no-icons` still hides them.

The `url` Lua plugin uses anchored Lua patterns and host/port validation to
recognize HTTP(S) URLs, bare domains, IPv4 addresses, and `localhost:PORT`.
Bare domains default to HTTPS; localhost with a port defaults to HTTP. Paths,
queries, and fragments are preserved. Ordinary multiword searches, email
addresses, unsupported schemes, and malformed hosts are ignored. Unicode
domains should be entered in their ASCII/punycode form; IPv6 literals are not
currently recognized.

Opening requires selecting the suggestion and pressing Enter. This plugin uses
the system default browser, independent of `--clipboard` and `--url-handler`.
Disable it with `--no-plugins`, or use `--plugin=NAME` to select other plugins.

The native services are also available to other Lua plugins:

```lua
api.open_browser("https://example.com") -- system browser; HTTP(S) only
local icon = api.browser_icon("https") -- default handler's icon; also accepts "http"
api.close() -- request closing after on_open, including for NoReturn results
```
