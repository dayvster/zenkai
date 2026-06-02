const std = @import("std");
const fsutils = @import("fsutils");

const default_config = @embedFile("config.toml");

fn configDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
        const dir = std.mem.sliceTo(xdg, 0);
        return try std.fs.path.join(allocator, &.{ dir, "zenkai" });
    }
    const home = std.c.getenv("HOME") orelse "/home";
    return try std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), ".config", "zenkai" });
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
