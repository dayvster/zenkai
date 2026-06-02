const std = @import("std");
const appreader = @import("core/appreader.zig");
const config = @import("config");
const qt = @import("libqt6zig");
const ui = @import("ui/ui.zig");
const log = @import("utils").log;
const theme = @import("theme/theme.zig");

const main_qss = @embedFile("styles/main.qss");

const QApp = qt.QApplication;
const QLabel = qt.QLabel;
const QWidget = qt.QWidget;
const QVBoxLayout = qt.QVBoxLayout;
const QLineEdit = qt.QLineEdit;
const QIcon = qt.QIcon;
const QCloseEvent = qt.QCloseEvent;
const QPalette = qt.QPalette;
const QColor = qt.QColor;
const qpalette = qt.qpalette_enums;

const CLOCK_MONOTONIC: i32 = 1;
const timespec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn clock_gettime(clk_id: i32, ts: *timespec) callconv(.c) i32;

fn monotonicNs() u64 {
    var ts: timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

const bench_enabled = @import("builtin").mode == .Debug;

const Bench = struct { label: []const u8, ns: u64 };
var bench_entries: [32]Bench = undefined;
var bench_count: usize = 0;

fn benchMark(label: []const u8) void {
    if (comptime !bench_enabled) return;
    if (bench_count < bench_entries.len) {
        bench_entries[bench_count] = .{ .label = label, .ns = monotonicNs() };
        bench_count += 1;
    }
}

fn printBenchmarks() void {
    if (comptime !bench_enabled) return;
    if (bench_count < 2) return;
    log.info("benchmark:", .{});
    var total: u64 = 0;
    for (1..bench_count) |i| {
        const delta = bench_entries[i].ns - bench_entries[i - 1].ns;
        total += delta;
        const ms = @as(f64, @floatFromInt(delta)) / std.time.ns_per_ms;
        log.info("  {s}  {d:.2}ms", .{ bench_entries[i - 1].label, ms });
    }
    log.info("  total  {d:.2}ms", .{@as(f64, @floatFromInt(total)) / std.time.ns_per_ms});
}

var search_list: *ui.List = undefined;

fn onSearchTextChanged(_: QLineEdit, text_cstr: [*:0]const u8) callconv(.c) void {
    const text = std.mem.span(text_cstr);
    search_list.setFilter(text);
}

fn onWindowClose(_: QWidget, _: QCloseEvent) callconv(.c) void {
    QApp.Quit();
}

fn setupDarkPalette() void {
    const bg = QColor.New5(0x1a, 0x1b, 0x1e);
    const bg_light = QColor.New5(0x31, 0x32, 0x44);
    const border = QColor.New5(0x45, 0x47, 0x5a);
    const fg = QColor.New5(0xcd, 0xd6, 0xf4);
    const placeholder = QColor.New5(0x6c, 0x70, 0x86);
    const highlight = QColor.New5(0x58, 0x5b, 0x70);
    const accent = QColor.New5(0x89, 0xb4, 0xfa);

    var palette = QPalette.New();
    defer palette.Delete();

    palette.SetColor2(qpalette.ColorRole.Window, bg);
    palette.SetColor2(qpalette.ColorRole.WindowText, fg);
    palette.SetColor2(qpalette.ColorRole.Base, bg_light);
    palette.SetColor2(qpalette.ColorRole.Text, fg);
    palette.SetColor2(qpalette.ColorRole.Button, border);
    palette.SetColor2(qpalette.ColorRole.ButtonText, fg);
    palette.SetColor2(qpalette.ColorRole.Highlight, highlight);
    palette.SetColor2(qpalette.ColorRole.HighlightedText, fg);
    palette.SetColor2(qpalette.ColorRole.PlaceholderText, placeholder);
    palette.SetColor2(qpalette.ColorRole.Light, bg_light);
    palette.SetColor2(qpalette.ColorRole.Accent, accent);

    bg.Delete();
    bg_light.Delete();
    border.Delete();
    fg.Delete();
    placeholder.Delete();
    highlight.Delete();
    accent.Delete();

    QApp.SetPalette(palette);
}

pub fn main(init: std.process.Init) !void {
    const argv = try qt.init(init.gpa, init.minimal.args);
    defer qt.deinit(init.gpa, argv);

    var icon_size: i32 = 32;
    var debug: bool = false;
    var benchmark_all: bool = false;
    var theme_arg: ?[]const u8 = null;
    for (init.minimal.args.vector) |arg_ptr| {
        const arg = std.mem.span(arg_ptr);
        if (std.mem.startsWith(u8, arg, "--size=")) {
            icon_size = std.fmt.parseInt(i32, arg["--size=".len..], 10) catch 32;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            log.verbose = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug = true;
            log.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--theme=")) {
            theme_arg = arg["--theme=".len..];
        } else if (comptime bench_enabled) {
            if (std.mem.eql(u8, arg, "--benchmark-all")) {
                benchmark_all = true;
                log.verbose = true;
            }
        } else if (std.mem.eql(u8, arg, "--no-icons")) {
            ui.List.setNoIcons(true);
        }
    }

    const theme_resolved = theme.resolve(init.gpa, theme_arg);
    defer if (theme_resolved.allocation) |m| init.gpa.free(m);

    if (comptime bench_enabled) {
        if (benchmark_all) benchMark("qt init");
    }
    const start_ns = if (debug) monotonicNs() else 0;

    var argc: i32 = @intCast(argv.len);
    const app = QApp.New(std.heap.page_allocator, &argc, argv);
    defer app.Delete();

    if (benchmark_all) benchMark("effects + palette");

    QApp.SetEffectEnabled2(0, false);
    QApp.SetEffectEnabled2(1, false);
    QApp.SetEffectEnabled2(2, false);
    QApp.SetEffectEnabled2(3, false);
    QApp.SetEffectEnabled2(4, false);
    QApp.SetEffectEnabled2(5, false);
    QApp.SetEffectEnabled2(6, false);

    setupDarkPalette();

    if (benchmark_all) benchMark("stylesheet");

    {
        const qss = try std.mem.concat(init.gpa, u8, &.{ main_qss, theme_resolved.qss });
        defer init.gpa.free(qss);
        app.SetStyleSheet(qss);
    }

    if (benchmark_all) benchMark("config deploy");

    {
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        const config_path = try config.deploy(io, init.gpa);
        defer init.gpa.free(config_path);
    }

    if (benchmark_all) benchMark("icon theme");

    if (config.detectIconTheme(init.gpa)) |icon_theme| {
        log.info("icon theme: {s}", .{icon_theme});
        QIcon.SetThemeName(icon_theme);
        init.gpa.free(icon_theme);
    } else {
        log.info("icon theme: default (Qt resolved)", .{});
    }

    if (benchmark_all) benchMark("reader load");

    var reader = appreader.AppReader.init(init.gpa);
    errdefer reader.deinit();

    reader.load() catch {
        var error_label = QLabel.New3("Error loading desktop files");
        defer error_label.Delete();
        error_label.SetAlignment(@as(i32, 0x8004));
        error_label.SetWindowFlag(2048);
        error_label.SetWindowFlag(262144);
        error_label.SetFixedSize2(300, 80);
        const screen = error_label.Screen();
        const screen_rect = screen.Geometry();
        const x = @divTrunc(screen_rect.Width() - 300, 2);
        const y = @divTrunc(screen_rect.Height() - 80, 2);
        error_label.Move(x, y);
        error_label.Show();
        if (benchmark_all) printBenchmarks();
        _ = QApp.Exec();
        return;
    };

    if (benchmark_all) benchMark("reader scan #1");

    reader.scan() catch {
        var error_label = QLabel.New3("Error parsing desktop files");
        defer error_label.Delete();
        error_label.SetAlignment(@as(i32, 0x8004));
        error_label.SetWindowFlag(2048);
        error_label.SetWindowFlag(262144);
        error_label.SetFixedSize2(300, 80);
        const screen = error_label.Screen();
        const screen_rect = screen.Geometry();
        const x = @divTrunc(screen_rect.Width() - 300, 2);
        const y = @divTrunc(screen_rect.Height() - 80, 2);
        error_label.Move(x, y);
        error_label.Show();
        if (benchmark_all) printBenchmarks();
        _ = QApp.Exec();
        return;
    };

    if (benchmark_all) benchMark("reader scan #2");

    reader.scan() catch {
        var error_label = QLabel.New3("Error parsing desktop files");
        error_label.SetAlignment(@as(i32, 0x8004));
        error_label.SetWindowFlag(2048);
        error_label.SetWindowFlag(262144);
        error_label.SetFixedSize2(300, 80);
        const screen = error_label.Screen();
        const screen_rect = screen.Geometry();
        const x = @divTrunc(screen_rect.Width() - 300, 2);
        const y = @divTrunc(screen_rect.Height() - 80, 2);
        error_label.Move(x, y);
        error_label.Show();
        if (benchmark_all) printBenchmarks();
        return;
    };
    defer reader.deinit();

    if (benchmark_all) benchMark("list init");

    var list = ui.List.init(init.gpa, reader.apps.items, icon_size);
    defer list.deinit();

    if (benchmark_all) benchMark("window setup");

    const win_w: i32 = 600;
    const win_h: i32 = 500;

    var window = QWidget.New2();
    window.SetWindowTitle("zenkai");

    const wt = qt.qnamespace_enums.WindowType;
    window.SetWindowFlags(
        wt.Tool |
            wt.FramelessWindowHint |
            wt.WindowStaysOnTopHint |
            wt.NoDropShadowWindowHint,
    );

    const main_layout = QVBoxLayout.New(window);

    var search_bar = QLineEdit.New2();
    search_bar.SetPlaceholderText("Search apps...");
    search_bar.SetClearButtonEnabled(false);

    list.setFilter("");
    search_list = &list;

    main_layout.AddWidget(search_bar);
    main_layout.AddWidget(list.view);

    window.SetMinimumSize2(win_w, win_h);
    window.SetMaximumSize2(win_w, win_h);

    const screen = window.Screen();
    const screen_rect = screen.Geometry();
    window.SetGeometry(
        @divTrunc(screen_rect.Width() - win_w, 2),
        @divTrunc(screen_rect.Height() - win_h, 2),
        win_w,
        win_h,
    );

    window.OnCloseEvent(onWindowClose);

    search_bar.OnTextChanged(onSearchTextChanged);
    ui.Keyboard.setup(window, &list);

    if (benchmark_all) benchMark("show window");

    window.Show();

    if (debug) {
        const elapsed = @as(f64, @floatFromInt(monotonicNs() - start_ns)) / std.time.ns_per_ms;
        log.info("appeared on screen in {d:.2}ms", .{elapsed});
    }

    if (benchmark_all) printBenchmarks();

    _ = QApp.Exec();
}
