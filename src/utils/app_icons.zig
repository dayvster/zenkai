const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const fsutils = @import("fsutils.zig");

extern "shlwapi" fn AssocQueryStringW(flags: u32, kind: u32, association: [*:0]const u16, extra: ?[*:0]const u16, output: [*]u16, length: *u32) callconv(.winapi) i32;

/// The caller owns the returned icon descriptor, just like a theme name.
pub fn browser(allocator: std.mem.Allocator, scheme: []const u8) ![]u8 {
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return error.InvalidScheme;
    if (comptime builtin.os.tag == .windows) {
        const association = try std.unicode.utf8ToUtf16LeAllocZ(allocator, scheme);
        defer allocator.free(association);
        var buffer: [32768]u16 = undefined;
        var length: u32 = buffer.len;
        // ASSOCF_IS_PROTOCOL, ASSOCSTR_EXECUTABLE.
        if (AssocQueryStringW(0x1000, 2, association, null, &buffer, &length) != 0 or length <= 1 or length > buffer.len) return error.NoAssociation;
        const path = try std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0 .. length - 1]);
        defer allocator.free(path);
        return std.fmt.allocPrint(allocator, "native-file:{s}", .{path});
    } else if (comptime builtin.os.tag == .macos) {
        const path = try utils.macos.browserPath(allocator, scheme);
        defer allocator.free(path);
        if (path.len == 0) return error.NoAssociation;
        return std.fmt.allocPrint(allocator, "native-file:{s}", .{path});
    } else if (comptime builtin.os.tag == .linux) {
        const mime = try std.fmt.allocPrint(allocator, "x-scheme-handler/{s}", .{scheme});
        defer allocator.free(mime);
        const desktop = try capture(allocator, "xdg-mime", &.{ "query", "default", mime });
        defer allocator.free(desktop);
        if (desktop.len == 0) return error.NoAssociation;
        return desktopIcon(allocator, desktop);
    } else return error.UnsupportedPlatform;
}

fn capture(allocator: std.mem.Allocator, tool: []const u8, args: []const []const u8) ![]u8 {
    var buffer: [32768]u8 = undefined;
    const result = try utils.runToolTimed(tool, args, &buffer, 1500, allocator);
    if (result.exit_code != 0 or result.truncated) return error.NoAssociation;
    return allocator.dupe(u8, std.mem.trim(u8, buffer[0..result.bytes], " \r\n\t"));
}

fn env(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    const text = std.mem.sliceTo(value, 0);
    return if (text.len == 0) null else text;
}

/// Match Wayland app IDs, X11 instance.Class, or a default handler's desktop ID.
pub fn desktopIcon(allocator: std.mem.Allocator, app: []const u8) ![]u8 {
    if (env("XDG_DATA_HOME")) |home| {
        if (try iconInRoot(allocator, home, app)) |icon| return icon;
    } else if (env("HOME")) |home| {
        const root = try std.fs.path.join(allocator, &.{ home, ".local/share" });
        defer allocator.free(root);
        if (try iconInRoot(allocator, root, app)) |icon| return icon;
    }
    var roots = std.mem.splitScalar(u8, env("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share", ':');
    while (roots.next()) |root| {
        if (root.len > 0) if (try iconInRoot(allocator, root, app)) |icon| return icon;
    }
    return std.ascii.allocLowerString(allocator, app);
}

fn iconInRoot(allocator: std.mem.Allocator, root: []const u8, app: []const u8) !?[]u8 {
    const directory = try std.fs.path.join(allocator, &.{ root, "applications" });
    defer allocator.free(directory);
    var files = try fsutils.readDir(allocator, directory, .{ .extensions = &.{".desktop"}, .recursive = true });
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }
    // Desktop IDs take priority over display names and StartupWMClass matches.
    for ([_]bool{ true, false }) |exact| {
        for (files.items) |file| {
            const relative = file[directory.len + 1 ..];
            const desktop_id = try allocator.dupe(u8, relative);
            defer allocator.free(desktop_id);
            std.mem.replaceScalar(u8, desktop_id, '/', '-');
            const id_matches = matches(app, desktop_id) or matches(app, std.fs.path.stem(desktop_id));
            if (exact and !id_matches) continue;
            const content = fsutils.readFile(allocator, file, 256 * 1024) catch continue;
            defer allocator.free(content);
            if (desktopEntryIcon(content, app, id_matches)) |icon| return try allocator.dupe(u8, icon);
        }
    }
    return null;
}

fn matches(app: []const u8, candidate: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(app, candidate)) return true;
    // wmctrl prints instance.Class, whereas native Wayland IDs can contain dots.
    if (std.mem.indexOfScalar(u8, app, '.')) |dot| {
        return std.ascii.eqlIgnoreCase(app[0..dot], candidate) or std.ascii.eqlIgnoreCase(app[dot + 1 ..], candidate);
    }
    return false;
}

fn desktopEntryIcon(content: []const u8, app: []const u8, id_matches: bool) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_entry = false;
    var matched = id_matches;
    var icon: ?[]const u8 = null;
    var hidden = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Icon") and value.len > 0) icon = value;
        if (std.mem.eql(u8, key, "Hidden")) hidden = std.mem.eql(u8, value, "true");
        if (std.mem.eql(u8, key, "StartupWMClass") or std.mem.eql(u8, key, "Name")) matched = matched or matches(app, value);
    }
    return if (matched and !hidden) icon else null;
}

test "desktop icons use the main entry and match window classes" {
    const entry = "[Desktop Entry]\nName=Browser\nStartupWMClass=Brave-browser\nIcon=brave-browser\n[Desktop Action Private]\nIcon=wrong\n";
    try std.testing.expectEqualStrings("brave-browser", desktopEntryIcon(entry, "brave.Brave-browser", false).?);
    try std.testing.expect(desktopEntryIcon(entry, "Editor", false) == null);
    try std.testing.expect(desktopEntryIcon("[Desktop Entry]\nHidden=true\nIcon=hidden", "hidden", true) == null);
    try std.testing.expectEqualStrings("/opt/browser/icon.png", desktopEntryIcon("[Desktop Entry]\nIcon=/opt/browser/icon.png", "browser.desktop", true).?);
}

test "browser icon lookup validates schemes on every platform" {
    try std.testing.expectError(error.InvalidScheme, browser(std.testing.allocator, "file"));
    if (builtin.os.tag == .windows) {
        const icon = browser(std.testing.allocator, "https") catch |err| switch (err) {
            error.NoAssociation => return,
            else => return err,
        };
        defer std.testing.allocator.free(icon);
        try std.testing.expect(std.mem.startsWith(u8, icon, "native-file:"));
    }
}
