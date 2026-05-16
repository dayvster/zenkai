const std = @import("std");

pub var verbose: bool = false;

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (verbose) {
        std.debug.print("[zenkai] " ++ fmt ++ "\n", args);
    }
}
