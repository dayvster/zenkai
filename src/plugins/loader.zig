const std = @import("std");
const fsutils = @import("utils").fsutils;

pub const standard_plugin_dirs = [_][]const u8{
    "external/plugins",
    "/usr/local/share/zenkai/plugins",
    "/usr/share/zenkai/plugins",
};

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try fsutils.readFile(allocator, path, 64 * 1024);
}

/// Plugin scripts may embed data tables (the emoji plugin carries ~130 KiB), so they get a
/// larger cap than manifests and configs.
pub const max_script_bytes = 1024 * 1024;

pub fn readScript(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try fsutils.readFile(allocator, path, max_script_bytes);
}
