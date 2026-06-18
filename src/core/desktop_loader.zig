const std = @import("std");
const platform = @import("platform.zig");
const de = @import("desktopapp");
const ui = @import("../ui/ui.zig");
const debug = @import("../debug/debug.zig");
const actions_mod = @import("actions.zig");
const fsutils = @import("utils").fsutils;
const lang = @import("lang");

pub const Error = error{ LoadFailed, ScanFailed };

var g_reader: ?platform.AppReader = null;

pub fn getDesktopApps() []const de.DesktopApp {
    if (g_reader) |*r| return r.apps.items;
    return &.{};
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
    if (benchmark) debug.mark("reader load");
    freeDesktopApps();

    var reader = platform.AppReader.init(allocator);
    reader.load() catch {
        ui.showError(lang.get().error_loading_desktop);
        return Error.LoadFailed;
    };

    if (benchmark) debug.mark("reader scan");
    reader.scan() catch {
        ui.showError(lang.get().error_parsing_desktop);
        return Error.ScanFailed;
    };

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
        reader.deinit();
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
