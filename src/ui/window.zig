const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");

const List = @import("list.zig").List;
const ListItem = @import("list.zig").ListItem;
const Keyboard = @import("keyboard.zig").Keyboard;
const BottomBar = @import("bottombar.zig").BottomBar;
const SearchBar = @import("search_bar.zig").SearchBar;

const QApp = qt.QApplication;
const QWidget = qt.QWidget;
const QVBoxLayout = qt.QVBoxLayout;
const QCloseEvent = qt.QCloseEvent;

var g_window: *Window = undefined;
var g_close_on_focus_out: bool = false;
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
            g_blur_timer.Start(200);
        }
    } else if (state == 4) {
        g_blur_timer.Stop();
    }
}

fn onLeaveWidget(_: QWidget, _: qt.QEvent) callconv(.c) void {
    g_mouse_left_at = nanoTimestamp();
}

fn onBlurTimerTimeout(_: qt.QTimer) callconv(.c) void {
    QApp.Quit();
}

fn onBackdropClick(_: qt.QWidget, _: qt.QMouseEvent) callconv(.c) void {
    QApp.Quit();
}

fn onBackdropMove(_: qt.QWidget, _: qt.QMoveEvent) callconv(.c) void {
    if (g_backdrop) |bd| {
        bd.SetGeometry(g_backdrop_geo[0], g_backdrop_geo[1], g_backdrop_geo[2], g_backdrop_geo[3]);
    }
}

fn onSearchDebounced(text: []const u8) void {
    g_window.list.setFilter(text);
}

fn onWindowClose(_: QWidget, _: QCloseEvent) callconv(.c) void {
    QApp.Quit();
}

fn closeBackdrop() void {
    if (g_backdrop) |bd| {
        bd.Delete();
        g_backdrop = null;
    }
}

pub const Window = struct {
    allocator: std.mem.Allocator,
    widget: QWidget,
    search_bar: SearchBar,
    list: List,
    bottom_bar: ?BottomBar,

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

        const cursor_pos = qt.QCursor.Pos();
        const screen_rect = QApp.ScreenAt(cursor_pos).Geometry();
        const screen_w = screen_rect.Width();
        const screen_h = screen_rect.Height();

        if (vis.show_backdrop) {
            const bd = QWidget.New2();
            bd.SetWindowTitle("zenkai-backdrop");
            bd.SetWindowFlags(
                wt.Tool |
                    wt.FramelessWindowHint |
                    wt.BypassWindowManagerHint |
                    wt.NoDropShadowWindowHint |
                    wt.WindowDoesNotAcceptFocus |
                    wt.WindowStaysOnBottomHint,
            );
            bd.SetAttribute2(qt.qnamespace_enums.WidgetAttribute.WA_TranslucentBackground, true);
            bd.SetAttribute2(qt.qnamespace_enums.WidgetAttribute.WA_NoSystemBackground, true);

            g_backdrop_geo = .{ screen_rect.X(), screen_rect.Y(), screen_w, screen_h };
            bd.SetGeometry(g_backdrop_geo[0], g_backdrop_geo[1], g_backdrop_geo[2], g_backdrop_geo[3]);
            bd.SetFixedSize2(screen_w, screen_h);
            bd.OnMousePressEvent(onBackdropClick);
            bd.OnMoveEvent(onBackdropMove);
            g_backdrop = bd;
            bd.Show();
        }

        var window = QWidget.New2();
        window.SetWindowTitle("zenkai");
        window.SetWindowFlags(
            wt.Tool |
                wt.FramelessWindowHint |
                wt.WindowStaysOnTopHint |
                wt.NoDropShadowWindowHint,
        );

        const main_layout = QVBoxLayout.New(window);
        main_layout.SetContentsMargins(vis.layout_margin, vis.layout_margin, vis.layout_margin, vis.layout_margin);
        main_layout.SetSpacing(vis.layout_spacing);

        var search_bar = SearchBar.init(window, 150);
        search_bar.on_debounced = onSearchDebounced;

        var list = List.fromItems(allocator, items, vis.icon_size);
        list.adoptGList();
        list.setFilter("");

        main_layout.AddWidget(search_bar.widget);
        main_layout.AddWidget(list.view);

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
            main_layout.AddWidget(self.bottom_bar.?.container);
        }

        window.SetMinimumSize2(win_w, win_h);
        window.SetMaximumSize2(win_w, win_h);

        window.SetGeometry(
            @divTrunc(screen_w - win_w, 2),
            @divTrunc(screen_h - win_h, 2),
            win_w,
            win_h,
        );

        const wa = qt.qnamespace_enums.WidgetAttribute;
        const fade_h: i32 = 40;
        var fade = QWidget.New(window);
        fade.SetObjectName("listFade");
        fade.SetFixedHeight(fade_h);
        if (no_bottom_bar) {
            fade.SetGeometry(0, win_h - fade_h, win_w, fade_h);
        } else {
            fade.SetGeometry(vis.layout_margin, win_h - vis.layout_margin - 28 - fade_h, win_w - 2 * vis.layout_margin, fade_h);
        }
        fade.Raise();
        fade.SetAttribute2(wa.WA_TransparentForMouseEvents, true);

        g_window = self;
        g_close_on_focus_out = vis.close_on_focus_out;
        g_mouse_left_at = nanoTimestamp();
        g_blur_timer = qt.QTimer.New();
        g_blur_timer.OnTimeout(onBlurTimerTimeout);

        window.OnCloseEvent(onWindowClose);
        window.OnLeaveEvent(onLeaveWidget);
        app.OnApplicationStateChanged(onAppStateChanged);
        Keyboard.setup(window, &self.list, self.search_bar.widget);
    }

    pub fn show(self: *Window) void {
        self.widget.Show();
        self.widget.Raise();
    }

    pub fn exec() void {
        _ = QApp.Exec();
    }

    pub fn deinit(self: *Window) void {
        g_blur_timer.Stop();
        g_blur_timer.Delete();
        closeBackdrop();
        self.search_bar.deinit();
        self.list.deinit();
        if (self.bottom_bar) |*bar| bar.deinit();
        self.widget.Delete();
    }
};
