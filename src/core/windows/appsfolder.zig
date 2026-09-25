const std = @import("std");

pub const StartApp = struct {
    name: []const u8,
    app_id: []const u8,
    target_path: []const u8,
    package_path: []const u8,
};

const Collection = struct {
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(StartApp),
    existing_apps: []const @import("desktopapp").DesktopApp,
    pending_name: ?[]const u8 = null,
    failure: ?anyerror = null,
};

extern "c" fn zenkai_enumerate_start_apps(
    filter: *const fn ([*:0]const u16, ?*anyopaque) callconv(.c) bool,
    callback: *const fn ([*:0]const u16, [*:0]const u16, [*:0]const u16, [*:0]const u16, ?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
) c_int;

fn shouldCollect(name: [*:0]const u16, raw_context: ?*anyopaque) callconv(.c) bool {
    const context: *Collection = @ptrCast(@alignCast(raw_context.?));
    if (context.failure != null) return false;
    const utf8_name = std.unicode.utf16LeToUtf8Alloc(context.allocator, std.mem.span(name)) catch {
        context.failure = error.OutOfMemory;
        return false;
    };
    for (context.existing_apps) |app| {
        if (std.ascii.eqlIgnoreCase(app.name, utf8_name)) return false;
    }
    for (context.entries.items) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, utf8_name)) return false;
    }
    context.pending_name = utf8_name;
    return true;
}

fn collect(name: [*:0]const u16, app_id: [*:0]const u16, target_path: [*:0]const u16, package_path: [*:0]const u16, raw_context: ?*anyopaque) callconv(.c) void {
    const context: *Collection = @ptrCast(@alignCast(raw_context.?));
    if (context.failure != null) return;

    const entry = StartApp{
        .name = context.pending_name orelse std.unicode.utf16LeToUtf8Alloc(context.allocator, std.mem.span(name)) catch return fail(context, error.OutOfMemory),
        .app_id = std.unicode.utf16LeToUtf8Alloc(context.allocator, std.mem.span(app_id)) catch return fail(context, error.OutOfMemory),
        .target_path = std.unicode.utf16LeToUtf8Alloc(context.allocator, std.mem.span(target_path)) catch return fail(context, error.OutOfMemory),
        .package_path = std.unicode.utf16LeToUtf8Alloc(context.allocator, std.mem.span(package_path)) catch return fail(context, error.OutOfMemory),
    };
    context.pending_name = null;
    context.entries.append(context.allocator, entry) catch return fail(context, error.OutOfMemory);
}

fn fail(context: *Collection, err: anyerror) void {
    context.failure = err;
}

pub fn enumerate(allocator: std.mem.Allocator, existing_apps: []const @import("desktopapp").DesktopApp) ![]StartApp {
    var entries: std.ArrayList(StartApp) = .empty;
    var collection = Collection{ .allocator = allocator, .entries = &entries, .existing_apps = existing_apps };
    const hr = zenkai_enumerate_start_apps(shouldCollect, collect, &collection);
    if (collection.failure) |err| return err;
    if (hr < 0) return error.StartAppsUnavailable;
    return entries.toOwnedSlice(allocator);
}
