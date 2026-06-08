const std = @import("std");

pub const ReadDirOptions = struct {
    extensions: ?[]const []const u8 = null,
    recursive: bool = false,
    max_depth: u32 = 16,
};

pub fn readDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: ReadDirOptions,
) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    const expanded = try expandTilde(allocator, dir_path);
    defer allocator.free(expanded);

    try readDirInternal(allocator, expanded, options, &files, 0);
    return files;
}

pub fn dirExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) {
            return false;
        }
        return false;
    };
    return true;
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const cwd = std.Io.Dir.cwd();
    const file = try std.Io.Dir.openFile(cwd, io, path, .{});
    defer std.Io.File.close(file, io);

    const stat = try std.Io.Dir.statFile(cwd, io, path, .{});
    const size: usize = @intCast(stat.size);
    if (size > max_size) return error.FileTooBig;

    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &buf);
    return try reader.interface.readAlloc(allocator, size);
}

pub fn makeDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
}

fn readDirInternal(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: ReadDirOptions,
    results: *std.ArrayList([]const u8),
    depth: u32,
) !void {
    if (depth > options.max_depth) return;

    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound, error.AccessDenied, error.NotDir => return,
            else => return err,
        }
    };
    defer std.Io.Dir.close(dir, io);

    var iter = dir.iterate();

    while (try iter.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(full_path);

        const matches_ext = if (options.extensions) |exts|
            filterExtensions(entry.name, exts)
        else
            true;

        if (entry.kind == .file or entry.kind == .sym_link) {
            if (matches_ext) {
                try results.append(allocator, full_path);
            } else {
                allocator.free(full_path);
            }
        } else if ((entry.kind == .directory or entry.kind == .sym_link) and options.recursive) {
            try readDirInternal(allocator, full_path, options, results, depth + 1);
            allocator.free(full_path);
        } else {
            allocator.free(full_path);
        }
    }
}

fn expandTilde(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return try allocator.dupe(u8, path);
    const home = if (std.c.getenv("HOME")) |h| std.mem.sliceTo(h, 0) else "/home";
    if (path.len == 1) return try allocator.dupe(u8, home);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
}

fn filterExtensions(filename: []const u8, extensions: ?[]const []const u8) bool {
    if (extensions == null) return true;
    for (extensions.?) |ext| {
        if (std.mem.endsWith(u8, filename, ext)) return true;
    }
    return false;
}
