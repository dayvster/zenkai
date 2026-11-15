const std = @import("std");
const qt = @import("libqt6zig");

const QAppType = qt.QApplication;
var g_qapp: qt.QApplication = undefined;

// Appearance rules (opacity, corners, text sizes) appended after the theme on every apply,
// including reloads from the theme reloader. Owned here, so callers can free their copy.
var g_appearance: []u8 = &.{};

pub fn setApp(app: qt.QApplication) void {
    g_qapp = app;
}

pub fn setAppearance(qss: []const u8) void {
    std.heap.page_allocator.free(g_appearance);
    g_appearance = std.heap.page_allocator.dupe(u8, qss) catch &.{};
}

pub fn apply(allocator: std.mem.Allocator, base_qss: []const u8, theme_qss: []const u8) void {
    const combined = std.mem.concat(allocator, u8, &.{ base_qss, theme_qss, g_appearance }) catch {
        g_qapp.setStyleSheet(base_qss);
        return;
    };
    defer allocator.free(combined);
    g_qapp.setStyleSheet(combined);
}

pub fn reapply(qss: []const u8) void {
    if (g_appearance.len == 0) return g_qapp.setStyleSheet(qss);
    const combined = std.mem.concat(std.heap.page_allocator, u8, &.{ qss, g_appearance }) catch return g_qapp.setStyleSheet(qss);
    defer std.heap.page_allocator.free(combined);
    g_qapp.setStyleSheet(combined);
}
