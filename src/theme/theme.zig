const std = @import("std");
const log = @import("utils").log;

pub const dark_qss = @embedFile("../styles/dark.theme.qss");
pub const light_qss = @embedFile("../styles/light.theme.qss");

const ThemeResult = struct {
    qss: []const u8,
    allocation: ?[]u8,
};

fn readThemeFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const resolved = if (path.len > 0 and path[0] == '~') blk: {
        const home = std.mem.sliceTo(std.c.getenv("HOME") orelse "/home", 0);
        if (path.len == 1) break :blk (allocator.dupe(u8, home) catch return null);
        break :blk (std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] }) catch return null);
    } else allocator.dupe(u8, path) catch return null;
    defer allocator.free(resolved);

    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const cwd = std.Io.Dir.cwd();
    const file = std.Io.Dir.openFile(cwd, io, resolved, .{}) catch return null;
    defer file.close(io);

    const stat = std.Io.Dir.statFile(cwd, io, resolved, .{}) catch return null;
    const size = @as(usize, @intCast(stat.size));
    if (size > 128 * 1024) return null;

    const buf = allocator.alloc(u8, size) catch return null;
    const n = file.readStreaming(io, &.{buf}) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..n];
}

pub fn resolve(allocator: std.mem.Allocator, theme_arg: ?[]const u8) ThemeResult {
    if (theme_arg) |name| {
        if (std.mem.eql(u8, name, "light")) {
            return .{ .qss = light_qss, .allocation = null };
        } else if (!std.mem.eql(u8, name, "dark")) {
            if (readThemeFile(allocator, name)) |content| {
                return .{ .qss = content, .allocation = content };
            } else {
                log.info("failed to load theme: {s}, using dark", .{name});
            }
        }
    }
    return .{ .qss = dark_qss, .allocation = null };
}
