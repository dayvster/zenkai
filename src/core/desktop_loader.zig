const std = @import("std");
const platform = @import("platform.zig");
const de = @import("desktopapp");
const ui = @import("../ui/ui.zig");
const debug = @import("../debug/debug.zig");
const actions_mod = @import("actions.zig");
const fsutils = @import("utils").fsutils;
const lang = @import("lang");
const config = @import("config");
const startup_benchmark = @import("../debug/startup_benchmark.zig");

const CachedItem = struct {
    name: []const u8,
    cmd: []const u8,
    icon: []const u8,
    desktop_app_idx: ?usize = null,
};
const cache_version: u32 = 3;
const CachedItems = struct {
    version: u32 = 0,
    items: []CachedItem,
};

fn cachePath(allocator: std.mem.Allocator) ![]u8 {
    if (startup_benchmark.enabled) {
        const path = std.c.getenv("ZENKAI_BENCHMARK_CACHE") orelse return error.NoBenchmarkCache;
        return try allocator.dupe(u8, std.mem.sliceTo(path, 0));
    }
    const dir = try config.configDir(allocator);
    defer allocator.free(dir);
    return try std.fmt.allocPrint(allocator, "{s}/apps-{s}.json", .{ dir, @tagName(@import("builtin").os.tag) });
}

pub fn cacheIsFresh(allocator: std.mem.Allocator) bool {
    const work = startup_benchmark.workStart();
    defer startup_benchmark.workEnd(.cache_stat, work);
    const path = cachePath(allocator) catch return false;
    defer allocator.free(path);
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const stat = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, path, .{}) catch return false;
    const now = std.Io.Timestamp.now(io, .real);
    const age = now.nanoseconds - stat.mtime.nanoseconds;
    return age >= 0 and age < 5 * std.time.ns_per_min;
}

pub fn loadCache(allocator: std.mem.Allocator) ?[]ui.ListItem {
    var work = startup_benchmark.workStart();
    var phase: startup_benchmark.WorkPhase = .cache_read;
    defer startup_benchmark.workEnd(phase, work);
    const path = cachePath(allocator) catch return null;
    defer allocator.free(path);
    const content = fsutils.readFile(allocator, path, 8 * 1024 * 1024) catch return null;
    defer allocator.free(content);
    startup_benchmark.workEnd(.cache_read, work);
    phase = .cache_decode;
    work = startup_benchmark.workStart();
    const parsed = std.json.parseFromSlice(CachedItems, allocator, content, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();
    if (parsed.value.version != cache_version) return null;
    const items = allocator.alloc(ui.ListItem, parsed.value.items.len) catch return null;
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| {
            allocator.free(item.name);
            allocator.free(item.cmd);
            allocator.free(item.icon);
        }
        allocator.free(items);
    }
    for (parsed.value.items, 0..) |item, i| {
        items[i] = .{
            .name = allocator.dupe(u8, item.name) catch return null,
            .cmd = allocator.dupe(u8, item.cmd) catch return null,
            .icon = allocator.dupe(u8, item.icon) catch return null,
            .desktop_app_idx = item.desktop_app_idx orelse 0,
        };
        initialized += 1;
    }
    return items;
}

pub fn saveCache(allocator: std.mem.Allocator, items: []const ui.ListItem) void {
    const work = startup_benchmark.workStart();
    defer startup_benchmark.workEnd(.cache_write, work);
    const cached = allocator.alloc(CachedItem, items.len) catch return;
    defer allocator.free(cached);
    for (items, 0..) |item, i| cached[i] = .{
        .name = item.name,
        .cmd = item.cmd,
        .icon = item.icon,
        .desktop_app_idx = item.desktop_app_idx,
    };
    const json = std.json.Stringify.valueAlloc(allocator, CachedItems{ .version = cache_version, .items = cached }, .{}) catch return;
    defer allocator.free(json);
    const path = cachePath(allocator) catch return;
    defer allocator.free(path);
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const cwd = std.Io.Dir.cwd();
    var file = std.Io.Dir.createFile(cwd, io, path, .{}) catch return;
    defer std.Io.File.close(file, io);
    file.writeStreamingAll(io, json) catch {};
}

pub const Error = error{ LoadFailed, ScanFailed };

var g_reader: ?platform.AppReader = null;

pub fn getDesktopApps() []const de.DesktopApp {
    if (g_reader) |*r| return r.apps.items;
    return &.{};
}

/// Load the desktop reader without building the UI item list. The startup
/// cache can populate the launcher before any app has been scanned; features
/// that need the full desktop entry call this on demand.
pub fn ensureAppsLoaded(allocator: std.mem.Allocator) bool {
    if (g_reader != null) return true;
    var reader = platform.AppReader.init(allocator);
    reader.load() catch {
        reader.deinit();
        return false;
    };
    reader.scan() catch {
        reader.deinit();
        return false;
    };
    g_reader = reader;
    return true;
}

pub fn freeDesktopApps() void {
    if (g_reader) |*r| r.deinit();
    g_reader = null;
}

fn parseAndStoreActions(allocator: std.mem.Allocator, da: *const de.DesktopApp, actions_out: *std.ArrayList(ui.ListItemAction)) !void {
    if (da.file_path) |fp| {
        const content = fsutils.readFile(allocator, fp, 2 * 1024 * 1024) catch return;
        defer allocator.free(content);

        const parsed = actions_mod.parseActions(allocator, content, da.actions) catch return;
        defer actions_mod.deinitActions(allocator, parsed);

        for (parsed) |action| {
            try actions_out.append(allocator, .{
                .name = try allocator.dupe(u8, action.name),
                .exec = try de.DesktopEntry.expandExecString(action.exec, da, allocator),
                .icon = if (action.icon) |ic| try allocator.dupe(u8, ic) else try allocator.dupe(u8, if (da.icon) |ic2| ic2 else ""),
            });
        }
    }
}

pub fn freeListItemActions(allocator: std.mem.Allocator, actions: []const ui.ListItemAction) void {
    for (actions) |a| {
        allocator.free(a.name);
        allocator.free(a.exec);
        allocator.free(a.icon);
    }
    allocator.free(actions);
}

fn makeListItem(allocator: std.mem.Allocator, da: *const de.DesktopApp, actions: []const ui.ListItemAction, app_idx: usize) !ui.ListItem {
    const cmd = if (da.exec) |e|
        try de.DesktopEntry.expandExecString(e, da, allocator)
    else
        try allocator.dupe(u8, "");
    return .{
        .icon = try allocator.dupe(u8, if (da.icon) |ic| ic else ""),
        .cmd = cmd,
        .name = try allocator.dupe(u8, da.name),
        .actions = actions,
        .desktop_app_idx = app_idx,
    };
}

pub fn load(allocator: std.mem.Allocator, benchmark: bool, show_actions: bool, actions_bottombar: bool) ![]ui.ListItem {
    const discovery_work = startup_benchmark.workStart();
    if (benchmark) debug.mark("reader load");
    freeDesktopApps();

    var reader = platform.AppReader.init(allocator);
    errdefer reader.deinit();
    reader.load() catch {
        ui.showError(lang.get().error_loading_desktop);
        return Error.LoadFailed;
    };

    if (benchmark) debug.mark("reader scan");
    reader.scan() catch {
        ui.showError(lang.get().error_parsing_desktop);
        return Error.ScanFailed;
    };
    startup_benchmark.workEnd(.discovery, discovery_work);
    const conversion_work = startup_benchmark.workStart();
    defer startup_benchmark.workEnd(.item_conversion, conversion_work);

    if (benchmark) debug.mark("list init");

    const need_actions = actions_bottombar or show_actions;
    const show_list_actions = show_actions and !actions_bottombar;

    var all_items = std.ArrayList(ui.ListItem).empty;
    errdefer {
        g_reader = null;
        for (all_items.items) |item| {
            allocator.free(item.icon);
            allocator.free(item.cmd);
            allocator.free(item.name);
            if (item.actions.len > 0) freeListItemActions(allocator, item.actions);
        }
        all_items.deinit(allocator);
    }

    g_reader = reader;

    for (reader.apps.items, 0..) |*da, app_idx| {
        if (need_actions and da.actions.len > 0) {
            var action_list = std.ArrayList(ui.ListItemAction).empty;
            parseAndStoreActions(allocator, da, &action_list) catch {};
            const action_slice = try action_list.toOwnedSlice(allocator);

            {
                const item = try makeListItem(allocator, da, action_slice, app_idx);
                errdefer {
                    allocator.free(item.icon);
                    allocator.free(item.cmd);
                    allocator.free(item.name);
                    if (item.actions.len > 0) freeListItemActions(allocator, item.actions);
                }
                try all_items.append(allocator, item);
            }

            if (show_list_actions) {
                for (action_slice) |action_item| {
                    const label = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ da.name, action_item.name });
                    errdefer allocator.free(label);
                    const cmd = try allocator.dupe(u8, action_item.exec);
                    errdefer allocator.free(cmd);
                    const icon = try allocator.dupe(u8, action_item.icon);
                    errdefer allocator.free(icon);
                    try all_items.append(allocator, .{
                        .icon = icon,
                        .cmd = cmd,
                        .name = label,
                        .desktop_app_idx = app_idx,
                    });
                }
            }
        } else {
            {
                const item = try makeListItem(allocator, da, &.{}, app_idx);
                errdefer {
                    allocator.free(item.icon);
                    allocator.free(item.cmd);
                    allocator.free(item.name);
                }
                try all_items.append(allocator, item);
            }
        }
    }

    return try all_items.toOwnedSlice(allocator);
}
