const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui/ui.zig");
const log = @import("utils").log;
const debug = @import("debug/debug.zig");
const bootstrap = @import("core/bootstrap.zig");
const desktop_loader = @import("core/desktop_loader.zig");
const args = @import("args/args.zig");
const theme = @import("theme/theme.zig");
const plugins = @import("plugins");
const styles_watcher = @import("ui/styles_watcher.zig");

extern fn freopen([*:0]const u8, [*:0]const u8, *anyopaque) ?*anyopaque;
extern var __stderrp: *anyopaque;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .macos) {
        _ = freopen("/dev/null", "w", __stderrp);
    }

    {
        var args_iter = init.minimal.args.iterate();
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--list-themes")) {
                std.debug.print("Available themes:\n", .{});
                for (theme.theme_entries) |entry| {
                    std.debug.print("  {s:<26} {s}\n", .{ entry.name, entry.desc });
                }
                std.process.exit(0);
            }
        }
    }

    var ctx = try bootstrap.init(init.gpa, init.minimal.args);
    defer ctx.deinit();

    const menu_entries = try args.parseMenus(init.gpa, ctx.argv);
    defer args.deinitMenuEntries(init.gpa, menu_entries);

    var pm = plugins.setup(init.gpa);
    defer pm.deinit();

    const use_menus = menu_entries.len > 0;
    const items = if (use_menus) blk: {
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
        break :blk try list_items.toOwnedSlice(init.gpa);
    } else try desktop_loader.load(init.gpa, ctx.cfg.benchmark_all, ctx.cfg.show_actions, ctx.cfg.actions_bottombar);

    defer {
        if (use_menus) {
            for (items) |item| {
                init.gpa.free(item.icon);
                init.gpa.free(item.cmd);
                init.gpa.free(item.name);
            }
            init.gpa.free(items);
        } else {
            for (items) |item| {
                init.gpa.free(item.icon);
                init.gpa.free(item.cmd);
                init.gpa.free(item.name);
                if (item.actions.len > 0) desktop_loader.freeListItemActions(init.gpa, item.actions);
            }
            init.gpa.free(items);
            desktop_loader.freeDesktopApps();
        }
    }

    if (ctx.cfg.benchmark_all) debug.mark("window setup");
    var window: ui.Window = undefined;
    ui.renderList(&window, init.gpa, items, ctx.visual, !ctx.cfg.no_bottom_bar, ctx.cfg.no_icons);
    window.list.plugin_manager = &pm;
    defer window.deinit();

    if (ctx.cfg.benchmark_all) debug.mark("show window");
    window.show();

    if (ctx.cfg.start_timer) {
        const elapsed = @as(f64, @floatFromInt(debug.monotonicNs() - ctx.start_ns)) / std.time.ns_per_ms;
        log.info("appeared on screen in {d:.2}ms", .{elapsed});
    }
    if (ctx.cfg.benchmark_all) debug.printBenchmarks();

    if (ctx.cfg.start_timer and ctx.cfg.theme_reloader) styles_watcher.start(init.gpa);
    ui.Window.exec();
}
