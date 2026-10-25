const std = @import("std");
const backend = @import("window_switcher.zig");
const layout = @import("window_layout.zig");
const Rect = layout.Rect;
fn number(value: std.json.Value) !i32 {
    return switch (value) {
        .integer => |v| std.math.cast(i32, v) orelse error.InvalidGeometry,
        else => error.InvalidGeometry,
    };
}
fn field(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidResponse;
    return value.object.get(key) orelse error.InvalidResponse;
}
fn rectangle(value: std.json.Value) !Rect {
    return .{ .x = try number(try field(value, "x")), .y = try number(try field(value, "y")), .width = try number(try field(value, "width")), .height = try number(try field(value, "height")) };
}
fn swayWindow(value: std.json.Value, id: i64) ?Rect {
    if (value != .object) return null;
    if (value.object.get("id")) |identity| {
        if (identity == .integer and identity.integer == id) return rectangle(value.object.get("rect") orelse return null) catch null;
    }
    for ([_][]const u8{ "nodes", "floating_nodes" }) |key| {
        if (value.object.get(key)) |children| {
            if (children == .array) for (children.array.items) |child| {
                if (swayWindow(child, id)) |rect| return rect;
            };
        }
    }
    return null;
}
fn command(a: std.mem.Allocator, kind: backend.Backend, tool: []const u8, args: []const []const u8) !void {
    const result = try backend.capture(a, tool, args);
    defer a.free(result);
    if (kind == .hyprland and !std.mem.eql(u8, std.mem.trim(u8, result, " \r\n"), "ok")) return error.WindowManagementFailed;
    if (kind == .sway) {
        const json = try std.json.parseFromSlice(std.json.Value, a, result, .{});
        defer json.deinit();
        if (json.value != .array or json.value.array.items.len == 0) return error.WindowManagementFailed;
        for (json.value.array.items) |reply| {
            const success = try field(reply, "success");
            if (success != .bool or !success.bool) return error.WindowManagementFailed;
        }
    }
}
fn parseXrandrGeometry(value: []const u8) !Rect {
    const x = std.mem.indexOfScalar(u8, value, 'x') orelse return error.InvalidGeometry;
    const offset_start = (std.mem.indexOfAny(u8, value[x + 1 ..], "+-") orelse return error.InvalidGeometry) + x + 1;
    const y_start = (std.mem.indexOfAny(u8, value[offset_start + 1 ..], "+-") orelse return error.InvalidGeometry) + offset_start + 1;
    const w_end = std.mem.indexOfScalar(u8, value[0..x], '/') orelse x;
    const h_end = (std.mem.indexOfScalar(u8, value[x + 1 .. offset_start], '/') orelse (offset_start - x - 1)) + x + 1;
    return .{ .x = try std.fmt.parseInt(i32, value[offset_start..y_start], 10), .y = try std.fmt.parseInt(i32, value[y_start..], 10), .width = try std.fmt.parseInt(i32, value[0..w_end], 10), .height = try std.fmt.parseInt(i32, value[x + 1 .. h_end], 10) };
}

pub fn manage(a: std.mem.Allocator, kind: backend.Backend, id: []const u8, action: layout.Action) !void {
    var areas: std.ArrayList(Rect) = .empty;
    defer areas.deinit(a);
    var current: ?Rect = null;
    var buffer: [512]u8 = undefined;
    switch (kind) {
        .hyprland => {
            const clients = try backend.capture(a, "hyprctl", &.{ "-j", "clients" });
            defer a.free(clients);
            const json = try std.json.parseFromSlice(std.json.Value, a, clients, .{});
            defer json.deinit();
            if (json.value != .array) return error.InvalidResponse;
            for (json.value.array.items) |client| {
                const address = try field(client, "address");
                if (address != .string or !std.mem.eql(u8, address.string, id)) continue;
                const at = try field(client, "at");
                const size = try field(client, "size");
                if (at != .array or size != .array or at.array.items.len != 2 or size.array.items.len != 2) return error.InvalidGeometry;
                current = .{ .x = try number(at.array.items[0]), .y = try number(at.array.items[1]), .width = try number(size.array.items[0]), .height = try number(size.array.items[1]) };
            }
            const monitors = try backend.capture(a, "hyprctl", &.{ "-j", "monitors" });
            defer a.free(monitors);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, monitors, .{});
            defer parsed.deinit();
            if (parsed.value != .array) return error.InvalidResponse;
            for (parsed.value.array.items) |monitor| {
                var area = try rectangle(monitor);
                const scale_value = try field(monitor, "scale");
                const scale: f64 = switch (scale_value) {
                    .float => |v| v,
                    .integer => |v| @floatFromInt(v),
                    else => return error.InvalidGeometry,
                };
                if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidGeometry;
                if (monitor.object.get("transform")) |transform| {
                    if (@mod(try number(transform), 2) == 1) std.mem.swap(i32, &area.width, &area.height);
                }
                const width = @as(f64, @floatFromInt(area.width)) / scale;
                const height = @as(f64, @floatFromInt(area.height)) / scale;
                if (width < 1 or height < 1 or width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.InvalidGeometry;
                area.width = @intFromFloat(width);
                area.height = @intFromFloat(height);
                try area.validate();
                if (monitor.object.get("reserved")) |reserved| {
                    if (reserved == .array and reserved.array.items.len == 4) {
                        const left = try number(reserved.array.items[0]);
                        const top = try number(reserved.array.items[1]);
                        const right = try number(reserved.array.items[2]);
                        const bottom = try number(reserved.array.items[3]);
                        if (left < 0 or top < 0 or right < 0 or bottom < 0 or @as(i64, left) + right >= area.width or @as(i64, top) + bottom >= area.height) return error.InvalidGeometry;
                        area.x += left;
                        area.y += top;
                        area.width -= left + right;
                        area.height -= top + bottom;
                    }
                }
                try areas.append(a, area);
            }
        },
        .sway => {
            const tree = try backend.capture(a, "swaymsg", &.{ "-t", "get_tree", "-r" });
            defer a.free(tree);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, tree, .{});
            defer parsed.deinit();
            current = swayWindow(parsed.value, try std.fmt.parseInt(i64, id, 10));
            const outputs = try field(parsed.value, "nodes");
            if (outputs != .array) return error.InvalidResponse;
            for (outputs.array.items) |output| {
                const name = try field(output, "name");
                if (name == .string and std.mem.eql(u8, name.string, "__i3")) continue;
                var area = try rectangle(try field(output, "rect"));
                const spaces = try field(output, "nodes");
                if (spaces == .array and spaces.array.items.len > 0) area = rectangle(try field(spaces.array.items[0], "rect")) catch area;
                if (area.width > 0 and area.height > 0) try areas.append(a, area);
            }
        },
        .x11 => {
            const windows = try backend.capture(a, "wmctrl", &.{"-lG"});
            defer a.free(windows);
            var lines = std.mem.splitScalar(u8, windows, '\n');
            while (lines.next()) |line| {
                var parts = std.mem.tokenizeAny(u8, line, " \t");
                if (!std.mem.eql(u8, parts.next() orelse continue, id)) continue;
                _ = parts.next() orelse return error.InvalidResponse;
                var values: [4]i32 = undefined;
                for (&values) |*v| v.* = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidResponse, 10);
                current = .{ .x = values[0], .y = values[1], .width = values[2], .height = values[3] };
            }
            const monitors = try backend.capture(a, "xrandr", &.{"--listactivemonitors"});
            defer a.free(monitors);
            var monitor_lines = std.mem.splitScalar(u8, monitors, '\n');
            _ = monitor_lines.next();
            while (monitor_lines.next()) |line| {
                var parts = std.mem.tokenizeAny(u8, line, " \t\r");
                _ = parts.next() orelse continue;
                _ = parts.next() orelse continue;
                try areas.append(a, try parseXrandrGeometry(parts.next() orelse continue));
            }
            const desktops = try backend.capture(a, "wmctrl", &.{"-d"});
            defer a.free(desktops);
            var desktop_lines = std.mem.splitScalar(u8, desktops, '\n');
            while (desktop_lines.next()) |line| {
                var parts = std.mem.tokenizeAny(u8, line, " \t");
                _ = parts.next() orelse continue;
                if (!std.mem.eql(u8, parts.next() orelse continue, "*")) continue;
                while (parts.next()) |part| if (std.mem.eql(u8, part, "WA:")) {
                    const xy = parts.next() orelse break;
                    const wh = parts.next() orelse break;
                    var pos = std.mem.splitScalar(u8, xy, ',');
                    var size = std.mem.splitScalar(u8, wh, 'x');
                    const work = Rect{ .x = try std.fmt.parseInt(i32, pos.next() orelse break, 10), .y = try std.fmt.parseInt(i32, pos.next() orelse break, 10), .width = try std.fmt.parseInt(i32, size.next() orelse break, 10), .height = try std.fmt.parseInt(i32, size.next() orelse break, 10) };
                    for (areas.items) |*area| {
                        try area.validate();
                        try work.validate();
                        const right = @min(area.x + area.width, work.x + work.width);
                        const bottom = @min(area.y + area.height, work.y + work.height);
                        area.x = @max(area.x, work.x);
                        area.y = @max(area.y, work.y);
                        area.width = right - area.x;
                        area.height = bottom - area.y;
                    }
                    break;
                };
            }
        },
        else => return error.UnsupportedPlatform,
    }
    const target = try layout.destination(current orelse return error.WindowNotFound, areas.items, action);
    switch (kind) {
        .x11 => {
            try command(a, kind, "wmctrl", &.{ "-ir", id, "-b", "remove,maximized_vert,maximized_horz" });
            try command(a, kind, "wmctrl", &.{ "-ir", id, "-e", try std.fmt.bufPrint(&buffer, "0,{d},{d},{d},{d}", .{ target.x, target.y, target.width, target.height }) });
        },
        .hyprland => {
            const selector = try std.fmt.allocPrint(a, "address:{s}", .{id});
            defer a.free(selector);
            try command(a, kind, "hyprctl", &.{ "dispatch", "setfloating", selector });
            try command(a, kind, "hyprctl", &.{ "dispatch", "resizewindowpixel", try std.fmt.bufPrint(&buffer, "exact {d} {d},{s}", .{ target.width, target.height, selector }) });
            try command(a, kind, "hyprctl", &.{ "dispatch", "movewindowpixel", try std.fmt.bufPrint(&buffer, "exact {d} {d},{s}", .{ target.x, target.y, selector }) });
        },
        .sway => try command(a, kind, "swaymsg", &.{ "-r", try std.fmt.bufPrint(&buffer, "[con_id={s}] fullscreen disable, floating enable, resize set {d} px {d} px, move absolute position {d} px {d} px", .{ id, target.width, target.height, target.x, target.y }) }),
        else => unreachable,
    }
}
test "Xrandr geometry includes physical dimensions and signed offsets" {
    const rect = try parseXrandrGeometry("1920/509x1080/286-1920+24");
    try std.testing.expectEqualDeep(Rect{ .x = -1920, .y = 24, .width = 1920, .height = 1080 }, rect);
}
