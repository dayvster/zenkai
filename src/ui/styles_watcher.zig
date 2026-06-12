const std = @import("std");
const qt = @import("libqt6zig");
const theme = @import("../theme/theme.zig");
const theme_handler = @import("theme_handler.zig");
const fsutils = @import("utils").fsutils;
const log = @import("utils").log;

const QTimer = qt.QTimer;

const styles_dir = "src/styles";

var g_allocator: std.mem.Allocator = undefined;
var g_timer: QTimer = undefined;

fn buildCombined(allocator: std.mem.Allocator) ![]u8 {
    var combined = std.ArrayList(u8).empty;
    errdefer combined.deinit(allocator);

    const main_qss_path = "src/styles/main.qss";
    const main_qss = try fsutils.readFile(allocator, main_qss_path, 128 * 1024);
    defer allocator.free(main_qss);
    try combined.appendSlice(allocator, main_qss);

    if (theme.g_theme_qss_filename.len > 0 and !std.mem.eql(u8, theme.g_theme_qss_filename, "main.qss")) {
        const theme_path = try std.fs.path.join(allocator, &.{ styles_dir, theme.g_theme_qss_filename });
        defer allocator.free(theme_path);
        const theme_qss = try fsutils.readFile(allocator, theme_path, 128 * 1024);
        defer allocator.free(theme_qss);
        try combined.appendSlice(allocator, theme_qss);
    }

    log.info("reloaded {d} bytes of QSS", .{combined.items.len});
    return combined.toOwnedSlice(allocator);
}

fn onReloadTimer(_: QTimer) callconv(.c) void {
    const combined = buildCombined(g_allocator) catch {
        return;
    };
    defer g_allocator.free(combined);

    theme_handler.reapply(combined);
}

pub fn start(allocator: std.mem.Allocator) void {
    g_allocator = allocator;

    g_timer = QTimer.New();
    g_timer.OnTimeout(onReloadTimer);
    g_timer.Start(500);

    log.info("styles watcher started (polling every 500ms)", .{});
}
