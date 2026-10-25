const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");

pub const Window = struct {
    id: []const u8,
    title: []const u8,
    app: []const u8,
    icon: []const u8 = "preferences-system-windows",
    native_handle: ?*const anyopaque = null,
};

pub const Backend = enum { windows, macos, x11, hyprland, sway };
pub const layout = @import("window_layout.zig");

pub const Snapshot = struct {
    backend: Backend = .windows,
    windows: std.ArrayList(Window) = .empty,

    pub fn manage(self: *const Snapshot, allocator: std.mem.Allocator, index: usize, action: layout.Action, screens: []const layout.Rect) !void {
        if (index >= self.windows.items.len) return error.WindowNotFound;
        const window = self.windows.items[index];
        if (comptime builtin.os.tag == .windows) {
            try @import("window_switcher_windows.zig").manage(window.id, action);
        } else if (comptime builtin.os.tag == .macos) {
            try @import("window_switcher_macos.zig").manage(window.native_handle orelse return error.WindowNotFound, action, screens);
        } else if (comptime builtin.os.tag == .linux) {
            try @import("window_management_linux.zig").manage(allocator, self.backend, window.id, action);
        } else return error.UnsupportedPlatform;
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.windows.items) |window| {
            if (comptime builtin.os.tag == .macos) {
                if (window.native_handle) |handle| utils.macos.CFRelease(handle);
            }
            allocator.free(window.id);
            allocator.free(window.title);
            allocator.free(window.app);
            allocator.free(window.icon);
        }
        self.windows.deinit(allocator);
        self.windows = .empty;
    }

    pub fn add(self: *Snapshot, allocator: std.mem.Allocator, id: []const u8, title: []const u8, app: []const u8) !void {
        return self.addWithIcon(allocator, id, title, app, "preferences-system-windows");
    }

    pub fn addWithIcon(self: *Snapshot, allocator: std.mem.Allocator, id: []const u8, title: []const u8, app: []const u8, icon: []const u8) !void {
        if (self.windows.items.len >= 2048) return error.TooManyWindows;
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_title = try allocator.dupe(u8, if (title.len == 0) app else title);
        errdefer allocator.free(owned_title);
        const owned_app = try allocator.dupe(u8, app);
        errdefer allocator.free(owned_app);
        const owned_icon = try allocator.dupe(u8, icon);
        errdefer allocator.free(owned_icon);
        try self.windows.append(allocator, .{ .id = owned_id, .title = owned_title, .app = owned_app, .icon = owned_icon });
    }

    pub fn refresh(self: *Snapshot, allocator: std.mem.Allocator) !void {
        self.deinit(allocator);
        errdefer self.deinit(allocator);
        if (comptime builtin.os.tag == .windows) {
            self.backend = .windows;
            try @import("window_switcher_windows.zig").enumerate(self, allocator);
        } else if (comptime builtin.os.tag == .macos) {
            self.backend = .macos;
            try @import("window_switcher_macos.zig").enumerate(self, allocator);
        } else if (comptime builtin.os.tag == .linux) {
            if (hasEnv("HYPRLAND_INSTANCE_SIGNATURE")) {
                self.backend = .hyprland;
                const output = try capture(allocator, "hyprctl", &.{ "-j", "clients" });
                defer allocator.free(output);
                try self.parseHyprland(allocator, output, std.c.getpid());
            } else if (hasEnv("SWAYSOCK")) {
                self.backend = .sway;
                const output = try capture(allocator, "swaymsg", &.{ "-t", "get_tree", "-r" });
                defer allocator.free(output);
                try self.parseSway(allocator, output, std.c.getpid());
            } else if (hasEnv("WAYLAND_DISPLAY")) {
                return error.UnsupportedWayland;
            } else if (hasEnv("DISPLAY")) {
                self.backend = .x11;
                const output = try capture(allocator, "wmctrl", &.{"-lpx"});
                defer allocator.free(output);
                try self.parseX11(allocator, output, std.c.getpid());
            } else return error.NoDisplay;
            for (self.windows.items, 0..) |*window, i| {
                const icon = blk: {
                    for (self.windows.items[0..i]) |previous| {
                        if (std.mem.eql(u8, previous.app, window.app)) break :blk try allocator.dupe(u8, previous.icon);
                    }
                    break :blk utils.app_icons.desktopIcon(allocator, window.app) catch continue;
                };
                allocator.free(window.icon);
                window.icon = icon;
            }
        } else return error.UnsupportedPlatform;
    }

    pub fn focus(self: *const Snapshot, allocator: std.mem.Allocator, id: []const u8) !void {
        // Only accept identities from the most recent enumeration.
        var found = false;
        for (self.windows.items) |window| {
            if (std.mem.eql(u8, window.id, id)) {
                if (comptime builtin.os.tag == .macos) {
                    return @import("window_switcher_macos.zig").focus(window.native_handle orelse return error.WindowNotFound);
                }
                found = true;
                break;
            }
        }
        if (!found) return error.WindowNotFound;
        if (comptime builtin.os.tag == .windows) {
            return @import("window_switcher_windows.zig").focus(id);
        } else {
            var buf: [128]u8 = undefined;
            const output = switch (self.backend) {
                .x11 => try capture(allocator, "wmctrl", &.{ "-ia", id }),
                .hyprland => try capture(allocator, "hyprctl", &.{ "dispatch", "focuswindow", try std.fmt.bufPrint(&buf, "address:{s}", .{id}) }),
                .sway => try capture(allocator, "swaymsg", &.{ "-r", try std.fmt.bufPrint(&buf, "[con_id={s}] focus", .{id}) }),
                .windows, .macos => return error.UnsupportedPlatform,
            };
            defer allocator.free(output);
            if (self.backend == .hyprland and !std.mem.eql(u8, std.mem.trim(u8, output, " \r\n"), "ok")) return error.FocusFailed;
            if (self.backend == .sway) {
                const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
                defer parsed.deinit();
                if (parsed.value != .array or parsed.value.array.items.len == 0) return error.FocusFailed;
                for (parsed.value.array.items) |reply| {
                    if (reply != .object) return error.FocusFailed;
                    const success = reply.object.get("success") orelse return error.FocusFailed;
                    if (success != .bool or !success.bool) return error.FocusFailed;
                }
            }
        }
    }

    fn parseX11(self: *Snapshot, allocator: std.mem.Allocator, output: []const u8, own_pid: i64) !void {
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t\r");
            const id = fields.next() orelse continue;
            _ = fields.next() orelse continue; // Desktop number.
            const pid = fields.next() orelse continue;
            const app = fields.next() orelse continue;
            _ = fields.next() orelse continue; // Machine name.
            if (!validHexId(id)) continue;
            if ((std.fmt.parseInt(i64, pid, 10) catch continue) == own_pid) continue;
            const title = std.mem.trim(u8, fields.rest(), " \t\r");
            if (title.len == 0) continue;
            try self.add(allocator, id, title, app);
        }
    }

    fn parseHyprland(self: *Snapshot, allocator: std.mem.Allocator, output: []const u8, own_pid: i64) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidResponse;
        for (parsed.value.array.items) |client| {
            if (client != .object) continue;
            const pid = integerField(client, "pid") orelse continue;
            if (pid == own_pid) continue;
            if (client.object.get("mapped")) |mapped| {
                if (mapped == .bool and !mapped.bool) continue;
            }
            const id = stringField(client, "address") orelse continue;
            if (!validHexId(id)) continue;
            try self.add(allocator, id, stringField(client, "title") orelse "", stringField(client, "class") orelse "Window");
        }
    }

    fn parseSway(self: *Snapshot, allocator: std.mem.Allocator, output: []const u8, own_pid: i64) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
        defer parsed.deinit();
        try self.walkSway(allocator, parsed.value, own_pid, 0);
    }

    fn walkSway(self: *Snapshot, allocator: std.mem.Allocator, node: std.json.Value, own_pid: i64, depth: usize) anyerror!void {
        if (depth > 64) return error.TreeTooDeep;
        if (node != .object) return error.InvalidResponse;
        if (integerField(node, "pid")) |pid| {
            if (pid != own_pid) {
                const id = integerField(node, "id") orelse return error.InvalidResponse;
                if (id <= 0) return error.InvalidResponse;
                var id_buf: [24]u8 = undefined;
                const app = stringField(node, "app_id") orelse blk: {
                    if (node.object.get("window_properties")) |props| break :blk stringField(props, "class") orelse "Window";
                    break :blk "Window";
                };
                try self.add(allocator, try std.fmt.bufPrint(&id_buf, "{d}", .{id}), stringField(node, "name") orelse "", app);
            }
        }
        for ([_][]const u8{ "nodes", "floating_nodes" }) |key| {
            if (node.object.get(key)) |children| {
                if (children == .array) {
                    for (children.array.items) |child| try self.walkSway(allocator, child, own_pid, depth + 1);
                }
            }
        }
    }
};

fn hasEnv(key: [*:0]const u8) bool {
    const value = std.c.getenv(key) orelse return false;
    return value[0] != 0;
}

fn validHexId(id: []const u8) bool {
    if (id.len <= 2 or id.len > 18 or !std.mem.startsWith(u8, id, "0x")) return false;
    return (std.fmt.parseInt(u64, id[2..], 16) catch return false) != 0;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn integerField(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .integer) field.integer else null;
}

pub fn capture(allocator: std.mem.Allocator, executable: []const u8, args: []const []const u8) ![]u8 {
    const buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buffer);
    const result = try utils.runToolTimed(executable, args, buffer, 2000, allocator);
    if (result.exit_code == null or result.exit_code.? != 0) return error.BackendFailed;
    if (result.truncated) return error.ResponseTooLarge;
    return allocator.dupe(u8, buffer[0..result.bytes]);
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedWayland => "This Wayland session needs a compositor backend. Supported: Hyprland and Sway.",
        error.NoDisplay => "No desktop session found.",
        error.ToolNotFound => "Install wmctrl and xrandr for X11, or ensure hyprctl/swaymsg is available for your compositor.",
        error.NoOtherDisplay => "Connect another display to move this window.",
        error.WindowManagementFailed, error.AttributeUnavailable => "The application or desktop refused to move or resize this window.",
        error.InvalidGeometry => "The desktop returned an unusable window or display size.",
        error.RunTimeout => "Window discovery timed out.",
        error.AccessibilityDenied => "Allow Zenkai Accessibility access in System Settings > Privacy & Security > Accessibility.",
        error.BackendFailed => "The window backend failed. Check desktop permissions and try again.",
        error.WindowNotFound, error.FocusFailed => "The window closed or the desktop refused focus. Change the query to refresh.",
        else => "Unable to read or focus windows. Check the desktop backend and try again.",
    };
}

test "X11 windows preserve titles with spaces and omit the launcher" {
    var snapshot: Snapshot = .{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.parseX11(std.testing.allocator,
        \\0x00000123 0 10 editor.Editor host Project with spaces
        \\0x00000456 1 99 zenkai.Zenkai host Zenkai
        \\bad 0 12 app.App host Not an identity
    , 99);
    try std.testing.expectEqual(@as(usize, 1), snapshot.windows.items.len);
    try std.testing.expectEqualStrings("Project with spaces", snapshot.windows.items[0].title);
    try std.testing.expectEqualStrings("editor.Editor", snapshot.windows.items[0].app);
}

test "Hyprland windows validate identities and filter unmapped and launcher windows" {
    var snapshot: Snapshot = .{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.parseHyprland(std.testing.allocator,
        \\[{"address":"0x123","title":"Terminal","class":"foot","pid":10,"mapped":true},
        \\ {"address":"0x234","title":"Hidden","pid":11,"mapped":false},
        \\ {"address":"0x345","title":"Zenkai","pid":99},
        \\ {"address":"0x123;exec evil","title":"Invalid","pid":12}]
    , 99);
    try std.testing.expectEqual(@as(usize, 1), snapshot.windows.items.len);
    try std.testing.expectEqualStrings("0x123", snapshot.windows.items[0].id);
}

test "Sway traverses tiled and floating windows including XWayland classes" {
    var snapshot: Snapshot = .{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.parseSway(std.testing.allocator,
        \\{"nodes":[{"nodes":[{"id":1,"pid":10,"name":"Editor","app_id":"code"},
        \\ {"id":2,"pid":99,"name":"Zenkai","app_id":"zenkai"}]}],
        \\ "floating_nodes":[{"id":3,"pid":11,"name":"Browser","app_id":null,
        \\ "window_properties":{"class":"Firefox"}}]}
    , 99);
    try std.testing.expectEqual(@as(usize, 2), snapshot.windows.items.len);
    try std.testing.expectEqualStrings("3", snapshot.windows.items[1].id);
    try std.testing.expectEqualStrings("Firefox", snapshot.windows.items[1].app);
    try std.testing.expectError(error.WindowNotFound, snapshot.focus(std.testing.allocator, "not enumerated"));
}

test "native window backend entry points" {
    const manage: *const fn (*const Snapshot, std.mem.Allocator, usize, layout.Action, []const layout.Rect) anyerror!void = Snapshot.manage;
    // Referencing both entry points also checks their platform-specific code in cross-compiles.
    const refresh: *const fn (*Snapshot, std.mem.Allocator) anyerror!void = Snapshot.refresh;
    const focus: *const fn (*const Snapshot, std.mem.Allocator, []const u8) anyerror!void = Snapshot.focus;
    var snapshot: Snapshot = .{};
    try std.testing.expectError(error.WindowNotFound, manage(&snapshot, std.testing.allocator, 0, .left, &.{}));
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectError(error.WindowNotFound, focus(&snapshot, std.testing.allocator, "invalid"));
    if (builtin.os.tag == .windows or hasEnv("ZENKAI_TEST_LIVE_WINDOWS")) try refresh(&snapshot, std.testing.allocator);
}
