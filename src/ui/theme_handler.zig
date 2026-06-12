const std = @import("std");
const qt = @import("libqt6zig");

const QAppType = qt.QApplication;
var g_qapp: qt.QApplication = undefined;

pub fn setApp(app: qt.QApplication) void {
    g_qapp = app;
}

pub fn apply(allocator: std.mem.Allocator, base_qss: []const u8, theme_qss: []const u8) void {
    const combined = std.mem.concat(allocator, u8, &.{ base_qss, theme_qss }) catch {
        g_qapp.SetStyleSheet(base_qss);
        return;
    };
    defer allocator.free(combined);
    g_qapp.SetStyleSheet(combined);
}

pub fn reapply(qss: []const u8) void {
    g_qapp.SetStyleSheet(qss);
}
