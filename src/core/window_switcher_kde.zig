const std = @import("std");
const kwinctl = @import("kwinctl");
const Snapshot = @import("window_switcher.zig").Snapshot;
const layout = @import("window_layout.zig");
const Rect = layout.Rect;

// KDE Plasma 6 on Wayland only lets KWin scripts see windows. kwinctl runs those scripts over
// D-Bus in pure Zig, so no external tool (kdotool) is needed.
const timeout_ms = 5000;

pub fn isSession() bool {
    // Only Plasma 6 has the KWin scripting API kwinctl uses. On older X11 sessions the generic
    // X11 backend still works, so do not claim them here.
    if (std.c.getenv("KDE_SESSION_VERSION")) |version| {
        const value = std.mem.span(version);
        if (value.len != 0) return std.mem.eql(u8, value, "6");
    }
    if (hasEnv("KDE_FULL_SESSION")) return true;
    const desktop = std.c.getenv("XDG_CURRENT_DESKTOP") orelse return false;
    return containsIgnoreCase(std.mem.span(desktop), "KDE");
}

fn connect(allocator: std.mem.Allocator) !kwinctl.Client {
    const bus = std.c.getenv("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoDisplay;
    const runtime = if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| std.mem.span(dir) else null;
    return kwinctl.Client.init(allocator, .{
        .bus_address = std.mem.span(bus),
        .runtime_dir = runtime,
        .timeout_ms = timeout_ms,
    }) catch |err| switch (err) {
        error.KWinNotRunning => error.UnsupportedWayland,
        else => error.BackendFailed,
    };
}

pub fn enumerate(snapshot: *Snapshot, allocator: std.mem.Allocator, own_pid: i64) !void {
    var client = try connect(allocator);
    defer client.deinit();
    const list = client.windows(allocator, .{}) catch return error.BackendFailed;
    defer list.deinit();
    try addWindows(snapshot, allocator, list.value, own_pid);
}

pub fn focus(allocator: std.mem.Allocator, id: []const u8) !void {
    var client = try connect(allocator);
    defer client.deinit();
    client.focus(id) catch |err| return switch (err) {
        error.WindowNotFound, error.InvalidId => error.WindowNotFound,
        else => error.FocusFailed,
    };
}

pub fn manage(allocator: std.mem.Allocator, id: []const u8, action: layout.Action) !void {
    var client = try connect(allocator);
    defer client.deinit();

    const list = client.windows(allocator, .{}) catch return error.BackendFailed;
    defer list.deinit();
    var norm_buf: [38]u8 = undefined;
    const norm = kwinctl.normalizeId(id, &norm_buf) orelse return error.WindowNotFound;
    const current = for (list.value) |w| {
        if (std.mem.eql(u8, w.id, norm)) break Rect{ .x = w.x, .y = w.y, .width = w.width, .height = w.height };
    } else return error.WindowNotFound;

    const outputs = client.screens(allocator) catch return error.BackendFailed;
    defer outputs.deinit();
    const areas = try allocator.alloc(Rect, outputs.value.len);
    defer allocator.free(areas);
    for (outputs.value, areas) |s, *r| r.* = .{ .x = s.work_area.x, .y = s.work_area.y, .width = s.work_area.width, .height = s.work_area.height };

    const target = try layout.destination(current, areas, action);
    client.setGeometry(id, .{ .x = target.x, .y = target.y, .width = target.width, .height = target.height }) catch |err| return switch (err) {
        error.WindowNotFound, error.InvalidId => error.WindowNotFound,
        else => error.WindowManagementFailed,
    };
}

/// Adds KWin's windows to the snapshot, leaving out zenkai's own.
fn addWindows(snapshot: *Snapshot, allocator: std.mem.Allocator, windows: []const kwinctl.Window, own_pid: i64) !void {
    for (windows) |w| {
        if (w.pid == own_pid) continue;
        const app = if (w.app.len == 0) "Window" else w.app;
        try snapshot.add(allocator, w.id, w.title, app);
    }
}

pub fn validId(id: []const u8) bool {
    var buf: [38]u8 = undefined;
    return kwinctl.normalizeId(id, &buf) != null;
}

fn hasEnv(key: [*:0]const u8) bool {
    const value = std.c.getenv(key) orelse return false;
    return value[0] != 0;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "KDE windows omit the launcher and name unnamed apps" {
    var snapshot: Snapshot = .{};
    defer snapshot.deinit(std.testing.allocator);
    const windows = [_]kwinctl.Window{
        .{ .id = "{04add7fb-72b8-4e58-8ac1-5e22730b907b}", .title = "Terminal", .app = "konsole", .pid = 10 },
        .{ .id = "{11111111-1111-1111-1111-111111111111}", .title = "Zenkai", .app = "zenkai", .pid = 99 },
        .{ .id = "{22222222-2222-2222-2222-222222222222}", .title = "", .app = "", .pid = 12 },
    };
    try addWindows(&snapshot, std.testing.allocator, &windows, 99);
    try std.testing.expectEqual(@as(usize, 2), snapshot.windows.items.len);
    try std.testing.expectEqualStrings("Terminal", snapshot.windows.items[0].title);
    try std.testing.expectEqualStrings("konsole", snapshot.windows.items[0].app);
    try std.testing.expectEqualStrings("Window", snapshot.windows.items[1].app);
}

test "KDE identities reject non-UUID values" {
    try std.testing.expect(validId("{04add7fb-72b8-4e58-8ac1-5e22730b907b}"));
    try std.testing.expect(!validId("0x123"));
    try std.testing.expect(!validId("{04add7fb-72b8-4e58-8ac1-5e22730b907z}"));
    try std.testing.expect(!validId("{04add7fb-72b8-4e58-8ac1-5e22730b907b}; exec evil"));
}

// Runs against a real KWin when one is provided (tests/run-headless.sh in the kwinctl repo sets
// KWINCTL_TEST_SOCKET); skipped otherwise.
test "KDE backend lists, focuses and tiles windows on a live KWin" {
    if (std.c.getenv("KWINCTL_TEST_SOCKET") == null) return error.SkipZigTest;
    const a = std.testing.allocator;
    var snapshot: Snapshot = .{};
    defer snapshot.deinit(a);
    try enumerate(&snapshot, a, -1);
    try std.testing.expect(snapshot.windows.items.len >= 1);
    const id = snapshot.windows.items[0].id;
    try focus(a, id);
    try manage(a, id, .left);
}
