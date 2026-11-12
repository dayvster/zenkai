//! Stand-in for window_switcher_kde.zig in builds without kwinctl (`-Dkde=false`, or
//! any non-Linux target). KDE sessions then fall through to the other backends.
const std = @import("std");
const Snapshot = @import("window_switcher.zig").Snapshot;
const layout = @import("window_layout.zig");

pub fn isSession() bool {
    return false;
}

pub fn enumerate(_: *Snapshot, _: std.mem.Allocator, _: i64) !void {
    return error.UnsupportedPlatform;
}

pub fn focus(_: std.mem.Allocator, _: []const u8) !void {
    return error.UnsupportedPlatform;
}

pub fn manage(_: std.mem.Allocator, _: []const u8, _: layout.Action) !void {
    return error.UnsupportedPlatform;
}

pub fn validId(_: []const u8) bool {
    return false;
}
