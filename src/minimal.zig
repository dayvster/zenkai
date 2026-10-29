const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const utils = @import("utils");
const args = @import("args/args.zig");
const bootstrap = @import("core/bootstrap.zig");
const loader = @import("core/desktop_loader.zig");
const Item = @import("desktopapp").ListItem;
const benchmark = @import("debug/startup_benchmark.zig");
const clock = @import("debug/debug.zig");
const icons = @import("ui/icon_loader.zig");
const lang = @import("lang");
const theme = @import("theme/theme.zig");
const animation = @import("ui/animation.zig");
const a = std.heap.c_allocator;

var launcher: *Launcher = undefined;

const Launcher = struct {
    window: qt.QWidget,
    search: qt.QLineEdit,
    view: qt.QListView,
    model: qt.QAbstractListModel,
    footer: ?qt.QLabel = null,
    backdrop: ?qt.QWidget = null,
    items: []Item = &.{},
    indices: std.ArrayList(usize) = .empty,
    icon_cache: std.AutoHashMapUnmanaged(usize, qt.QIcon) = .empty,
    painting_row: ?i32 = null,
    no_icons: bool,
    run_mode: bool,
    actions_bar: bool,
    close_on_blur: bool,
    icon_size: i32,
    refresh_timer: ?qt.QTimer = null,
    refresh_after_paint: bool = false,
    show_actions: bool,

    fn deinit(self: *Launcher) void {
        if (self.refresh_timer) |timer| timer.stop();
        self.window.delete();
        self.model.delete();
        if (self.backdrop) |backdrop| backdrop.delete();
        self.clearItems();
        self.indices.deinit(a);
    }

    fn clearItems(self: *Launcher) void {
        var it = self.icon_cache.valueIterator();
        while (it.next()) |icon| icon.delete();
        self.icon_cache.clearAndFree(a);
        for (self.items) |item| {
            a.free(item.name);
            a.free(item.cmd);
            a.free(item.icon);
            if (item.actions.len > 0) loader.freeListItemActions(a, item.actions);
        }
        a.free(self.items);
        self.items = &.{};
    }

    fn setItems(self: *Launcher, items: []Item) void {
        self.model.beginResetModel();
        self.clearItems();
        self.items = items;
        self.indices.clearRetainingCapacity();
        self.model.endResetModel();
        const query = self.search.text(a);
        defer a.free(query);
        self.filter(query);
    }

    fn filter(self: *Launcher, query: []const u8) void {
        self.model.beginResetModel();
        self.indices.clearRetainingCapacity();
        for (self.items, 0..) |item, i| {
            if (matches(item.name, query)) self.indices.append(a, i) catch break;
        }
        self.model.endResetModel();
        self.select(0);
    }

    fn select(self: *Launcher, row: i32) void {
        if (self.indices.items.len == 0) {
            if (self.footer) |footer| footer.setText("Esc  Close");
            return;
        }
        const parent = qt.QModelIndex.new3();
        defer parent.delete();
        const index = self.model.index(@mod(row, @as(i32, @intCast(self.indices.items.len))), 0, parent);
        defer index.delete();
        self.view.setCurrentIndex(index);
        self.view.scrollTo(index, qt.qabstractitemview_enums.ScrollHint.EnsureVisible);
    }

    fn selected(self: *Launcher) ?Item {
        const index = self.view.currentIndex();
        defer index.delete();
        const row = index.row();
        if (row < 0 or row >= self.indices.items.len) return null;
        return self.items[self.indices.items[@intCast(row)]];
    }
};

fn matches(name: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len <= name.len) {
        for (0..name.len - query.len + 1) |i| {
            if (std.ascii.eqlIgnoreCase(name[i..][0..query.len], query)) return true;
        }
    }
    if (query.len < 3 or name.len > 256 or query.len > 256) return false;
    var name_buf: [256]u8 = undefined;
    var query_buf: [256]u8 = undefined;
    const lower_name = std.ascii.lowerString(&name_buf, name);
    const lower_query = std.ascii.lowerString(&query_buf, query);
    return (utils.demerauLevenshteinDistance(a, lower_query, lower_name, 3) catch 3) < 3;
}

fn rowCount(_: qt.QAbstractListModel, parent: qt.QModelIndex) callconv(.c) i32 {
    return if (parent.isValid()) 0 else @intCast(launcher.indices.items.len);
}

fn data(_: qt.QAbstractListModel, index: qt.QModelIndex, role: i32) callconv(.c) qt.QVariant {
    const row = index.row();
    if (row < 0 or row >= launcher.indices.items.len) return qt.QVariant.new();
    const i = launcher.indices.items[@intCast(row)];
    const item = launcher.items[i];
    if (role == 0) return qt.QVariant.new24(item.name);
    if (role == 1 and !launcher.no_icons) {
        if (launcher.icon_cache.get(i)) |icon| return icon.toQVariant();
        // Qt asks every row for size hints. Resolve native icons only when painted.
        if (launcher.painting_row != row) return qt.QVariant.new();
        const started = benchmark.iconStarted();
        defer benchmark.iconFinished(started);
        if (launcher.icon_cache.count() >= 64) {
            var cached = launcher.icon_cache.valueIterator();
            while (cached.next()) |icon| icon.delete();
            launcher.icon_cache.clearRetainingCapacity();
        }
        const icon = icons.load(item.icon);
        launcher.icon_cache.put(a, i, icon) catch {
            icon.delete();
            return qt.QVariant.new();
        };
        return icon.toQVariant();
    }
    if (role == 13) {
        const size = qt.QSize.new4(0, @max(40, launcher.icon_size + 12));
        defer size.delete();
        return qt.QVariant.new30(size);
    }
    return qt.QVariant.new();
}

fn paint(delegate: qt.QStyledItemDelegate, painter: qt.QPainter, option: qt.QStyleOptionViewItem, index: qt.QModelIndex) callconv(.c) void {
    launcher.painting_row = index.row();
    defer launcher.painting_row = null;
    delegate.superPaint(painter, option, index);
}

fn painted(view: qt.QListView, event: qt.QPaintEvent) callconv(.c) void {
    view.superPaintEvent(event);
    if (launcher.refresh_after_paint) {
        launcher.refresh_after_paint = false;
        launcher.refresh_timer.?.start(0);
    }
}

fn changed(_: qt.QLineEdit, text: [*:0]const u8) callconv(.c) void {
    launcher.filter(std.mem.span(text));
}

fn launchCommand(command: []const u8, shell: bool) void {
    if (command.len == 0) return;
    if (shell) {
        utils.execute(command, a) catch return;
    } else {
        const argv = utils.tokenizeCommandLine(a, command) catch return;
        defer {
            for (argv) |arg| a.free(arg);
            a.free(argv);
        }
        utils.executeArgv(a, argv) catch return;
    }
    animation.animateFadeOutAndQuit();
}

fn launchSelected() void {
    if (launcher.run_mode) {
        const command = launcher.search.text(a);
        defer a.free(command);
        launchCommand(command, true);
    } else if (launcher.selected()) |item| launchCommand(item.cmd, item.desktop_app_idx == null);
}

fn clicked(_: qt.QListView, _: qt.QModelIndex) callconv(.c) void {
    launchSelected();
}

fn selected(_: qt.QListView, _: qt.QModelIndex, _: qt.QModelIndex) callconv(.c) void {
    const footer = launcher.footer orelse return;
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    text.writer.writeAll("Enter  Open    Esc  Close") catch return;
    if (launcher.actions_bar) {
        if (launcher.selected()) |item| {
            for (item.actions[0..@min(10, item.actions.len)], 0..) |action, i| {
                text.writer.print("    Ctrl+{d}  {s}", .{ @mod(i + 1, 10), action.name }) catch break;
            }
        }
    }
    footer.setText(text.written());
}

fn key(edit: qt.QLineEdit, event: qt.QKeyEvent) callconv(.c) void {
    const keys = qt.qnamespace_enums.Key;
    const index = launcher.view.currentIndex();
    defer index.delete();
    const row = index.row();
    if (event.modifiers() & qt.qnamespace_enums.KeyboardModifier.ControlModifier != 0) {
        if (event.key() >= keys.Key_0 and event.key() <= keys.Key_9) {
            const action_index: usize = @intCast(@mod(event.key() - keys.Key_1, 10));
            if (launcher.selected()) |item| {
                if (action_index < item.actions.len) launchCommand(item.actions[action_index].exec, false);
            }
            return;
        }
        if (event.key() == keys.Key_L) {
            edit.selectAll();
            return;
        }
    }
    switch (event.key()) {
        keys.Key_Escape => qt.QApplication.quit(),
        keys.Key_Return, keys.Key_Enter => launchSelected(),
        keys.Key_Up => launcher.select(row - 1),
        keys.Key_Down => launcher.select(row + 1),
        keys.Key_PageUp => launcher.select(row - 8),
        keys.Key_PageDown => launcher.select(row + 8),
        else => edit.superKeyPressEvent(event),
    }
}

fn stateChanged(_: qt.QApplication, state: i32) callconv(.c) void {
    if (launcher.close_on_blur and state != qt.qnamespace_enums.ApplicationState.ApplicationActive) qt.QApplication.quit();
}

fn backdropClicked(_: qt.QWidget, _: qt.QMouseEvent) callconv(.c) void {
    qt.QApplication.quit();
}

fn refresh(timer: qt.QTimer) callconv(.c) void {
    timer.stop();
    benchmark.refreshStarted();
    const items = loader.load(a, false, launcher.show_actions, launcher.actions_bar) catch {
        benchmark.failed();
        return;
    };
    launcher.setItems(items);
    if (!launcher.show_actions and !launcher.actions_bar and items.len > 0) loader.saveCache(a, items);
    loader.freeDesktopApps();
    benchmark.dataReady(items.len);
}

extern fn setenv([*:0]const u8, [*:0]const u8, i32) i32;

pub fn main(init: std.process.Init) !void {
    benchmark.entry_ns = clock.monotonicNs();
    var no_icons = true;
    {
        var it = try init.minimal.args.iterateAllocator(a);
        defer it.deinit();
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--icons")) no_icons = false;
            if (std.mem.eql(u8, arg, "--no-icons")) no_icons = true;
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                std.debug.print("Minimal launcher: no plugins, previews, action pane, or window management.\nIcons and animations are off by default; --icons enables icons.\n\n", .{});
                var lines = std.mem.splitScalar(u8, args.help, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trimStart(u8, line, " ");
                    if (!unsupportedOption(trimmed) and !std.mem.startsWith(u8, trimmed, "--no-file-previews") and !std.mem.startsWith(u8, trimmed, "--no-plugins") and !std.mem.startsWith(u8, trimmed, "--no-window-switcher")) std.debug.print("{s}\n", .{line});
                }
                return;
            }
            if (unsupportedOption(arg)) {
                std.debug.print("{s} requires the full build of Zenkai.\n", .{arg});
                return error.UnsupportedMinimalOption;
            }
        }
    }
    if (builtin.os.tag == .linux) {
        var fullscreen = false;
        var monitor = false;
        var it = try init.minimal.args.iterateAllocator(a);
        defer it.deinit();
        while (it.next()) |arg| {
            fullscreen = fullscreen or std.mem.eql(u8, arg, "--fullscreen");
            monitor = monitor or std.mem.startsWith(u8, arg, "--monitor=");
        }
        if (fullscreen and monitor and std.c.getenv("WAYLAND_DISPLAY") != null) _ = setenv("QT_QPA_PLATFORM", "xcb", 1);
    }
    var ctx = try bootstrap.initMinimal(a, init.minimal.args);
    defer ctx.deinit();
    benchmark.icons_enabled = !no_icons;
    if (ctx.cfg.list_themes) {
        for (theme.theme_entries) |entry| std.debug.print("{s:<26} {s}\n", .{ entry.name, entry.desc });
        return;
    }
    if (ctx.cfg.list_monitors) {
        const screens = qt.QApplication.screens(a);
        defer a.free(screens);
        for (screens, 0..) |screen, i| {
            const name = screen.name(a);
            defer a.free(name);
            const rect = screen.geometry();
            defer rect.delete();
            std.debug.print("{d}: {s} {d}x{d}+{d}+{d}\n", .{ i, name, rect.width(), rect.height(), rect.x(), rect.y() });
        }
        return;
    }
    benchmark.pluginsDone(0);
    @import("dapp_parser").setLocale(ctx.cfg.language);
    const window = qt.QWidget.new2();
    const search = qt.QLineEdit.new(window);
    const view = qt.QListView.new(window);
    const model = qt.QAbstractListModel.new();
    var state: Launcher = .{
        .window = window,
        .search = search,
        .view = view,
        .model = model,
        .no_icons = no_icons,
        .run_mode = ctx.cfg.run_mode,
        .actions_bar = ctx.cfg.actions_bottombar,
        .show_actions = ctx.cfg.show_actions,
        .close_on_blur = ctx.visual.close_on_focus_out,
        .icon_size = ctx.visual.icon_size,
    };
    launcher = &state;
    defer state.deinit();
    const flags = qt.qnamespace_enums.WindowType;
    window.setWindowFlags(flags.FramelessWindowHint | flags.WindowStaysOnTopHint | flags.NoDropShadowWindowHint | (if (ctx.visual.fullscreen) @as(i32, 0) else flags.Tool));
    window.setObjectName("mainWindow");
    window.setWindowTitle(lang.get().window_title);
    search.setObjectName("searchbarInput");
    search.setPlaceholderText(if (ctx.cfg.run_mode) "Type a command to run..." else lang.get().search_placeholder);
    search.onTextChanged(changed);
    search.onKeyPressEvent(key);
    const layout = qt.QVBoxLayout.new(window);
    layout.setContentsMargins(ctx.visual.layout_margin, ctx.visual.layout_margin, ctx.visual.layout_margin, ctx.visual.layout_margin);
    layout.setSpacing(ctx.visual.layout_spacing);
    layout.addWidget(search);
    view.setObjectName("appList");
    view.setUniformItemSizes(true);
    view.setFocusPolicy(qt.qnamespace_enums.FocusPolicy.NoFocus);
    view.setHorizontalScrollBarPolicy(qt.qnamespace_enums.ScrollBarPolicy.ScrollBarAlwaysOff);
    const size = qt.QSize.new4(ctx.visual.icon_size, ctx.visual.icon_size);
    defer size.delete();
    view.setIconSize(size);
    model.onRowCount(rowCount);
    model.onData(data);
    view.setModel(model);
    const delegate = qt.QStyledItemDelegate.new2(view);
    delegate.onPaint(paint);
    view.setItemDelegate(delegate);
    view.onDoubleClicked(clicked);
    view.onCurrentChanged(selected);
    view.onPaintEvent(painted);
    layout.addWidget2(view, 1);
    if (!ctx.cfg.no_bottom_bar) {
        const footer = qt.QLabel.new5("Enter  Open    Esc  Close", window);
        footer.setObjectName("bottomBar");
        footer.setTextFormat(qt.qnamespace_enums.TextFormat.PlainText);
        footer.setMargin(10);
        layout.addWidget(footer);
        state.footer = footer;
    }
    const cursor = qt.QCursor.pos();
    defer cursor.delete();
    var screen = qt.QApplication.screenAt(cursor);
    if (screen.ptr == null) screen = qt.QApplication.primaryScreen();
    if (ctx.visual.monitor) |monitor| {
        const screens = qt.QApplication.screens(a);
        defer a.free(screens);
        if (screens.len > 0) screen = screens[@min(@as(usize, @intCast(@max(0, monitor))), screens.len - 1)];
    }
    const rect = screen.geometry();
    defer rect.delete();
    const width = @max(200, ctx.visual.window_width);
    const height = if (ctx.cfg.run_mode) 140 else @max(120, ctx.visual.window_height);
    window.resize(width, height);
    window.move(rect.x() + @divTrunc(rect.width() - width, 2), rect.y() + @divTrunc(rect.height() - height, 2));
    if (ctx.visual.show_backdrop) {
        const backdrop = qt.QWidget.new2();
        backdrop.setWindowFlags(flags.Tool | flags.FramelessWindowHint | flags.WindowDoesNotAcceptFocus | flags.WindowStaysOnBottomHint);
        backdrop.setAttribute2(qt.qnamespace_enums.WidgetAttribute.WA_TranslucentBackground, true);
        backdrop.setGeometry(rect.x(), rect.y(), rect.width(), rect.height());
        backdrop.onMousePressEvent(backdropClicked);
        backdrop.show();
        state.backdrop = backdrop;
    }
    const menus = try args.parseMenus(a, ctx.argv);
    defer args.deinitMenuEntries(a, menus);
    const skip_desktop = menus.len > 0 or ctx.cfg.no_dapps or ctx.cfg.run_mode;
    var needs_refresh = !skip_desktop;
    benchmark.cache_state = if (skip_desktop) "skipped" else "miss";
    if (menus.len > 0) {
        const items = try a.alloc(Item, menus.len);
        for (menus, 0..) |entry, i| items[i] = .{
            .name = try a.dupe(u8, entry.name),
            .cmd = try a.dupe(u8, entry.cmd),
            .icon = try a.dupe(u8, entry.icon),
        };
        state.setItems(items);
    } else if (!skip_desktop and !ctx.cfg.show_actions and !ctx.cfg.actions_bottombar) {
        if (loader.loadCache(a)) |items| {
            state.setItems(items);
            needs_refresh = items.len == 0 or !loader.cacheIsFresh(a);
            benchmark.cache_state = if (needs_refresh) "stale" else "fresh";
        }
    }
    if (!needs_refresh) benchmark.dataReady(state.items.len);
    benchmark.attach(ctx.app, window, view.viewport(), search);
    defer benchmark.deinit();
    animation.setConfig(.{
        .enabled = !ctx.visual.no_animations and !benchmark.enabled and (ctx.cfg.animation_interval != null or ctx.cfg.animation_easing != null),
        .interval_ms = ctx.visual.animation_interval,
        .easing = if (ctx.visual.animation_easing) |name| animation.EasingType.fromName(name) else .OutCubic,
    });
    animation.setWindowWidget(window);
    if (needs_refresh) {
        const timer = qt.QTimer.new2(window);
        timer.setSingleShot(true);
        timer.onTimeout(refresh);
        state.refresh_timer = timer;
        state.refresh_after_paint = true;
    }
    if (ctx.visual.fullscreen) {
        window.setGeometry(rect.x(), rect.y(), rect.width(), rect.height());
        window.showFullScreen();
    } else window.show();
    window.activateWindow();
    search.setFocus();
    animation.animateFadeIn(window);
    benchmark.showReturned();
    ctx.app.onApplicationStateChanged(stateChanged);
    if (ctx.cfg.start_timer) utils.log.info("appeared on screen in {d:.2}ms", .{@as(f64, @floatFromInt(clock.monotonicNs() - benchmark.entry_ns)) / std.time.ns_per_ms});
    if (ctx.cfg.start_timer and ctx.cfg.theme_reloader) @import("ui/styles_watcher.zig").start(a);
    _ = qt.QApplication.exec();
}

test "minimal search keeps case-insensitive matching and typo tolerance" {
    try std.testing.expect(matches("Visual Studio Code", "CODE"));
    try std.testing.expect(matches("Firefox", "Firefx"));
    try std.testing.expect(matches("Terminal", ""));
    try std.testing.expect(!matches("Terminal", "brave"));
}

fn unsupportedOption(arg: []const u8) bool {
    for ([_][]const u8{ "--plugin=", "--file-previews", "--clipboard=", "--url-handler=", "--window-switcher" }) |prefix| {
        if (std.mem.startsWith(u8, arg, prefix)) return true;
    }
    return false;
}

test "minimal list filters, navigates and replaces owned results" {
    var argc: i32 = 1;
    var arg = "zenkai".*;
    var argv = [_][:0]u8{&arg};
    const app = qt.QApplication.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();
    const window = qt.QWidget.new2();
    var state: Launcher = .{
        .window = window,
        .search = qt.QLineEdit.new(window),
        .view = qt.QListView.new(window),
        .model = qt.QAbstractListModel.new(),
        .no_icons = true,
        .run_mode = false,
        .actions_bar = false,
        .show_actions = false,
        .close_on_blur = false,
        .icon_size = 32,
    };
    launcher = &state;
    defer state.deinit();
    state.model.onRowCount(rowCount);
    state.model.onData(data);
    state.view.setModel(state.model);
    const items = try a.alloc(Item, 3);
    for ([_][]const u8{ "Firefox", "Terminal", "Files" }, 0..) |name, i| items[i] = .{
        .name = try a.dupe(u8, name),
        .cmd = try a.dupe(u8, ""),
        .icon = try a.dupe(u8, ""),
    };
    state.setItems(items);
    state.select(-1);
    try std.testing.expectEqualStrings("Files", state.selected().?.name);
    state.filter("TERM");
    try std.testing.expectEqual(@as(usize, 1), state.indices.items.len);
    try std.testing.expectEqualStrings("Terminal", state.selected().?.name);
    state.filter("missing application");
    try std.testing.expect(state.selected() == null);
    state.setItems(&.{});
    try std.testing.expect(state.items.len == 0 and state.indices.items.len == 0);
}
