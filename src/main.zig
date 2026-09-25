const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const QApp = qt.QApplication;
const ui = @import("ui/ui.zig");
const log = @import("utils").log;
const debug = @import("debug/debug.zig");
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

var g_app_refresh_window: ?*ui.Window = null;
var g_app_refresh_timer: ?qt.QTimer = null;
var g_app_refresh_allocator: std.mem.Allocator = undefined;
var g_app_refresh_benchmark = false;
var g_app_refresh_actions = false;
var g_app_refresh_actions_bar = false;

fn onAppsRefresh(timer: qt.QTimer) callconv(.c) void {
    timer.stop();
    if (g_app_refresh_window) |window| {
        const started = debug.monotonicNs();
        const loaded = desktop_loader.load(g_app_refresh_allocator, g_app_refresh_benchmark, g_app_refresh_actions, g_app_refresh_actions_bar) catch |err| {
            log.info("desktop load failed: {}", .{err});
            timer.delete();
            g_app_refresh_timer = null;
            return;
        };
        const items = loaded;
        window.setOwnedItems(items);
        if (!g_app_refresh_actions and !g_app_refresh_actions_bar) desktop_loader.saveCache(g_app_refresh_allocator, items);
        log.info("app list refreshed in {d:.2}ms", .{@as(f64, @floatFromInt(debug.monotonicNs() - started)) / std.time.ns_per_ms});
    }
    timer.delete();
    g_app_refresh_timer = null;
}

extern fn freopen([*:0]const u8, [*:0]const u8, *anyopaque) ?*anyopaque;
extern fn setenv([*:0]const u8, [*:0]const u8, i32) i32;
extern var __stderrp: *anyopaque;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .macos) {
        _ = freopen("/dev/null", "w", __stderrp);
    }

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
    if (ctx.cfg.run_mode) ctx.visual.window_height = 140;

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
                    std.debug.print("  {d}: {s} {s} ({s}) — {d}x{d}+{d}+{d}\n", .{
                        i,           manu,         model,   name,
                        geo.width(), geo.height(), geo.x(), geo.y(),
                    });
                }
                std.process.exit(0);
            }
        }
    }

    const menu_entries = try args.parseMenus(init.gpa, ctx.argv);
    defer args.deinitMenuEntries(init.gpa, menu_entries);

    const plugin_names = try args.parsePluginNames(init.gpa, ctx.argv);
    defer args.deinitPluginNames(init.gpa, plugin_names);

    var pm: ?plugins.PluginManager = if (ctx.cfg.no_plugins or ctx.cfg.run_mode) null else plugins.setup(init.gpa, plugin_names);
    defer if (pm) |*p| p.deinit();

    if (pm) |*p| {
        plugins.setActiveManager(p);
        if (ctx.visual.clipboard) |clip| {
            if (clip.len > 0) p.clipboard_cmd = init.gpa.dupe(u8, clip) catch null;
        }
        if (ctx.visual.url_handler) |handler| {
            if (handler.len > 0) p.url_handler = init.gpa.dupe(u8, handler) catch null;
        }
        p.dispatchStartup();
    }
    dapp_parser.setLocale(ctx.cfg.language);

    const use_menus = menu_entries.len > 0;
    const skip_desktop = use_menus or ctx.cfg.no_dapps or ctx.cfg.run_mode;

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

    if (ctx.cfg.benchmark_all) debug.mark("window setup");
    var window: ui.Window = undefined;
    ui.renderList(&window, init.gpa, items, ctx.visual, !ctx.cfg.no_bottom_bar, ctx.cfg.no_icons, ctx.app);
    window.list.plugin_manager = if (pm) |*p| p else null;
    window.list.run_mode = ctx.cfg.run_mode;
    if (ctx.cfg.run_mode) window.search_bar.setPlaceholder("Type a command to run...");
    defer window.deinit();

    const can_use_app_cache = !skip_desktop and !ctx.cfg.show_actions and !ctx.cfg.actions_bottombar;
    var refresh_apps = !skip_desktop;
    if (can_use_app_cache) {
        if (desktop_loader.loadCache(init.gpa)) |cached| {
            window.setOwnedItems(cached);
            log.info("loaded {d} apps from cache", .{cached.len});
            refresh_apps = !desktop_loader.cacheIsFresh(init.gpa);
        }
    }

    var freq_store = core_freq.FrequencyStore.init(init.gpa);
    defer freq_store.deinit();
    var cfg_dir_opt: ?[]u8 = null;
    if (config.configDir(init.gpa)) |cfg_dir| {
        freq_store.load(cfg_dir);
        window.list.frequency_store = &freq_store;
        cfg_dir_opt = cfg_dir;
    } else |_| {}
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

    if (ctx.cfg.benchmark_all) debug.mark("show window");
    window.show();
    if (ctx.cfg.run_mode) window.search_bar.focus();

    if (refresh_apps) {
        g_app_refresh_window = &window;
        g_app_refresh_allocator = init.gpa;
        g_app_refresh_benchmark = ctx.cfg.benchmark_all;
        g_app_refresh_actions = ctx.cfg.show_actions;
        g_app_refresh_actions_bar = ctx.cfg.actions_bottombar;
        g_app_refresh_timer = qt.QTimer.new();
        g_app_refresh_timer.?.onTimeout(onAppsRefresh);
        g_app_refresh_timer.?.start(50);
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

    if (cfg_dir_opt) |cfg_dir| freq_store.save(cfg_dir);
}
