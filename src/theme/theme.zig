const std = @import("std");
const log = @import("utils").log;

pub const dark_qss = @embedFile("../styles/dark.theme.qss");
pub const light_qss = @embedFile("../styles/light.theme.qss");
pub const dracula_qss = @embedFile("../styles/dracula.qss");
pub const ayu_dark_qss = @embedFile("../styles/ayu-dark.qss");

pub const Colors = struct {
    bg: []const u8,
    text: []const u8,
    muted: []const u8,
    border: []const u8,
    accent: []const u8,
    surface: []const u8,
};

pub var current: Colors = undefined;

pub const dark_colors = Colors{
    .bg = "#1a1b1e",
    .text = "#cdd6f4",
    .muted = "#6c7086",
    .border = "#45475a",
    .accent = "#89b4fa",
    .surface = "#313244",
};

pub const light_colors = Colors{
    .bg = "#eff1f5",
    .text = "#4c4f69",
    .muted = "#9ca0b0",
    .border = "#ccd0da",
    .accent = "#7287fd",
    .surface = "#e6e9ef",
};

pub const dracula_colors = Colors{
    .bg = "#282a36",
    .text = "#f8f8f2",
    .muted = "#6272a4",
    .border = "#6272a4",
    .accent = "#bd93f9",
    .surface = "#44475a",
};

pub const ayu_dark_colors = Colors{
    .bg = "#0d1017",
    .text = "#bfc7d5",
    .muted = "#565f73",
    .border = "#1f2430",
    .accent = "#39bae6",
    .surface = "#131721",
};

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
            current = light_colors;
            return .{ .qss = light_qss, .allocation = null };
        } else if (std.mem.eql(u8, name, "dracula")) {
            current = dracula_colors;
            return .{ .qss = dracula_qss, .allocation = null };
        } else if (std.mem.eql(u8, name, "ayu-dark")) {
            current = ayu_dark_colors;
            return .{ .qss = ayu_dark_qss, .allocation = null };
        } else if (!std.mem.eql(u8, name, "dark")) {
            if (readThemeFile(allocator, name)) |content| {
                current = dark_colors;
                return .{ .qss = content, .allocation = content };
            } else {
                log.info("failed to load theme: {s}, using dark", .{name});
            }
        }
    }
    current = dark_colors;
    return .{ .qss = dark_qss, .allocation = null };
}
