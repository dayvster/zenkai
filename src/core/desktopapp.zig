const std = @import("std");

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

    pub const Type = enum {
        Application,
        Link,
        Directory,
    };

    pub fn deinit(self: *DesktopEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);

        if (self.version) |s| allocator.free(s);
        if (self.generic_name) |s| allocator.free(s);
        if (self.comment) |s| allocator.free(s);
        if (self.icon) |s| allocator.free(s);
        if (self.try_exec) |s| allocator.free(s);
        if (self.exec) |s| allocator.free(s);
        if (self.path) |s| allocator.free(s);
        if (self.file_path) |s| allocator.free(s);
        if (self.startup_wm_class) |s| allocator.free(s);
        if (self.url) |s| allocator.free(s);

        freeStringSlice(allocator, self.only_show_in);
        freeStringSlice(allocator, self.not_show_in);
        freeStringSlice(allocator, self.actions);
        freeStringSlice(allocator, self.mime_type);
        freeStringSlice(allocator, self.categories);
        freeStringSlice(allocator, self.implements);
        freeStringSlice(allocator, self.keywords);

        var extra_iter = self.extra.iterator();
        while (extra_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.extra.deinit();
    }

    pub fn expandExec(self: *const DesktopEntry, allocator: std.mem.Allocator) ![]const u8 {
        const exec = self.exec orelse return error.NoExec;

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        var i: usize = 0;
        while (i < exec.len) {
            if (exec[i] == '%' and i + 1 < exec.len) {
                switch (exec[i + 1]) {
                    '%' => try buf.append(allocator, '%'),
                    'f', 'F', 'u', 'U' => {},
                    'i' => {
                        if (self.icon) |icon| {
                            try buf.appendSlice(allocator, "--icon ");
                            try shellQuote(allocator, &buf, icon);
                        }
                    },
                    'c' => try shellQuote(allocator, &buf, self.name),
                    'k' => {
                        if (self.file_path) |fp| try shellQuote(allocator, &buf, fp);
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

    fn freeStringSlice(allocator: std.mem.Allocator, slice: [][]const u8) void {
        for (slice) |s| {
            allocator.free(s);
        }
        allocator.free(slice);
    }
};
