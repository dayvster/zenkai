const std = @import("std");
const Snapshot = @import("window_switcher.zig").Snapshot;

const HWND = *anyopaque;
extern "user32" fn EnumWindows(callback: *const fn (HWND, isize) callconv(.winapi) i32, context: isize) callconv(.winapi) i32;
extern "user32" fn IsWindowVisible(window: HWND) callconv(.winapi) i32;
extern "user32" fn IsWindow(window: HWND) callconv(.winapi) i32;
extern "user32" fn IsIconic(window: HWND) callconv(.winapi) i32;
extern "user32" fn GetWindow(window: HWND, command: u32) callconv(.winapi) ?HWND;
extern "user32" fn GetShellWindow() callconv(.winapi) ?HWND;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowLongW(window: HWND, index: i32) callconv(.winapi) i32;
extern "user32" fn GetWindowTextW(window: HWND, text: [*]u16, count: i32) callconv(.winapi) i32;
extern "user32" fn GetWindowThreadProcessId(window: HWND, pid: *u32) callconv(.winapi) u32;
extern "user32" fn ShowWindowAsync(window: HWND, command: i32) callconv(.winapi) i32;
extern "user32" fn SetForegroundWindow(window: HWND) callconv(.winapi) i32;
extern "dwmapi" fn DwmGetWindowAttribute(window: HWND, attribute: u32, value: *anyopaque, size: u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn QueryFullProcessImageNameW(process: *anyopaque, flags: u32, name: [*]u16, size: *u32) callconv(.winapi) i32;

const Context = struct {
    snapshot: *Snapshot,
    allocator: std.mem.Allocator,
    failure: ?anyerror = null,
};

fn visit(window: HWND, raw: isize) callconv(.winapi) i32 {
    const context: *Context = @ptrFromInt(@as(usize, @bitCast(raw)));
    collect(context, window) catch |err| {
        context.failure = err;
        return 0;
    };
    return 1;
}

fn collect(context: *Context, window: HWND) !void {
    if (IsWindowVisible(window) == 0 or window == GetShellWindow()) return;
    var pid: u32 = 0;
    _ = GetWindowThreadProcessId(window, &pid);
    if (pid == 0 or pid == GetCurrentProcessId()) return;
    const style: u32 = @bitCast(GetWindowLongW(window, -20));
    if (style & 0x08000000 != 0) return; // WS_EX_NOACTIVATE.
    if (style & 0x00040000 == 0 and (style & 0x80 != 0 or GetWindow(window, 4) != null)) return;
    var cloaked: u32 = 0;
    if (DwmGetWindowAttribute(window, 14, &cloaked, @sizeOf(u32)) == 0 and cloaked != 0) return;
    var title_buf: [4096]u16 = undefined;
    const length = GetWindowTextW(window, &title_buf, title_buf.len);
    if (length <= 0) return;
    const title = try std.unicode.utf16LeToUtf8Alloc(context.allocator, title_buf[0..@intCast(length)]);
    defer context.allocator.free(title);
    var app_buf: [1024]u16 = undefined;
    var app_length: u32 = app_buf.len;
    var app: []const u8 = "Window";
    var owned_app: ?[]u8 = null;
    defer if (owned_app) |name| context.allocator.free(name);
    if (OpenProcess(0x1000, 0, pid)) |process| {
        defer _ = CloseHandle(process);
        if (QueryFullProcessImageNameW(process, 0, &app_buf, &app_length) != 0) {
            owned_app = try std.unicode.utf16LeToUtf8Alloc(context.allocator, app_buf[0..app_length]);
            app = std.fs.path.stem(owned_app.?);
        }
    }
    var id_buf: [48]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{x}:{d}", .{ @intFromPtr(window), pid });
    const icon = if (owned_app) |path| try std.fmt.allocPrint(context.allocator, "native-file:{s}", .{path}) else null;
    defer if (icon) |value| context.allocator.free(value);
    try context.snapshot.addWithIcon(context.allocator, id, title, app, icon orelse "preferences-system-windows");
}

pub fn enumerate(snapshot: *Snapshot, allocator: std.mem.Allocator) !void {
    var context = Context{ .snapshot = snapshot, .allocator = allocator };
    const ok = EnumWindows(visit, @bitCast(@intFromPtr(&context)));
    if (context.failure) |err| return err;
    if (ok == 0) return error.BackendFailed;
}

fn validatedHandle(id: []const u8) !HWND {
    const separator = std.mem.indexOfScalar(u8, id, ':') orelse return error.WindowNotFound;
    const address = std.fmt.parseInt(usize, id[0..separator], 16) catch return error.WindowNotFound;
    const expected_pid = std.fmt.parseInt(u32, id[separator + 1 ..], 10) catch return error.WindowNotFound;
    if (address == 0) return error.WindowNotFound;
    const window: HWND = @ptrFromInt(address);
    if (IsWindow(window) == 0) return error.WindowNotFound;
    var pid: u32 = 0;
    _ = GetWindowThreadProcessId(window, &pid);
    if (pid != expected_pid or pid == GetCurrentProcessId()) return error.WindowNotFound;
    return window;
}

pub fn focus(id: []const u8) !void {
    const window = try validatedHandle(id);
    if (IsIconic(window) != 0) _ = ShowWindowAsync(window, 9);
    if (SetForegroundWindow(window) == 0 and GetForegroundWindow() != window) return error.FocusFailed;
}

const layout = @import("window_layout.zig");
const NativeRect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const MonitorInfo = extern struct { size: u32 = @sizeOf(MonitorInfo), monitor: NativeRect = undefined, work: NativeRect = undefined, flags: u32 = 0 };
extern "user32" fn GetWindowRect(HWND, *NativeRect) callconv(.winapi) i32;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowPos(HWND, ?HWND, i32, i32, i32, i32, u32) callconv(.winapi) i32;
extern "user32" fn EnumDisplayMonitors(?*anyopaque, ?*const NativeRect, *const fn (*anyopaque, ?*anyopaque, *NativeRect, isize) callconv(.winapi) i32, isize) callconv(.winapi) i32;
extern "user32" fn GetMonitorInfoW(*anyopaque, *MonitorInfo) callconv(.winapi) i32;

fn rect(value: NativeRect) layout.Rect {
    return .{ .x = value.left, .y = value.top, .width = value.right - value.left, .height = value.bottom - value.top };
}
const MonitorList = struct { areas: [32]layout.Rect = undefined, len: usize = 0 };
fn monitorCallback(monitor: *anyopaque, _: ?*anyopaque, _: *NativeRect, data: isize) callconv(.winapi) i32 {
    const list: *MonitorList = @ptrFromInt(@as(usize, @bitCast(data)));
    var info: MonitorInfo = .{};
    if (GetMonitorInfoW(monitor, &info) != 0 and list.len < list.areas.len) {
        list.areas[list.len] = rect(info.work);
        list.len += 1;
    }
    return 1;
}
pub fn manage(id: []const u8, action: layout.Action) !void {
    const window = try validatedHandle(id);
    if (action == .maximize) {
        if (ShowWindowAsync(window, 3) == 0) return error.WindowManagementFailed;
        return;
    }
    // Restore before measuring: minimized/maximized frame borders differ.
    _ = ShowWindow(window, 9);
    var raw: NativeRect = undefined;
    if (GetWindowRect(window, &raw) == 0) return error.WindowNotFound;
    var monitors: MonitorList = .{};
    if (EnumDisplayMonitors(null, null, monitorCallback, @bitCast(@intFromPtr(&monitors))) == 0) return error.NoDisplay;
    var visible: NativeRect = undefined;
    const has_frame = DwmGetWindowAttribute(window, 9, &visible, @sizeOf(NativeRect)) == 0;
    const target = try layout.destination(rect(if (has_frame) visible else raw), monitors.areas[0..monitors.len], action);
    // Account for the invisible Windows resize border when snapping halves.
    var x = target.x;
    var y = target.y;
    var width = target.width;
    var height = target.height;
    if (has_frame) {
        x -= visible.left - raw.left;
        y -= visible.top - raw.top;
        width += (visible.left - raw.left) + (raw.right - visible.right);
        height += (visible.top - raw.top) + (raw.bottom - visible.bottom);
    }
    if (SetWindowPos(window, null, x, y, width, height, 0x4000 | 0x0004 | 0x0010) == 0) return error.WindowManagementFailed;
}
