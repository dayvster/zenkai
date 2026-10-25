const std = @import("std");
const backend = @import("window_switcher.zig");

test {
    std.testing.refAllDecls(backend);
}

/// Owns the native snapshot independently of Lua and application discovery.
pub const Search = struct {
    enabled: bool = true,
    /// Treat every non-prefixed query as a window search. Used by the
    /// dedicated `--window-switcher` launch mode.
    standalone: bool = false,
    active: bool = false,
    cached: bool = false,
    snapshot: backend.Snapshot = .{},
    matches: std.ArrayList(usize) = .empty,
    message: ?[]const u8 = null,

    pub fn deinit(self: *Search, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
        self.matches.deinit(allocator);
        self.matches = .empty;
    }

    pub fn query(self: *Search, allocator: std.mem.Allocator, text: []const u8) !bool {
        const has_prefix = text.len >= 4 and std.ascii.eqlIgnoreCase(text[0..4], "win:");
        self.active = self.enabled and (self.standalone or has_prefix);
        self.matches.clearRetainingCapacity();
        self.message = null;
        if (!self.active) {
            self.cached = false;
            self.snapshot.deinit(allocator);
            return false;
        }
        const term = std.mem.trim(u8, if (has_prefix) text[4..] else text, " \t\r\n");
        if (!self.cached or term.len == 0) {
            self.snapshot.refresh(allocator) catch |err| {
                self.cached = false;
                self.message = backend.errorMessage(err);
                return true;
            };
            self.cached = true;
        }
        for (self.snapshot.windows.items, 0..) |window, i| {
            if (contains(window.title, term) or contains(window.app, term)) try self.matches.append(allocator, i);
        }
        if (self.matches.items.len == 0) self.message = "No matching windows";
        return true;
    }

    /// False keeps the launcher open and exposes the failure as a result row.
    pub fn select(self: *Search, allocator: std.mem.Allocator, index: usize) bool {
        if (index >= self.snapshot.windows.items.len) return false;
        self.snapshot.focus(allocator, self.snapshot.windows.items[index].id) catch |err| {
            self.message = backend.errorMessage(err);
            self.cached = false;
            return false;
        };
        return true;
    }
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "core window search filters titles and apps without plugins" {
    const a = std.testing.allocator;
    var search: Search = .{};
    defer search.deinit(a);
    try search.snapshot.addWithIcon(a, "one", "Code [work]", "Editor", "editor-icon");
    try search.snapshot.add(a, "two", "Documentation", "Browser");
    search.cached = true;
    try std.testing.expect(try search.query(a, "WIN: [WORK]"));
    try std.testing.expectEqual(@as(usize, 1), search.matches.items.len);
    try std.testing.expectEqualStrings("editor-icon", search.snapshot.windows.items[search.matches.items[0]].icon);
    try std.testing.expect(try search.query(a, "win: browser"));
    try std.testing.expectEqual(@as(usize, 1), search.matches.items[0]);
    try std.testing.expect(try search.query(a, "win: not found"));
    try std.testing.expectEqualStrings("No matching windows", search.message.?);
    try std.testing.expect(!try search.query(a, "ordinary query"));
    try std.testing.expect(!search.cached and search.snapshot.windows.items.len == 0);
}

test "standalone core window search claims ordinary queries" {
    const a = std.testing.allocator;
    var search: Search = .{ .standalone = true };
    defer search.deinit(a);
    try search.snapshot.add(a, "one", "Code [work]", "Editor");
    try search.snapshot.add(a, "two", "Documentation", "Browser");
    search.cached = true;
    try std.testing.expect(try search.query(a, "browser"));
    try std.testing.expectEqual(@as(usize, 1), search.matches.items[0]);
    try std.testing.expect(try search.query(a, "WIN: [WORK]"));
    try std.testing.expectEqual(@as(usize, 0), search.matches.items[0]);
    try std.testing.expect(try search.query(a, "win: editor"));
    try std.testing.expectEqual(@as(usize, 0), search.matches.items[0]);
    try std.testing.expect(try search.query(a, "not found"));
    try std.testing.expectEqualStrings("No matching windows", search.message.?);
}

test "disabled core window search never claims the prefix" {
    var search: Search = .{ .enabled = false };
    defer search.deinit(std.testing.allocator);
    try std.testing.expect(!try search.query(std.testing.allocator, "win:"));
    try std.testing.expect(!search.cached);

    var standalone: Search = .{ .enabled = false, .standalone = true };
    defer standalone.deinit(std.testing.allocator);
    try std.testing.expect(!try standalone.query(std.testing.allocator, "editor"));
    try std.testing.expect(!standalone.active);
}
