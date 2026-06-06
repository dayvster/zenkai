const std = @import("std");
const qt = @import("libqt6zig");
const ui = @import("../ui/ui.zig");
const config = @import("config");
const log = @import("utils").log;
const theme = @import("../theme/theme.zig");
const debug = @import("../debug/debug.zig");
const args = @import("../args/args.zig");

const QApp = qt.QApplication;
const QIcon = qt.QIcon;

pub const Context = struct {
    allocator: std.mem.Allocator,
    argv: [][:0]u8,
    cfg: args.Config,
    app: qt.QApplication,
    start_ns: u64,

    pub fn deinit(self: *Context) void {
        self.app.Delete();
        qt.deinit(self.allocator, self.argv);
    }
};

pub fn init(allocator: std.mem.Allocator, raw_args: anytype) !Context {
    const argv = try qt.init(allocator, raw_args);
    errdefer qt.deinit(allocator, argv);

    const cfg = args.parse(argv);
    const theme_resolved = theme.resolve(allocator, cfg.theme);
    defer if (theme_resolved.allocation) |m| allocator.free(m);

    if (cfg.benchmark_all) debug.mark("qt init");
    const start_ns = if (cfg.start_timer) debug.monotonicNs() else 0;

    var argc: i32 = @intCast(argv.len);
    const app = QApp.New(std.heap.page_allocator, &argc, argv);
    errdefer app.Delete();
    ui.theme.setApp(app);

    if (cfg.benchmark_all) debug.mark("theme apply");
    ui.theme.apply(allocator, theme_resolved.qss, theme.current);

    if (cfg.benchmark_all) debug.mark("config deploy");
    {
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        const config_path = try config.deploy(io, allocator);
        defer allocator.free(config_path);
    }

    if (cfg.benchmark_all) debug.mark("icon theme");
    if (config.detectIconTheme(allocator)) |icon_theme| {
        log.info("icon theme: {s}", .{icon_theme});
        QIcon.SetThemeName(icon_theme);
        allocator.free(icon_theme);
    } else {
        log.info("icon theme: default (Qt resolved)", .{});
    }

    return .{
        .allocator = allocator,
        .argv = argv,
        .cfg = cfg,
        .app = app,
        .start_ns = start_ns,
    };
}
