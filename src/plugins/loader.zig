const std = @import("std");
const fsutils = @import("utils").fsutils;

pub const standard_plugin_dirs = [_][]const u8{
    "/usr/local/share/zenkai/plugins",
    "/usr/share/zenkai/plugins",
};

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try fsutils.readFile(allocator, path, 64 * 1024);
}
