const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");

pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
    is_link: bool,
};
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    entries: []Entry,
    more: bool,

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
    }
};

pub fn absolute(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPath;
    if (raw[0] == '~' and raw.len > 1 and raw[1] != '/' and raw[1] != '\\') return error.InvalidPath;
    const expanded = try utils.fsutils.expandTilde(allocator, raw);
    defer allocator.free(expanded);
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const current = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(current);
    if (builtin.os.tag == .windows and expanded.len == 2 and expanded[1] == ':') {
        return std.fmt.allocPrint(allocator, "{s}\\", .{expanded});
    }
    return std.fs.path.resolve(allocator, &.{ current, expanded });
}

pub fn isDirectory(path: []const u8) !bool {
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    return stat.kind == .directory;
}

fn contains(name: []const u8, filter: []const u8) bool {
    if (filter.len > name.len) return false;
    for (0..name.len - filter.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(name[i .. i + filter.len], filter)) return true;
    }
    return false;
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    const order = std.ascii.orderIgnoreCase(a.name, b.name);
    return if (order == .eq) std.mem.order(u8, a.name, b.name) == .lt else order == .lt;
}

/// A bounded page of a sorted directory. No shell and no recursive traversal.
/// Search roots, recursion, exclusions and navigation are chosen by the Lua plugin.
pub fn list(allocator: std.mem.Allocator, raw: []const u8, offset: usize, filter: []const u8) !Listing {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path = try absolute(a, raw);
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    var directory = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer directory.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    var iterator = directory.iterate();
    var visited: usize = 0;
    while (try iterator.next(io)) |entry| {
        visited += 1;
        if (visited > 100000) return error.DirectoryTooLarge;
        if (!contains(entry.name, filter)) continue;
        const full = try std.fs.path.join(a, &.{ path, entry.name });
        const is_link = entry.kind == .sym_link;
        const is_dir = if (is_link or entry.kind == .unknown) isDirectory(full) catch false else entry.kind == .directory;
        try entries.append(a, .{ .name = try a.dupe(u8, entry.name), .path = full, .is_dir = is_dir, .is_link = is_link });
    }
    std.mem.sort(Entry, entries.items, {}, lessThan);
    const start = @min(offset, entries.items.len);
    const end = start + @min(@as(usize, 128), entries.items.len - start);
    return .{ .arena = arena, .path = path, .entries = entries.items[start..end], .more = end < entries.items.len };
}

pub fn open(allocator: std.mem.Allocator, raw: []const u8) !void {
    const path = try absolute(allocator, raw);
    defer allocator.free(path);
    _ = try isDirectory(path); // Refuse missing paths; keep the launcher open on errors.
    if (comptime builtin.os.tag == .windows) return utils.openTarget(path, allocator);
    return utils.spawnTool(if (builtin.os.tag == .macos) "/usr/bin/open" else "xdg-open", &.{path}, allocator);
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidName => "Enter a single file or folder name, without path separators",
        error.PathAlreadyExists => "A file or folder with that name already exists",
        error.OperationUnsupported => "This filesystem does not support safe renaming",
        error.TrashFailed => "Unable to move this item to trash. Nothing was permanently deleted",
        error.ProtectedPath => "This action is not available for a filesystem root",
        error.ActionRequired => "File actions must be selected from the action menu",
        error.ActionUnavailable => "This file action is unavailable",
        error.FileNotFound => "Path not found",
        error.NotDir => "This path is not a folder",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.DirectoryTooLarge => "This folder is too large to browse; narrow the path",
        error.InvalidPath => "Enter an absolute path, ~/path, or ./path",
        else => "Unable to read or open this path",
    };
}

pub fn validateName(name: []const u8) !void {
    for (name) |byte| if (byte < 32) return error.InvalidName;
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\x00\r\n") != null) return error.InvalidName;
    if (builtin.os.tag == .windows) {
        if (std.mem.indexOfAny(u8, name, ":*?\"<>|") != null or name[name.len - 1] == '.' or name[name.len - 1] == ' ') return error.InvalidName;
        const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.InvalidName;
        }
    }
}

pub fn create(allocator: std.mem.Allocator, parent: []const u8, name: []const u8, directory: bool) ![]u8 {
    try validateName(name);
    const path = try std.fs.path.join(allocator, &.{ parent, name });
    errdefer allocator.free(path);
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    if (directory) {
        try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    } else {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        file.close(io);
    }
    return path;
}

pub fn rename(allocator: std.mem.Allocator, path: []const u8, name: []const u8) ![]u8 {
    try validateName(name);
    const parent = std.fs.path.dirname(path) orelse return error.ProtectedPath;
    if (std.mem.eql(u8, parent, path)) return error.ProtectedPath;
    const destination = try std.fs.path.join(allocator, &.{ parent, name });
    errdefer allocator.free(destination);
    if (std.mem.eql(u8, path, destination)) return destination;
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    try std.Io.Dir.cwd().renamePreserve(path, .cwd(), destination, io);
    return destination;
}

test "file mutations preserve existing content and reject traversal" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "existing.txt", .data = "keep me" });
    try std.testing.expectError(error.PathAlreadyExists, create(a, root, "existing.txt", false));
    try std.testing.expectError(error.InvalidName, create(a, root, "../escape", false));
    const file = try create(a, root, "a & 'quoted'.txt", false);
    defer a.free(file);
    try std.testing.expectError(error.PathAlreadyExists, rename(a, file, "existing.txt"));
    const renamed = try rename(a, file, "renamed.txt");
    defer a.free(renamed);
    const folder = try create(a, root, "new folder", true);
    defer a.free(folder);
    const moved = try rename(a, folder, "renamed folder");
    defer a.free(moved);
    try std.testing.expect(try isDirectory(moved));
    const existing = try std.fs.path.join(a, &.{ root, "existing.txt" });
    defer a.free(existing);
    const content = try utils.fsutils.readFile(a, existing, 100);
    defer a.free(content);
    try std.testing.expectEqualStrings("keep me", content);
}

test "directory listing sorts folders first, preserves names, filters and paginates" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "folder", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "a space & quote'.txt", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var first = try list(a, path, 0, "");
    defer first.deinit();
    try std.testing.expect(first.entries[0].is_dir);
    try std.testing.expectEqualStrings("a space & quote'.txt", first.entries[1].name);
    var filtered = try list(a, path, 0, "SPACE");
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.entries.len);
    for (0..130) |i| {
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "file-{d}.txt", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    var page = try list(a, path, 128, "");
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 4), page.entries.len);
    try std.testing.expect(!page.more);
}
