const std = @import("std");
const qt = @import("libqt6zig");

const StandardLoc = qt.QStandardPaths;

pub const AppReader = struct {
    allocator: std.mem.Allocator,
    paths: [][]const u8,

    pub fn init(allocator: std.mem.Allocator) AppReader {
        return .{
            .allocator = allocator,
            .paths = StandardLoc.StandardLocations(allocator, 3),
        };
    }

    pub fn deinit(self: *AppReader) void {
        for (self.paths) |p| self.allocator.free(p);
        self.allocator.free(self.paths);
    }

    pub fn scan(self: *AppReader) !void {
        _ = self;
    }
};
