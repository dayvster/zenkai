const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const theme_handler = @import("../ui/theme_handler.zig");
const config = @import("config");
const log = @import("utils").log;
const theme = @import("../theme/theme.zig");
const debug = @import("../debug/debug.zig");
const benchmark = @import("../debug/startup_benchmark.zig");
const args = @import("../args/args.zig");
const lang = @import("lang");

const QApp = qt.QApplication;
const QIcon = qt.QIcon;

pub const Context = struct {
    allocator: std.mem.Allocator,
    argv: [][:0]u8,
    cfg: args.Config,
    visual: config.VisualConfig,
    app: qt.QApplication,
    start_ns: u64,

    pub fn deinit(self: *Context) void {
        self.visual.deinit(self.allocator);
        lang.deinit();
        self.app.delete();
        qt.deinit(self.allocator, self.argv);
    }
};

pub fn init(allocator: std.mem.Allocator, raw_args: anytype) !Context {
    return initMode(allocator, raw_args, false);
}

pub fn initMinimal(allocator: std.mem.Allocator, raw_args: anytype) !Context {
    return initMode(allocator, raw_args, true);
}

fn initMode(allocator: std.mem.Allocator, raw_args: anytype, comptime minimal: bool) !Context {
    const argv = try qt.init(allocator, raw_args);
    errdefer qt.deinit(allocator, argv);

    const config_work_start = debug.monotonicNs();
    const cfg = args.parse(argv);
    benchmark.enabled = cfg.benchmark_startup;
    benchmark.icons_enabled = !cfg.no_icons;
    benchmark.run_mode = cfg.run_mode;

    lang.init(allocator, cfg.language);

    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const config_path = try config.deploy(io, allocator);
    defer allocator.free(config_path);

    var visual = try config.loadConfig(allocator, config_path);
    visual.applyOverrides(allocator, cfg);
    if (cfg.benchmark_startup) {
        visual.no_animations = true;
        visual.close_on_focus_out = false;
        visual.show_backdrop = false;
    }
    if (visual.theme == null and builtin.os.tag == .windows) {
        visual.theme = try allocator.dupe(u8, "native");
    }

    if (benchmark.enabled) benchmark.workEnd(.config, config_work_start);
    benchmark.configDone();
    if (cfg.benchmark_all) debug.mark("qt init");
    const start_ns = if (cfg.start_timer) debug.monotonicNs() else 0;

    var argc: i32 = @intCast(argv.len);
    const app = QApp.new(std.heap.page_allocator, &argc, argv);
    errdefer app.delete();
    theme_handler.setApp(app);

    const theme_resolved = if (visual.theme) |theme_name|
        if (std.mem.eql(u8, theme_name, "native")) theme.resolveNative(allocator) else theme.resolve(allocator, visual.theme)
    else
        theme.resolve(allocator, null);
    defer if (theme_resolved.allocation) |m| allocator.free(m);

    if (cfg.benchmark_all) debug.mark("theme apply");
    const main_qss_loaded = if (minimal) null else theme.readMainQss(allocator);
    const base_qss = main_qss_loaded orelse if (minimal) @embedFile("../styles/launcher.qss") else theme.main_qss;
    defer if (main_qss_loaded) |m| allocator.free(m);
    theme_handler.apply(allocator, base_qss, theme_resolved.qss);

    if (cfg.benchmark_all) debug.mark("icon theme");
    if (config.detectIconTheme(allocator)) |icon_theme| {
        log.info("icon theme: {s}", .{icon_theme});
        QIcon.setThemeName(icon_theme);
        allocator.free(icon_theme);
    } else {
        log.info("icon theme: default (Qt resolved)", .{});
    }

    benchmark.qtDone();
    return .{
        .allocator = allocator,
        .argv = argv,
        .cfg = cfg,
        .visual = visual,
        .app = app,
        .start_ns = start_ns,
    };
}
