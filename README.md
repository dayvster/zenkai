<p align="center">
  <img src="assets/logo.png" alt="zenkai logo" />
</p>

# zenkai


A fast app launcher for Linux. Written in Zig with Qt6.

Scans your .desktop files from the usual places, shows you everything in a searchable list, and lets you filter through it as you type with fuzzy matching. Built because apparently 50 other launchers weren't enough.

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

- **Zig 0.16.0** - the compiler and build system. Download from [ziglang.org/download](https://ziglang.org/download/) or use your distro's package manager if it has a recent enough version.
- **Qt 6.8.2 development libraries** (Core, Gui, Widgets) - the GUI toolkit. Install `qt6-base-dev` or equivalent for your distro.
- **GCC or Clang** - used by Zig to link C++ code (Qt is written in C++).
- **libstdc++ or libc++** - the C++ standard library, comes with your compiler.
- **pkg-config** - helps the build system find Qt headers and libraries.

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

Download the tarball for your architecture from [ziglang.org/download](https://ziglang.org/download/), extract it, and put the `zig` binary somewhere in your `PATH`. Most distro repositories lag behind and 0.16.0 is required.

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

### `--theme=<theme>`

```sh
./zig-out/bin/zenkai --theme=dracula
./zig-out/bin/zenkai --theme=./my-custom-theme.qss
```

Name one of the 65 built-in themes or point at a `.qss` file. See [screenshots](screenshots/) to save yourself the trouble of running each individually.

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
