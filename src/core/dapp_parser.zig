const std = @import("std");
const de = @import("desktopapp");
const utils = @import("utils");

const CARRIAGE_RETURN = '\r';
const LINE_FEED = '\n';

pub var g_locale: ?[]const u8 = null;

pub fn setLocale(locale: ?[]const u8) void {
    g_locale = locale;
}

pub const MaxDesktops = 8;

pub fn shouldShowApp(app: *const de.DesktopApp, desktop_names: []const []const u8) bool {
    if (app.only_show_in.len > 0) {
        var found = false;
        for (app.only_show_in) |only| {
            if (envsContains(desktop_names, only)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    if (app.not_show_in.len > 0) {
        for (app.not_show_in) |not| {
            if (envsContains(desktop_names, not)) return false;
        }
    }
    return true;
}

// A desktop entry is launchable only when it is a Type=Application entry.
// Type=Link and Type=Directory entries carry no Exec and must not be listed
// or launched as applications.
pub fn shouldListApp(app: *const de.DesktopApp, desktop_names: []const []const u8) bool {
    if (app.type != .Application) return false;
    return shouldShowApp(app, desktop_names);
}

fn envsContains(desktop_names: []const []const u8, target: []const u8) bool {
    const t = std.mem.trim(u8, target, " \t");
    if (t.len == 0) return false;
    for (desktop_names) |name| {
        if (eqIgnoreCase(name, t)) return true;
    }
    return false;
}

pub fn readCurrentDesktops(buf: *[MaxDesktops][]const u8) []const []const u8 {
    var count: usize = 0;
    const var_names = .{ "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP" };
    inline for (var_names) |var_name| {
        if (std.c.getenv(var_name)) |raw| {
            const val = std.mem.sliceTo(raw, 0);
            var it = std.mem.splitScalar(u8, val, ':');
            while (it.next()) |part| {
                const t = std.mem.trim(u8, part, " \t");
                if (t.len > 0 and count < MaxDesktops) {
                    buf[count] = t;
                    count += 1;
                }
            }
        }
    }
    return buf[0..count];
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn firstTag(x: []const u8) []const u8 {
    for (x, 0..) |c, i| {
        if (c == '_' or c == '-') return x[0..i];
    }
    return x;
}

fn localeScore(candidate: []const u8, locale: []const u8) i32 {
    if (eqIgnoreCase(candidate, locale)) return 3;
    if (eqIgnoreCase(firstTag(candidate), firstTag(locale))) return 2;
    return 0;
}

fn pickLocalizedName(app: *de.DesktopApp, locale: []const u8) void {
    const loc = std.mem.trim(u8, locale, " \t");
    if (loc.len == 0) return;

    var best: ?[]const u8 = null;
    var best_locale: ?[]const u8 = null;
    var best_score: i32 = -1;

    var it = app.extra.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "Name[")) continue;
        const close = std.mem.lastIndexOfScalar(u8, key, ']') orelse continue;
        if (close < 6) continue;
        const candidate = key[5..close];
        if (candidate.len == 0) continue;
        const value = entry.value_ptr.*;
        if (value.len == 0) continue;

        const score = localeScore(candidate, loc);
        const better = if (score > best_score) true else if (score == best_score)
            if (best_locale) |bl| std.mem.lessThan(u8, candidate, bl) else true
        else false;
        if (better) {
            best_score = score;
            best = value;
            best_locale = candidate;
        }
    }

    if (best) |b| app.name = b;
}

pub const DappParser = struct {
    pub fn parseDesktopFile(allocator: std.mem.Allocator, content: []const u8) !de.DesktopApp {
        var app = initDefaultDapp(allocator);
        errdefer app.deinit(allocator);
        var no_display = false;

        var entry_iter = desktopEntryIterator(content);

        while (entry_iter.next()) |entry| {
            if (!isDesktopEntry(entry)) continue;
            var line_iter = lineIterator(entry);
            while (line_iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;

                if (splitToKV(trimmed)) |kv| {
                    if (std.mem.indexOfScalar(u8, kv.key, '[') != null) {
                        if (std.mem.startsWith(u8, kv.key, "Name[")) {
                            try parseKeyValue(allocator, &app, kv.key, kv.value);
                        }
                        continue;
                    }

                    if (utils.strcomp(kv.key, "NoDisplay") and utils.strcomp(kv.value, "true")) {
                        no_display = true;
                    }

                    if (utils.strcomp(kv.key, "Hidden") and utils.strcomp(kv.value, "true")) {
                        no_display = true;
                    }

                    try parseKeyValue(allocator, &app, kv.key, kv.value);
                }
            }
        }

        if (no_display) return error.NoDisplay;

        if (g_locale) |locale| {
            pickLocalizedName(&app, locale);
        }

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

    pub fn splitToKV(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
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
        } else if (utils.strcomp(key, "Type") and value.len > 0) {
            if (std.mem.eql(u8, value, "Application")) {
                app.type = .Application;
            } else if (std.mem.eql(u8, value, "Link")) {
                app.type = .Link;
            } else if (std.mem.eql(u8, value, "Directory")) {
                app.type = .Directory;
            }
        } else if (std.mem.startsWith(u8, key, "Name[") and std.mem.endsWith(u8, key, "]")) {
            if (value.len > 0 and key.len > 6) {
                app.extra.put(key, value) catch {};
            }
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

        if (utils.simd.memchrCrOrLf(self.source[self.index..])) |pos| {
            self.index += pos;
        } else {
            self.index = self.source.len;
            return self.source[start..self.index];
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

        while (true) {
            const line_start = self.index;
            var line_iter = lineIterator(self.source[self.index..]);
            const raw_line = line_iter.next() orelse break;
            self.index += line_iter.index;

            const trimmed = std.mem.trim(u8, raw_line, " \t");

            if (trimmed.len > 0 and trimmed[0] == '[') {
                if (start != null) {
                    self.index = line_start;
                    return self.source[start.?..line_start];
                }
                start = line_start;
            }
        }

        if (start) |s| {
            const section = self.source[s..];
            self.index = self.source.len;
            return section;
        }

        return null;
    }
};

pub fn isDesktopEntry(section: []const u8) bool {
    var iter = lineIterator(section);
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        return std.mem.startsWith(u8, trimmed, "[Desktop Entry]");
    }
    return false;
}
