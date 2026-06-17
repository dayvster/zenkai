const std = @import("std");
const args = @import("args");
const dapp_parser = @import("dapp_parser");
const desktopapp = @import("desktopapp");

fn smithBytes(smith: *std.testing.Smith, buf: []u8) []const u8 {
    const len = smith.sliceWithHash(buf, @truncate(@intFromPtr(buf.ptr)));
    return buf[0..@min(len, buf.len)];
}

test "args: no_dapps and no_plugins flags" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([:0]u8).empty;
    defer {
        for (argv.items) |a| allocator.free(a);
        argv.deinit(allocator);
    }

    try argv.append(allocator, try allocator.dupeZ(u8, "zenkai"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--no-dapps"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--no-plugins"));

    const cfg = args.parse(argv.items);
    try std.testing.expect(cfg.no_dapps);
    try std.testing.expect(cfg.no_plugins);
}

test "args: theme and size flags" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([:0]u8).empty;
    defer {
        for (argv.items) |a| allocator.free(a);
        argv.deinit(allocator);
    }

    try argv.append(allocator, try allocator.dupeZ(u8, "zenkai"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--theme=dracula"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--size=48"));

    const cfg = args.parse(argv.items);
    try std.testing.expectEqualStrings("dracula", cfg.theme.?);
    try std.testing.expectEqual(@as(i32, 48), cfg.icon_size.?);
}

test "args: fuzzed inputs don't crash" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            const allocator = std.testing.allocator;
            var buf: [4096]u8 = undefined;
            const bytes = smithBytes(smith, &buf);

            var fuzz_args = std.ArrayList([:0]u8).empty;
            defer {
                for (fuzz_args.items) |a| allocator.free(a);
                fuzz_args.deinit(allocator);
            }

            var i: usize = 0;
            while (i < bytes.len) {
                const end = i + 1 + @as(usize, @intCast(smith.valueWithHash(u8, @intCast(i))));
                const slice = bytes[i..@min(end, bytes.len)];
                const dup = try allocator.dupeZ(u8, slice);
                try fuzz_args.append(allocator, dup);
                i = end;
            }

            const cfg = args.parse(fuzz_args.items);
            _ = cfg;
        }
    }.testOne, .{});
}

test "args: parsePluginNames" {
    const allocator = std.testing.allocator;

    {
        var argv = std.ArrayList([:0]u8).empty;
        defer {
            for (argv.items) |a| allocator.free(a);
            argv.deinit(allocator);
        }
        try argv.append(allocator, try allocator.dupeZ(u8, "zenkai"));
        try argv.append(allocator, try allocator.dupeZ(u8, "--plugin=calculator"));
        const names = try args.parsePluginNames(allocator, argv.items);
        defer args.deinitPluginNames(allocator, names);
        try std.testing.expectEqual(@as(usize, 1), names.len);
        try std.testing.expectEqualStrings("calculator", names[0]);
    }

    {
        var argv = std.ArrayList([:0]u8).empty;
        defer {
            for (argv.items) |a| allocator.free(a);
            argv.deinit(allocator);
        }
        try argv.append(allocator, try allocator.dupeZ(u8, "zenkai"));
        try argv.append(allocator, try allocator.dupeZ(u8, "--plugin=a"));
        try argv.append(allocator, try allocator.dupeZ(u8, "--plugin=b"));
        const names = try args.parsePluginNames(allocator, argv.items);
        defer args.deinitPluginNames(allocator, names);
        try std.testing.expectEqual(@as(usize, 2), names.len);
        try std.testing.expectEqualStrings("a", names[0]);
        try std.testing.expectEqualStrings("b", names[1]);
    }

    {
        var argv = std.ArrayList([:0]u8).empty;
        defer {
            for (argv.items) |a| allocator.free(a);
            argv.deinit(allocator);
        }
        try argv.append(allocator, try allocator.dupeZ(u8, "zenkai"));
        const names = try args.parsePluginNames(allocator, argv.items);
        defer args.deinitPluginNames(allocator, names);
        try std.testing.expectEqual(@as(usize, 0), names.len);
    }
}

test "dapp_parser: valid desktop entry" {
    const allocator = std.testing.allocator;
    const content =
        \\[Desktop Entry]
        \\Name=Firefox
        \\Exec=firefox %u
        \\Icon=firefox
        \\Type=Application
        \\Categories=Network;WebBrowser;
        \\
    ;

    var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("Firefox", entry.name);
    try std.testing.expectEqualStrings("firefox %u", entry.exec.?);
    try std.testing.expectEqualStrings("firefox", entry.icon.?);
}

test "dapp_parser: NoDisplay entry" {
    const allocator = std.testing.allocator;
    const content =
        \\[Desktop Entry]
        \\Name=Hidden
        \\NoDisplay=true
        \\
    ;

    const result = dapp_parser.DappParser.parseDesktopFile(allocator, content);
    try std.testing.expectError(error.NoDisplay, result);
}

test "dapp_parser: Hidden entry" {
    const allocator = std.testing.allocator;
    const content =
        \\[Desktop Entry]
        \\Name=Hidden
        \\Hidden=true
        \\
    ;

    const result = dapp_parser.DappParser.parseDesktopFile(allocator, content);
    try std.testing.expectError(error.NoDisplay, result);
}

test "dapp_parser: malformed content" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "not a desktop file",
        "[Desktop Entry]",
        "[Desktop Entry]\nName=",
        "[Desktop Entry]\nNoDisplay=maybe",
        " \t\n\r",
        "[Desktop Entry]\nExec=foo\n\n\n[Desktop Entry]\nName=Second",
        "[Desktop Entry]\nType=Link\nName=Link\nURL=https://example.com",
        "[Desktop Entry]\nCategories=;;;",
    };

    for (cases) |content| {
        var entry = dapp_parser.DappParser.parseDesktopFile(allocator, content) catch continue;
        defer entry.deinit(allocator);
    }
}

test "dapp_parser: fuzzed inputs don't crash" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            const allocator = std.testing.allocator;
            var buf: [2048]u8 = undefined;
            const bytes = smithBytes(smith, &buf);
            const content = try allocator.dupe(u8, bytes);
            defer allocator.free(content);
            var entry = dapp_parser.DappParser.parseDesktopFile(allocator, content) catch return;
            defer entry.deinit(allocator);
        }
    }.testOne, .{});
}

test "dapp_parser: random short inputs" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0);
    const random = rng.random();

    for (0..100) |_| {
        var buf: [64]u8 = undefined;
        random.bytes(&buf);
        const content = try allocator.dupe(u8, buf[0..]);
        defer allocator.free(content);
        var entry = dapp_parser.DappParser.parseDesktopFile(allocator, content) catch continue;
        defer entry.deinit(allocator);
    }
}

test "expandExecString with url field code" {
    const allocator = std.testing.allocator;

    var entry = desktopapp.DesktopEntry{
        .name = "TestApp",
        .exec = "firefox %u",
        .icon = null,
        .file_path = null,
        .type = .Application,
        .extra = std.StringHashMap([]const u8).init(allocator),
    };

    const expanded = try desktopapp.DesktopEntry.expandExecString("firefox %u", &entry, allocator);
    defer {
        allocator.free(expanded);
        entry.deinit(allocator);
    }
    try std.testing.expectEqualStrings("firefox ", expanded);
}

test "expandExecString with icon field code" {
    const allocator = std.testing.allocator;

    var entry = desktopapp.DesktopEntry{
        .name = "TestApp",
        .exec = "app %i",
        .icon = "test-icon",
        .file_path = null,
        .type = .Application,
        .extra = std.StringHashMap([]const u8).init(allocator),
    };

    const expanded = try desktopapp.DesktopEntry.expandExecString("app %i", &entry, allocator);
    defer {
        allocator.free(expanded);
        entry.deinit(allocator);
    }
    try std.testing.expectEqualStrings("app --icon 'test-icon'", expanded);
}
