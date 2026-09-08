const std = @import("std");
const clipboard = @import("history.zig");
const History = clipboard.History;
const ItemKind = clipboard.ItemKind;

pub fn cacheDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |xdg| {
        const dir = std.mem.sliceTo(xdg, 0);
        return try std.fs.path.join(allocator, &.{ dir, "zenkai" });
    }
    const home = std.c.getenv("HOME") orelse "/home";
    return try std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), ".cache", "zenkai" });
}

pub fn ensureCacheDir(allocator: std.mem.Allocator) ![]u8 {
    const dir = try cacheDir(allocator);
    errdefer allocator.free(dir);

    std.fs.cwd().makePath(dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    return dir;
}

pub fn historyPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try ensureCacheDir(allocator);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "clipboard-history.json" });
}

pub fn pidPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try ensureCacheDir(allocator);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "clipboard-daemon.pid" });
}

pub fn load(allocator: std.mem.Allocator, max_items: usize) !History {
    var history = History.init(allocator, max_items);
    errdefer history.deinit();

    const path = try historyPath(allocator);
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return history,
        else => return err,
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return history;

    for (root.array.items) |item| {
        if (item != .object) continue;

        const kind_value = item.object.get("kind") orelse continue;
        const kind: ItemKind = if (kind_value == .string)
            ItemKind.fromString(kind_value.string)
        else
            .text;

        const text_value = item.object.get("text") orelse continue;
        if (text_value != .string) continue;
        const text = text_value.string;

        var payload: []const u8 = "";
        if (item.object.get("payload")) |p| {
            if (p == .string) payload = p.string;
        }

        if (text.len == 0 and payload.len == 0) continue;

        var pinned = false;
        if (item.object.get("pinned")) |p| {
            if (p == .bool) pinned = p.bool;
        }

        var timestamp: i64 = 0;
        if (item.object.get("timestamp")) |t| {
            if (t == .integer) timestamp = t.integer;
        }

        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);
        const owned_payload = try allocator.dupe(u8, payload);
        errdefer allocator.free(owned_payload);

        try history.items.append(allocator, .{
            .kind = kind,
            .text = owned_text,
            .payload = owned_payload,
            .timestamp = timestamp,
            .pinned = pinned,
        });
    }

    return history;
}

pub fn save(history: *const History, allocator: std.mem.Allocator) !void {
    const path = try historyPath(allocator);
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(dir);

    var arr = std.json.Value{ .array = std.json.Array.init(allocator) };
    defer arr.array.deinit();

    for (history.items.items) |item| {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("kind", std.json.Value{ .string = try allocator.dupe(u8, item.kind.jsonString()) });
        try obj.put("text", std.json.Value{ .string = try allocator.dupe(u8, item.text) });
        try obj.put("payload", std.json.Value{ .string = try allocator.dupe(u8, item.payload) });
        try obj.put("timestamp", std.json.Value{ .integer = item.timestamp });
        try obj.put("pinned", std.json.Value{ .bool = item.pinned });
        try arr.array.append(.{ .object = obj });
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try std.json.stringify(arr, .{ .whitespace = .indent_2 }, file.writer());
        try file.writeAll("\n");
    }

    try std.fs.cwd().rename(tmp_path, path);
}
