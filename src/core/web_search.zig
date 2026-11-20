const std = @import("std");

pub const Engine = struct { name: []const u8, title: []const u8, url: []const u8 };

pub const engines = [_]Engine{
    .{ .name = "duckduckgo", .title = "DuckDuckGo", .url = "https://duckduckgo.com/?q=%s" },
    .{ .name = "google", .title = "Google", .url = "https://www.google.com/search?q=%s" },
    .{ .name = "bing", .title = "Bing", .url = "https://www.bing.com/search?q=%s" },
    .{ .name = "brave", .title = "Brave Search", .url = "https://search.brave.com/search?q=%s" },
    .{ .name = "startpage", .title = "Startpage", .url = "https://www.startpage.com/do/search?q=%s" },
    .{ .name = "kagi", .title = "Kagi", .url = "https://kagi.com/search?q=%s" },
    .{ .name = "ecosia", .title = "Ecosia", .url = "https://www.ecosia.org/search?q=%s" },
};

pub const engine_names = blk: {
    var names: [engines.len][]const u8 = undefined;
    for (engines, 0..) |engine, i| names[i] = engine.name;
    break :blk names;
};

pub fn find(setting: ?[]const u8) Engine {
    const value = setting orelse return engines[0];
    for (engines) |engine| {
        if (std.ascii.eqlIgnoreCase(engine.name, value)) return engine;
    }
    if (std.mem.indexOf(u8, value, "%s") != null and
        (std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://")))
    {
        return .{ .name = value, .title = "the web", .url = value };
    }
    return engines[0];
}

pub fn label(allocator: std.mem.Allocator, engine: Engine, query: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Search {s} for \u{201c}{s}\u{201d}", .{ engine.title, query });
}

pub fn url(allocator: std.mem.Allocator, engine: Engine, query: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, engine.url, "%s") orelse return allocator.dupe(u8, engine.url);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, engine.url[0..at]);
    for (query) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try out.append(allocator, byte);
        } else if (byte == ' ') {
            try out.append(allocator, '+');
        } else {
            try out.print(allocator, "%{X:0>2}", .{byte});
        }
    }
    try out.appendSlice(allocator, engine.url[at + 2 ..]);
    return out.toOwnedSlice(allocator);
}

test "engines are found by name, custom URLs need %s, anything else falls back" {
    try std.testing.expectEqualStrings("Google", find("Google").title);
    try std.testing.expectEqualStrings("DuckDuckGo", find(null).title);
    try std.testing.expectEqualStrings("DuckDuckGo", find("altavista").title);
    try std.testing.expectEqualStrings("DuckDuckGo", find("https://example.com/no-placeholder").title);
    try std.testing.expectEqualStrings("https://example.com/?s=%s", find("https://example.com/?s=%s").url);
}

test "queries are encoded into the engine's URL" {
    const a = std.testing.allocator;
    const built = try url(a, find("duckduckgo"), "zig & qt/6 café?");
    defer a.free(built);
    try std.testing.expectEqualStrings("https://duckduckgo.com/?q=zig+%26+qt%2F6+caf%C3%A9%3F", built);
    const text = try label(a, find("kagi"), "zenkai");
    defer a.free(text);
    try std.testing.expectEqualStrings("Search Kagi for \u{201c}zenkai\u{201d}", text);
}
