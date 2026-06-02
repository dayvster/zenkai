const std = @import("std");
const de = @import("desktopapp");
const utils = @import("utils");

const CARRIAGE_RETURN = '\r';
const LINE_FEED = '\n';

pub const DappParser = struct {
    pub fn parseDesktopFile(allocator: std.mem.Allocator, content: []const u8) !de.DesktopApp {
        var app = initDefaultDapp(allocator);
        var no_display = false;

        var entry_iter = desktopEntryIterator(content);

        while (entry_iter.next()) |entry| {
            var line_iter = lineIterator(entry);
            while (line_iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;

                if (splitToKV(trimmed)) |kv| {
                    if (std.mem.indexOfScalar(u8, kv.key, '[') != null) continue;

                    if (utils.strcomp(kv.key, "NoDisplay") and utils.strcomp(kv.value, "true")) {
                        no_display = true;
                    }

                    try parseKeyValue(allocator, &app, kv.key, kv.value);
                }
            }
        }

        if (no_display) return error.NoDisplay;

        return app;
    }

    fn initDefaultDapp(allocator: std.mem.Allocator) de.DesktopApp {
        return de.DesktopApp{
            .name = "",
            .exec = null,
            .icon = null,
            .comment = null,
            .type = .Application,
            .extra = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn splitToKV(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
            const key = std.mem.trim(u8, line[0..eq_pos], " \t");
            const value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
            return .{ .key = key, .value = value };
        }
        return null;
    }

    fn parseKeyValue(allocator: std.mem.Allocator, app: *de.DesktopApp, key: []const u8, value: []const u8) !void {
        if (utils.strcomp(key, "Name")) {
            app.name = value;
        } else if (utils.strcomp(key, "Exec")) {
            app.exec = if (value.len > 0) value else null;
        } else if (utils.strcomp(key, "Icon")) {
            app.icon = if (value.len > 0) value else null;
        } else if (utils.strcomp(key, "Comment")) {
            app.comment = if (value.len > 0) value else null;
        } else if (utils.strcomp(key, "GenericName")) {
            app.generic_name = if (value.len > 0) value else null;
        } else if (utils.strcomp(key, "Version")) {
            app.version = if (value.len > 0) value else null;
        } else if (utils.strcomp(key, "TryExec")) {
            app.try_exec = if (value.len > 0) value else null;
        } else if (utils.strcomp(key, "Path")) {
            app.path = if (value.len > 0) value else null;
        } else if (utils.strcomp(key, "StartupWMClass")) {
            app.startup_wm_class = if (value.len > 0) value else null;
        } else if (utils.strcomp(key, "URL")) {
            app.url = if (value.len > 0) value else null;
        } else if (utils.strcomp(key, "Terminal")) {
            app.terminal = utils.strcomp(value, "true");
        } else if (utils.strcomp(key, "Hidden")) {
            app.hidden = utils.strcomp(value, "true");
        } else if (utils.strcomp(key, "DBusActivatable")) {
            app.dbus_activatable = utils.strcomp(value, "true");
        } else if (utils.strcomp(key, "PrefersNonDefaultGPU")) {
            app.prefers_non_default_gpu = utils.strcomp(value, "true");
        } else if (utils.strcomp(key, "SingleMainWindow")) {
            app.single_main_window = utils.strcomp(value, "true");
        } else if (utils.strcomp(key, "StartupNotify")) {
            app.startup_notify = utils.strcomp(value, "true");
        } else if (utils.strcomp(key, "Categories")) {
            app.categories = try splitString(allocator, value, ';');
        } else if (utils.strcomp(key, "MimeType")) {
            app.mime_type = try splitString(allocator, value, ';');
        } else if (utils.strcomp(key, "Keywords")) {
            app.keywords = try splitString(allocator, value, ';');
        } else if (utils.strcomp(key, "OnlyShowIn")) {
            app.only_show_in = try splitString(allocator, value, ';');
        } else if (utils.strcomp(key, "NotShowIn")) {
            app.not_show_in = try splitString(allocator, value, ';');
        } else if (utils.strcomp(key, "Actions")) {
            app.actions = try splitString(allocator, value, ';');
        } else if (utils.strcomp(key, "Implements")) {
            app.implements = try splitString(allocator, value, ';');
        }
    }

    fn splitString(allocator: std.mem.Allocator, value: []const u8, delim: u8) ![][]const u8 {
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, value, delim);
        while (it.next()) |part| {
            if (part.len > 0) count += 1;
        }

        const result = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        it.reset();
        while (it.next()) |part| {
            if (part.len > 0) {
                result[i] = part;
                i += 1;
            }
        }
        return result;
    }
};

pub fn lineIterator(source: []const u8) LineIterator {
    return .{ .source = source, .index = 0 };
}

pub const LineIterator = struct {
    source: []const u8,
    index: usize,

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.index >= self.source.len) return null;

        const start = self.index;

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == CARRIAGE_RETURN or c == LINE_FEED) {
                break;
            }
            self.index += 1;
        }
        const line = self.source[start..self.index];

        if (self.index < self.source.len and self.source[self.index] == CARRIAGE_RETURN) {
            self.index += 1;
        }
        if (self.index < self.source.len and self.source[self.index] == LINE_FEED) {
            self.index += 1;
        }

        return line;
    }
};

pub fn desktopEntryIterator(source: []const u8) DesktopEntryIterator {
    return .{ .source = source, .index = 0 };
}

pub const DesktopEntryIterator = struct {
    source: []const u8,
    index: usize,

    pub fn next(self: *DesktopEntryIterator) ?[]const u8 {
        var start: ?usize = null;

        var line_iter = lineIterator(self.source[self.index..]);

        while (line_iter.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \t");

            if (std.mem.startsWith(u8, trimmed, "[Desktop Entry]")) {
                if (start != null) {
                    const end = self.index + (raw_line.ptr - self.source[self.index..].ptr);
                    const section = self.source[start.?..end];
                    self.index += (raw_line.ptr - self.source[self.index..].ptr);
                    return section;
                }
                start = self.index + (raw_line.ptr - self.source[self.index..].ptr);
            } else if (start != null and trimmed.len > 0 and trimmed[0] == '[') {
                break;
            }

            self.index += raw_line.len + @as(usize, @intFromBool(self.source[self.index + raw_line.len] == LINE_FEED));
        }

        if (start) |s| {
            const section = self.source[s..];
            self.index = self.source.len;
            return section;
        }

        return null;
    }
};
