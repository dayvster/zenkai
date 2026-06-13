# Contributing

## Prerequisites

- Zig 0.16.0
- GCC / Clang (for linking C++ code)
- libstdc++ (or libc++)
- Qt 6.8.2 development libraries (Core, Gui, Widgets)
- pkg-config

## Building

```sh
zig build          # build release binary
zig build check    # check compilation (no binary)
zig build run      # build and run
```

## Formatting

Run `zig fmt` before committing:

```sh
zig fmt src/
```

## Testing

```sh
zig build test
```

## Commit messages

```
<type>: short description
```

Keep it concise. No AI-generated commit messages.

## Pull requests

Fork the repo, make your changes on a branch in your fork, then open a PR back upstream.

- One change per PR
- Keep the history clean - no merge commits
- Make sure it compiles and tests pass

### PR description format

```
## Fixes

<what your PR fixes or adds>

## Reasoning

<why this approach, what problem it solves>
```

Other formats are fine too as long as you reasonably explain what you changed and why.

Low quality PRs - AI-generated refactoring, readme rewrites, dependency bumps without reason, or anything that looks like busywork - will be closed without discussion.

## License

By contributing, you agree that your work will be licensed under GPLv3, same as the rest of the project.
