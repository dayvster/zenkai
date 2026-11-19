const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const QApp = qt.QApplication;
const ui = @import("ui/ui.zig");
const log = @import("utils").log;
const debug = @import("debug/debug.zig");
const benchmark = @import("debug/startup_benchmark.zig");
const bootstrap = @import("core/bootstrap.zig");
const desktop_loader = @import("core/desktop_loader.zig");
const dapp_parser = @import("dapp_parser");
const args = @import("args/args.zig");
const theme = @import("theme/theme.zig");
const plugins = @import("plugins");
const styles_watcher = @import("ui/styles_watcher.zig");
const config = @import("config");
const core_freq = @import("core_freq");
const lang = @import("lang");
const service = @import("core/service.zig");
const resident = @import("ui/resident.zig");
const clipboard_history = @import("core/clipboard_history.zig");

var g_app_refresh_window: ?*ui.Window = null;
var g_app_refresh_timer: ?qt.QTimer = null;
var g_app_refresh_allocator: std.mem.Allocator = undefined;
var g_app_refresh_benchmark = false;
var g_app_refresh_actions = false;
var g_app_refresh_actions_bar = false;
var g_apps_loaded_at: u64 = 0;
var g_dmenu_window: ?*ui.Window = null;
var g_dmenu_picked = false;
var g_plugin_manager: ?*plugins.PluginManager = null;
var g_plugin_timer: ?qt.QTimer = null;

fn onPluginsReady(timer: qt.QTimer) callconv(.c) void {
    timer.stop();
    const work = benchmark.workStart();
    defer benchmark.workEnd(.plugins, work);
    if (g_plugin_manager) |pm| pm.ensureInitialized();
}

fn afterFirstPaint() void {
    // Queue initialization only after the viewport's paint handler completes.
    if (g_plugin_timer) |timer| timer.start(0);
}

fn onAppsRefresh(timer: qt.QTimer) callconv(.c) void {
    if (@import("ui/file_actions.zig").isOpen()) {
        timer.start(100);
        return;
    }
    timer.stop();
    if (g_app_refresh_window) |window| {
        const started = debug.monotonicNs();
        benchmark.refreshStarted();
        const loaded = desktop_loader.load(g_app_refresh_allocator, g_app_refresh_benchmark, g_app_refresh_actions, g_app_refresh_actions_bar) catch |err| {
            benchmark.failed();
            log.info("desktop load failed: {}", .{err});
            timer.delete();
            g_app_refresh_timer = null;
            return;
        };
        const items = loaded;
        window.setOwnedItems(items);
        if (!g_app_refresh_actions and !g_app_refresh_actions_bar and items.len > 0) {
            desktop_loader.saveCache(g_app_refresh_allocator, items);
        }
        benchmark.dataReady(items.len);
        g_apps_loaded_at = debug.monotonicNs();
        log.info("app list refreshed in {d:.2}ms", .{@as(f64, @floatFromInt(debug.monotonicNs() - started)) / std.time.ns_per_ms});
    }
    timer.delete();
    g_app_refresh_timer = null;
}

fn scheduleAppRefresh() void {
    if (g_app_refresh_timer != null) return;
    g_app_refresh_timer = qt.QTimer.new();
    g_app_refresh_timer.?.onTimeout(onAppsRefresh);
    g_app_refresh_timer.?.start(50);
}

// The background service reloads the app list after hiding, the same five minutes after the
// last load that a normal launch treats its cache as fresh. Doing it while hidden means the
// list never changes under someone typing.
fn refreshStaleAppsWhileHidden() void {
    if (g_app_refresh_window == null) return;
    if (debug.monotonicNs() - g_apps_loaded_at < 5 * std.time.ns_per_min) return;
    scheduleAppRefresh();
}

extern fn freopen([*:0]const u8, [*:0]const u8, *anyopaque) ?*anyopaque;
extern fn setenv([*:0]const u8, [*:0]const u8, i32) i32;
extern var __stderrp: *anyopaque;

/// Handles --toggle, --quit-service and --clipboard-store before Qt starts, so talking to the
/// background service costs a socket write. True when there's nothing left to do. Without a
/// service, --toggle carries on and starts zenkai normally.
fn sendServiceCommand(init: std.process.Init) !bool {
    var toggle = false;
    var quit_service = false;
    var window_switcher = false;
    var clipboard = false;
    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--toggle")) toggle = true;
        if (std.mem.eql(u8, arg, "--quit-service")) quit_service = true;
        if (std.mem.eql(u8, arg, "--window-switcher")) window_switcher = true;
        if (std.mem.eql(u8, arg, "--clipboard-history")) clipboard = true;
        if (std.mem.eql(u8, arg, "--clipboard-store")) {
            storeClipboard(init.gpa);
            return true;
        }
    }
    if (quit_service) {
        if (!service.send(.quit)) std.debug.print("No background service is running.\n", .{});
        return true;
    }
    const command: service.Command = if (window_switcher) .toggle_window_switcher else if (clipboard) .toggle_clipboard else .toggle_launcher;
    return toggle and service.send(command);
}

/// `zenkai --clipboard-store`, which wl-paste runs for every copy on Wayland with the copied
/// text on stdin. Hands it to the background service, unless wl-paste flagged it as a
/// password.
fn storeClipboard(allocator: std.mem.Allocator) void {
    // Whatever happens, read the copy to the end, so the app writing it never hits a
    // closed pipe.
    defer drainStdin();
    const state = if (std.c.getenv("CLIPBOARD_STATE")) |value| std.mem.span(value) else null;
    if (!@import("ui/clipboard_watch.zig").shouldStore(state)) return;
    const text = allocator.alloc(u8, clipboard_history.max_text_bytes + 1) catch return;
    defer allocator.free(text);
    var len: usize = 0;
    while (len < text.len) {
        const n = std.c.read(0, text[len..].ptr, text.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    // Too big to keep; the history would leave it out anyway.
    if (len > clipboard_history.max_text_bytes) return;
    _ = service.sendClip(text[0..len]);
}

fn drainStdin() void {
    var buf: [16 * 1024]u8 = undefined;
    while (std.c.read(0, &buf, buf.len) > 0) {}
}

fn readDmenuEntries(allocator: std.mem.Allocator) ![]args.MenuEntry {
    if (std.c.isatty(0) != 0) {
        std.debug.print("zenkai --dmenu reads its entries from stdin, e.g. ls | zenkai --dmenu\n", .{});
        std.process.exit(2);
    }
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n <= 0) break;
        try input.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    var entries: std.ArrayList(args.MenuEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.cmd);
            allocator.free(entry.icon);
        }
        entries.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, input.items, '\n');
    while (lines.next()) |raw| {
        const line = parseDmenuLine(std.mem.trimEnd(u8, raw, "\r"));
        if (line.text.len == 0) continue;
        const name = try allocator.dupe(u8, line.text);
        errdefer allocator.free(name);
        const cmd = try allocator.dupe(u8, "");
        errdefer allocator.free(cmd);
        const icon = try allocator.dupe(u8, line.icon);
        errdefer allocator.free(icon);
        try entries.append(allocator, .{ .name = name, .cmd = cmd, .icon = icon });
    }
    return entries.toOwnedSlice(allocator);
}

const DmenuLine = struct { text: []const u8, icon: []const u8 = "" };

fn parseDmenuLine(line: []const u8) DmenuLine {
    const nul = std.mem.indexOfScalar(u8, line, 0) orelse return .{ .text = line };
    var fields = std.mem.splitScalar(u8, line[nul + 1 ..], 0x1f);
    while (fields.next()) |key| {
        const value = fields.next() orelse break;
        if (std.mem.eql(u8, key, "icon")) return .{ .text = line[0..nul], .icon = value };
    }
    return .{ .text = line[0..nul] };
}

test "dmenu lines take the icon option and keep plain text as is" {
    try std.testing.expectEqualDeep(DmenuLine{ .text = "plain line" }, parseDmenuLine("plain line"));
    try std.testing.expectEqualDeep(DmenuLine{ .text = "Firefox", .icon = "firefox" }, parseDmenuLine("Firefox\x00icon\x1ffirefox"));
    try std.testing.expectEqualDeep(DmenuLine{ .text = "Docs", .icon = "/tmp/a.png" }, parseDmenuLine("Docs\x00meta\x1fpdf\x1ficon\x1f/tmp/a.png"));
    try std.testing.expectEqualDeep(DmenuLine{ .text = "No icon" }, parseDmenuLine("No icon\x00nonselectable\x1ftrue"));
    try std.testing.expectEqualDeep(DmenuLine{ .text = "Broken" }, parseDmenuLine("Broken\x00icon"));
}

fn onDmenuPick(entry: ?[]const u8) void {
    const window = g_dmenu_window orelse return;
    const text = entry orelse window.search_bar.getText();
    if (text.len == 0) return;
    _ = std.c.write(1, text.ptr, text.len);
    _ = std.c.write(1, "\n", 1);
    g_dmenu_picked = true;
    qt.QApplication.quit();
}

/// Clipboard history comes with the `clip:` plugin, so it's off whenever that plugin is: in
/// disabled_plugins, or left out by --plugin=NAME, or with --no-plugins.
fn clipboardHistoryEnabled(plugin_manager: ?*const plugins.PluginManager, plugin_names: []const []const u8, disabled: []const []const u8) bool {
    if (plugin_manager == null) return false;
    const name = "clipboard";
    if (plugin_names.len > 0) {
        for (plugin_names) |selected| if (std.mem.eql(u8, selected, name)) return true;
        return false;
    }
    for (disabled) |off| if (std.mem.eql(u8, off, name)) return false;
    return true;
}

test {
    std.testing.refAllDecls(@import("core/service.zig"));
    std.testing.refAllDecls(@import("ui/resident.zig"));
    std.testing.refAllDecls(@import("ui/clipboard_watch.zig"));
    std.testing.refAllDecls(@import("core/clipboard_history.zig"));
    std.testing.refAllDecls(@import("ui/list.zig"));
    std.testing.refAllDecls(@import("ui/window.zig"));
    std.testing.refAllDecls(@import("ui/action_menu.zig"));
    std.testing.refAllDecls(@import("ui/browser_actions.zig"));
    std.testing.refAllDecls(@import("ui/http.zig"));
    std.testing.refAllDecls(@import("ui/file_preview.zig"));
    std.testing.refAllDecls(@import("ui/file_actions.zig"));
    std.testing.refAllDecls(@import("core/window_layout.zig"));
    std.testing.refAllDecls(@import("theme/theme.zig"));
    std.testing.refAllDecls(@import("theme/colors.zig"));
    std.testing.refAllDecls(@import("ui/settings.zig"));
}

pub fn main(init: std.process.Init) !void {
    benchmark.entry_ns = debug.monotonicNs();
    if (try sendServiceCommand(init)) return;

    var debug_freq = false;
    if (comptime builtin.os.tag == .linux) {
        var fullscreen = false;
        var use_monitor = false;
        var args_iter = try init.minimal.args.iterateAllocator(init.gpa);
        defer args_iter.deinit();
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--fullscreen")) fullscreen = true;
            if (std.mem.startsWith(u8, arg, "--monitor=")) use_monitor = true;
        }
        if (fullscreen and use_monitor) {
            if (std.c.getenv("WAYLAND_DISPLAY")) |_| {
                _ = setenv("QT_QPA_PLATFORM", "xcb", 1);
            }
        }
    }
    {
        var args_iter2 = try init.minimal.args.iterateAllocator(init.gpa);
        defer args_iter2.deinit();
        while (args_iter2.next()) |arg| {
            if (std.mem.eql(u8, arg, "--list-themes")) {
                std.debug.print("{s}", .{lang.get().available_themes});
                for (theme.theme_entries) |entry| {
                    std.debug.print("  {s:<26} {s}\n", .{ entry.name, entry.desc });
                }
                std.process.exit(0);
            }
            if (std.mem.eql(u8, arg, "--debug-freq")) {
                debug_freq = true;
            }
        }
    }

    var ctx = try bootstrap.init(init.gpa, init.minimal.args);
    defer ctx.deinit();
    if (builtin.os.tag == .macos and !ctx.cfg.benchmark_startup) {
        _ = freopen("/dev/null", "w", __stderrp);
    }
    if (ctx.cfg.run_mode) ctx.visual.window_height = 140;
    if (ctx.cfg.settings) return @import("ui/settings.zig").run(init.gpa, ctx.app);
    if (ctx.cfg.service and ctx.cfg.dmenu) {
        std.debug.print("--dmenu reads from the terminal that starts it, so it can't run as the background service.\n", .{});
        std.process.exit(2);
    }
    if (ctx.cfg.service and !service.supported) {
        std.debug.print("The background service is only available on Linux for now.\n", .{});
        std.process.exit(1);
    }

    {
        var args_iter = try init.minimal.args.iterateAllocator(init.gpa);
        defer args_iter.deinit();
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--list-monitors")) {
                const screens = QApp.screens(init.gpa);
                defer init.gpa.free(screens);
                std.debug.print("Available monitors:\n", .{});
                for (screens, 0..) |screen, i| {
                    const geo = screen.geometry();
                    const name = screen.name(init.gpa);
                    defer init.gpa.free(name);
                    const manu = screen.manufacturer(init.gpa);
                    defer init.gpa.free(manu);
                    const model = screen.model(init.gpa);
                    defer init.gpa.free(model);
                    std.debug.print("  {d}: {s} {s} ({s}) - {d}x{d}+{d}+{d}\n", .{
                        i,           manu,         model,   name,
                        geo.width(), geo.height(), geo.x(), geo.y(),
                    });
                }
                std.process.exit(0);
            }
        }
    }

    const cli_work = benchmark.workStart();
    const menu_entries = if (ctx.cfg.dmenu) try readDmenuEntries(init.gpa) else try args.parseMenus(init.gpa, ctx.argv);
    defer args.deinitMenuEntries(init.gpa, menu_entries);

    const plugin_names = try args.parsePluginNames(init.gpa, ctx.argv);
    defer args.deinitPluginNames(init.gpa, plugin_names);

    var pm: ?plugins.PluginManager = if (ctx.cfg.no_plugins or ctx.cfg.run_mode or ctx.cfg.dmenu) null else plugins.setup(init.gpa, plugin_names);
    defer if (pm) |*p| p.deinit();

    if (pm) |*p| {
        plugins.setActiveManager(p);
        p.copy_text = ui.copyText;
        p.http_get = ui.http.get;
        p.file_action = @import("ui/file_actions.zig").perform;
        p.disabled_plugins = ctx.visual.disabled_plugins;
        if (ctx.visual.clipboard) |clip| {
            if (clip.len > 0) p.clipboard_cmd = init.gpa.dupe(u8, clip) catch null;
        }
        if (ctx.visual.url_handler) |handler| {
            if (handler.len > 0) p.url_handler = init.gpa.dupe(u8, handler) catch null;
        }
    }
    benchmark.pluginsDone(if (pm) |p| p.plugins.items.len else 0);
    dapp_parser.setLocale(ctx.cfg.language);

    const use_menus = menu_entries.len > 0 or ctx.cfg.dmenu;
    // The background service serves both the launcher and the window switcher, so it always
    // loads apps; --toggle --window-switcher picks the mode each time.
    const window_switcher = ctx.cfg.window_switcher and !ctx.cfg.no_window_switcher and !ctx.cfg.run_mode and !ctx.cfg.service and !ctx.cfg.dmenu;
    const skip_desktop = use_menus or ctx.cfg.no_dapps or ctx.cfg.run_mode or window_switcher;

    var items: []ui.ListItem = undefined;
    if (use_menus) {
        var list_items = try std.ArrayList(ui.ListItem).initCapacity(init.gpa, menu_entries.len);
        errdefer {
            for (list_items.items) |item| {
                init.gpa.free(item.icon);
                init.gpa.free(item.cmd);
                init.gpa.free(item.name);
            }
            list_items.deinit(init.gpa);
        }
        for (menu_entries) |me| {
            const icon = try init.gpa.dupe(u8, me.icon);
            errdefer init.gpa.free(icon);
            const cmd = try init.gpa.dupe(u8, me.cmd);
            errdefer init.gpa.free(cmd);
            const name = try init.gpa.dupe(u8, me.name);
            errdefer init.gpa.free(name);
            list_items.appendAssumeCapacity(.{
                .icon = icon,
                .cmd = cmd,
                .name = name,
            });
        }
        items = try list_items.toOwnedSlice(init.gpa);
    } else {
        items = try init.gpa.alloc(ui.ListItem, 0);
    }

    defer {
        if (use_menus) {
            for (items) |item| {
                init.gpa.free(item.icon);
                init.gpa.free(item.cmd);
                init.gpa.free(item.name);
            }
            init.gpa.free(items);
        } else {
            init.gpa.free(items);
            if (!skip_desktop) desktop_loader.freeDesktopApps();
        }
    }

    benchmark.workEnd(.cli_setup, cli_work);
    if (ctx.cfg.benchmark_all) debug.mark("window setup");
    var window: ui.Window = undefined;
    const dmenu_icons = for (menu_entries) |entry| {
        if (entry.icon.len > 0) break true;
    } else false;
    ui.renderList(&window, init.gpa, items, ctx.visual, !ctx.cfg.no_bottom_bar, ctx.cfg.no_icons or (ctx.cfg.dmenu and !dmenu_icons), ctx.app);
    window.list.plugin_manager = if (pm) |*p| p else null;
    window.list.window_search.enabled = !ctx.cfg.no_window_switcher and !ctx.cfg.run_mode and !ctx.cfg.dmenu;
    if (ctx.cfg.dmenu) {
        g_dmenu_window = &window;
        window.list.on_pick = onDmenuPick;
    }
    window.list.window_search.standalone = window_switcher;
    if (pm) |*p| {
        g_plugin_manager = p;
        g_plugin_timer = qt.QTimer.new();
        g_plugin_timer.?.setSingleShot(true);
        g_plugin_timer.?.onTimeout(onPluginsReady);
        window.list.after_first_paint = afterFirstPaint;
    }
    defer {
        if (g_plugin_timer) |timer| {
            timer.stop();
            timer.delete();
        }
        g_plugin_timer = null;
        g_plugin_manager = null;
    }
    window.list.run_mode = ctx.cfg.run_mode;
    if (ctx.cfg.run_mode) {
        window.search_bar.setPlaceholder("Type a command to run...");
    } else if (window_switcher) {
        window.search_bar.setPlaceholder("Search windows...");
    }
    if (ctx.cfg.prompt) |prompt| window.search_bar.setPlaceholder(prompt);
    defer window.deinit();
    benchmark.attach(ctx.app, window.widget, window.list.view.viewport(), window.search_bar.widget);
    defer benchmark.deinit();

    const can_use_app_cache = !skip_desktop and !ctx.cfg.show_actions and !ctx.cfg.actions_bottombar;
    var refresh_apps = !skip_desktop;
    benchmark.cache_state = if (skip_desktop) "skipped" else "miss";
    if (can_use_app_cache) {
        if (desktop_loader.loadCache(init.gpa)) |cached| {
            window.setOwnedItems(cached);
            log.info("loaded {d} apps from cache", .{cached.len});
            refresh_apps = cached.len == 0 or !desktop_loader.cacheIsFresh(init.gpa);
            benchmark.cache_state = if (refresh_apps) "stale" else "fresh";
        }
    }

    if (!refresh_apps) benchmark.dataReady(if (window.owned_items) |owned| owned.len else items.len);

    const frequency_work = benchmark.workStart();
    var freq_store = core_freq.FrequencyStore.init(init.gpa);
    defer freq_store.deinit();
    var cfg_dir_opt: ?[]u8 = null;
    if (config.configDir(init.gpa)) |cfg_dir| {
        freq_store.load(cfg_dir);
        if (!ctx.cfg.dmenu) window.list.frequency_store = &freq_store;
        cfg_dir_opt = cfg_dir;
    } else |_| {}
    benchmark.workEnd(.frequency, frequency_work);
    defer {
        if (cfg_dir_opt) |cfg_dir| init.gpa.free(cfg_dir);
    }

    if (debug_freq) {
        std.debug.print("{s}", .{lang.get().freq_contents});
        var it = freq_store.scores.iterator();
        while (it.next()) |entry| {
            std.debug.print("  {s} = {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        std.debug.print("  (dirty: {any})\n", .{freq_store.dirty});
    }

    if (skip_desktop) {
        window.list.setFilter("");
    }

    if (ctx.cfg.service) {
        resident.start(&window, init.gpa, .{
            .config_dir = cfg_dir_opt,
            .on_hide = refreshStaleAppsWhileHidden,
            .clipboard_history = clipboardHistoryEnabled(if (pm) |*p| p else null, plugin_names, ctx.visual.disabled_plugins),
        }) catch |err| {
            switch (err) {
                error.AlreadyRunning => std.debug.print("A background service is already running. Show it with zenkai --toggle.\n", .{}),
                else => std.debug.print("Can't start the background service: {}\n", .{err}),
            }
            std.process.exit(1);
        };
        // There's no first paint to wait for, so load plugins now and keep them ready.
        if (g_plugin_timer) |timer| timer.start(0);
    } else {
        if (ctx.cfg.benchmark_all) debug.mark("show window");
        window.show();
        if (ctx.cfg.benchmark_startup) window.widget.activateWindow();
        if (ctx.cfg.run_mode or window_switcher or ctx.cfg.benchmark_startup) window.search_bar.focus();
        benchmark.showReturned();
    }
    defer if (ctx.cfg.service) resident.stop();

    if (!skip_desktop) {
        g_app_refresh_window = &window;
        g_app_refresh_allocator = init.gpa;
        g_app_refresh_benchmark = ctx.cfg.benchmark_all;
        g_app_refresh_actions = ctx.cfg.show_actions;
        g_app_refresh_actions_bar = ctx.cfg.actions_bottombar;
        g_apps_loaded_at = debug.monotonicNs();
        if (refresh_apps) scheduleAppRefresh();
    }

    if (ctx.cfg.start_timer) {
        const elapsed = @as(f64, @floatFromInt(debug.monotonicNs() - ctx.start_ns)) / std.time.ns_per_ms;
        log.info("appeared on screen in {d:.2}ms", .{elapsed});
    }

    if (ctx.cfg.benchmark_all) debug.printBenchmarks();

    if (ctx.cfg.start_timer and ctx.cfg.theme_reloader) styles_watcher.start(init.gpa);
    ui.Window.exec();

    if (g_app_refresh_timer) |timer| {
        timer.stop();
        timer.delete();
        g_app_refresh_timer = null;
    }
    g_app_refresh_window = null;

    if (!ctx.cfg.benchmark_startup) {
        if (cfg_dir_opt) |cfg_dir| freq_store.save(cfg_dir);
    }
    if (ctx.cfg.dmenu and !g_dmenu_picked) std.process.exit(1);
}
