const std = @import("std");
const utils = @import("utils");

pub const DesktopApp = DesktopEntry;

pub const DesktopEntry = struct {
    type: Type,
    name: []const u8,

    version: ?[]const u8 = null,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    try_exec: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    path: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    startup_wm_class: ?[]const u8 = null,
    url: ?[]const u8 = null,

    no_display: bool = false,
    hidden: bool = false,
    terminal: bool = false,
    dbus_activatable: bool = false,
    startup_notify: ?bool = null,
    prefers_non_default_gpu: bool = false,
    single_main_window: bool = false,

    only_show_in: [][]const u8 = &.{},
    not_show_in: [][]const u8 = &.{},
    actions: [][]const u8 = &.{},
    mime_type: [][]const u8 = &.{},
    categories: [][]const u8 = &.{},
    implements: [][]const u8 = &.{},
    keywords: [][]const u8 = &.{},

    extra: std.StringHashMap([]const u8),

    pub fn deinit(self: *DesktopEntry, allocator: std.mem.Allocator) void {
        if (self.categories.len > 0) allocator.free(self.categories);
        if (self.mime_type.len > 0) allocator.free(self.mime_type);
        if (self.keywords.len > 0) allocator.free(self.keywords);
        if (self.only_show_in.len > 0) allocator.free(self.only_show_in);
        if (self.not_show_in.len > 0) allocator.free(self.not_show_in);
        if (self.actions.len > 0) allocator.free(self.actions);
        if (self.implements.len > 0) allocator.free(self.implements);
        self.extra.deinit();
    }

    pub const Type = enum {
        Application,
        Link,
        Directory,
    };

    pub fn expandExec(self: *const DesktopEntry, allocator: std.mem.Allocator) ![]const u8 {
        const exec = self.exec orelse return error.NoExec;
        return expandExecString(exec, self, allocator);
    }

    const ArgvFlusher = struct {
        allocator: std.mem.Allocator,
        frag: *std.ArrayList(u8),
        out: *std.ArrayList([]const u8),

        fn run(self: *ArgvFlusher) !void {
            if (self.frag.items.len == 0) return;
            try self.out.append(self.allocator, try self.allocator.dupe(u8, self.frag.items));
            self.frag.clearRetainingCapacity();
        }
    };

    fn expandToken(allocator: std.mem.Allocator, entry: *const DesktopEntry, token: []const u8) ![]const []const u8 {
        var out = std.ArrayList([]const u8).empty;
        errdefer {
            for (out.items) |a| allocator.free(a);
            out.deinit(allocator);
        }
        var frag = std.ArrayList(u8).empty;
        defer frag.deinit(allocator);

        var flusher = ArgvFlusher{ .allocator = allocator, .frag = &frag, .out = &out };

        var i: usize = 0;
        while (i < token.len) {
            const c = token[i];
            if (c == '%' and i + 1 < token.len) {
                switch (token[i + 1]) {
                    'i' => {
                        try flusher.run();
                        if (entry.icon) |icon| {
                            if (icon.len > 0) {
                                try out.append(allocator, try allocator.dupe(u8, "--icon"));
                                try out.append(allocator, try allocator.dupe(u8, icon));
                            }
                        }
                    },
                    'c' => {
                        try flusher.run();
                        if (entry.name.len > 0) try out.append(allocator, try allocator.dupe(u8, entry.name));
                    },
                    'k' => {
                        try flusher.run();
                        if (entry.file_path) |fp| {
                            if (fp.len > 0) try out.append(allocator, try allocator.dupe(u8, fp));
                        }
                    },
                    'f', 'F', 'u', 'U' => try flusher.run(),
                    '%' => try frag.append(allocator, '%'),
                    'd', 'D', 'n', 'N', 'v', 'm' => {},
                    else => {},
                }
                i += 2;
            } else {
                try frag.append(allocator, c);
                i += 1;
            }
        }
        try flusher.run();

        return try out.toOwnedSlice(allocator);
    }

    pub fn buildCommandArgv(allocator: std.mem.Allocator, entry: *const DesktopEntry, exec: []const u8) ![]const []const u8 {
        if (exec.len == 0) return error.NoExec;

        const tokens = try utils.tokenizeCommandLine(allocator, exec);
        defer {
            for (tokens) |t| allocator.free(t);
            allocator.free(tokens);
        }

        var argv = std.ArrayList([]const u8).empty;
        errdefer {
            for (argv.items) |a| allocator.free(a);
            argv.deinit(allocator);
        }

        for (tokens) |token| {
            if (token.len == 0) continue;
            const expanded = try expandToken(allocator, entry, token);
            for (expanded, 0..) |e, idx| {
                if (e.len == 0) {
                    allocator.free(e);
                    continue;
                }
                argv.append(allocator, e) catch |err| {
                    for (expanded[idx..]) |rest| allocator.free(rest);
                    allocator.free(expanded);
                    return err;
                };
            }
            allocator.free(expanded);
        }

        if (argv.items.len == 0) return error.NoExec;
        return try argv.toOwnedSlice(allocator);
    }

    pub fn commandArgv(self: *const DesktopEntry, allocator: std.mem.Allocator) ![]const []const u8 {
        const exec = self.exec orelse return error.NoExec;
        return buildCommandArgv(allocator, self, exec);
    }

    pub fn expandExecString(exec: []const u8, entry: *const DesktopEntry, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        var i: usize = 0;
        while (i < exec.len) {
            if (exec[i] == '%' and i + 1 < exec.len) {
                switch (exec[i + 1]) {
                    '%' => try buf.append(allocator, '%'),
                    'f', 'F', 'u', 'U' => {},
                    'i' => {
                        if (entry.icon) |icon| {
                            try buf.appendSlice(allocator, "--icon ");
                            try shellQuote(allocator, &buf, icon);
                        }
                    },
                    'c' => try shellQuote(allocator, &buf, entry.name),
                    'k' => {
                        if (entry.file_path) |fp| try shellQuote(allocator, &buf, fp);
                    },
                    else => {
                        try buf.append(allocator, '%');
                        try buf.append(allocator, exec[i + 1]);
                    },
                }
                i += 2;
            } else {
                try buf.append(allocator, exec[i]);
                i += 1;
            }
        }

        return try buf.toOwnedSlice(allocator);
    }

    fn shellQuote(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
        try buf.append(allocator, '\'');
        for (value) |c| {
            if (c == '\'') {
                try buf.appendSlice(allocator, "'\\''");
            } else {
                try buf.append(allocator, c);
            }
        }
        try buf.append(allocator, '\'');
    }
};
