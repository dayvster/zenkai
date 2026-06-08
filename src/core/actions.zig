const std = @import("std");
const dapp_parser = @import("dapp_parser");
const utils = @import("utils");

pub const DesktopAction = struct {
    id: []const u8,
    name: []const u8,
    exec: []const u8,
    icon: ?[]const u8,
};

pub fn parseActions(allocator: std.mem.Allocator, content: []const u8, action_ids: [][]const u8) ![]DesktopAction {
    var actions = std.ArrayList(DesktopAction).empty;
    errdefer {
        for (actions.items) |a| {
            allocator.free(a.id);
            allocator.free(a.name);
            allocator.free(a.exec);
            if (a.icon) |ic| allocator.free(ic);
        }
        actions.deinit(allocator);
    }

    var entry_iter = dapp_parser.desktopEntryIterator(content);
    while (entry_iter.next()) |section| {
        const section_name = extractSectionName(section) orelse continue;
        if (utils.log.verbose) utils.log.info("  section: '{s}'", .{section_name});
        const action_id = stripDesktopActionPrefix(section_name) orelse continue;

        const is_wanted = for (action_ids) |id| {
            if (std.mem.eql(u8, id, action_id)) break true;
        } else false;
        if (!is_wanted) continue;

        var name: ?[]const u8 = null;
        var exec: ?[]const u8 = null;
        var icon: ?[]const u8 = null;

        var line_iter = dapp_parser.lineIterator(section);
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const kv = splitToKV(trimmed) orelse continue;
            if (std.mem.indexOfScalar(u8, kv.key, '[') != null) continue;

            if (utils.strcomp(kv.key, "Name")) {
                name = kv.value;
            } else if (utils.strcomp(kv.key, "Exec")) {
                exec = if (kv.value.len > 0) kv.value else null;
            } else if (utils.strcomp(kv.key, "Icon")) {
                icon = if (kv.value.len > 0) kv.value else null;
            }
        }

        if (name == null or exec == null) {
            if (utils.log.verbose) utils.log.info("action '{s}' skipped: name={?s} exec={?s}", .{ action_id, name, exec });
            continue;
        }

        try actions.append(allocator, .{
            .id = try allocator.dupe(u8, action_id),
            .name = try allocator.dupe(u8, name.?),
            .exec = try allocator.dupe(u8, exec.?),
            .icon = if (icon) |ic| try allocator.dupe(u8, ic) else null,
        });
    }

    if (utils.log.verbose) utils.log.info("parseActions: found {d} actions for {d} requested ids", .{ actions.items.len, action_ids.len });
    return try actions.toOwnedSlice(allocator);
}

pub fn deinitActions(allocator: std.mem.Allocator, actions: []DesktopAction) void {
    for (actions) |a| {
        allocator.free(a.id);
        allocator.free(a.name);
        allocator.free(a.exec);
        if (a.icon) |ic| allocator.free(ic);
    }
    allocator.free(actions);
}

fn extractSectionName(section: []const u8) ?[]const u8 {
    var line_iter = dapp_parser.lineIterator(section);
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse continue;
            return trimmed[1..close];
        }
    }
    return null;
}

fn stripDesktopActionPrefix(section_name: []const u8) ?[]const u8 {
    const prefix = "Desktop Action ";
    if (std.mem.startsWith(u8, section_name, prefix)) {
        return section_name[prefix.len..];
    }
    return null;
}

fn splitToKV(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        const value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
        return .{ .key = key, .value = value };
    }
    return null;
}
