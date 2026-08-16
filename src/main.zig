const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const QApp = qt.QApplication;
const ui = @import("ui/ui.zig");
const log = @import("utils").log;
const debug = @import("debug/debug.zig");
const bootstrap = @import("core/bootstrap.zig");
const desktop_loader = @import("core/desktop_loader.zig");
const args = @import("args/args.zig");
const theme = @import("theme/theme.zig");
const plugins = @import("plugins");
const styles_watcher = @import("ui/styles_watcher.zig");
const config = @import("config");
const core_freq = @import("core_freq");
const lang = @import("lang");

extern fn freopen([*:0]const u8, [*:0]const u8, *anyopaque) ?*anyopaque;
extern fn setenv([*:0]const u8, [*:0]const u8, i32) i32;
extern var __stderrp: *anyopaque;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .macos) {
        _ = freopen("/dev/null", "w", __stderrp);
    }

    var debug_freq = false;
    {
        var fullscreen = false;
        var use_monitor = false;
        var args_iter = init.minimal.args.iterate();
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
        var args_iter2 = init.minimal.args.iterate();
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

    {
        var args_iter = init.minimal.args.iterate();
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

    var pm: ?plugins.PluginManager = if (ctx.cfg.no_plugins) null else plugins.setup(init.gpa, plugin_names);
    defer if (pm) |*p| p.deinit();

    if (pm) |*p| {
        plugins.setActiveManager(p);
        if (ctx.visual.clipboard) |clip| {
            p.clipboard_cmd = init.gpa.dupe(u8, clip) catch null;
        }
        if (ctx.visual.url_handler) |handler| {
            p.url_handler = init.gpa.dupe(u8, handler) catch null;
        }
    }

    const use_menus = menu_entries.len > 0;
    const skip_desktop = use_menus or ctx.cfg.no_dapps;

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
    defer window.deinit();

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

    if (!skip_desktop) {
        const loaded = desktop_loader.load(init.gpa, ctx.cfg.benchmark_all, ctx.cfg.show_actions, ctx.cfg.actions_bottombar) catch |err| blk: {
            log.info("desktop load failed: {}", .{err});
            break :blk try init.gpa.alloc(ui.ListItem, 0);
        };
        window.setOwnedItems(loaded);
    }

    if (ctx.cfg.start_timer) {
        const elapsed = @as(f64, @floatFromInt(debug.monotonicNs() - ctx.start_ns)) / std.time.ns_per_ms;
        log.info("appeared on screen in {d:.2}ms", .{elapsed});
    }

    if (ctx.cfg.benchmark_all) debug.printBenchmarks();

    if (ctx.cfg.start_timer and ctx.cfg.theme_reloader) styles_watcher.start(init.gpa);
    ui.Window.exec();

    if (cfg_dir_opt) |cfg_dir| freq_store.save(cfg_dir);
}
