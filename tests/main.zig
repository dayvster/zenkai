const std = @import("std");
const args = @import("args");
const dapp_parser = @import("dapp_parser");
const desktopapp = @import("desktopapp");
const config = @import("config");
const utils = @import("utils");

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
    try std.testing.expectEqualStrings("app --icon \"test-icon\"", expanded);
}

test "config: parseTomlString strips quotes" {
    const allocator = std.testing.allocator;

    {
        const v = config.parseTomlString(allocator, "\"dracula\"");
        defer allocator.free(v.?);
        try std.testing.expectEqualStrings("dracula", v.?);
    }

    {
        const v = config.parseTomlString(allocator, "'wl-clipboard'");
        defer allocator.free(v.?);
        try std.testing.expectEqualStrings("wl-clipboard", v.?);
    }

    {
        const v = config.parseTomlString(allocator, "xdg-open");
        defer allocator.free(v.?);
        try std.testing.expectEqualStrings("xdg-open", v.?);
    }

    {
        const v = config.parseTomlString(allocator, "\"\"");
        try std.testing.expect(v == null);
    }

    {
        const v = config.parseTomlString(allocator, "");
        try std.testing.expect(v == null);
    }
}

test "args: negative numeric flags are rejected" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([:0]u8).empty;
    defer {
        for (argv.items) |a| allocator.free(a);
        argv.deinit(allocator);
    }

    try argv.append(allocator, try allocator.dupeZ(u8, "zenkai"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--size=-5"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--width=-100"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--height=-1"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--monitor=-2"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--animation-interval=-3"));

    const cfg = args.parse(argv.items);
    try std.testing.expect(cfg.icon_size == null);
    try std.testing.expect(cfg.window_width == null);
    try std.testing.expect(cfg.window_height == null);
    try std.testing.expect(cfg.monitor == null);
    try std.testing.expect(cfg.animation_interval == null);
}

test "args: non-numeric numeric flags are rejected" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([:0]u8).empty;
    defer {
        for (argv.items) |a| allocator.free(a);
        argv.deinit(allocator);
    }

    try argv.append(allocator, try allocator.dupeZ(u8, "zenkai"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--size=abc"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--monitor="));
    try argv.append(allocator, try allocator.dupeZ(u8, "--width=12.5"));

    const cfg = args.parse(argv.items);
    try std.testing.expect(cfg.icon_size == null);
    try std.testing.expect(cfg.monitor == null);
    try std.testing.expect(cfg.window_width == null);
}

test "dapp_parser: positive numeric flags still parse" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([:0]u8).empty;
    defer {
        for (argv.items) |a| allocator.free(a);
        argv.deinit(allocator);
    }

    try argv.append(allocator, try allocator.dupeZ(u8, "zenkai"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--size=0"));
    try argv.append(allocator, try allocator.dupeZ(u8, "--monitor=3"));

    const cfg = args.parse(argv.items);
    try std.testing.expectEqual(@as(i32, 0), cfg.icon_size.?);
    try std.testing.expectEqual(@as(i32, 3), cfg.monitor.?);
}

test "dapp_parser: parses Type" {
    const allocator = std.testing.allocator;

    {
        const content =
            \\[Desktop Entry]
            \\Name=Link
            \\Type=Link
            \\URL=https://example.com
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expectEqual(desktopapp.DesktopEntry.Type.Link, entry.type);
    }

    {
        const content =
            \\[Desktop Entry]
            \\Name=Dir
            \\Type=Directory
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expectEqual(desktopapp.DesktopEntry.Type.Directory, entry.type);
    }

    {
        const content =
            \\[Desktop Entry]
            \\Name=App
            \\Type=Application
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expectEqual(desktopapp.DesktopEntry.Type.Application, entry.type);
    }

    {
        const content =
            \\[Desktop Entry]
            \\Name=Default
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expectEqual(desktopapp.DesktopEntry.Type.Application, entry.type);
    }
}

test "dapp_parser: localized Name selection" {
    const allocator = std.testing.allocator;
    defer dapp_parser.setLocale(null);

    const content =
        \\[Desktop Entry]
        \\Name=Firefox
        \\Name[de]=Feuerfuchs
        \\Name[de_DE]=Feuerfuchs Spezial
        \\Name[fr]=Phénix
        \\
    ;

    {
        dapp_parser.setLocale("de_DE");
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expectEqualStrings("Feuerfuchs Spezial", entry.name);
    }

    {
        dapp_parser.setLocale("de");
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expectEqualStrings("Feuerfuchs", entry.name);
    }

    {
        dapp_parser.setLocale("fr");
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expectEqualStrings("Phénix", entry.name);
    }

    {
        dapp_parser.setLocale("it");
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expectEqualStrings("Firefox", entry.name);
    }

    {
        dapp_parser.setLocale(null);
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expectEqualStrings("Firefox", entry.name);
    }
}

test "dapp_parser: OnlyShowIn and NotShowIn filtering" {
    const allocator = std.testing.allocator;

    {
        const content =
            \\[Desktop Entry]
            \\Name=GNOMEApp
            \\OnlyShowIn=GNOME;
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);

        const gnome = [_][]const u8{"GNOME"};
        try std.testing.expect(dapp_parser.shouldShowApp(&entry, &gnome));

        const kde = [_][]const u8{"KDE"};
        try std.testing.expect(!dapp_parser.shouldShowApp(&entry, &kde));

        const empty = [_][]const u8{};
        try std.testing.expect(!dapp_parser.shouldShowApp(&entry, &empty));
    }

    {
        const content =
            \\[Desktop Entry]
            \\Name=KDEOnly
            \\NotShowIn=GNOME;
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);

        const gnome = [_][]const u8{"GNOME"};
        try std.testing.expect(!dapp_parser.shouldShowApp(&entry, &gnome));

        const kde = [_][]const u8{"X-KDE"};
        try std.testing.expect(dapp_parser.shouldShowApp(&entry, &kde));
    }

    {
        const content =
            \\[Desktop Entry]
            \\Name=NoFilter
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);

        const any = [_][]const u8{"Whatever"};
        try std.testing.expect(dapp_parser.shouldShowApp(&entry, &any));
        const empty = [_][]const u8{};
        try std.testing.expect(dapp_parser.shouldShowApp(&entry, &empty));
    }
}

test "desktopapp: expandExecString quotes field code values for Exec grammar" {
    const allocator = std.testing.allocator;

    var entry = desktopapp.DesktopEntry{
        .name = "Foo Bar",
        .exec = null,
        .icon = "gimp",
        .file_path = "/path/to/hi.desktop",
        .type = .Application,
        .extra = std.StringHashMap([]const u8).init(allocator),
    };
    defer entry.deinit(allocator);

    const exec = "env FOO=bar %i -- %k %c %%";
    const expanded = try desktopapp.DesktopEntry.expandExecString(exec, &entry, allocator);
    defer allocator.free(expanded);

    try std.testing.expectEqualStrings("env FOO=bar --icon \"gimp\" -- \"/path/to/hi.desktop\" \"Foo Bar\" %", expanded);

    const argv = try utils.tokenizeCommandLine(allocator, expanded);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("env", argv[0]);
    try std.testing.expectEqualStrings("FOO=bar", argv[1]);
    try std.testing.expectEqualStrings("--icon", argv[2]);
    try std.testing.expectEqualStrings("gimp", argv[3]);
    try std.testing.expectEqualStrings("--", argv[4]);
    try std.testing.expectEqualStrings("/path/to/hi.desktop", argv[5]);
    try std.testing.expectEqualStrings("Foo Bar", argv[6]);
}

test "desktopapp: expandExecString drops file and deprecated field codes" {
    const allocator = std.testing.allocator;

    var entry = desktopapp.DesktopEntry{
        .name = "AppC",
        .exec = null,
        .icon = null,
        .file_path = null,
        .type = .Application,
        .extra = std.StringHashMap([]const u8).init(allocator),
    };
    defer entry.deinit(allocator);

    const expanded = try desktopapp.DesktopEntry.expandExecString("myapp %f %F %u %U %d %D %n %N %v %m -q", &entry, allocator);
    defer allocator.free(expanded);

    const argv = try utils.tokenizeCommandLine(allocator, expanded);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("myapp", argv[0]);
    try std.testing.expectEqualStrings("-q", argv[1]);
}

test "desktopapp: expandExecString keeps literal percent codes" {
    const allocator = std.testing.allocator;

    var entry = desktopapp.DesktopEntry{
        .name = "AppC",
        .exec = null,
        .icon = null,
        .file_path = null,
        .type = .Application,
        .extra = std.StringHashMap([]const u8).init(allocator),
    };
    defer entry.deinit(allocator);

    const expanded = try desktopapp.DesktopEntry.expandExecString("show %%literal and a%qb", &entry, allocator);
    defer allocator.free(expanded);

    const argv = try utils.tokenizeCommandLine(allocator, expanded);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("show", argv[0]);
    try std.testing.expectEqualStrings("%literal", argv[1]);
    try std.testing.expectEqualStrings("a%qb", argv[2]);
}

test "desktopapp: expandExecString then tokenizeCommandLine round-trips quoted values" {
    const allocator = std.testing.allocator;

    var entry = desktopapp.DesktopEntry{
        .name = "Quote\" $ `\\ App",
        .exec = null,
        .icon = null,
        .file_path = "/tmp/we ird//path.desktop",
        .type = .Application,
        .extra = std.StringHashMap([]const u8).init(allocator),
    };
    defer entry.deinit(allocator);

    const expanded = try desktopapp.DesktopEntry.expandExecString("launch %k %c", &entry, allocator);
    defer allocator.free(expanded);

    const argv = try utils.tokenizeCommandLine(allocator, expanded);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("launch", argv[0]);
    try std.testing.expectEqualStrings("/tmp/we ird//path.desktop", argv[1]);
    try std.testing.expectEqualStrings("Quote\" $ `\\ App", argv[2]);
}

test "dapp_parser: shouldListApp filters non-application entry types" {
    const allocator = std.testing.allocator;
    const any = [_][]const u8{"Whatever"};

    {
        const content =
            \\[Desktop Entry]
            \\Name=Link
            \\Type=Link
            \\URL=https://example.com
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expect(!dapp_parser.shouldListApp(&entry, &any));
    }

    {
        const content =
            \\[Desktop Entry]
            \\Name=Dir
            \\Type=Directory
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expect(!dapp_parser.shouldListApp(&entry, &any));
    }

    {
        const content =
            \\[Desktop Entry]
            \\Name=App
            \\Type=Application
            \\
        ;
        var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
        defer entry.deinit(allocator);
        try std.testing.expect(dapp_parser.shouldListApp(&entry, &any));

        const kde = [_][]const u8{"KDE"};
        try std.testing.expect(dapp_parser.shouldListApp(&entry, &kde));
    }
}

test "dapp_parser: shouldListApp keeps OnlyShowIn filtering" {
    const allocator = std.testing.allocator;

    const content =
        \\[Desktop Entry]
        \\Name=GNOMEApp
        \\OnlyShowIn=GNOME;
        \\
    ;
    var entry = try dapp_parser.DappParser.parseDesktopFile(allocator, content);
    defer entry.deinit(allocator);

    const gnome = [_][]const u8{"GNOME"};
    try std.testing.expect(dapp_parser.shouldListApp(&entry, &gnome));

    const kde = [_][]const u8{"KDE"};
    try std.testing.expect(!dapp_parser.shouldListApp(&entry, &kde));
}

test "utils: tokenizeCommandLine handles Exec grammar escapes in double quotes" {
    const allocator = std.testing.allocator;

    const input = "foo --bar=\"hello world\" \"a\\\"b\" \"$HOME\" \"\\`t\\`\" plain";
    const tokens = try utils.tokenizeCommandLine(allocator, input);
    defer {
        for (tokens) |t| allocator.free(t);
        allocator.free(tokens);
    }

    try std.testing.expectEqual(@as(usize, 6), tokens.len);
    try std.testing.expectEqualStrings("foo", tokens[0]);
    try std.testing.expectEqualStrings("--bar=hello world", tokens[1]);
    try std.testing.expectEqualStrings("a\"b", tokens[2]);
    try std.testing.expectEqualStrings("$HOME", tokens[3]);
    try std.testing.expectEqualStrings("`t`", tokens[4]);
    try std.testing.expectEqualStrings("plain", tokens[5]);
}
