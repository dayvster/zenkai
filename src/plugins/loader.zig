const std = @import("std");
const builtin = @import("builtin");
const fsutils = @import("utils").fsutils;

pub const standard_plugin_dirs = if (builtin.os.tag == .windows)
    [_][]const u8{
        "C:\\ProgramData\\zenkai\\plugins",
    }
else
    [_][]const u8{
        "/usr/local/share/zenkai/plugins",
        "/usr/share/zenkai/plugins",
    };

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try fsutils.readFile(allocator, path, 64 * 1024);
}
