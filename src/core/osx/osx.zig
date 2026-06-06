const std = @import("std");
const qt = @import("libqt6zig");

pub const AppReader = @import("appreader.zig").AppReader;

pub fn appDirs(allocator: std.mem.Allocator) [][]const u8 {
    _ = allocator;
    const qsp = qt.QStandardPaths;
    _ = qsp;
    return &.{};
}
