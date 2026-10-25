const std = @import("std");
const mac = @import("utils").macos;
const Snapshot = @import("window_switcher.zig").Snapshot;

pub fn enumerate(snapshot: *Snapshot, allocator: std.mem.Allocator) !void {
    if (!mac.AXIsProcessTrusted()) return error.AccessibilityDenied;
    const scope = mac.pool();
    defer mac.send(void, scope, "drain", .{});
    const workspace = mac.send(mac.Object, mac.class("NSWorkspace"), "sharedWorkspace", .{});
    const applications = mac.send(mac.Object, workspace, "runningApplications", .{});
    const count = mac.send(usize, applications, "count", .{});
    for (0..count) |i| {
        const application = mac.send(mac.Object, applications, "objectAtIndex:", .{i});
        const pid = mac.send(i32, application, "processIdentifier", .{});
        if (pid == std.c.getpid() or mac.send(isize, application, "activationPolicy", .{}) != 0) continue;
        const element = mac.AXUIElementCreateApplication(pid) orelse continue;
        defer mac.CFRelease(element);
        _ = mac.AXUIElementSetMessagingTimeout(element, 0.2);
        const windows = mac.attribute(element, "AXWindows") catch continue;
        defer mac.CFRelease(windows);
        if (mac.CFGetTypeID(windows) != mac.CFArrayGetTypeID()) continue;
        const app = mac.string(mac.send(mac.Object, application, "localizedName", .{}));
        const bundle = mac.send(mac.Object, application, "bundleURL", .{});
        const path = mac.string(mac.send(mac.Object, bundle, "path", .{}));
        const icon = if (path.len > 0) try std.fmt.allocPrint(allocator, "native-file:{s}", .{path}) else try allocator.dupe(u8, "preferences-system-windows");
        defer allocator.free(icon);
        const window_count = mac.CFArrayGetCount(windows);
        var index: isize = 0;
        while (index < window_count) : (index += 1) {
            const window = mac.CFArrayGetValueAtIndex(windows, index) orelse continue;
            _ = mac.AXUIElementSetMessagingTimeout(window, 0.2);
            const title_value = mac.attribute(window, "AXTitle") catch continue;
            defer mac.CFRelease(title_value);
            const title = mac.copyString(allocator, title_value) catch continue;
            defer allocator.free(title);
            var id_buffer: [64]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buffer, "{d}:{d}", .{ pid, index });
            try snapshot.addWithIcon(allocator, id, title, app, icon);
            // Keep the exact AX object: changing titles or window order cannot target a sibling.
            snapshot.windows.items[snapshot.windows.items.len - 1].native_handle = mac.CFRetain(window);
        }
    }
}

pub fn focus(window: mac.Ref) !void {
    if (!mac.AXIsProcessTrusted()) return error.AccessibilityDenied;
    var pid: i32 = 0;
    if (mac.AXUIElementGetPid(window, &pid) != 0 or pid <= 0) return error.WindowNotFound;
    const scope = mac.pool();
    defer mac.send(void, scope, "drain", .{});
    const application = mac.send(mac.Object, mac.class("NSRunningApplication"), "runningApplicationWithProcessIdentifier:", .{pid});
    if (application == null) return error.WindowNotFound;
    // Some applications do not expose AXMinimized; raising them is still valid.
    mac.setAttribute(window, "AXMinimized", mac.kCFBooleanFalse) catch {};
    if (!mac.send(bool, application, "activateWithOptions:", .{@as(usize, 2)})) return error.FocusFailed;
    try mac.raise(window);
}

const layout = @import("window_layout.zig");
const Point = extern struct { x: f64, y: f64 };
const Size = extern struct { width: f64, height: f64 };
extern "ApplicationServices" fn AXValueGetValue(mac.Ref, u32, *anyopaque) bool;
extern "ApplicationServices" fn AXValueCreate(u32, *const anyopaque) ?mac.Ref;
pub fn geometry(window: mac.Ref) !layout.Rect {
    const position = try mac.attribute(window, "AXPosition");
    defer mac.CFRelease(position);
    const size = try mac.attribute(window, "AXSize");
    defer mac.CFRelease(size);
    var point: Point = undefined;
    var dimensions: Size = undefined;
    if (!AXValueGetValue(position, 1, &point) or !AXValueGetValue(size, 2, &dimensions)) return error.InvalidGeometry;
    for ([_]f64{ point.x, point.y, dimensions.width, dimensions.height }) |value| {
        if (!std.math.isFinite(value) or value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.InvalidGeometry;
    }
    return .{ .x = @intFromFloat(point.x), .y = @intFromFloat(point.y), .width = @intFromFloat(dimensions.width), .height = @intFromFloat(dimensions.height) };
}
pub fn manage(window: mac.Ref, action: layout.Action, screens: []const layout.Rect) !void {
    if (!mac.AXIsProcessTrusted()) return error.AccessibilityDenied;
    const target = try layout.destination(try geometry(window), screens, action);
    // Maximize fills the usable desktop; it does not create a fullscreen Space.
    mac.setAttribute(window, "AXMinimized", mac.kCFBooleanFalse) catch {};
    mac.setAttribute(window, "AXFullScreen", mac.kCFBooleanFalse) catch {};
    var point = Point{ .x = @floatFromInt(target.x), .y = @floatFromInt(target.y) };
    var dimensions = Size{ .width = @floatFromInt(target.width), .height = @floatFromInt(target.height) };
    const position = AXValueCreate(1, &point) orelse return error.OutOfMemory;
    defer mac.CFRelease(position);
    const size = AXValueCreate(2, &dimensions) orelse return error.OutOfMemory;
    defer mac.CFRelease(size);
    try mac.setAttribute(window, "AXPosition", position);
    try mac.setAttribute(window, "AXSize", size);
    // Some apps adjust position while resizing to their minimum size.
    try mac.setAttribute(window, "AXPosition", position);
}
