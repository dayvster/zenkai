const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const config = @import("config");
const lang = @import("lang");

const List = @import("list.zig").List;
const ListItem = @import("list.zig").ListItem;
const ListItemAction = @import("list.zig").ListItemAction;
const Keyboard = @import("keyboard.zig").Keyboard;
const BottomBar = @import("bottombar.zig").BottomBar;
const SearchBar = @import("search_bar.zig").SearchBar;
const animation = @import("animation.zig");

const QApp = qt.QApplication;
const QWidget = qt.QWidget;
const QVBoxLayout = qt.QVBoxLayout;
const QCloseEvent = qt.QCloseEvent;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

var g_window: *Window = undefined;
var g_close_on_focus_out: bool = false;
var g_fullscreen: bool = false;
var g_monitor: ?i32 = null;
var g_blur_timer: qt.QTimer = undefined;
var g_mouse_left_at: i64 = 0;
var g_backdrop: ?QWidget = null;
var g_backdrop_geo: [4]i32 = .{ 0, 0, 0, 0 };

fn nanoTimestamp() i64 {
    if (comptime builtin.os.tag == .windows) {
        return @intCast(GetTickCount64() * std.time.ns_per_ms);
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
    }
}

pub fn clampMonitorIndex(idx: i32, count: usize) usize {
    if (count == 0) return 0;
    const i = if (idx < 0) 0 else @as(usize, @intCast(idx));
    return @min(i, count - 1);
}

test "clampMonitorIndex" {
    try std.testing.expectEqual(@as(usize, 0), clampMonitorIndex(-1, 3));
    try std.testing.expectEqual(@as(usize, 0), clampMonitorIndex(-100, 3));
    try std.testing.expectEqual(@as(usize, 0), clampMonitorIndex(0, 3));
    try std.testing.expectEqual(@as(usize, 1), clampMonitorIndex(1, 3));
    try std.testing.expectEqual(@as(usize, 2), clampMonitorIndex(2, 3));
    try std.testing.expectEqual(@as(usize, 2), clampMonitorIndex(999, 3));
    try std.testing.expectEqual(@as(usize, 0), clampMonitorIndex(0, 1));
    try std.testing.expectEqual(@as(usize, 0), clampMonitorIndex(5, 1));
    try std.testing.expectEqual(@as(usize, 0), clampMonitorIndex(-3, 0));
    try std.testing.expectEqual(@as(usize, 0), clampMonitorIndex(0, 0));
    try std.testing.expectEqual(@as(usize, 0), clampMonitorIndex(2, 0));
}

test "footer stays visible after rebuilding actions and is omitted only when requested" {
    var argc: i32 = 1;
    var arg = [_:0]u8{ 'z', 'e', 'n', 'k', 'a', 'i' };
    var argv = [_][:0]u8{arg[0.. :0]};
    const app = QApp.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();
    app.setStyleSheet(@embedFile("../styles/main.qss") ++ @embedFile("../styles/dark.theme.qss"));

    for ([_]bool{ false, true }) |hide_bar| {
        var window: Window = undefined;
        window.init(std.testing.allocator, &.{}, .{ .no_animations = true, .file_previews = hide_bar }, hide_bar, true, app);
        defer window.deinit();
        window.widget.show();
        QApp.processEvents();
        try std.testing.expectEqual(!hide_bar, window.bottom_bar != null);
        try std.testing.expectEqual(hide_bar, window.preview != null);
        onItemFocused(0, &.{});
        if (window.preview) |preview| try std.testing.expect(preview.widget.isHidden());
        togglePreview();
        try std.testing.expectEqual(!hide_bar, window.preview_enabled);
        try std.testing.expect(window.preview != null);
        togglePreview();
        try std.testing.expectEqual(hide_bar, window.preview_enabled);
        if (window.bottom_bar) |*bar| {
            bar.setDefaultActions();
            QApp.processEvents();
            try std.testing.expect(bar.container.isVisible());
            try std.testing.expectEqual(BottomBar.minimum_height, bar.container.height());
            for (bar.items) |item| try std.testing.expect(item.isVisible());

            const actions: [10]ListItemAction = @splat(.{ .name = "An action with a long descriptive label", .exec = "", .icon = "" });
            bar.setItemActions(&actions);
            QApp.processEvents();
            try std.testing.expect(bar.menu_button != null);
            try std.testing.expectEqual(@as(usize, 2), bar.items.len);
            for (bar.items) |item| {
                try std.testing.expect(item.isVisible());
                try std.testing.expect(item.x() + item.width() <= bar.container.width());
            }
            if (std.c.getenv("ZENKAI_UI_PREVIEW")) |path| {
                const preview = window.widget.grab();
                defer preview.delete();
                try std.testing.expect(preview.save(std.mem.sliceTo(path, 0)));
            }
            bar.setDefaultActions();
            QApp.processEvents();
            try std.testing.expect(bar.menu_button != null);
            for (bar.items) |item| try std.testing.expect(item.isVisible());
        }
    }
}

fn onAppStateChanged(_: QApp, state: i32) callconv(.c) void {
    if (!g_close_on_focus_out) return;
    if (state == 2) {
        const elapsed = nanoTimestamp() - g_mouse_left_at;
        if (elapsed > 100_000_000) {
            g_blur_timer.start(200);
        }
    } else if (state == 4) {
        g_blur_timer.stop();
    }
}

fn onLeaveWidget(_: QWidget, _: qt.QEvent) callconv(.c) void {
    g_mouse_left_at = nanoTimestamp();
}

fn onBlurTimerTimeout(_: qt.QTimer) callconv(.c) void {
    if (@import("action_menu.zig").isOpen()) return;
    if (@import("file_actions.zig").isOpen()) return;
    QApp.quit();
}

fn onBackdropClick(_: qt.QWidget, _: qt.QMouseEvent) callconv(.c) void {
    QApp.quit();
}

fn onBackdropMove(_: qt.QWidget, _: qt.QMoveEvent) callconv(.c) void {
    if (g_backdrop) |bd| {
        bd.setGeometry(g_backdrop_geo[0], g_backdrop_geo[1], g_backdrop_geo[2], g_backdrop_geo[3]);
    }
}

fn onSearchDebounced(text: []const u8) void {
    if (@import("file_actions.zig").isOpen()) return;
    g_window.list.setFilter(text);
    if (g_window.list.plugin_manager) |pm| {
        pm.dispatchIdle();
    }
}

fn onHttpComplete() void {
    if (@import("file_actions.zig").isOpen()) return;
    if (g_window.list.plugin_manager) |pm| {
        pm.dispatchIdle();
        if (pm.pending_query) |query| {
            pm.pending_query = null;
            defer pm.allocator.free(query);
            onQueryRequested(query);
        }
    }
}

fn onQueryRequested(text: []const u8) void {
    g_window.search_bar.setText(text);
    if (g_window.search_bar.debounce_timer) |timer| timer.stop();
    onSearchDebounced(text);
    g_window.list.selectFirst();
    g_window.search_bar.focus();
}

pub fn togglePreview() void {
    g_window.preview_enabled = !g_window.preview_enabled;
    if (g_window.preview_enabled and g_window.preview == null) {
        const content = g_window.list.view.parentWidget();
        g_window.preview = @import("file_preview.zig").Preview.init(content);
        g_window.preview.?.widget.setFixedWidth(@min(270, @divTrunc(g_window.widget.width(), 2)));
        content.layout().addWidget(g_window.preview.?.widget);
    }
    onItemFocused(0, List.currentItemActions());
}

fn onItemFocused(_: usize, actions: []const ListItemAction) void {
    if (g_window.preview) |*preview| {
        const entry = g_window.list.selectedEntry();
        const path = if (entry != null and entry.? == .plugin)
            g_window.list.plugin_results.items[entry.?.plugin].preview_path
        else
            null;
        preview.select(if (g_window.preview_enabled) path else null);
    }
    if (g_window.bottom_bar) |*bar| {
        if (actions.len > 0) {
            bar.setItemActions(actions);
        } else {
            bar.setDefaultActions();
        }
    }
}

fn onWindowClose(_: QWidget, _: QCloseEvent) callconv(.c) void {
    QApp.quit();
}

fn closeBackdrop() void {
    if (g_backdrop) |bd| {
        bd.delete();
        g_backdrop = null;
    }
}

pub const Window = struct {
    allocator: std.mem.Allocator,
    widget: QWidget,
    search_bar: SearchBar,
    list: List,
    bottom_bar: ?BottomBar,
    preview: ?@import("file_preview.zig").Preview = null,
    preview_enabled: bool = false,
    owned_items: ?[]ListItem = null,

    pub fn init(
        self: *Window,
        allocator: std.mem.Allocator,
        items: []const ListItem,
        vis: config.VisualConfig,
        no_bottom_bar: bool,
        no_icons: bool,
        app: QApp,
    ) void {
        List.setNoIcons(no_icons);

        const win_w: i32 = @max(vis.window_width, 200);
        const win_h: i32 = @max(vis.window_height, 120);

        const wt = qt.qnamespace_enums.WindowType;

        const cursor_pos = qt.QCursor.pos();
        const cursor_screen = QApp.screenAt(cursor_pos);

        const target_screen = if (vis.monitor) |idx| blk: {
            const screens = QApp.screens(allocator);
            defer allocator.free(screens);
            if (screens.len == 0) break :blk cursor_screen;
            const i = clampMonitorIndex(idx, screens.len);
            break :blk screens[i];
        } else cursor_screen;

        const screen_rect = target_screen.geometry();
        const screen_w = screen_rect.width();
        const screen_h = screen_rect.height();

        if (vis.show_backdrop) {
            const bd = QWidget.new2();
            {
                var buf: [256]u8 = undefined;
                const title = lang.get().backdrop_title;
                const len = @min(title.len, buf.len - 1);
                @memcpy(buf[0..len], title[0..len]);
                buf[len] = 0;
                bd.setWindowTitle(buf[0..len]);
            }
            bd.setWindowFlags(
                wt.Tool |
                    wt.FramelessWindowHint |
                    wt.BypassWindowManagerHint |
                    wt.NoDropShadowWindowHint |
                    wt.WindowDoesNotAcceptFocus |
                    wt.WindowStaysOnBottomHint,
            );
            bd.setAttribute2(qt.qnamespace_enums.WidgetAttribute.WA_TranslucentBackground, true);
            bd.setAttribute2(qt.qnamespace_enums.WidgetAttribute.WA_NoSystemBackground, true);

            g_backdrop_geo = .{ screen_rect.x(), screen_rect.y(), screen_w, screen_h };
            bd.setGeometry(g_backdrop_geo[0], g_backdrop_geo[1], g_backdrop_geo[2], g_backdrop_geo[3]);
            bd.setFixedSize2(screen_w, screen_h);
            bd.onMousePressEvent(onBackdropClick);
            bd.onMoveEvent(onBackdropMove);
            g_backdrop = bd;
            bd.show();
        }

        const is_launchpad = if (vis.theme) |t| std.mem.eql(u8, t, "launchpad") else false;

        if (vis.fullscreen) {
            const cp = target_screen.geometry();
            qt.QCursor.setPos(cp.x() + @divTrunc(cp.width(), 2), cp.y() + @divTrunc(cp.height(), 2));
        }

        var window = QWidget.new2();
        window.setObjectName("mainWindow");
        {
            var buf: [256]u8 = undefined;
            const title = lang.get().window_title;
            const len = @min(title.len, buf.len - 1);
            @memcpy(buf[0..len], title[0..len]);
            buf[len] = 0;
            window.setWindowTitle(buf[0..len]);
        }

        window.setWindowFlags(blk: {
            var flags: i32 = wt.FramelessWindowHint | wt.WindowStaysOnTopHint | wt.NoDropShadowWindowHint;
            if (!vis.fullscreen) flags |= wt.Tool;
            break :blk flags;
        });

        const main_layout = QVBoxLayout.new(window);
        main_layout.setContentsMargins(vis.layout_margin, vis.layout_margin, vis.layout_margin, vis.layout_margin);
        main_layout.setSpacing(vis.layout_spacing);

        var search_bar = SearchBar.init(window, 150);
        search_bar.on_debounced = onSearchDebounced;

        if (is_launchpad) {
            search_bar.widget.setMaximumWidth(470);
            main_layout.addWidget3(search_bar.widget, 0, qt.qnamespace_enums.AlignmentFlag.AlignHCenter);
        } else {
            main_layout.addWidget(search_bar.widget);
        }

        var list = List.fromItems(allocator, items, vis.icon_size);
        list.adoptGList();

        const content = QWidget.new(window);
        const content_layout = qt.QHBoxLayout.new(content);
        content_layout.setContentsMargins(0, 0, 0, 0);
        content_layout.setSpacing(0);
        content_layout.addWidget(list.view);
        main_layout.addWidget(content);

        self.* = .{
            .allocator = allocator,
            .widget = window,
            .search_bar = search_bar,
            .list = list,
            .bottom_bar = null,
            .preview_enabled = vis.file_previews,
        };

        self.list.adoptGList();
        if (vis.file_previews) {
            self.preview = @import("file_preview.zig").Preview.init(content);
            self.preview.?.widget.setFixedWidth(@min(270, @divTrunc(win_w, 2)));
            content_layout.addWidget(self.preview.?.widget);
        }
        List.setOnItemFocused(onItemFocused);
        self.list.on_query_requested = onQueryRequested;
        self.search_bar.setup();

        if (!no_bottom_bar) {
            self.bottom_bar = BottomBar.init(allocator, window, vis);
            self.bottom_bar.?.setup(&self.list);
            self.bottom_bar.?.setDefaultActions();
            List.setOnItemFocused(onItemFocused);
            main_layout.addWidget(self.bottom_bar.?.container);
        }

        window.setMinimumSize2(win_w, win_h);
        window.setMaximumSize2(win_w, win_h);

        window.setGeometry(
            screen_rect.x() + @divTrunc(screen_w - win_w, 2),
            screen_rect.y() + @divTrunc(screen_h - win_h, 2),
            win_w,
            win_h,
        );

        const wa = qt.qnamespace_enums.WidgetAttribute;
        const fade_h: i32 = 40;
        var fade = QWidget.new(window);
        fade.setObjectName("listFade");
        fade.setFixedHeight(fade_h);
        if (no_bottom_bar) {
            fade.setGeometry(0, win_h - fade_h, win_w, fade_h);
        } else {
            fade.setGeometry(vis.layout_margin, win_h - vis.layout_margin - BottomBar.minimum_height - fade_h, win_w - 2 * vis.layout_margin, fade_h);
        }
        fade.raise();
        fade.setAttribute2(wa.WA_TransparentForMouseEvents, true);

        g_window = self;
        @import("file_actions.zig").parent = window;
        @import("http.zig").on_complete = onHttpComplete;
        g_close_on_focus_out = vis.close_on_focus_out;
        g_fullscreen = vis.fullscreen;
        g_monitor = vis.monitor;
        g_mouse_left_at = nanoTimestamp();
        g_blur_timer = qt.QTimer.new();
        g_blur_timer.onTimeout(onBlurTimerTimeout);

        {
            var anim_cfg = animation.AnimationConfig{
                .enabled = !vis.no_animations,
                .interval_ms = vis.animation_interval,
            };
            if (vis.animation_easing) |easing_name| {
                anim_cfg.easing = animation.EasingType.fromName(easing_name);
            }
            animation.setConfig(anim_cfg);
            animation.setWindowWidget(window);
        }

        window.onCloseEvent(onWindowClose);
        window.onLeaveEvent(onLeaveWidget);
        app.onApplicationStateChanged(onAppStateChanged);
        Keyboard.setup(window, &self.list, self.search_bar.widget);
    }

    pub fn setOwnedItems(self: *Window, items: []ListItem) void {
        self.list.invalidateIcons();
        if (self.owned_items) |old_items| {
            for (old_items) |item| {
                self.allocator.free(item.icon);
                self.allocator.free(item.cmd);
                self.allocator.free(item.name);
                if (item.actions.len > 0) {
                    for (item.actions) |action| {
                        self.allocator.free(action.name);
                        self.allocator.free(action.exec);
                        self.allocator.free(action.icon);
                    }
                    self.allocator.free(item.actions);
                }
            }
            self.allocator.free(old_items);
        }
        self.owned_items = items;
        self.list.source = .{ .items = items };
        self.list.setFilter("");
    }

    pub fn show(self: *Window) void {
        if (animation.config().enabled) {
            self.widget.setWindowOpacity(0.0);
        }
        if (g_fullscreen) {
            if (g_monitor) |idx| {
                const screens = QApp.screens(self.allocator);
                defer self.allocator.free(screens);
                if (screens.len > 0) {
                    const i = clampMonitorIndex(idx, screens.len);
                    const geo = screens[i].geometry();
                    qt.QCursor.setPos(geo.x() + @divTrunc(geo.width(), 2), geo.y() + @divTrunc(geo.height(), 2));
                    self.widget.setGeometry(geo.x(), geo.y(), geo.width(), geo.height());
                }
            }
            self.widget.showFullScreen();
        } else {
            self.widget.show();
        }
        self.widget.raise();
        animation.animateFadeIn(self.widget);
    }

    pub fn exec() void {
        _ = QApp.exec();
    }

    pub fn deinit(self: *Window) void {
        @import("file_actions.zig").parent = null;
        if (self.preview) |*preview| preview.deinit();
        @import("http.zig").deinit();
        List.setOnItemFocused(null);
        g_blur_timer.stop();
        g_blur_timer.delete();
        closeBackdrop();
        self.search_bar.deinit();
        self.list.deinit();
        if (self.bottom_bar) |*bar| bar.deinit();
        if (self.owned_items) |items| {
            for (items) |item| {
                self.allocator.free(item.icon);
                self.allocator.free(item.cmd);
                self.allocator.free(item.name);
                if (item.actions.len > 0) {
                    for (item.actions) |a| {
                        self.allocator.free(a.name);
                        self.allocator.free(a.exec);
                        self.allocator.free(a.icon);
                    }
                    self.allocator.free(item.actions);
                }
            }
            self.allocator.free(items);
        }
        self.widget.delete();
    }
};
