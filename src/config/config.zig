const std = @import("std");
const fsutils = @import("utils").fsutils;
const log = @import("utils").log;

const default_config = @embedFile("config.toml");

pub const VisualConfig = struct {
    window_width: i32 = 600,
    window_height: i32 = 500,
    layout_margin: i32 = 0,
    layout_spacing: i32 = 0,
    icon_size: i32 = 32,
    close_on_focus_out: bool = false,
    show_backdrop: bool = false,
    fullscreen: bool = false,
    monitor: ?i32 = null,
    theme: ?[]const u8 = null,
    clipboard: ?[]const u8 = null,
    url_handler: ?[]const u8 = null,
    no_animations: bool = false,
    animation_interval: i32 = 200,
    animation_easing: ?[]const u8 = null,

    pub fn deinit(self: *VisualConfig, allocator: std.mem.Allocator) void {
        if (self.theme) |v| allocator.free(v);
        if (self.clipboard) |v| allocator.free(v);
        if (self.url_handler) |v| allocator.free(v);
        if (self.animation_easing) |v| allocator.free(v);
    }

    pub fn applyOverrides(self: *VisualConfig, allocator: std.mem.Allocator, cfg: anytype) void {
        if (cfg.window_width) |v| self.window_width = v;
        if (cfg.window_height) |v| self.window_height = v;
        if (cfg.icon_size) |v| self.icon_size = v;
        if (cfg.close_on_focus_out) |v| self.close_on_focus_out = v;
        if (cfg.show_backdrop) self.show_backdrop = true;
        if (cfg.fullscreen) self.fullscreen = true;
        if (cfg.monitor) |v| self.monitor = v;
        if (cfg.theme) |v| {
            if (self.theme) |old| allocator.free(old);
            self.theme = allocator.dupe(u8, v) catch null;
        }
        if (cfg.clipboard) |v| {
            if (self.clipboard) |old| allocator.free(old);
            self.clipboard = if (v.len > 0) allocator.dupe(u8, v) catch null else null;
        }
        if (cfg.url_handler) |v| {
            if (self.url_handler) |old| allocator.free(old);
            self.url_handler = if (v.len > 0) allocator.dupe(u8, v) catch null else null;
        }
        if (cfg.no_animations) self.no_animations = true;
        if (cfg.animation_interval) |v| self.animation_interval = v;
        if (cfg.animation_easing) |v| {
            if (self.animation_easing) |old| allocator.free(old);
            self.animation_easing = allocator.dupe(u8, v) catch null;
        }
    }
};

pub fn configDir(allocator: std.mem.Allocator) ![]u8 {
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

fn parseInt(val: []const u8) !i32 {
    const trimmed = std.mem.trim(u8, val, " \t\r");
    return try std.fmt.parseInt(i32, trimmed, 10);
}

pub fn loadConfig(allocator: std.mem.Allocator, config_path: []const u8) !VisualConfig {
    const content = fsutils.readFile(allocator, config_path, 128 * 1024) catch |err| {
        log.info("no config found, using defaults ({})", .{err});
        return VisualConfig{};
    };
    defer allocator.free(content);

    var cfg = VisualConfig{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var eq_idx: ?usize = null;
        for (trimmed, 0..) |c, i| {
            if (c == '=') {
                eq_idx = i;
                break;
            }
        }
        const eq = eq_idx orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "window_width")) cfg.window_width = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "window_height")) cfg.window_height = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "layout_margin")) cfg.layout_margin = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "layout_spacing")) cfg.layout_spacing = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "icon_size")) cfg.icon_size = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "close_on_focus_out")) cfg.close_on_focus_out = std.mem.eql(u8, val, "true");
        if (std.mem.eql(u8, key, "show_backdrop")) cfg.show_backdrop = std.mem.eql(u8, val, "true");
        if (std.mem.eql(u8, key, "fullscreen")) cfg.fullscreen = std.mem.eql(u8, val, "true");
        if (std.mem.eql(u8, key, "monitor")) cfg.monitor = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "theme")) {
            if (val.len > 0) cfg.theme = allocator.dupe(u8, val) catch null;
        }
        if (std.mem.eql(u8, key, "clipboard")) {
            if (val.len > 0) cfg.clipboard = allocator.dupe(u8, val) catch null;
        }
        if (std.mem.eql(u8, key, "no_animations")) cfg.no_animations = std.mem.eql(u8, val, "true");
        if (std.mem.eql(u8, key, "animation_interval")) cfg.animation_interval = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "animation_easing")) {
            if (val.len > 0) cfg.animation_easing = allocator.dupe(u8, val) catch null;
        }
        if (std.mem.eql(u8, key, "url_handler")) {
            if (val.len > 0) cfg.url_handler = allocator.dupe(u8, val) catch null;
        }
    }

    return cfg;
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
