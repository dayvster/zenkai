const std = @import("std");

pub const standard_plugin_dirs = [_][]const u8{
    "/usr/local/share/zenkai/plugins",
    "/usr/share/zenkai/plugins",
};

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    return try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, @as(std.Io.Limit, @enumFromInt(1024 * 64)));
}
