const std = @import("std");
const log = @import("utils").log;

pub const Config = struct {
    icon_size: ?i32,
    start_timer: bool,
    benchmark_all: bool,
    no_bottom_bar: bool,
    no_icons: bool,
    theme: ?[]const u8,
    show_actions: bool,
    actions_bottombar: bool,
    window_width: ?i32,
    window_height: ?i32,
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

pub fn deinitMenuEntries(allocator: std.mem.Allocator, entries: []MenuEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.cmd);
        allocator.free(e.icon);
    }
    allocator.free(entries);
}

pub fn parse(args: [][:0]u8) Config {
    var cfg: Config = .{
        .icon_size = null,
        .start_timer = false,
        .benchmark_all = false,
        .no_bottom_bar = false,
        .no_icons = false,
        .theme = null,
        .show_actions = false,
        .actions_bottombar = false,
        .window_width = null,
        .window_height = null,
    };

    for (args) |arg_slice| {
        const arg: []const u8 = arg_slice;
        if (std.mem.startsWith(u8, arg, "--size=")) {
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
        }
    }

    return cfg;
}
