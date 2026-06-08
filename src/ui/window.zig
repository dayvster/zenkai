const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");

const List = @import("list.zig").List;
const ListItem = @import("list.zig").ListItem;
const Keyboard = @import("keyboard.zig").Keyboard;
const BottomBar = @import("bottombar.zig").BottomBar;

const QApp = qt.QApplication;
const QWidget = qt.QWidget;
const QVBoxLayout = qt.QVBoxLayout;
const QLineEdit = qt.QLineEdit;
const QCloseEvent = qt.QCloseEvent;
const QTimer = qt.QTimer;

var g_window: *Window = undefined;
var g_search_text: [256]u8 = undefined;
var g_search_text_len: usize = 0;

fn onSearchTextChanged(_: QLineEdit, text_cstr: [*:0]const u8) callconv(.c) void {
    const text = std.mem.span(text_cstr);
    const len = @min(text.len, g_search_text.len);
    @memcpy(g_search_text[0..len], text[0..len]);
    g_search_text_len = len;
    if (g_window.debounce_timer) |timer| {
        timer.Stop();
        timer.Start(150);
    }
}

fn onDebounceTimeout(_: QTimer) callconv(.c) void {
    const text = g_search_text[0..g_search_text_len];
    g_window.list.setFilter(text);
}

fn onWindowClose(_: QWidget, _: QCloseEvent) callconv(.c) void {
    QApp.Quit();
}

pub const Window = struct {
    allocator: std.mem.Allocator,
    widget: QWidget,
    search_bar: QLineEdit,
    list: List,
    bottom_bar: ?BottomBar,
    debounce_timer: ?QTimer,

    pub fn init(
        self: *Window,
        allocator: std.mem.Allocator,
        items: []const ListItem,
        vis: config.VisualConfig,
        no_bottom_bar: bool,
        no_icons: bool,
    ) void {
        List.setNoIcons(no_icons);

        const win_w: i32 = @max(vis.window_width, 200);
        const win_h: i32 = @max(vis.window_height, 200);

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
        main_layout.SetContentsMargins(vis.layout_margin, vis.layout_margin, vis.layout_margin, vis.layout_margin);
        main_layout.SetSpacing(vis.layout_spacing);

        var search_bar = QLineEdit.New2();
        search_bar.SetObjectName("searchbarInput");
        search_bar.SetPlaceholderText("Search apps...");
        search_bar.SetClearButtonEnabled(false);

        var list = List.fromItems(allocator, items, vis.icon_size);
        list.setFilter("");

        main_layout.AddWidget(search_bar);
        main_layout.AddWidget(list.view);

        var debounce_timer = QTimer.New2(window);
        debounce_timer.SetSingleShot(true);
        debounce_timer.OnTimeout(onDebounceTimeout);

        self.* = .{
            .allocator = allocator,
            .widget = window,
            .search_bar = search_bar,
            .list = list,
            .bottom_bar = null,
            .debounce_timer = debounce_timer,
        };

        if (!no_bottom_bar) {
            var bar = BottomBar.init(allocator, window, vis);
            bar.setup(&self.list);
            bar.setDefaultActions();
            main_layout.AddWidget(bar.container);
            self.bottom_bar = bar;
        }

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

        g_window = self;

        window.OnCloseEvent(onWindowClose);
        search_bar.OnTextChanged(onSearchTextChanged);
        Keyboard.setup(window, &self.list);
    }

    pub fn show(self: *Window) void {
        self.widget.Show();
    }

    pub fn exec() void {
        _ = QApp.Exec();
    }

    pub fn deinit(self: *Window) void {
        self.list.deinit();
        if (self.bottom_bar) |*bar| bar.deinit();
        if (self.debounce_timer) |timer| timer.Delete();
        self.search_bar.Delete();
        self.widget.Delete();
    }
};
