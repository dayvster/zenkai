const std = @import("std");
const qt = @import("libqt6zig");
const History = @import("history.zig").History;
const ItemKind = @import("history.zig").ItemKind;
const HistoryItem = @import("history.zig").HistoryItem;
const store = @import("store.zig");
const daemon = @import("daemon.zig");

pub const history = @import("history.zig");

/// Load clipboard history from disk and optionally ensure the background
/// watcher daemon is running.
pub fn loadHistory(allocator: std.mem.Allocator, start_daemon: bool) !History {
    if (start_daemon) daemon.ensureDaemonRunning(allocator);
    return try store.load(allocator, 200);
}

/// Save history back to disk.
pub fn saveHistory(history_history: *const History, allocator: std.mem.Allocator) !void {
    try store.save(history_history, allocator);
}

/// Convert a history item into a UI list item.
pub fn toListItem(allocator: std.mem.Allocator, item: HistoryItem) !struct {
    icon: []const u8,
    name: []const u8,
    cmd: []const u8,
} {
    const icon: []const u8 = switch (item.kind) {
        .text => "edit-paste",
        .file => "document-open",
        .image => "image-x-generic",
        .html => "text-html",
        .unknown => "edit-paste",
    };

    const display = try allocator.dupe(u8, item.text);
    errdefer allocator.free(display);

    // The "cmd" is the payload we restore when the user selects the item.
    const cmd = try allocator.dupe(u8, item.payload);
    errdefer allocator.free(cmd);

    return .{
        .icon = icon,
        .name = display,
        .cmd = cmd,
    };
}

/// Restore the given payload back to the clipboard as plain text.
pub fn restoreText(allocator: std.mem.Allocator, app: anytype, text: []const u8) void {
    const clip = app.clipboard();
    clip.setText(text);
    daemon.rememberRestoredText(allocator, text);
}

/// Run the clipboard watcher daemon. Blocks until the app exits.
pub fn runDaemon(allocator: std.mem.Allocator, app: anytype) !void {
    try daemon.run(allocator, app);
}

pub const isDaemonRunning = daemon.isDaemonRunning;
