const std = @import("std");

pub const AppReader = @import("appreader.zig").AppReader;
pub const PlistParser = @import("parser.zig").PlistParser;
pub const PlistValue = @import("plist.zig").PlistValue;
pub const InfoPlist = @import("plist.zig").InfoPlist;

pub fn appDirs(allocator: std.mem.Allocator) [][]const u8 {
    const dirs = [_][]const u8{
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices",
    };
    const result = allocator.alloc([]const u8, dirs.len) catch return &.{};
    for (dirs, 0..) |dir, i| result[i] = dir;
    return result;
}
