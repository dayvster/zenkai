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
    font_family: []const u8 = "Fira Sans, Noto Sans, DejaVu Sans, sans-serif",
    font_size: i32 = 13,
    search_font_size: i32 = 14,
    search_padding_top: i32 = 8,
    search_padding_bottom: i32 = 8,
    search_padding_left: i32 = 12,
    search_padding_right: i32 = 12,
    search_border_width: i32 = 1,
    search_border_radius: i32 = 6,
    list_font_size: i32 = 13,
    list_item_padding_top: i32 = 8,
    list_item_padding_bottom: i32 = 8,
    list_item_padding_left: i32 = 12,
    list_item_padding_right: i32 = 12,
    list_item_border_radius: i32 = 4,
    bottom_bar_margin_top: i32 = 4,
    bottom_bar_margin_bottom: i32 = 4,
    bottom_bar_margin_left: i32 = 8,
    bottom_bar_margin_right: i32 = 8,
    bottom_bar_spacing: i32 = 4,
    label_font_size: i32 = 11,
    button_font_size: i32 = 12,
    button_padding_top: i32 = 4,
    button_padding_bottom: i32 = 4,
    button_padding_left: i32 = 6,
    button_padding_right: i32 = 6,
    button_border_radius: i32 = 4,
    scrollbar_width: i32 = 6,
    scrollbar_border_radius: i32 = 3,
    scrollbar_handle_min_height: i32 = 30,

    pub fn applyOverrides(self: *VisualConfig, cfg: anytype) void {
        if (cfg.window_width) |v| self.window_width = v;
        if (cfg.window_height) |v| self.window_height = v;
        if (cfg.icon_size) |v| self.icon_size = v;
    }
};

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

fn parseString(val: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parseInt(val: []const u8) !i32 {
    const trimmed = std.mem.trim(u8, val, " \t\r");
    return try std.fmt.parseInt(i32, trimmed, 10);
}

const FieldHandler = struct {
    key: []const u8,
    handler: *const fn (cfg: *VisualConfig, allocator: std.mem.Allocator, val: []const u8) void,
};

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

        if (std.mem.eql(u8, key, "icon_size")) cfg.icon_size = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "theme")) continue;
        if (std.mem.eql(u8, key, "window_width")) cfg.window_width = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "window_height")) cfg.window_height = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "layout_margin")) cfg.layout_margin = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "layout_spacing")) cfg.layout_spacing = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "font_family")) {
            const raw = parseString(val);
            cfg.font_family = allocator.dupe(u8, raw) catch continue;
        }
        if (std.mem.eql(u8, key, "font_size")) cfg.font_size = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "search_font_size")) cfg.search_font_size = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "search_padding_top")) cfg.search_padding_top = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "search_padding_bottom")) cfg.search_padding_bottom = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "search_padding_left")) cfg.search_padding_left = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "search_padding_right")) cfg.search_padding_right = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "search_border_width")) cfg.search_border_width = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "search_border_radius")) cfg.search_border_radius = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "list_font_size")) cfg.list_font_size = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "list_item_padding_top")) cfg.list_item_padding_top = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "list_item_padding_bottom")) cfg.list_item_padding_bottom = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "list_item_padding_left")) cfg.list_item_padding_left = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "list_item_padding_right")) cfg.list_item_padding_right = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "list_item_border_radius")) cfg.list_item_border_radius = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "bottom_bar_margin_top")) cfg.bottom_bar_margin_top = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "bottom_bar_margin_bottom")) cfg.bottom_bar_margin_bottom = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "bottom_bar_margin_left")) cfg.bottom_bar_margin_left = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "bottom_bar_margin_right")) cfg.bottom_bar_margin_right = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "bottom_bar_spacing")) cfg.bottom_bar_spacing = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "label_font_size")) cfg.label_font_size = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "button_font_size")) cfg.button_font_size = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "button_padding_top")) cfg.button_padding_top = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "button_padding_bottom")) cfg.button_padding_bottom = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "button_padding_left")) cfg.button_padding_left = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "button_padding_right")) cfg.button_padding_right = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "button_border_radius")) cfg.button_border_radius = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "scrollbar_width")) cfg.scrollbar_width = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "scrollbar_border_radius")) cfg.scrollbar_border_radius = parseInt(val) catch continue;
        if (std.mem.eql(u8, key, "scrollbar_handle_min_height")) cfg.scrollbar_handle_min_height = parseInt(val) catch continue;
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
