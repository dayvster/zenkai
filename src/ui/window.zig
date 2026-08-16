const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");
const lang = @import("lang");

const List = @import("list.zig").List;
const ListItem = @import("list.zig").ListItem;
const Keyboard = @import("keyboard.zig").Keyboard;
const BottomBar = @import("bottombar.zig").BottomBar;
const SearchBar = @import("search_bar.zig").SearchBar;
const animation = @import("animation.zig");

const QApp = qt.QApplication;
const QWidget = qt.QWidget;
const QVBoxLayout = qt.QVBoxLayout;
const QCloseEvent = qt.QCloseEvent;

var g_window: *Window = undefined;
var g_close_on_focus_out: bool = false;
var g_fullscreen: bool = false;
var g_monitor: ?i32 = null;
var g_blur_timer: qt.QTimer = undefined;
var g_mouse_left_at: i64 = 0;
var g_backdrop: ?QWidget = null;
var g_backdrop_geo: [4]i32 = .{ 0, 0, 0, 0 };

fn nanoTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
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
    g_window.list.setFilter(text);
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
        const win_h: i32 = @max(vis.window_height, 200);

        const wt = qt.qnamespace_enums.WindowType;

        const cursor_pos = qt.QCursor.pos();
        const cursor_screen = QApp.screenAt(cursor_pos);

        const target_screen = if (vis.monitor) |idx| blk: {
            const screens = QApp.screens(allocator);
            defer allocator.free(screens);
            const i = @min(@max(@as(usize, @intCast(idx)), 0), screens.len - 1);
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

        main_layout.addWidget(list.view);

        self.* = .{
            .allocator = allocator,
            .widget = window,
            .search_bar = search_bar,
            .list = list,
            .bottom_bar = null,
        };

        self.list.adoptGList();
        self.search_bar.setup();

        if (!no_bottom_bar) {
            self.bottom_bar = BottomBar.init(allocator, window, vis);
            self.bottom_bar.?.setup(&self.list);
            self.bottom_bar.?.setDefaultActions();
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
            fade.setGeometry(vis.layout_margin, win_h - vis.layout_margin - 28 - fade_h, win_w - 2 * vis.layout_margin, fade_h);
        }
        fade.raise();
        fade.setAttribute2(wa.WA_TransparentForMouseEvents, true);

        g_window = self;
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
                const i = @min(@max(@as(usize, @intCast(idx)), 0), screens.len - 1);
                const geo = screens[i].geometry();
                qt.QCursor.setPos(geo.x() + @divTrunc(geo.width(), 2), geo.y() + @divTrunc(geo.height(), 2));
                self.widget.setGeometry(geo.x(), geo.y(), geo.width(), geo.height());
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
