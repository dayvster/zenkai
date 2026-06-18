const std = @import("std");
const log = @import("utils").log;

pub const help =
    \\Usage: zenkai [options]
    \\
    \\Options:
    \\  --menu=name|cmd|icon      Add a custom menu entry
    \\  --size=N                  Icon size in pixels
    \\  --width=N                 Window width in pixels
    \\  --height=N                Window height in pixels
    \\  --theme=NAME              Theme (dark, light, dracula, ayu-dark, minimal, or path)
    \\  --debug                   Start debug timer
    \\  --theme-reloader          Enable live QSS reloading (requires --debug)
    \\  --verbose, -v             Verbose logging
    \\  --benchmark-all           Benchmark all stages
    \\  --no-icons                Hide icons
    \\  --no-bottom-bar           Hide bottom bar
    \\  --show-actions            Show item actions
    \\  --actions-bottombar       Show actions in bottom bar
    \\  --list-themes             List all available themes with descriptions
    \\  --close-on-focus-out     Close the launcher when it loses focus
    \\  --no-close-on-focus-out  Keep the launcher open when it loses focus
    \\  --show-backdrop           Show a backdrop to detect clicks outside the launcher
    \\  --clipboard=CMD           Clipboard command for ExecCmd plugin results (e.g. xclip -selection c)
    \\  --url-handler=CMD         URL handler for plugin open_url results (e.g. xdg-open, firefox)
    \\  --no-dapps                Skip scanning desktop applications (useful for plugin-only usage)
    \\  --no-plugins              Skip loading plugins
    \\  --plugin=NAME             Only load the specified plugin (may be repeated)
    \\  --language=CODE           Translation language code (e.g. fr, de)
    \\  --help, -h                Show this help and exit
;

pub const Config = struct {
    icon_size: ?i32,
    start_timer: bool,
    theme_reloader: bool,
    benchmark_all: bool,
    no_bottom_bar: bool,
    no_icons: bool,
    theme: ?[]const u8,
    show_actions: bool,
    actions_bottombar: bool,
    list_themes: bool,
    close_on_focus_out: ?bool,
    show_backdrop: bool,
    window_width: ?i32,
    window_height: ?i32,
    clipboard: ?[]const u8,
    url_handler: ?[]const u8,
    no_dapps: bool,
    no_plugins: bool,
    language: ?[]const u8,
};

pub const MenuEntry = struct {
    name: []const u8,
    cmd: []const u8,
    icon: []const u8,
};

pub fn parseMenus(allocator: std.mem.Allocator, args: [][:0]u8) ![]MenuEntry {
    var menus = std.ArrayList(MenuEntry).empty;
    errdefer {
        for (menus.items) |m| {
            allocator.free(m.name);
            allocator.free(m.cmd);
            allocator.free(m.icon);
        }
        menus.deinit(allocator);
    }

    for (args) |arg_slice| {
        const arg: []const u8 = arg_slice;
        if (std.mem.startsWith(u8, arg, "--menu=")) {
            const val = arg["--menu=".len..];
            if (val.len == 0) continue;

            var it = std.mem.splitScalar(u8, val, '|');
            const name = it.first();
            const cmd = it.next() orelse continue;
            const icon = it.next() orelse "";

            try menus.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .cmd = try allocator.dupe(u8, cmd),
                .icon = try allocator.dupe(u8, icon),
            });
        }
    }

    return try menus.toOwnedSlice(allocator);
}

pub fn show_help() void {
    std.debug.print("{s}", .{help});
}

pub fn deinitMenuEntries(allocator: std.mem.Allocator, entries: []MenuEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.cmd);
        allocator.free(e.icon);
    }
    allocator.free(entries);
}

pub fn parsePluginNames(allocator: std.mem.Allocator, args: [][:0]u8) ![][]const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    for (args) |arg_slice| {
        const arg: []const u8 = arg_slice;
        if (std.mem.startsWith(u8, arg, "--plugin=")) {
            const val = arg["--plugin=".len..];
            if (val.len == 0) continue;
            try names.append(allocator, try allocator.dupe(u8, val));
        }
    }

    return try names.toOwnedSlice(allocator);
}

pub fn deinitPluginNames(allocator: std.mem.Allocator, names: [][]const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

pub fn parse(args: [][:0]u8) Config {
    var cfg: Config = .{
        .icon_size = null,
        .start_timer = false,
        .theme_reloader = false,
        .benchmark_all = false,
        .no_bottom_bar = false,
        .no_icons = false,
        .theme = null,
        .show_actions = false,
        .actions_bottombar = false,
        .list_themes = false,
        .close_on_focus_out = null,
        .show_backdrop = false,
        .window_width = null,
        .window_height = null,
        .clipboard = null,
        .url_handler = null,
        .no_dapps = false,
        .no_plugins = false,
        .language = null,
    };

    for (args) |arg_slice| {
        const arg: []const u8 = arg_slice;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help();
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "--size=")) {
            cfg.icon_size = std.fmt.parseInt(i32, arg["--size=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            cfg.window_width = std.fmt.parseInt(i32, arg["--width=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--height=")) {
            cfg.window_height = std.fmt.parseInt(i32, arg["--height=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            log.verbose = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            cfg.start_timer = true;
            log.verbose = true;
        } else if (std.mem.eql(u8, arg, "--theme-reloader")) {
            cfg.theme_reloader = true;
        } else if (std.mem.startsWith(u8, arg, "--theme=")) {
            const val = arg["--theme=".len..];
            cfg.theme = if (val.len > 0) val else null;
        } else if (std.mem.eql(u8, arg, "--benchmark-all")) {
            cfg.benchmark_all = true;
            log.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-icons")) {
            cfg.no_icons = true;
        } else if (std.mem.eql(u8, arg, "--no-bottom-bar")) {
            cfg.no_bottom_bar = true;
        } else if (std.mem.eql(u8, arg, "--show-actions")) {
            cfg.show_actions = true;
        } else if (std.mem.eql(u8, arg, "--actions-bottombar")) {
            cfg.actions_bottombar = true;
        } else if (std.mem.eql(u8, arg, "--close-on-focus-out")) {
            cfg.close_on_focus_out = true;
        } else if (std.mem.eql(u8, arg, "--no-close-on-focus-out")) {
            cfg.close_on_focus_out = false;
        } else if (std.mem.eql(u8, arg, "--show-backdrop")) {
            cfg.show_backdrop = true;
        } else if (std.mem.startsWith(u8, arg, "--clipboard=")) {
            const val = arg["--clipboard=".len..];
            cfg.clipboard = if (val.len > 0) val else null;
        } else if (std.mem.startsWith(u8, arg, "--url-handler=")) {
            const val = arg["--url-handler=".len..];
            cfg.url_handler = if (val.len > 0) val else null;
        } else if (std.mem.eql(u8, arg, "--no-dapps")) {
            cfg.no_dapps = true;
        } else if (std.mem.eql(u8, arg, "--no-plugins")) {
            cfg.no_plugins = true;
        } else if (std.mem.startsWith(u8, arg, "--language=")) {
            const val = arg["--language=".len..];
            cfg.language = if (val.len > 0) val else null;
        } else if (std.mem.eql(u8, arg, "--list-themes")) {
            cfg.list_themes = true;
        }
    }

    return cfg;
}
