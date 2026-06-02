const std = @import("std");
const de = @import("desktopapp");
const utils = @import("utils");

const NEWLINE_CHARS = "\r\n";
const CARRIAGE_RETURN = '\r';
const LINE_FEED = '\n';

pub const DappParser = struct {
    pub fn parseDesktopFile(allocator: std.mem.Allocator, content: []const u8) !de.DesktopApp {
        var app = initDefaultDapp();

        var entry_iter = desktopEntryIterator(content);

        while (entry_iter.next()) |entry| {
            var line_iter = lineIterator(entry);
            while (line_iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;

                if (splitToKV(trimmed)) |kv| {
                    parseKeyValue(&app, kv.key, kv.value);
                }
            }
        }

        return app;
    }

    fn initDefaultDapp() de.DesktopApp {
        const app = de.DesktopApp{ .name = null, .exec = null, .icon = null, .comment = null, .type = "Application" };
        return app;
    }

    fn splitToKV(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
            const key = std.mem.trim(u8, line[0..eq_pos], " \t");
            const value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
            return .{ .key = key, .value = value };
        }
        return null;
    }

    fn parseKeyValue(app: *de.DesktopApp, key: []const u8, value: []const u8) !void {
        if (utils.strcomp(key, "Name")) app.name = value;
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
