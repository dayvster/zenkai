const std = @import("std");
const fsutils = @import("utils").fsutils;
const log = @import("utils").log;

const default_config = @embedFile("config.toml");

fn configDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
        const dir = std.mem.sliceTo(xdg, 0);
        return try std.fs.path.join(allocator, &.{ dir, "zenkai" });
    }
    const home = std.c.getenv("HOME") orelse "/home";
    return try std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), ".config", "zenkai" });
}

pub fn detectIconTheme(allocator: std.mem.Allocator) ?[]const u8 {
    if (readFromKdeglobals(allocator)) |theme| return theme;
    if (readFromGtkSettings(allocator, "gtk-3.0")) |theme| return theme;
    if (readFromGtkSettings(allocator, "gtk-4.0")) |theme| return theme;
    return null;
}

fn kdeglobalsPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.c.getenv("HOME") orelse return error.MissingHome;
    return try std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), ".config", "kdeglobals" });
}

fn readFromKdeglobals(allocator: std.mem.Allocator) ?[]const u8 {
    const path = kdeglobalsPath(allocator) catch return null;
    defer allocator.free(path);

    const content = fsutils.readFile(allocator, path, 128 * 1024) catch return null;
    defer allocator.free(content);

    var in_icons_section = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '[') {
            in_icons_section = std.mem.eql(u8, trimmed, "[Icons]");
            continue;
        }
        if (in_icons_section) {
            if (std.mem.startsWith(u8, trimmed, "Theme=")) {
                const value = std.mem.trim(u8, trimmed["Theme=".len..], " \t");
                if (value.len > 0) return allocator.dupe(u8, value) catch null;
            }
        }
    }
    return null;
}

fn gtkSettingsPath(allocator: std.mem.Allocator, ver: []const u8) ![]u8 {
    const home = std.c.getenv("HOME") orelse return error.MissingHome;
    return try std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), ".config", ver, "settings.ini" });
}

fn readFromGtkSettings(allocator: std.mem.Allocator, ver: []const u8) ?[]const u8 {
    const path = gtkSettingsPath(allocator, ver) catch return null;
    defer allocator.free(path);

    const content = fsutils.readFile(allocator, path, 128 * 1024) catch return null;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "gtk-icon-theme-name=")) {
            const value = std.mem.trim(u8, trimmed["gtk-icon-theme-name=".len..], " \t\"");
            if (value.len > 0) return allocator.dupe(u8, value) catch null;
        }
    }
    return null;
}

pub fn deploy(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);

    if (!fsutils.dirExists(io, dir_path)) {
        try fsutils.makeDir(io, dir_path);
    }

    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "config.toml" });

    const cwd = std.Io.Dir.cwd();
    if (std.Io.Dir.openFile(cwd, io, config_path, .{})) |file| {
        file.close(io);
        return config_path;
    } else |_| {
        var file = try std.Io.Dir.createFile(cwd, io, config_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, default_config);
        return config_path;
    }
}
