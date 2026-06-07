const std = @import("std");
const ui = @import("ui/ui.zig");
const log = @import("utils").log;
const debug = @import("debug/debug.zig");
const bootstrap = @import("core/bootstrap.zig");
const desktop_loader = @import("core/desktop_loader.zig");
const plugins = @import("plugins");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .macos) {
        const H = struct {
            extern fn freopen([*:0]const u8, [*:0]const u8, *anyopaque) ?*anyopaque;
            extern var __stderrp: *anyopaque;
        };
        _ = H.freopen("/dev/null", "w", H.__stderrp);
    }
    var ctx = try bootstrap.init(init.gpa, init.minimal.args);
    defer ctx.deinit();

    var pm = plugins.setup(init.gpa);
    defer pm.deinit();

    const items = try desktop_loader.load(init.gpa, ctx.cfg.benchmark_all);
    defer {
        for (items) |item| {
            init.gpa.free(item.icon);
            init.gpa.free(item.cmd);
            init.gpa.free(item.name);
        }
        init.gpa.free(items);
    }

    if (ctx.cfg.benchmark_all) debug.mark("window setup");
    var window: ui.Window = undefined;
    ui.renderList(&window, init.gpa, items, ctx.cfg.icon_size, !ctx.cfg.no_bottom_bar, ctx.cfg.no_icons);
    window.list.plugin_manager = &pm;
    defer window.deinit();

    if (ctx.cfg.benchmark_all) debug.mark("show window");
    window.show();

    if (ctx.cfg.start_timer) {
        const elapsed = @as(f64, @floatFromInt(debug.monotonicNs() - ctx.start_ns)) / std.time.ns_per_ms;
        log.info("appeared on screen in {d:.2}ms", .{elapsed});
    }
    if (ctx.cfg.benchmark_all) debug.printBenchmarks();

    ui.Window.exec();
}
