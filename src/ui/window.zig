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

fn onSearchDebounced(text: []const u8) void {
    g_window.list.setFilter(text);
}

fn onWindowClose(_: QWidget, _: QCloseEvent) callconv(.c) void {
    QApp.Quit();
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
        fade.SetAttribute2(qt.qnamespace_enums.WidgetAttribute.WA_TransparentForMouseEvents, true);

        g_window = self;

        window.OnCloseEvent(onWindowClose);
        Keyboard.setup(window, &self.list);
    }

    pub fn show(self: *Window) void {
        self.widget.Show();
    }

    pub fn exec() void {
        _ = QApp.Exec();
    }

    pub fn deinit(self: *Window) void {
        self.search_bar.deinit();
        self.list.deinit();
        if (self.bottom_bar) |*bar| bar.deinit();
        self.widget.Delete();
    }
};
