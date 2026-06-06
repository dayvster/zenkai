const std = @import("std");
const appreader = @import("appreader.zig");
const ui = @import("../ui/ui.zig");
const debug = @import("../debug/debug.zig");

pub const Error = error{ LoadFailed, ScanFailed };

pub fn load(allocator: std.mem.Allocator, benchmark: bool) ![]ui.ListItem {
    if (benchmark) debug.mark("reader load");
    var reader = appreader.AppReader.init(allocator);
    defer reader.deinit();
    reader.load() catch {
        ui.showError("Error loading desktop files");
        return Error.LoadFailed;
    };

    if (benchmark) debug.mark("reader scan");
    reader.scan() catch {
        ui.showError("Error parsing desktop files");
        return Error.ScanFailed;
    };

    if (benchmark) debug.mark("list init");
    const items = try allocator.alloc(ui.ListItem, reader.apps.items.len);
    errdefer allocator.free(items);

    var i: usize = 0;
    errdefer for (0..i) |j| {
        allocator.free(items[j].icon);
        allocator.free(items[j].cmd);
        allocator.free(items[j].name);
    };

    for (reader.apps.items, 0..) |da, idx| {
        i = idx;
        items[idx] = .{
            .icon = try allocator.dupe(u8, if (da.icon) |ic| ic else ""),
            .cmd = try allocator.dupe(u8, if (da.exec) |e| e else ""),
            .name = try allocator.dupe(u8, da.name),
        };
    }
    return items;
}
