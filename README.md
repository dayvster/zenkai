<p align="center">
  <img src="assets/logo.png" alt="zenkai logo" />
</p>

# zenkai

A fast app launcher for Linux. Written in Zig with Qt6.

Scans your .desktop files from the usual places, shows you everything in a searchable list, and lets you filter through it as you type with fuzzy matching.

Thanks to [rcalixte](https://github.com/rcalixte) for [libqt6zig](https://github.com/rcalixte/libqt6zig), the Zig bindings this project is built on.

## Requirements

- Zig 0.16.0
- Qt 6.8.2 (Core, Gui, Widgets)
- C++ toolchain
- [libqt6zig](https://github.com/rcalixte/libqt6zig) (fetched automatically by `zig build fetch`)

## Build

```sh
zig build fetch
zig build
zig build run
```

Binary at `zig-out/bin/zenkai`.

## Run 
For optimal results especially if you are using a Nvidia graphics card I've included `zenkai.sh` with some sane defaults that brings the RAM usage of the launcher down to 20-50MB 

*Your results may vary


## Status

v0.1. Core loop works — scan, search, filter. What's missing: no app launching, no icons in the list, theme switching isn't wired. Getting there.
