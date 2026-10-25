const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const utils = @import("utils");

pub const Family = enum { chromium, edge, firefox };
pub const Action = enum { new_window, private_window };

fn basename(path: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| i + 1 else 0;
    const name = path[start..];
    return if (std.ascii.endsWithIgnoreCase(name, ".exe")) name[0 .. name.len - 4] else name;
}

fn family(name: []const u8) ?Family {
    const entry = basename(name);
    inline for (.{ "chrome", "google-chrome", "google-chrome-stable", "google-chrome-beta", "google-chrome-unstable", "Google Chrome", "Google Chrome Beta", "Google Chrome Canary", "chromium", "chromium-browser", "brave", "brave-browser", "brave-browser-beta", "brave-browser-nightly", "Brave Browser", "Brave Browser Beta", "Brave Browser Nightly", "vivaldi", "vivaldi-stable", "Vivaldi", "com.brave.Browser", "com.google.Chrome", "org.chromium.Chromium", "com.vivaldi.Vivaldi" }) |known| {
        if (std.ascii.eqlIgnoreCase(entry, known)) return .chromium;
    }
    inline for (.{ "msedge", "microsoft-edge", "microsoft-edge-stable", "microsoft-edge-beta", "microsoft-edge-dev", "Microsoft Edge", "Microsoft Edge Beta", "Microsoft Edge Dev", "Microsoft Edge Canary", "com.microsoft.Edge" }) |known| {
        if (std.ascii.eqlIgnoreCase(entry, known)) return .edge;
    }
    inline for (.{ "firefox", "firefox-esr", "librewolf", "org.mozilla.firefox", "io.gitlab.librewolf-community" }) |known| {
        if (std.ascii.eqlIgnoreCase(entry, known)) return .firefox;
    }
    return null;
}

fn identify(argv: []const []const u8) ?Family {
    if (argv.len == 0) return null;
    // Do not add browser-window actions to installed web apps or kiosk entries.
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) return null;
        if (std.mem.startsWith(u8, arg, "--app") or std.mem.eql(u8, arg, "--kiosk")) return null;
    }
    if (family(argv[0])) |value| return value;
    const launcher = basename(argv[0]);
    if ((std.mem.eql(u8, launcher, "flatpak") or std.mem.eql(u8, launcher, "snap")) and argv.len >= 3 and std.mem.eql(u8, argv[1], "run")) {
        // Options precede the exact application ID; never infer from a URL/title.
        for (argv[2..]) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;
            return family(arg);
        }
    }
    return null;
}

pub const Browser = struct {
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    kind: Family,

    pub fn deinit(self: *Browser) void {
        self.arena.deinit();
    }

    pub fn privateLabel(self: Browser) []const u8 {
        return if (self.kind == .edge) "New InPrivate Window" else "New Private Window";
    }

    pub fn arguments(self: *Browser, action: Action) ![]const []const u8 {
        const a = self.arena.allocator();
        var result: std.ArrayList([]const u8) = .empty;
        // Retain profile and packaging arguments, replace only window-mode flags.
        for (self.argv) |arg| {
            if (std.mem.eql(u8, arg, "--incognito") or std.mem.eql(u8, arg, "--inprivate") or std.mem.eql(u8, arg, "-inprivate") or std.mem.eql(u8, arg, "--private-window") or std.mem.eql(u8, arg, "-private-window") or std.mem.eql(u8, arg, "--new-window") or std.mem.eql(u8, arg, "-new-window")) continue;
            try result.append(a, arg);
        }
        if (action == .new_window) {
            try result.append(a, "--new-window");
            if (self.kind == .firefox) try result.append(a, "about:blank");
        } else {
            try result.append(a, switch (self.kind) {
                .chromium => "--incognito",
                .edge => "--inprivate",
                .firefox => "--private-window",
            });
        }
        return result.toOwnedSlice(a);
    }

    pub fn launch(self: *Browser, action: Action) !void {
        const args = try self.arguments(action);
        if (comptime builtin.os.tag == .macos) {
            // Invoke the browser's bundle executable so its running instance
            // receives the flags too; `open --args` can silently ignore them.
            return utils.spawnTool(args[0], args[1..], self.arena.allocator());
        }
        return utils.executeArgv(self.arena.allocator(), args);
    }
};

/// Called only when opening Actions on an application, never during discovery.
pub fn detect(allocator: std.mem.Allocator, command: []const u8) !?Browser {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var retained = false;
    defer if (!retained) arena.deinit();
    const a = arena.allocator();
    const argv = if (builtin.os.tag == .macos and command.len > 0 and command[0] != '"' and std.mem.indexOf(u8, command, ".app/Contents/MacOS/") != null) blk: {
        const values = try a.alloc([]const u8, 1);
        values[0] = try a.dupe(u8, command);
        break :blk values;
    } else try utils.tokenizeCommandLine(a, command);
    if (argv.len == 0) return null;
    if (comptime builtin.os.tag == .windows) {
        if (std.ascii.endsWithIgnoreCase(argv[0], ".lnk")) {
            // A web-app shortcut can also target chrome.exe. Only recognize
            // ordinary browser shortcuts when their hidden arguments are unknown.
            if (family(argv[0][0 .. argv[0].len - 4]) == null) return null;
            const file = qt.QFileInfo.new2(argv[0]);
            defer file.delete();
            const target = file.symLinkTarget(a);
            if (target.len == 0) return null;
            // Use the actual executable, not a shell shortcut with unknown flags.
            @constCast(argv)[0] = target;
        }
    }
    const kind = identify(argv) orelse return null;
    retained = true;
    return .{ .arena = arena, .argv = argv, .kind = kind };
}

test "installed Brave shortcut resolves to its browser executable" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const root = std.c.getenv("PROGRAMDATA") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const command = try std.fmt.allocPrint(a, "\"{s}\\Microsoft\\Windows\\Start Menu\\Programs\\Brave.lnk\"", .{std.mem.span(root)});
    defer a.free(command);
    var browser = (try detect(a, command)) orelse return error.SkipZigTest;
    defer browser.deinit();
    try std.testing.expectEqual(Family.chromium, browser.kind);
    try std.testing.expectEqualStrings("brave", basename(browser.argv[0]));
    const args = try browser.arguments(.private_window);
    try std.testing.expectEqualStrings("--incognito", args[args.len - 1]);
}

test "browser identification uses executable identities and package IDs" {
    try std.testing.expectEqual(Family.chromium, identify(&.{ "C:\\Program Files\\BraveSoftware\\brave.exe", "--profile-directory=Profile 1" }).?);
    try std.testing.expectEqual(Family.edge, identify(&.{"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"}).?);
    try std.testing.expectEqual(Family.firefox, identify(&.{ "flatpak", "run", "--branch=stable", "org.mozilla.firefox" }).?);
    try std.testing.expectEqual(Family.chromium, identify(&.{ "snap", "run", "chromium" }).?);
    try std.testing.expect(identify(&.{ "editor", "https://chrome.example" }) == null);
    try std.testing.expect(identify(&.{"not-brave.exe"}) == null);
    try std.testing.expect(identify(&.{ "chrome", "--app=https://example.com" }) == null);
    try std.testing.expect(identify(&.{"Safari"}) == null);
}

test "browser actions preserve profiles and use family-specific private flags" {
    var browser = (try detect(std.testing.allocator, "brave --profile-directory=Work --incognito")).?;
    defer browser.deinit();
    const argv = try browser.arguments(.new_window);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    for ([_][]const u8{ "brave", "--profile-directory=Work", "--new-window" }, argv) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    browser.kind = .edge;
    const private = try browser.arguments(.private_window);
    try std.testing.expectEqualStrings("--inprivate", private[private.len - 1]);
    browser.kind = .firefox;
    const window = try browser.arguments(.new_window);
    try std.testing.expectEqualStrings("--new-window", window[window.len - 2]);
    try std.testing.expectEqualStrings("about:blank", window[window.len - 1]);
}
