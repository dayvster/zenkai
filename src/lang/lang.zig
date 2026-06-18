const std = @import("std");
const en = @import("en.zig");
const translations = @import("translations.zig");
const config = @import("config");
const fsutils = @import("utils").fsutils;
const log = @import("utils").log;

var g_translations: translations.Translations = en.en;
var g_arena: ?std.heap.ArenaAllocator = null;

pub fn get() *const translations.Translations {
    return &g_translations;
}

pub fn init(allocator: std.mem.Allocator, language: ?[]const u8) void {
    const lang = language orelse return;
    if (lang.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    const a = arena.allocator();

    if (loadTranslation(a, lang)) |t| {
        g_translations = t;
        g_arena = arena;
    } else |err| {
        log.info("translation '{s}' not loaded ({s}), using defaults", .{ lang, @errorName(err) });
        arena.deinit();
    }
}

pub fn deinit() void {
    if (g_arena) |*arena| {
        arena.deinit();
        g_arena = null;
    }
    g_translations = en.en;
}

fn configDir(allocator: std.mem.Allocator) ![]u8 {
    return config.configDir(allocator);
}

const translation_search_dirs = [_][]const u8{
    "external/translations",
    "/usr/local/share/zenkai/translations",
    "/usr/share/zenkai/translations",
};

fn loadTranslation(a: std.mem.Allocator, lang_code: []const u8) !translations.Translations {
    const cfg_dir = try configDir(a);
    defer a.free(cfg_dir);

    const cfg_trans_dir = try std.fs.path.join(a, &.{ cfg_dir, "translations" });
    defer a.free(cfg_trans_dir);

    var candidates = std.ArrayList([]const u8).empty;
    defer {
        for (candidates.items) |c| a.free(c);
        candidates.deinit(a);
    }

    {
        const user_path = try std.fs.path.join(a, &.{ cfg_trans_dir, lang_code });
        defer a.free(user_path);
        try candidates.append(a, try std.fmt.allocPrint(a, "{s}.toml", .{user_path}));
    }

    for (translation_search_dirs) |dir| {
        const dir_path = try std.fs.path.join(a, &.{ dir, lang_code });
        defer a.free(dir_path);
        try candidates.append(a, try std.fmt.allocPrint(a, "{s}.toml", .{dir_path}));
    }

    for (candidates.items) |path| {
        const content = fsutils.readFile(a, path, 128 * 1024) catch continue;
        return parseContent(a, content);
    }

    log.info("translation '{s}' not found, using defaults", .{lang_code});
    return en.en;
}

fn parseContent(a: std.mem.Allocator, content: []const u8) !translations.Translations {
    var tr = en.en;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const eq_idx = findEq(trimmed) orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        const val_raw = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

        const val = parseValue(a, val_raw) catch continue;

        applyField(&tr, key, val);
    }
    return tr;
}

fn findEq(s: []const u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == '=') return i;
    }
    return null;
}

fn parseMultilineString(a: std.mem.Allocator, raw: []const u8, quote: u8) ![]const u8 {
    const inner = raw[3..];
    const close = findClosing(inner, quote, quote) orelse return error.UnclosedString;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(a);
    var lines = std.mem.splitScalar(u8, inner[0..close], '\n');
    while (lines.next()) |line| {
        if (buf.items.len > 0) try buf.append(a, '\n');
        try buf.appendSlice(a, line);
    }
    return buf.toOwnedSlice(a);
}

fn parseQuotedString(a: std.mem.Allocator, raw: []const u8, quote: u8) ![]const u8 {
    const close = findClosing(raw[1..], quote, '\\') orelse return error.UnclosedString;
    const inner = raw[1 .. close + 1];
    return unescape(a, inner);
}

fn parseValue(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return error.EmptyValue;

    const first = raw[0];
    if (first == '"' or first == '\'') {
        if (raw.len >= 3 and raw[1] == first and raw[2] == first) {
            return parseMultilineString(a, raw, first);
        }
        if (first == '\'') {
            const close = findClosing(raw[1..], '\'', 0) orelse return error.UnclosedString;
            return a.dupe(u8, raw[1 .. close + 1]);
        }
        return parseQuotedString(a, raw, '"');
    }

    return a.dupe(u8, raw);
}

fn findClosing(s: []const u8, close_char: u8, escape_char: u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (escape_char != 0 and s[i] == escape_char and i + 1 < s.len) {
            i += 2;
            continue;
        }
        if (s[i] == close_char) return i;
        i += 1;
    }
    return null;
}

fn unescape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                '"' => try buf.append(a, '"'),
                '\\' => try buf.append(a, '\\'),
                'n' => try buf.append(a, '\n'),
                't' => try buf.append(a, '\t'),
                else => {
                    try buf.append(a, s[i]);
                    try buf.append(a, s[i + 1]);
                },
            }
            i += 2;
        } else {
            try buf.append(a, s[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(a);
}

fn applyField(tr: *translations.Translations, key: []const u8, val: []const u8) void {
    inline for (std.meta.fields(translations.Translations)) |field| {
        if (std.mem.eql(u8, key, field.name)) {
            @field(tr, field.name) = val;
            return;
        }
    }
}
